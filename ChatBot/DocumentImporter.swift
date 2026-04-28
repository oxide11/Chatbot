//
//  DocumentImporter.swift
//  ChatBot
//
//  One-way pipeline: pick a PDF / ePub / text / Markdown file → extract its
//  full text → hand the text to WikiEngine.extractKnowledgeFromDocument →
//  record the import. The original file is copied into Documents/Imports/
//  so it can be re-extracted later (e.g. after switching to a more capable
//  provider).
//
//  Replaces the old KnowledgeBaseStore + DocumentChunk RAG path. The wiki
//  is now the single source of long-term knowledge in retrieval.
//

import Foundation
import SwiftData
import PDFKit
import Compression
import os

// MARK: - Document Type

enum DocumentType: String, Codable, CaseIterable, Sendable {
    case pdf
    case epub
    case text
    case markdown

    var label: String {
        switch self {
        case .pdf:      return "PDF"
        case .epub:     return "ePUB"
        case .text:     return "Text"
        case .markdown: return "Markdown"
        }
    }

    var icon: String {
        switch self {
        case .pdf:      return "doc.richtext"
        case .epub:     return "book"
        case .text:     return "doc.text"
        case .markdown: return "doc.plaintext"
        }
    }

    static func from(fileExtension ext: String) -> DocumentType? {
        switch ext.lowercased() {
        case "pdf":              return .pdf
        case "epub":             return .epub
        case "txt":              return .text
        case "md", "markdown":   return .markdown
        default:                 return nil
        }
    }
}

// MARK: - SwiftData Model

@Model
final class SDDocumentImport {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var documentTypeRaw: String
    var importedAt: Date
    var lastImportedAt: Date
    var fileSize: Int64
    /// Path component under `Documents/Imports/` — e.g. "<UUID>.pdf".
    var storagePath: String
    var pagesCreated: Int
    var pagesMerged: Int
    var lastErrorMessage: String?
    /// JSON-encoded array of UUIDs of wiki pages that came from this import.
    var sourceWikiPageIDsRaw: String = "[]"

    var documentType: DocumentType {
        get { DocumentType(rawValue: documentTypeRaw) ?? .text }
        set { documentTypeRaw = newValue.rawValue }
    }

    var sourceWikiPageIDs: [UUID] {
        get { (try? JSONDecoder().decode([UUID].self, from: Data(sourceWikiPageIDsRaw.utf8))) ?? [] }
        set { sourceWikiPageIDsRaw = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]" }
    }

    init(
        id: UUID = UUID(),
        fileName: String,
        documentType: DocumentType,
        importedAt: Date = Date(),
        fileSize: Int64,
        storagePath: String,
        pagesCreated: Int = 0,
        pagesMerged: Int = 0,
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.documentTypeRaw = documentType.rawValue
        self.importedAt = importedAt
        self.lastImportedAt = importedAt
        self.fileSize = fileSize
        self.storagePath = storagePath
        self.pagesCreated = pagesCreated
        self.pagesMerged = pagesMerged
        self.lastErrorMessage = lastErrorMessage
    }

    func toStruct() -> DocumentImport {
        DocumentImport(
            id: id,
            fileName: fileName,
            documentType: documentType,
            importedAt: importedAt,
            lastImportedAt: lastImportedAt,
            fileSize: fileSize,
            storagePath: storagePath,
            pagesCreated: pagesCreated,
            pagesMerged: pagesMerged,
            lastErrorMessage: lastErrorMessage,
            sourceWikiPageIDs: sourceWikiPageIDs
        )
    }
}

// MARK: - Lightweight Transfer Struct

struct DocumentImport: Identifiable, Hashable, Sendable {
    let id: UUID
    var fileName: String
    let documentType: DocumentType
    let importedAt: Date
    var lastImportedAt: Date
    let fileSize: Int64
    var storagePath: String
    var pagesCreated: Int
    var pagesMerged: Int
    var lastErrorMessage: String?
    var sourceWikiPageIDs: [UUID]
}

// MARK: - Actor

@ModelActor
actor DocumentImportActor {

    func loadAll() throws -> [DocumentImport] {
        let descriptor = FetchDescriptor<SDDocumentImport>(
            sortBy: [SortDescriptor(\.importedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { $0.toStruct() }
    }

    func insert(_ record: DocumentImport) throws {
        let sd = SDDocumentImport(
            id: record.id,
            fileName: record.fileName,
            documentType: record.documentType,
            importedAt: record.importedAt,
            fileSize: record.fileSize,
            storagePath: record.storagePath,
            pagesCreated: record.pagesCreated,
            pagesMerged: record.pagesMerged,
            lastErrorMessage: record.lastErrorMessage
        )
        sd.sourceWikiPageIDs = record.sourceWikiPageIDs
        modelContext.insert(sd)
        try modelContext.save()
    }

    func updateResult(
        id: UUID,
        pagesCreated: Int,
        pagesMerged: Int,
        sourceWikiPageIDs: [UUID],
        lastErrorMessage: String?
    ) throws {
        let predicate = #Predicate<SDDocumentImport> { $0.id == id }
        let descriptor = FetchDescriptor<SDDocumentImport>(predicate: predicate)
        guard let sd = try modelContext.fetch(descriptor).first else { return }
        sd.pagesCreated = pagesCreated
        sd.pagesMerged = pagesMerged
        sd.sourceWikiPageIDs = Array(Set(sd.sourceWikiPageIDs).union(sourceWikiPageIDs))
        sd.lastImportedAt = Date()
        sd.lastErrorMessage = lastErrorMessage
        try modelContext.save()
    }

    func delete(id: UUID) throws {
        let predicate = #Predicate<SDDocumentImport> { $0.id == id }
        let descriptor = FetchDescriptor<SDDocumentImport>(predicate: predicate)
        if let sd = try modelContext.fetch(descriptor).first {
            modelContext.delete(sd)
            try modelContext.save()
        }
    }
}

// MARK: - Import Job (in-flight ingestion)

struct DocumentImportJob: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let documentType: DocumentType
    var status: Status
    var progress: WikiDocumentExtractionProgress?

    enum Status: Equatable, Sendable {
        case queued
        case extractingText
        case importing(WikiDocumentExtractionProgress?)
        case completed(WikiDocumentExtractionSummary)
        case failed(String)
    }

    var label: String {
        switch status {
        case .queued:                  return "Queued"
        case .extractingText:          return "Reading document…"
        case .importing(let p):
            if let p { return "Chunk \(p.chunkIndex) of \(p.chunkCount)" }
            return "Sending to model…"
        case .completed(let s):
            let problems = s.failedChunks > 0 ? " · \(s.failedChunks) failed" : ""
            return "\(s.pagesCreated) created, \(s.pagesMerged) merged\(problems)"
        case .failed(let msg):         return msg
        }
    }

    var isFinished: Bool {
        switch status {
        case .completed, .failed: return true
        default:                  return false
        }
    }
}

// MARK: - Importer

@MainActor
@Observable
final class DocumentImporter {

    private(set) var imports: [DocumentImport] = []
    private(set) var queue: [DocumentImportJob] = []
    private(set) var isProcessing: Bool = false
    private(set) var isConfigured: Bool = false

    private var actor: DocumentImportActor?
    private var wikiEngine: WikiEngine?
    private var currentTask: Task<Void, Never>?

    // MARK: - Configuration

    func configure(with container: ModelContainer, wikiEngine: WikiEngine) {
        guard !isConfigured else { return }
        self.actor = DocumentImportActor(modelContainer: container)
        self.wikiEngine = wikiEngine
        ensureImportsDirectoryExists()
        isConfigured = true
        Task { await loadAll() }
    }

    /// On-disk directory where copies of imported files live.
    static var importsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Imports", isDirectory: true)
    }

    /// Resolve a stored file from a DocumentImport's `storagePath`.
    static func fileURL(for record: DocumentImport) -> URL {
        importsDirectory.appendingPathComponent(record.storagePath)
    }

    private func ensureImportsDirectoryExists() {
        let url = Self.importsDirectory
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Load

    func loadAll() async {
        guard let actor else { return }
        do {
            imports = try await actor.loadAll()
            AppLogger.importer.info("Loaded \(self.imports.count) document imports")
        } catch {
            AppLogger.importer.error("Failed loading imports: \(error.localizedDescription)")
        }
    }

    // MARK: - Queue

    /// Enqueue one or more files for import. Each picked URL is copied into
    /// our Imports directory and processed sequentially.
    func enqueue(urls: [URL]) {
        let prepared = urls.compactMap { prepare(url: $0) }
        for job in prepared {
            queue.append(job)
        }
        if !isProcessing { currentTask = Task { await processQueue() } }
    }

    /// Re-run extraction against an already-imported document.
    func reimport(_ record: DocumentImport) {
        let job = DocumentImportJob(
            id: record.id,
            fileName: record.fileName,
            documentType: record.documentType,
            status: .queued,
            progress: nil
        )
        queue.append(job)
        if !isProcessing { currentTask = Task { await processQueue() } }
    }

    /// Cancel the in-flight processing task. The job that was running will
    /// finish whatever LLM call is in progress and stop before the next chunk.
    func cancelAll() {
        currentTask?.cancel()
        for index in queue.indices where queue[index].status == .queued {
            queue[index].status = .failed("Cancelled")
        }
    }

    func clearFinishedJobs() {
        queue.removeAll(where: { $0.isFinished })
    }

    // MARK: - Delete

    /// Delete the import record and its on-disk file. Optionally also delete
    /// every wiki page that came from this import.
    func delete(_ record: DocumentImport, alsoDeleteWikiPages: Bool) async {
        // Best-effort file removal first.
        let fileURL = Self.fileURL(for: record)
        try? FileManager.default.removeItem(at: fileURL)

        // Optionally cascade into the wiki.
        if alsoDeleteWikiPages, let wikiEngine {
            for pageID in record.sourceWikiPageIDs {
                await wikiEngine.wikiStore.deletePage(id: pageID)
            }
        }

        // Then drop the SwiftData record.
        if let actor {
            do {
                try await actor.delete(id: record.id)
            } catch {
                AppLogger.importer.error("Failed deleting import record: \(error.localizedDescription)")
            }
        }

        await loadAll()
    }

    // MARK: - Pipeline

    private func prepare(url: URL) -> DocumentImportJob? {
        let ext = url.pathExtension
        guard let docType = DocumentType.from(fileExtension: ext) else {
            AppLogger.importer.warning("Unsupported file type for import: \(ext)")
            return nil
        }
        let id = UUID()
        let fileName = url.deletingPathExtension().lastPathComponent
        let storageName = "\(id.uuidString).\(ext)"
        let destination = Self.importsDirectory.appendingPathComponent(storageName)

        // Security-scoped read of the picked URL → copy into our managed directory.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            AppLogger.importer.error("Failed copying import file: \(error.localizedDescription)")
            return nil
        }

        return DocumentImportJob(
            id: id,
            fileName: fileName,
            documentType: docType,
            status: .queued,
            progress: nil
        )
    }

    private func processQueue() async {
        guard let wikiEngine, let actor else { return }
        isProcessing = true
        defer { isProcessing = false }

        while let nextIndex = queue.firstIndex(where: { $0.status == .queued }) {
            if Task.isCancelled { break }

            queue[nextIndex].status = .extractingText
            let job = queue[nextIndex]

            // Resolve the source file. New imports use the storage UUID-named
            // copy; reimports look up the stored record.
            let fileURL: URL
            if let record = imports.first(where: { $0.id == job.id }) {
                fileURL = Self.fileURL(for: record)
            } else {
                fileURL = Self.importsDirectory.appendingPathComponent(
                    "\(job.id.uuidString).\(extensionFor(job.documentType))"
                )
            }

            let extractionResult = await Task.detached(priority: .userInitiated) {
                Self.extractText(from: fileURL, type: job.documentType)
            }.value

            guard let text = extractionResult, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                queue[nextIndex].status = .failed("Couldn't read text from \(job.fileName).\(extensionFor(job.documentType))")
                if let record = imports.first(where: { $0.id == job.id }) {
                    try? await actor.updateResult(
                        id: record.id,
                        pagesCreated: record.pagesCreated,
                        pagesMerged: record.pagesMerged,
                        sourceWikiPageIDs: record.sourceWikiPageIDs,
                        lastErrorMessage: "Couldn't read text"
                    )
                    await loadAll()
                }
                continue
            }

            // First-time imports persist a record before extraction so the
            // wiki pages link to it via sourceDocumentID.
            let isNewImport = imports.first(where: { $0.id == job.id }) == nil
            if isNewImport {
                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = (attrs?[.size] as? Int64) ?? 0
                let fileExt = extensionFor(job.documentType)
                let storagePath = "\(job.id.uuidString).\(fileExt)"
                let record = DocumentImport(
                    id: job.id,
                    fileName: job.fileName,
                    documentType: job.documentType,
                    importedAt: Date(),
                    lastImportedAt: Date(),
                    fileSize: fileSize,
                    storagePath: storagePath,
                    pagesCreated: 0,
                    pagesMerged: 0,
                    lastErrorMessage: nil,
                    sourceWikiPageIDs: []
                )
                do { try await actor.insert(record) }
                catch { AppLogger.importer.error("Failed persisting initial import record: \(error.localizedDescription)") }
                await loadAll()
            }

            queue[nextIndex].status = .importing(nil)

            // Capture the wiki page count delta so we can record exactly which
            // pages came from this import (for delete-with-pages later).
            let priorPageIDs = Set(wikiEngine.wikiStore.pages.map(\.id))

            let summary = await wikiEngine.extractKnowledgeFromDocument(
                text: text,
                sourceName: job.fileName,
                sourceDocumentID: job.id
            ) { progress in
                self.queue[nextIndex].status = .importing(progress)
                self.queue[nextIndex].progress = progress
            }

            let newPageIDs = wikiEngine.wikiStore.pages
                .filter { !priorPageIDs.contains($0.id) }
                .map(\.id)

            do {
                try await actor.updateResult(
                    id: job.id,
                    pagesCreated: summary.pagesCreated,
                    pagesMerged: summary.pagesMerged,
                    sourceWikiPageIDs: newPageIDs,
                    lastErrorMessage: summary.failedChunks > 0
                        ? "\(summary.failedChunks) chunk(s) failed"
                        : nil
                )
            } catch {
                AppLogger.importer.error("Failed updating import record: \(error.localizedDescription)")
            }

            queue[nextIndex].status = .completed(summary)
            await loadAll()
        }
    }

    private func extensionFor(_ type: DocumentType) -> String {
        switch type {
        case .pdf:      return "pdf"
        case .epub:     return "epub"
        case .text:     return "txt"
        case .markdown: return "md"
        }
    }

    // MARK: - Text Extraction (lifted from the old KnowledgeBaseStore)

    /// Background-safe text extraction for any supported document type.
    nonisolated static func extractText(from url: URL, type: DocumentType) -> String? {
        switch type {
        case .pdf:
            return joinSections(extractPDF(at: url))
        case .epub:
            return (try? extractEPUB(at: url)).map(joinSections)
        case .text, .markdown:
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    private nonisolated static func joinSections(_ sections: [(label: String, text: String)]) -> String {
        sections
            .map { section -> String in
                "## \(section.label)\n\(section.text)"
            }
            .joined(separator: "\n\n")
    }

    nonisolated static func extractPDF(at url: URL) -> [(label: String, text: String)] {
        guard let document = PDFDocument(url: url) else { return [] }
        var pages: [(String, String)] = []
        for i in 0..<document.pageCount {
            if let page = document.page(at: i),
               let text = page.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(("Page \(i + 1)", text))
            }
        }
        return pages
    }

    nonisolated static func extractEPUB(at url: URL) throws -> [(label: String, text: String)] {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entries = try extractZIP(at: url, to: tempDir)
        guard !entries.isEmpty else { return [] }

        let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: containerURL),
              let containerStr = String(data: containerData, encoding: .utf8),
              let opfPath = parseOPFPath(from: containerStr) else {
            return extractAllHTML(in: tempDir, entries: entries)
        }

        let opfURL = tempDir.appendingPathComponent(opfPath)
        let opfDir = opfURL.deletingLastPathComponent()
        guard let opfData = try? Data(contentsOf: opfURL),
              let opfStr = String(data: opfData, encoding: .utf8) else {
            return extractAllHTML(in: tempDir, entries: entries)
        }

        let spineFiles = parseSpineFiles(from: opfStr)
        guard !spineFiles.isEmpty else {
            return extractAllHTML(in: tempDir, entries: entries)
        }

        var chapters: [(String, String)] = []
        for (i, filename) in spineFiles.enumerated() {
            let fileURL = opfDir.appendingPathComponent(filename)
            guard let htmlData = try? Data(contentsOf: fileURL),
                  let html = String(data: htmlData, encoding: .utf8) else { continue }
            let text = stripHTMLTags(html)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chapters.append(("Chapter \(i + 1)", text))
            }
        }
        return chapters.isEmpty ? extractAllHTML(in: tempDir, entries: entries) : chapters
    }

    private nonisolated static func extractAllHTML(
        in directory: URL,
        entries: [String]
    ) -> [(label: String, text: String)] {
        var results: [(String, String)] = []
        let htmlEntries = entries
            .filter { $0.hasSuffix(".xhtml") || $0.hasSuffix(".html") || $0.hasSuffix(".htm") }
            .sorted()
        for (i, entry) in htmlEntries.enumerated() {
            let fileURL = directory.appendingPathComponent(entry)
            guard let data = try? Data(contentsOf: fileURL),
                  let html = String(data: data, encoding: .utf8) else { continue }
            let text = stripHTMLTags(html)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(("Section \(i + 1)", text))
            }
        }
        return results
    }

    private nonisolated static func parseOPFPath(from xml: String) -> String? {
        guard let range = xml.range(of: "full-path=\"[^\"]+\"", options: .regularExpression) else { return nil }
        let match = String(xml[range])
        return match
            .replacingOccurrences(of: "full-path=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
    }

    private nonisolated static func parseSpineFiles(from opf: String) -> [String] {
        var manifest: [String: String] = [:]
        if let itemRegex = try? NSRegularExpression(pattern: "<item[^>]*>") {
            let matches = itemRegex.matches(in: opf, range: NSRange(opf.startIndex..., in: opf))
            for match in matches {
                guard let range = Range(match.range, in: opf) else { continue }
                let tag = String(opf[range])
                if let id = extractAttribute("id", from: tag),
                   let href = extractAttribute("href", from: tag) {
                    manifest[id] = href
                }
            }
        }

        var spineIDs: [String] = []
        if let itemrefRegex = try? NSRegularExpression(pattern: "<itemref[^>]*>") {
            let matches = itemrefRegex.matches(in: opf, range: NSRange(opf.startIndex..., in: opf))
            for match in matches {
                guard let range = Range(match.range, in: opf) else { continue }
                let tag = String(opf[range])
                if let idref = extractAttribute("idref", from: tag) {
                    spineIDs.append(idref)
                }
            }
        }
        return spineIDs.compactMap { manifest[$0] }
    }

    private nonisolated static func extractAttribute(_ name: String, from tag: String) -> String? {
        let pattern = "\(name)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    private nonisolated static func stripHTMLTags(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<p[^>]*>", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\s*\\n\\s*\\n\\s*", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func extractZIP(at url: URL, to destination: URL) throws -> [String] {
        let fileData = try Data(contentsOf: url)
        var extractedPaths: [String] = []
        var offset = 0

        while offset + 30 <= fileData.count {
            let sig = fileData.subdata(in: offset..<offset + 4)
            guard sig == Data([0x50, 0x4B, 0x03, 0x04]) else { break }

            let compressionMethod = fileData.subdata(in: offset + 8..<offset + 10).withUnsafeBytes { $0.load(as: UInt16.self) }
            let compressedSize = Int(fileData.subdata(in: offset + 18..<offset + 22).withUnsafeBytes { $0.load(as: UInt32.self) })
            let uncompressedSize = Int(fileData.subdata(in: offset + 22..<offset + 26).withUnsafeBytes { $0.load(as: UInt32.self) })
            let nameLength = Int(fileData.subdata(in: offset + 26..<offset + 28).withUnsafeBytes { $0.load(as: UInt16.self) })
            let extraLength = Int(fileData.subdata(in: offset + 28..<offset + 30).withUnsafeBytes { $0.load(as: UInt16.self) })

            guard compressedSize >= 0, uncompressedSize >= 0, nameLength > 0 else { break }

            let nameStart = offset + 30
            let nameEnd = nameStart + nameLength
            guard nameEnd <= fileData.count else { break }
            let nameData = fileData.subdata(in: nameStart..<nameEnd)
            guard let name = String(data: nameData, encoding: .utf8) else {
                offset = nameEnd + extraLength + compressedSize
                continue
            }

            let dataStart = nameEnd + extraLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= fileData.count else { break }

            if !name.hasSuffix("/") {
                let entryData: Data
                if compressionMethod == 0 {
                    entryData = fileData.subdata(in: dataStart..<dataEnd)
                } else if compressionMethod == 8 {
                    let compressed = fileData.subdata(in: dataStart..<dataEnd)
                    guard let decompressed = decompress(compressed, expectedSize: uncompressedSize) else {
                        offset = dataEnd
                        continue
                    }
                    entryData = decompressed
                } else {
                    offset = dataEnd
                    continue
                }

                let fileURL = destination.appendingPathComponent(name)
                let dirURL = fileURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try? entryData.write(to: fileURL)
                extractedPaths.append(name)
            }
            offset = dataEnd
        }
        return extractedPaths
    }

    private nonisolated static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        let maxAllowedSize = 100 * 1024 * 1024
        let bufferSize = min(max(expectedSize, 1024), maxAllowedSize)
        guard bufferSize > 0 else { return nil }

        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        let result = data.withUnsafeBytes { sourcePtr -> Int in
            guard let baseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer, bufferSize,
                baseAddress.assumingMemoryBound(to: UInt8.self), data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard result > 0 else { return nil }
        return Data(bytes: destinationBuffer, count: result)
    }
}
