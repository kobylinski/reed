import Foundation
import Network

/// Minimal one-shot HTTP listener on IPv4 loopback to capture an OAuth redirect.
/// Used by the in-app credential registration, whose SoundCloud client expects a
/// `http://127.0.0.1:8765/callback` redirect.
final class LoopbackServer {
    private let port: UInt16
    private var listener: NWListener?
    private var completion: ((Result<[String: String], Error>) -> Void)?

    init(port: UInt16) { self.port = port }

    func start(completion: @escaping (Result<[String: String], Error>) -> Void) throws {
        self.completion = completion
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Pin to IPv4 127.0.0.1 so it matches the registered redirect exactly.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                           port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let request = String(data: data, encoding: .utf8) {
                let params = Self.parseQuery(requestLine: request)
                let body = """
                <html><head><meta charset="utf-8"></head>
                <body style="font-family:-apple-system,system-ui;text-align:center;padding-top:64px;color:#333">
                <h2>Reed</h2><p>Connected. You can close this window and return to the app.</p></body></html>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
                self.finish(.success(params))
            } else if let error {
                self.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        completion?(result)
        completion = nil
        listener?.cancel()
        listener = nil
    }

    private static func parseQuery(requestLine request: String) -> [String: String] {
        guard let firstLine = request.split(separator: "\r\n").first else { return [:] }
        let tokens = firstLine.split(separator: " ")
        guard tokens.count >= 2, let query = tokens[1].split(separator: "?").dropFirst().first else { return [:] }
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            result[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
        }
        return result
    }
}
