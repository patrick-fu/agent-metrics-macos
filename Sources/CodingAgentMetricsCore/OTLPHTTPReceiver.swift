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

    private let queue = DispatchQueue(label: "dev.codingagentmetrics.otlp-receiver")
    private let consume: @Sendable ([PerformanceFact]) throws -> Void
    private let stateLock = NSLock()
    private var stateStorage: OTLPReceiverState = .stopped
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var pendingStartup: PendingStartup?

    public init(
        configuration: OTLPReceiverConfiguration,
        consume: @escaping @Sendable ([PerformanceFact]) throws -> Void
    ) {
        self.configuration = configuration
        self.consume = consume
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
        let startup = StartupSignal()
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let listener else { connection.cancel(); return }
            self?.receive(connection, from: listener, buffered: Data())
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            self.handle(listener: listener, stateUpdate: state, startup: startup)
        }
        let shouldStart = withStateLock { () -> Bool in
            guard self.listener == nil else { return false }
            self.listener = listener
            stateStorage = .starting
            pendingStartup = PendingStartup(listener: listener, signal: startup)
            return true
        }
        guard shouldStart else { return }
        guard withStateLock({ self.listener === listener }) else { throw OTLPHTTPReceiverError.startupCancelled }
        listener.start(queue: queue)
        guard startup.wait(timeout: .now() + 1) == .success else {
            let shouldCancel = withStateLock { () -> Bool in
                guard self.listener === listener else { return false }
                self.listener = nil
                stateStorage = .failed("Timed out starting the local receiver.")
                clearPendingStartup(for: listener)
                return true
            }
            if shouldCancel { listener.cancel() }
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
        let resources = withStateLock { () -> (NWListener?, [NWConnection], StartupSignal?) in
            let activeListener = listener
            let activeConnections = Array(connections.values)
            let startup = pendingStartup?.signal
            listener = nil
            connections.removeAll()
            pendingStartup = nil
            stateStorage = .stopped
            return (activeListener, activeConnections, startup)
        }
        resources.0?.cancel()
        resources.1.forEach { $0.cancel() }
        resources.2?.signal()
    }

    private func receive(_ connection: NWConnection, from owner: NWListener, buffered: Data) {
        let accepted = withStateLock { () -> Bool in
            guard listener === owner else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
        guard accepted else { connection.cancel(); return }
        connection.start(queue: queue)
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

    private func handle(listener candidate: NWListener, stateUpdate: NWListener.State, startup: StartupSignal) {
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
                stateStorage = .failed(String(describing: error))
                clearPendingStartup(for: candidate)
                return true
            }
            if isCurrent { candidate.cancel() }
            startup.signal()
        case .cancelled:
            _ = withStateLock {
                guard listener === candidate else { return false }
                listener = nil
                stateStorage = .stopped
                clearPendingStartup(for: candidate)
                return true
            }
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
}

private struct PendingStartup {
    let listenerID: ObjectIdentifier
    let signal: StartupSignal

    init(listener: NWListener, signal: StartupSignal) {
        listenerID = ObjectIdentifier(listener)
        self.signal = signal
    }
}

private final class StartupSignal: @unchecked Sendable {
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
}
