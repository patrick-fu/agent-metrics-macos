import Foundation
import Network

/// An opt-in, local-only OTLP/HTTP receiver.  It never reads or writes agent
/// configuration; callers must configure their own exporter to use it.
public final class OTLPHTTPReceiver: @unchecked Sendable {
    public let configuration: OTLPReceiverConfiguration
    public private(set) var isRunning = false
    public private(set) var boundPort: UInt16?

    private let queue = DispatchQueue(label: "dev.codingagentmetrics.otlp-receiver")
    private let consume: @Sendable ([PerformanceFact]) -> Void
    private var listener: NWListener?

    public init(
        configuration: OTLPReceiverConfiguration,
        consume: @escaping @Sendable ([PerformanceFact]) -> Void
    ) {
        self.configuration = configuration
        self.consume = consume
    }

    deinit { stop() }

    public func start() throws {
        guard configuration.isEnabled, listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port) ?? .any
        )
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.receive(connection, buffered: Data()) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .ready = state else { return }
            self?.isRunning = true
            self?.boundPort = listener?.port?.rawValue
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        boundPort = nil
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
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
        consume(result.facts)
        respond(connection, status: "200 OK")
    }

    private func respond(_ connection: NWConnection, status: String) {
        connection.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
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
        self.contentType = headers["content-type"]?.lowercased() ?? ""
        self.body = bytes.subdata(in: bodyStart..<(bodyStart + contentLength))
    }
}
