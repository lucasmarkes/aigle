import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os.log

/// Turns anything the system can hand us — Finder files, browser image drags
/// (which arrive as promises or raw data), URLs, pasted images — into library
/// items. Drag & drop is a fundamental in Aigle, so this is deliberately broad.
@MainActor
public enum DropImporter {
    nonisolated static let log = Logger(subsystem: "cool.aigle.Aigle", category: "drop")

    public static let acceptedTypes: [UTType] = [
        .fileURL, .url, .plainText,
        .image, .png, .jpeg, .tiff, .gif, .pdf, .svg,
        .movie, .video, .quickTimeMovie, .mpeg4Movie, .audiovisualContent, .audio,
        // Catch-all, deliberately last: recorders and screenshot tools (CleanShot
        // X, Finder promises, browser downloads) hand over a promise that only
        // advertises its own concrete type. Accept anything file-shaped here and
        // let the importer decide what it can actually use.
        .data,
    ]

    public static func handleDrop(
        providers: [NSItemProvider],
        into collectionID: String?,
        controller: LibraryController
    ) -> Bool {
        guard !providers.isEmpty else { return false }
        Task { await ingest(providers: providers, into: collectionID, controller: controller) }
        return true
    }

    static func ingest(providers: [NSItemProvider], into collectionID: String?, controller: LibraryController) async {
        var fileURLs: [URL] = []
        var webURLs: [URL] = []
        var staged: [URL] = []
        var unhandled: [NSItemProvider] = []

        for provider in providers {
            if let url = await loadFileURL(provider) {
                fileURLs.append(url)
                continue
            }
            // Promise-backed drags — a screen recorder handing over a clip it
            // just finished writing, a Finder file promise, a browser download.
            // These advertise no file URL at all, so the bytes have to be pulled
            // out of the provider and staged before anything can import them.
            if let url = await loadPromisedFile(provider) {
                staged.append(url)
                fileURLs.append(url)
                continue
            }
            if let url = await loadMediaData(provider) {
                staged.append(url)
                fileURLs.append(url)
                continue
            }
            if let data = await loadImageData(provider) {
                controller.importImageData(
                    data.bytes,
                    name: data.name,
                    ext: data.ext,
                    into: collectionID
                )
                continue
            }
            if let url = await loadWebURL(provider) {
                webURLs.append(url)
                continue
            }
            unhandled.append(provider)
        }

        if !fileURLs.isEmpty {
            // A URL that arrives on a drag is security-scoped like any other the
            // app didn't open itself, and the scope has to outlive the copy into
            // the library — which is why the import is awaited rather than
            // fired and forgotten.
            let scopes = fileURLs.map { ($0, $0.startAccessingSecurityScopedResource()) }
            await controller.importFiles(fileURLs, into: collectionID).value
            for (url, started) in scopes where started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        discardStaged(staged)

        for url in webURLs {
            if isDirectMedia(url) {
                controller.importRemoteMedia(url, into: collectionID)
            } else {
                controller.importLink(url, into: collectionID)
            }
        }

        if fileURLs.isEmpty, webURLs.isEmpty, !unhandled.isEmpty {
            let identifiers = unhandled.flatMap(\.registeredTypeIdentifiers)
            log.error("Drop produced nothing importable; types: \(identifiers.joined(separator: ", "), privacy: .public)")
            controller.showStatus(String(localized: "Aigle couldn’t read anything from that drop."))
        }
    }

    static func isDirectMedia(_ url: URL) -> Bool {
        ItemKind.importableExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Provider adapters

    static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    /// Type identifiers on the provider that describe a file's contents, rather
    /// than a link or a scrap of text.
    static func fileTypeIdentifiers(of provider: NSItemProvider) -> [String] {
        provider.registeredTypeIdentifiers.filter { identifier in
            guard let type = UTType(identifier) else { return false }
            // `.fileURL` conforms to `.url`, and both are handled elsewhere.
            if type.conforms(to: .url) || type.conforms(to: .text) { return false }
            return true
        }
    }

    /// Materialises a promised file. The provider writes it somewhere temporary
    /// and deletes it the moment the completion handler returns, so the bytes are
    /// copied into Aigle's own staging folder inside the callback.
    static func loadPromisedFile(_ provider: NSItemProvider) async -> URL? {
        for identifier in fileTypeIdentifiers(of: provider) {
            let staged: URL? = await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                    continuation.resume(returning: url.flatMap(stage))
                }
            }
            if let staged { return staged }
        }
        return nil
    }

    /// Fallback for providers that carry bytes but no file representation: write
    /// the data out under the extension its type implies.
    static func loadMediaData(_ provider: NSItemProvider) async -> URL? {
        for identifier in fileTypeIdentifiers(of: provider) {
            guard let type = UTType(identifier),
                  let ext = type.preferredFilenameExtension?.lowercased(),
                  ItemKind.importableExtensions.contains(ext)
            else { continue }
            let data: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            guard let data, !data.isEmpty else { continue }
            let name = provider.suggestedName.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
            } ?? "Dropped \(timestamp())"
            if let staged = stage(data, name: name, ext: ext) { return staged }
        }
        return nil
    }

    // MARK: - Staging

    nonisolated static var stagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "aigle-drop-staging", directoryHint: .isDirectory)
    }

    /// Copies a soon-to-vanish file somewhere Aigle controls. Called from
    /// provider callbacks, so it stays off the main actor.
    nonisolated static func stage(_ url: URL) -> URL? {
        let directory = stagingRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    nonisolated static func stage(_ data: Data, name: String, ext: String) -> URL? {
        let directory = stagingRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeName = name.isEmpty ? "Dropped" : name
            let destination = directory.appending(path: "\(safeName).\(ext)")
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    nonisolated static func discardStaged(_ urls: [URL]) {
        for url in urls {
            // Each staged file lives in its own UUID folder; remove the folder.
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    static func loadWebURL(_ provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url?.isFileURL == false ? url : nil)
                }
            }
            if let url { return url }
        }
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else { return nil }
        let text: String? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        guard let text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true
        else { return nil }
        return url
    }

    struct DroppedImage: Sendable {
        var bytes: Data
        var name: String
        var ext: String
    }

    static func loadImageData(_ provider: NSItemProvider) async -> DroppedImage? {
        let candidates: [(UTType, String)] = [(.png, "png"), (.jpeg, "jpg"), (.gif, "gif"), (.tiff, "tiff"), (.pdf, "pdf")]
        for (type, ext) in candidates where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            guard let data, !data.isEmpty else { continue }
            let name = provider.suggestedName.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                ?? "Dropped \(Self.timestamp())"
            return DroppedImage(bytes: data, name: name, ext: ext)
        }
        return nil
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    // MARK: - Paste

    /// Handles ⌘V from anywhere in the app.
    public static func paste(into collectionID: String?, controller: LibraryController) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let files = urls.filter(\.isFileURL)
            let web = urls.filter { !$0.isFileURL }
            if !files.isEmpty { controller.importFiles(files, into: collectionID) }
            for url in web {
                isDirectMedia(url)
                    ? controller.importRemoteMedia(url, into: collectionID)
                    : controller.importLink(url, into: collectionID)
            }
            if !files.isEmpty || !web.isEmpty { return }
        }
        if let text = pasteboard.string(forType: .string),
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme?.hasPrefix("http") == true {
            isDirectMedia(url)
                ? controller.importRemoteMedia(url, into: collectionID)
                : controller.importLink(url, into: collectionID)
            return
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type) else { continue }
            let ext = type == .png ? "png" : "tiff"
            controller.importImageData(data, name: "Pasted \(timestamp())", ext: ext, into: collectionID)
            return
        }
    }
}
