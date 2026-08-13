import Foundation
import Network
import Observation
import os.log

/// Localhost-only HTTP endpoint the Chrome extension posts to.
///
/// Off by default; bound to 127.0.0.1 and gated by a random token shown in
/// Settings, so nothing on the network can talk to it.
@MainActor
@Observable
public final class ExtensionServer {
    public enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    public private(set) var state: State = .stopped
    public private(set) var lastRequestDescription: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let log = Logger(subsystem: "cool.aigle.Aigle", category: "server")
    @ObservationIgnored public var onSave: ((SaveRequest) -> Void)?

    public struct SaveRequest: Sendable {
        public var url: URL
        public var pageURL: URL?
        public var type: String
        public var title: String
    }

    public init() {}

    public func start(port: Int, token: String) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            state = .failed(String(localized: "Invalid port."))
            return
        }
        state = .starting
        log.info("Starting extension server on 127.0.0.1:\(nwPort.rawValue, privacy: .public)")
        do {
            let parameters = NWParameters.tcp
            // Bind to 127.0.0.1 explicitly. `requiredInterfaceType = .loopback`
            // is not enough — that still binds the wildcard address. The port
            // travels in the endpoint, so `NWListener(using:on:)` must not be
            // used here (passing both is an EINVAL).
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    switch newState {
                    case .ready:
                        self?.log.info("Extension server ready")
                        self?.state = .running(port: nwPort.rawValue)
                    case .failed(let error):
                        self?.log.error("Listener failed: \(error.localizedDescription, privacy: .public)")
                        self?.state = .failed(error.localizedDescription)
                    case .cancelled: self?.state = .stopped
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.handle(connection: connection, token: token) }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            log.error("Listener could not be created: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    /// Brings the listener in line with the current preferences. Called at launch
    /// and whenever the toggle, port or token changes — the server must not
    /// depend on the Settings window ever being opened.
    public func sync(settings: AppSettings, controller: LibraryController) {
        onSave = { [weak controller] request in
            guard let controller else { return }
            switch request.type {
            case "image", "video":
                controller.importRemoteMedia(request.url, into: nil)
            default:
                controller.importLink(request.url, into: nil)
            }
        }
        guard settings.extensionServerEnabled else {
            log.info("Extension server disabled by preference")
            stop()
            return
        }
        start(port: settings.extensionPort, token: settings.extensionToken)
    }

    private func handle(connection: NWConnection, token: String) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, _, _ in
            guard let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                let response = self?.process(request: request, token: token) ?? Self.http(status: "500 Internal Server Error", body: "{}")
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func process(request: String, token: String) -> String {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return Self.http(status: "400 Bad Request", body: "{}") }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return Self.http(status: "400 Bad Request", body: "{}") }
        let method = String(parts[0])
        let path = String(parts[1])

        if method == "OPTIONS" {
            return Self.http(status: "204 No Content", body: "")
        }
        if method == "GET", path == "/ping" {
            return Self.http(status: "200 OK", body: #"{"ok":true,"app":"Aigle"}"#)
        }
        guard method == "POST", path == "/save" else {
            return Self.http(status: "404 Not Found", body: "{}")
        }

        let headerToken = lines.first { $0.lowercased().hasPrefix("x-aigle-token:") }?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces)
        guard headerToken == token else {
            return Self.http(status: "401 Unauthorized", body: #"{"error":"bad token"}"#)
        }

        guard let separator = request.range(of: "\r\n\r\n") else {
            return Self.http(status: "400 Bad Request", body: "{}")
        }
        let body = String(request[separator.upperBound...])
        guard let payload = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let raw = payload["url"] as? String,
              let url = URL(string: raw)
        else {
            return Self.http(status: "400 Bad Request", body: #"{"error":"missing url"}"#)
        }

        let save = SaveRequest(
            url: url,
            pageURL: (payload["pageUrl"] as? String).flatMap(URL.init(string:)),
            type: (payload["type"] as? String) ?? "image",
            title: (payload["title"] as? String) ?? ""
        )
        lastRequestDescription = url.absoluteString
        onSave?(save)
        return Self.http(status: "200 OK", body: #"{"ok":true}"#)
    }

    private static func http(status: String, body: String) -> String {
        """
        HTTP/1.1 \(status)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Headers: content-type, x-aigle-token\r
        Access-Control-Allow-Methods: POST, GET, OPTIONS\r
        Connection: close\r
        \r
        \(body)
        """
    }
}
