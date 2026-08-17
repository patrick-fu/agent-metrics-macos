import Foundation
import Network

/// An opt-in, local-only OTLP/HTTP receiver.  It never reads or writes agent
/// configuration; callers must configure their own exporter to use it.
public final class OTLPHTTPReceiver: @unchecked Sendable {
    public let configuration: OTLPReceiverConfiguration
    public var state: OTLPReceiverState { withStateLock { stateStorage } }
    public var isRunning: Bool { if case .running = state { return true }; return false }
    public var boundPort: UInt16? { isRunning ? configuration.port : nil }
    public var endpoint: URL { configuration.endpoint }

    private let listenerQueueKey = DispatchSpecificKey<UInt8>()
    private let listenerQueue: DispatchQueue
    private let connectionQueue: DispatchQueue
    private let consume: @Sendable ([PerformanceFact]) throws -> Void
    private let stateLock = NSLock()
    private var stateStorage: OTLPReceiverState = .stopped
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var pendingStartup: PendingLifecycle?
    private var pendingRelease: PendingLifecycle?
    private var startedListener: NWListener?
    private var skippedReleaseWaitOnListenerQueue = false
    private var startAdoptionBarrierForTesting: (@Sendable () -> Void)?
    private var releaseWaitBarrierForTesting: (@Sendable () -> Void)?

    public init(
        configuration: OTLPReceiverConfiguration,
        consume: @escaping @Sendable ([PerformanceFact]) throws -> Void
    ) {
        self.configuration = configuration
        self.consume = consume
        let listenerQueue = DispatchQueue(label: "dev.codingagentmetrics.otlp-receiver.listener")
        listenerQueue.setSpecific(key: listenerQueueKey, value: 1)
        self.listenerQueue = listenerQueue
        self.connectionQueue = DispatchQueue(label: "dev.codingagentmetrics.otlp-receiver.connection")
    }

    deinit { stop() }

    public func start() throws {
        guard configuration.isEnabled else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port) ?? .any
        )
        let listener = try NWListener(using: parameters)
        let startup = LifecycleSignal()
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener else { connection.cancel(); return }
            self.connectionQueue.async {
                self.receive(connection, from: listener, buffered: Data())
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            self.handle(listener: listener, stateUpdate: state, startup: startup)
        }
        startAdoptionBarrierForTesting?()
        enum Adoption {
            case adopted
            case alreadyRunning
            case blocked(OTLPHTTPReceiverError)
        }
        let adoption = withStateLock { () -> Adoption in
            if let blocked = startBlockedReasonLocked() { return .blocked(blocked) }
            guard self.listener == nil else { return .alreadyRunning }
            self.listener = listener
            stateStorage = .starting
            pendingStartup = PendingLifecycle(listener: listener, signal: startup)
            startedListener = listener
            listener.start(queue: listenerQueue)
            return .adopted
        }
        switch adoption {
        case .alreadyRunning:
            listener.cancel()
            return
        case let .blocked(error):
            listener.cancel()
            throw error
        case .adopted:
            break
        }
        guard startup.wait(timeout: .now() + 1) == .success else {
            let release = withStateLock { () -> LifecycleSignal? in
                guard self.listener === listener else { return nil }
                self.listener = nil
                startedListener = nil
                stateStorage = .failed("Timed out starting the local receiver.")
                clearPendingStartup(for: listener)
                return installReleaseLocked(for: listener)
            }
            if release != nil { listener.cancel() }
            waitForRelease(release)
            throw OTLPHTTPReceiverError.startupTimedOut
        }
        let finalState = withStateLock { () -> OTLPReceiverState in
            clearPendingStartup(for: listener)
            guard self.listener === listener else { return stateStorage }
            return stateStorage
        }
        if case .running = finalState { return }
        if case let .failed(message) = finalState { throw OTLPHTTPReceiverError.listenerFailed(message) }
        throw OTLPHTTPReceiverError.startupCancelled
    }

    public func stop() {
        let resources = withStateLock { () -> (NWListener?, [NWConnection], LifecycleSignal?, LifecycleSignal?) in
            let activeListener = listener
            let activeConnections = Array(connections.values)
            let startup = pendingStartup?.signal
            let release: LifecycleSignal?
            if let activeListener, startedListener === activeListener {
                release = installReleaseLocked(for: activeListener)
            } else {
                release = nil
            }
            listener = nil
            connections.removeAll()
            pendingStartup = nil
            startedListener = nil
            stateStorage = .stopped
            return (activeListener, activeConnections, startup, release)
        }
        if resources.3 != nil { releaseWaitBarrierForTesting?() }
        resources.0?.cancel()
        resources.1.forEach { $0.cancel() }
        resources.2?.signal()
        waitForRelease(resources.3)
    }

    func setStartAdoptionBarrierForTesting(_ barrier: (@Sendable () -> Void)?) {
        startAdoptionBarrierForTesting = barrier
    }

    func setReleaseWaitBarrierForTesting(_ barrier: (@Sendable () -> Void)?) {
        releaseWaitBarrierForTesting = barrier
    }

    func hasPendingReleaseForTesting() -> Bool {
        withStateLock { pendingRelease != nil }
    }

    /// Test seam: force the release-timeout fail-closed path without a live bind.
    func simulateUnsignaledReleaseTimeoutForTesting() {
        let signal = LifecycleSignal()
        withStateLock {
            pendingRelease = PendingLifecycle(listenerID: ObjectIdentifier(self), signal: signal)
        }
        waitForRelease(signal, timeout: .now())
    }

    private func receive(_ connection: NWConnection, from owner: NWListener, buffered: Data) {
        let accepted = withStateLock { () -> Bool in
            guard listener === owner else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
        guard accepted else { connection.cancel(); return }
        connection.start(queue: connectionQueue)
        receiveNext(connection, buffered: buffered)
    }

    private func receiveNext(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            guard let self else { return }
            var bytes = buffered
            if let data { bytes.append(data) }
            if bytes.count > 1_048_576 {
                self.respond(connection, status: "413 Payload Too Large")
            } else if let request = HTTPRequest(bytes: bytes) {
                self.handle(request, connection: connection)
            } else if complete || error != nil {
                self.respond(connection, status: "400 Bad Request")
            } else {
                self.receiveNext(connection, buffered: bytes)
            }
        }
    }

    private func handle(_ request: HTTPRequest, connection: NWConnection) {
        guard request.method == "POST", request.path == "/v1/traces", request.contentType == "application/json" else {
            respond(connection, status: "404 Not Found")
            return
        }
        let result = OTLPHTTPJSONDecoder().decode(request.body, receivedAt: Date())
        guard result.diagnostics.isEmpty else {
            respond(connection, status: "400 Bad Request")
            return
        }
        do {
            try consume(result.facts)
            respond(connection, status: "200 OK")
        } catch {
            respond(connection, status: "500 Internal Server Error")
        }
    }

    private func respond(_ connection: NWConnection, status: String) {
        connection.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            guard let self else { return }
            _ = self.withStateLock { self.connections.removeValue(forKey: ObjectIdentifier(connection)) }
        })
    }

    private func handle(listener candidate: NWListener, stateUpdate: NWListener.State, startup: LifecycleSignal) {
        switch stateUpdate {
        case .ready:
            let isCurrent = withStateLock { () -> Bool in
                guard listener === candidate else { return false }
                stateStorage = .running
                clearPendingStartup(for: candidate)
                return true
            }
            _ = isCurrent
            startup.signal()
        case let .failed(error):
            let isCurrent = withStateLock { () -> Bool in
                guard listener === candidate else { return false }
                listener = nil
                if startedListener === candidate { startedListener = nil }
                stateStorage = .failed(String(describing: error))
                clearPendingStartup(for: candidate)
                return true
            }
            if isCurrent { candidate.cancel() }
            signalRelease(for: candidate)
            startup.signal()
        case .cancelled:
            _ = withStateLock {
                guard listener === candidate else { return false }
                listener = nil
                if startedListener === candidate { startedListener = nil }
                stateStorage = .stopped
                clearPendingStartup(for: candidate)
                return true
            }
            signalRelease(for: candidate)
            startup.signal()
        default:
            break
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func clearPendingStartup(for listener: NWListener) {
        guard pendingStartup?.listenerID == ObjectIdentifier(listener) else { return }
        pendingStartup = nil
    }

    private func installReleaseLocked(for listener: NWListener) -> LifecycleSignal {
        if let pending = pendingRelease, pending.listenerID == ObjectIdentifier(listener) {
            return pending.signal
        }
        let signal = LifecycleSignal()
        pendingRelease = PendingLifecycle(listener: listener, signal: signal)
        return signal
    }

    private func signalRelease(for candidate: NWListener) {
        let signal = withStateLock { () -> LifecycleSignal? in
            guard pendingRelease?.listenerID == ObjectIdentifier(candidate) else { return nil }
            let signal = pendingRelease?.signal
            pendingRelease = nil
            if case .failed = stateStorage, listener == nil {
                stateStorage = .stopped
            }
            return signal
        }
        signal?.signal()
    }

    private func startBlockedReasonLocked() -> OTLPHTTPReceiverError? {
        if pendingRelease != nil || skippedReleaseWaitOnListenerQueue {
            return .portReleasePending
        }
        return nil
    }

    private func waitForRelease(_ signal: LifecycleSignal?, timeout: DispatchTime = .now() + 1) {
        guard let signal else { return }
        // Public stop() waits for listener terminal off this queue so release is observable.
        // deinit/re-entrant stop on the listener queue must not wait on itself; the instance
        // is then invalid and start() fail-closes instead of rebinding.
        if DispatchQueue.getSpecific(key: listenerQueueKey) != nil {
            withStateLock { skippedReleaseWaitOnListenerQueue = true }
            return
        }
        switch signal.wait(timeout: timeout) {
        case .success:
            withStateLock {
                if pendingRelease?.signal === signal { pendingRelease = nil }
            }
        case .timedOut:
            withStateLock {
                stateStorage = .failed("Timed out releasing the local receiver.")
            }
        }
    }
}

private struct PendingLifecycle {
    let listenerID: ObjectIdentifier
    let signal: LifecycleSignal

    init(listener: NWListener, signal: LifecycleSignal) {
        self.init(listenerID: ObjectIdentifier(listener), signal: signal)
    }

    init(listenerID: ObjectIdentifier, signal: LifecycleSignal) {
        self.listenerID = listenerID
        self.signal = signal
    }
}

private final class LifecycleSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didSignal = false

    func signal() {
        lock.lock()
        defer { lock.unlock() }
        guard !didSignal else { return }
        didSignal = true
        semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var contentType: String
    var body: Data

    init?(bytes: Data) {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = bytes.range(of: delimiter),
              let header = String(data: bytes[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first?.split(separator: " "), requestLine.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { return nil }
            headers[String(pieces[0]).lowercased()] = String(pieces[1]).trimmingCharacters(in: .whitespaces)
        }
        guard let contentLength = headers["content-length"].flatMap(Int.init), contentLength >= 0 else { return nil }
        let bodyStart = range.upperBound
        guard bytes.distance(from: bodyStart, to: bytes.endIndex) >= contentLength else { return nil }
        self.method = String(requestLine[0])
        self.path = String(requestLine[1])
        self.contentType = headers["content-type"]?.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        self.body = bytes.subdata(in: bodyStart..<(bodyStart + contentLength))
    }
}

public enum OTLPReceiverState: Sendable, Equatable {
    case stopped
    case starting
    case running
    case failed(String)
}

public enum OTLPHTTPReceiverError: Error, Sendable, Equatable {
    case startupTimedOut
    case startupCancelled
    case listenerFailed(String)
    case portReleasePending
}
