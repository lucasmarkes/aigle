import AppKit
import SafariServices
import os.log

/// Native messaging bridge for the embedded Safari Web Extension.
///
/// The extension sends `{ action: "save", url: …, pageUrl: …, type: … }`.
/// Because the app extension lives in its own sandbox we hand the payload to
/// the main app through its `aigle://save` URL scheme, which requires no
/// app group (and therefore no paid developer team) to work.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let log = Logger(subsystem: "cool.aigle.Aigle.Safari", category: "handler")

    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        let message = Self.message(from: context)

        if let message, (message["action"] as? String) ?? "save" == "save" {
            if let deepLink = Self.deepLink(from: message) {
                NSWorkspace.shared.open(deepLink)
                response.userInfo = [SFExtensionMessageKey: ["ok": true]]
            } else {
                response.userInfo = [SFExtensionMessageKey: ["ok": false, "error": "missing url"]]
            }
        } else {
            response.userInfo = [SFExtensionMessageKey: ["ok": false, "error": "unknown action"]]
        }

        context.completeRequest(returningItems: [response])
    }

    private static func message(from context: NSExtensionContext) -> [String: Any]? {
        guard let item = context.inputItems.first as? NSExtensionItem else { return nil }
        return item.userInfo?[SFExtensionMessageKey] as? [String: Any]
    }

    static func deepLink(from message: [String: Any]) -> URL? {
        guard let raw = message["url"] as? String, !raw.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "aigle"
        components.host = "save"
        var query = [URLQueryItem(name: "url", value: raw)]
        if let page = message["pageUrl"] as? String { query.append(URLQueryItem(name: "pageUrl", value: page)) }
        if let type = message["type"] as? String { query.append(URLQueryItem(name: "type", value: type)) }
        if let title = message["title"] as? String { query.append(URLQueryItem(name: "title", value: title)) }
        components.queryItems = query
        return components.url
    }
}
