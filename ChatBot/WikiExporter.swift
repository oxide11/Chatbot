//
//  WikiExporter.swift
//  ChatBot
//
//  Markdown export of the entire wiki as a folder of .md files —
//  `[[wikilinks]]` are preserved (the body already uses that syntax)
//  and each file gets a YAML frontmatter block with title, tags, and
//  timestamps. Output is compatible with Obsidian / Logseq vaults, so
//  the user can drop the exported folder straight in.
//
//  Drives `.fileExporter` from the wiki list "More" menu. The
//  document's `fileWrapper(configuration:)` returns a directory
//  wrapper, which `.fileExporter` writes as a folder via UTType.folder.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct WikiExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    static var writableContentTypes: [UTType] { [.folder] }

    let pages: [WikiPage]
    let conversationTitle: (UUID) -> String?
    let documentName: (UUID) -> String?

    init(
        pages: [WikiPage],
        conversationTitle: @escaping (UUID) -> String? = { _ in nil },
        documentName: @escaping (UUID) -> String? = { _ in nil }
    ) {
        self.pages = pages
        self.conversationTitle = conversationTitle
        self.documentName = documentName
    }

    /// Read path is unused — this document is export-only — but
    /// `FileDocument` requires the initialiser.
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var children: [String: FileWrapper] = [:]
        // Deduplicate filenames — two pages with the same slug (rare
        // but possible after capitalisation/punctuation normalisation)
        // would clobber each other otherwise. Append `-2`, `-3`, etc.
        var usedNames: Set<String> = []
        for page in pages {
            let base = Self.slug(for: page.title)
            var name = "\(base).md"
            var suffix = 2
            while usedNames.contains(name) {
                name = "\(base)-\(suffix).md"
                suffix += 1
            }
            usedNames.insert(name)
            let markdown = render(page)
            children[name] = FileWrapper(regularFileWithContents: Data(markdown.utf8))
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }

    // MARK: - Rendering

    /// Produce a single page's `.md` payload. Format:
    ///
    ///     ---
    ///     title: Adam Optimizer
    ///     tags: [optimizer, deep-learning]
    ///     created: 2026-04-27T14:23:00Z
    ///     updated: 2026-05-12T09:10:00Z
    ///     sources:
    ///       - document: PDF.pdf
    ///       - conversation: Thread Title
    ///     ---
    ///
    ///     # Adam Optimizer
    ///
    ///     > Adaptive optimizer combining momentum and RMSProp; default…
    ///
    ///     <body>
    ///
    /// `[[Page Title]]` references stay verbatim — Obsidian / Logseq
    /// resolve them against the surrounding folder.
    private func render(_ page: WikiPage) -> String {
        var out = "---\n"
        out += "title: \(yamlEscape(page.title))\n"
        if !page.tags.isEmpty {
            let tags = page.tags.map(yamlEscape).joined(separator: ", ")
            out += "tags: [\(tags)]\n"
        }
        out += "created: \(Self.iso8601.string(from: page.createdAt))\n"
        out += "updated: \(Self.iso8601.string(from: page.updatedAt))\n"

        let sourceLines = sourcesYAML(for: page)
        if !sourceLines.isEmpty {
            out += "sources:\n"
            for line in sourceLines { out += "  - \(line)\n" }
        }
        out += "---\n\n"

        out += "# \(page.title)\n\n"

        let summary = page.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            out += "> \(summary)\n\n"
        }

        out += page.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    private func sourcesYAML(for page: WikiPage) -> [String] {
        var lines: [String] = []
        for id in page.sourceDocumentIDs {
            if let name = documentName(id) {
                lines.append("document: \(yamlEscape(name))")
            }
        }
        for id in page.sourceConversationIDs {
            if let title = conversationTitle(id) {
                lines.append("conversation: \(yamlEscape(title))")
            }
        }
        return lines
    }

    // MARK: - Helpers

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Filesystem-safe slug derived from a page title. Lowercases,
    /// replaces whitespace with `-`, strips characters outside
    /// `[a-z0-9-_]`. Falls back to `untitled` when the title reduces to
    /// nothing (e.g. emoji-only).
    static func slug(for title: String) -> String {
        let lowered = title
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        let scalars = lowered.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(scalars))
        return result.isEmpty ? "untitled" : result
    }

    /// Escape a string for inline YAML use. We quote anything that
    /// contains `: # & * ! [ ] { } ,` or starts with a problematic
    /// character — simpler to just always quote when needed than to
    /// reproduce the full YAML grammar.
    private func yamlEscape(_ value: String) -> String {
        let problematic: Set<Character> = [":", "#", "&", "*", "!", "[", "]", "{", "}", ",", "\""]
        let needsQuoting = value.contains(where: problematic.contains)
            || value.first?.isWhitespace == true
            || value.last?.isWhitespace == true
        guard needsQuoting else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
