//
//  DocumentDropSupport.swift
//  ChatBot
//
//  Shared file-picker UTType allowlist and drop-provider resolver used
//  by both the dedicated Imports sheet and the in-chat "attach a
//  document" affordance. Lifting these out of `DocumentImportListView`
//  keeps the two surfaces in sync — adding a new file type only needs
//  changing one place.
//

import Foundation
import UniformTypeIdentifiers

enum DocumentDropSupport {

    /// UTI types accepted by both the file picker and the drop target.
    /// Markdown is registered as a `.plainText` subtype via a filename
    /// extension fallback so it works even when the system doesn't
    /// register a dedicated UTI for `.md`.
    static var acceptedContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .epub, .plainText]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        return types
    }

    /// Resolve a list of dropped `NSItemProvider`s to local file URLs in
    /// a tmp directory the importer can later read from. Each provider
    /// is queried for the first accepted type it conforms to; providers
    /// that surface no usable URL (e.g. plain-text drags rather than a
    /// file reference) are skipped silently.
    static func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadFileURL(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        for type in acceptedContentTypes
            where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    if let url, error == nil {
                        // The system gives us a temp URL that's reaped
                        // once this completion handler returns. Copy
                        // into our own tmp dir so the caller can safely
                        // import it later.
                        let dest = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension(url.pathExtension)
                        do {
                            try FileManager.default.copyItem(at: url, to: dest)
                            continuation.resume(returning: dest)
                        } catch {
                            continuation.resume(returning: nil)
                        }
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        return nil
    }
}
