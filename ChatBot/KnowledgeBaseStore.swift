import Foundation
import PDFKit
import Compression

// MARK: - Data Models

enum DocumentType: String, Codable, CaseIterable, Sendable {
    case pdf
    case epub
    case text

    var icon: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .epub: return "book"
        case .text: return "doc.text"
        }
    }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .epub: return "ePUB"
        case .text: return "Text"
        }
    }
}

struct KnowledgeBase: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    let documentType: DocumentType
    let createdAt: Date
    var updatedAt: Date
    var chunkCount: Int
    let fileSize: Int64

    /// The model identifier that produced the stored embeddings.
    /// Used to detect when re-embedding is needed (e.g. after an OS update).
    var embeddingModelID: String?

    nonisolated init(id: UUID = UUID(), name: String, documentType: DocumentType, chunkCount: Int, fileSize: Int64, embeddingModelID: String? = nil) {
        self.id = id
        self.name = name
        self.documentType = documentType
        self.createdAt = Date()
        self.updatedAt = Date()
        self.chunkCount = chunkCount
        self.fileSize = fileSize
        self.embeddingModelID = embeddingModelID
    }

    /// Backward-compatible decoding: old data without `updatedAt` falls back to `createdAt`.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        documentType = try container.decode(DocumentType.self, forKey: .documentType)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        chunkCount = try container.decode(Int.self, forKey: .chunkCount)
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        embeddingModelID = try container.decodeIfPresent(String.self, forKey: .embeddingModelID)
    }
}

struct DocumentChunk: Identifiable, Codable, Sendable {
    let id: UUID
    let knowledgeBaseID: UUID
    let content: String
    let keywords: [String]
    let locationLabel: String
    let index: Int

    /// Semantic embedding vector (512-dim from NLContextualEmbedding).
    /// Optional for backward compatibility with chunks created before embeddings.
    var embedding: [Double]?

    nonisolated init(knowledgeBaseID: UUID, content: String, keywords: [String], locationLabel: String, index: Int, embedding: [Double]? = nil) {
        self.id = UUID()
        self.knowledgeBaseID = knowledgeBaseID
        self.content = content
        self.keywords = keywords.map { $0.lowercased() }
        self.locationLabel = locationLabel
        self.index = index
        self.embedding = embedding
    }
}

// MARK: - Ingestion Job

struct IngestionJob: Identifiable {
    let id: UUID
    let url: URL
    let fileName: String
    var status: IngestionStatus

    /// Whether this job has finished (completed or failed).
    var isFinished: Bool {
        switch status {
        case .completed, .failed: return true
        case .queued, .processing: return false
        }
    }

    enum IngestionStatus: Equatable {
        case queued
        case processing
        case completed
        case failed(String)

        var label: String {
            switch self {
            case .queued: return "Queued"
            case .processing: return "Processing…"
            case .completed: return "Done"
            case .failed(let msg): return msg
            }
        }

        var icon: String {
            switch self {
            case .queued: return "clock"
            case .processing: return "arrow.trianglehead.2.clockwise"
            case .completed: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }

        var iconColor: String {
            switch self {
            case .queued: return "secondary"
            case .processing: return "blue"
            case .completed: return "green"
            case .failed: return "red"
            }
        }
    }
}

// MARK: - Knowledge Base Store

@Observable
final class KnowledgeBaseStore {
    private(set) var knowledgeBases: [KnowledgeBase] = []
    private(set) var isProcessing = false
    private(set) var processingProgress: Double = 0
    private(set) var processingError: String?

    /// Batch ingestion queue
    private(set) var ingestionQueue: [IngestionJob] = []
    private var isQueueRunning = false

    private var chunkCache: [UUID: [DocumentChunk]] = [:]

    /// Pre-computed embedding matrix for fast batch similarity scoring.
    /// Invalidated whenever chunks are added, removed, or re-embedded.
    private var embeddingMatrix: EmbeddingMatrix?

    private static let metadataFilename = "knowledge_bases.json"

    init() {
        loadMetadata()
        verifyDataIntegrity()
        reembedStaleKnowledgeBasesIfNeeded()
    }

    // MARK: - Embedding Maintenance

    /// Re-embed any knowledge bases whose stored model ID doesn't match
    /// the current device's embedding model (e.g. after an OS update).
    /// Also embeds chunks that were imported before embeddings were available.
    /// Runs synchronously on init but the actual embedding is fast (~ms per chunk).
    private func reembedStaleKnowledgeBasesIfNeeded() {
        let service = EmbeddingService.shared
        guard service.isAvailable else { return }
        let currentModelID = service.modelIdentifier

        for i in knowledgeBases.indices {
            let kb = knowledgeBases[i]

            // Skip if already embedded with the current model
            if kb.embeddingModelID == currentModelID { continue }

            // Load chunks, re-embed, and save
            var chunks = loadChunks(for: kb.id)
            guard !chunks.isEmpty else { continue }

            for j in chunks.indices {
                chunks[j].embedding = service.embed(chunks[j].content)
            }

            saveChunks(chunks, for: kb.id)
            chunkCache[kb.id] = chunks
            invalidateEmbeddingMatrix()
            invertedKeywordIndex.removeAll()

            // Update the model stamp
            knowledgeBases[i].embeddingModelID = currentModelID
        }

        saveMetadata()
    }

    // MARK: - Ingestion Pipeline

    /// Queue one or more documents for ingestion. Processing runs sequentially.
    func queueDocuments(from urls: [URL]) {
        for url in urls {
            let job = IngestionJob(
                id: UUID(),
                url: url,
                fileName: url.deletingPathExtension().lastPathComponent,
                status: .queued
            )
            ingestionQueue.append(job)
        }

        if !isQueueRunning {
            Task { await processQueue() }
        }
    }

    /// Legacy single-file entry point (kept for Share Extension / programmatic use).
    func ingestDocument(from url: URL) async {
        queueDocuments(from: [url])
        // Wait for queue to finish so callers that `await` still work
        while isQueueRunning || ingestionQueue.contains(where: { $0.status == .queued }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Cancel all remaining queued (not yet started) jobs.
    func cancelQueue() {
        for i in ingestionQueue.indices {
            if ingestionQueue[i].status == .queued {
                ingestionQueue[i].status = .failed("Cancelled")
            }
        }
    }

    /// Remove a completed or failed job from the queue display.
    func removeJob(_ job: IngestionJob) {
        ingestionQueue.removeAll { $0.id == job.id }
    }

    /// Clear all completed/failed jobs from the queue.
    func clearFinishedJobs() {
        ingestionQueue.removeAll { job in
            job.isFinished
        }
    }

    // MARK: - Queue Processor

    private func processQueue() async {
        isQueueRunning = true
        isProcessing = true
        processingError = nil

        while let nextIndex = ingestionQueue.firstIndex(where: { $0.status == .queued }) {
            ingestionQueue[nextIndex].status = .processing
            updateOverallProgress()

            let job = ingestionQueue[nextIndex]

            // Security-scoped access must start on the calling thread
            let accessing = job.url.startAccessingSecurityScopedResource()

            // Run all heavy work (extraction, chunking, embedding, file I/O) off the main actor
            let outcome = await Task.detached(priority: .userInitiated) {
                await Self.ingestSingleDocument(url: job.url)
            }.value

            if accessing { job.url.stopAccessingSecurityScopedResource() }

            // Update UI state back on MainActor
            if let idx = ingestionQueue.firstIndex(where: { $0.id == job.id }) {
                switch outcome {
                case .success(let result):
                    ingestionQueue[idx].status = .completed
                    knowledgeBases.insert(result.kb, at: 0)
                    chunkCache[result.kb.id] = result.chunks
                    invalidateEmbeddingMatrix()
                    invertedKeywordIndex.removeAll()
                    saveMetadata()
                case .failure(let reason):
                    ingestionQueue[idx].status = .failed(reason)
                }
            }
            updateOverallProgress()
        }

        isQueueRunning = false
        isProcessing = false
        processingProgress = ingestionQueue.isEmpty ? 0 : 1.0
    }

    /// Compute overall progress across all jobs in the queue.
    private func updateOverallProgress() {
        guard !ingestionQueue.isEmpty else {
            processingProgress = 0
            return
        }
        let total = Double(ingestionQueue.count)
        var completed = 0.0
        for job in ingestionQueue {
            switch job.status {
            case .completed, .failed: completed += 1.0
            case .processing: completed += 0.5
            case .queued: break
            }
        }
        processingProgress = completed / total
    }

    // MARK: - Background Ingestion (off main actor)

    /// Result of a successful ingestion, ready to merge into the store.
    private struct IngestionResult: Sendable {
        let kb: KnowledgeBase
        let chunks: [DocumentChunk]
    }

    /// Outcome of a background ingestion job.
    private enum IngestionOutcome: Sendable {
        case success(IngestionResult)
        case failure(String)
    }

    /// Perform the entire document ingestion pipeline off the main actor.
    /// This is a static nonisolated method so it runs on a background thread.
    nonisolated private static func ingestSingleDocument(
        url: URL
    ) async -> IngestionOutcome {
        let ext = url.pathExtension.lowercased()
        guard ext == "pdf" || ext == "epub" || ext == "txt" else {
            return .failure("Unsupported: .\(ext)")
        }

        let docType: DocumentType
        if ext == "pdf" { docType = .pdf }
        else if ext == "epub" { docType = .epub }
        else { docType = .text }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let kbID = UUID()

        // Extract text (CPU-heavy)
        let sections: [(label: String, text: String)]
        if docType == .pdf {
            sections = extractTextFromPDFBackground(at: url)
        } else if docType == .epub {
            sections = (try? extractTextFromEPUBBackground(at: url)) ?? []
        } else {
            // Plain text file
            if let textContent = try? String(contentsOf: url, encoding: .utf8),
               !textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections = [("Full Text", textContent)]
            } else {
                sections = []
            }
        }

        guard !sections.isEmpty else {
            return .failure("No text content found")
        }

        // Chunk all sections (CPU-heavy)
        var allChunks: [DocumentChunk] = []
        var chunkIndex = 0

        for section in sections {
            let sectionChunks = chunkTextBackground(
                section.text,
                locationLabel: section.label,
                knowledgeBaseID: kbID,
                startIndex: &chunkIndex
            )
            allChunks.append(contentsOf: sectionChunks)
        }

        guard !allChunks.isEmpty else {
            return .failure("No chunks created")
        }

        // Compute semantic embeddings (CPU-heavy — BERT inference)
        let embeddingService = EmbeddingService.shared
        if embeddingService.isAvailable {
            for i in allChunks.indices {
                allChunks[i].embedding = embeddingService.embed(allChunks[i].content)
            }
        }

        // Write chunk file to disk (I/O)
        let kb = KnowledgeBase(
            id: kbID,
            name: url.deletingPathExtension().lastPathComponent,
            documentType: docType,
            chunkCount: allChunks.count,
            fileSize: fileSize,
            embeddingModelID: embeddingService.isAvailable ? embeddingService.modelIdentifier : nil
        )

        SharedDataManager.ensureDirectoriesExist()
        guard let dir = SharedDataManager.chunksDirectoryURL else {
            print("[KBStore] ERROR: Storage directory unavailable during ingestion")
            return .failure("Storage directory unavailable")
        }
        let fileURL = dir.appendingPathComponent("\(kbID.uuidString).json")
        do {
            let data = try JSONEncoder().encode(allChunks)
            try data.write(to: fileURL, options: .atomic)
            print("[KBStore] Saved \(allChunks.count) chunks for '\(kb.name)' (\(data.count) bytes)")
        } catch {
            print("[KBStore] ERROR writing chunks during ingestion: \(error.localizedDescription)")
            return .failure("Failed to save chunks: \(error.localizedDescription)")
        }

        return .success(IngestionResult(kb: kb, chunks: allChunks))
    }

    // MARK: - Background-safe Extraction & Chunking (nonisolated static)
    //
    // These are pure functions with no instance state access, safe to call from
    // any thread via Task.detached. The instance methods above delegate to these.

    nonisolated private static func extractTextFromPDFBackground(at url: URL) -> [(label: String, text: String)] {
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

    nonisolated private static func extractTextFromEPUBBackground(at url: URL) throws -> [(label: String, text: String)] {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entries = try extractZIPBackground(at: url, to: tempDir)
        guard !entries.isEmpty else { return [] }

        let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: containerURL),
              let containerStr = String(data: containerData, encoding: .utf8),
              let opfPath = parseOPFPathBackground(from: containerStr) else {
            return extractTextFromAllHTMLBackground(in: tempDir, entries: entries)
        }

        let opfURL = tempDir.appendingPathComponent(opfPath)
        let opfDir = opfURL.deletingLastPathComponent()
        guard let opfData = try? Data(contentsOf: opfURL),
              let opfStr = String(data: opfData, encoding: .utf8) else {
            return extractTextFromAllHTMLBackground(in: tempDir, entries: entries)
        }

        let spineFiles = parseSpineFilesBackground(from: opfStr)
        guard !spineFiles.isEmpty else {
            return extractTextFromAllHTMLBackground(in: tempDir, entries: entries)
        }

        var chapters: [(String, String)] = []
        for (i, filename) in spineFiles.enumerated() {
            let fileURL = opfDir.appendingPathComponent(filename)
            guard let htmlData = try? Data(contentsOf: fileURL),
                  let html = String(data: htmlData, encoding: .utf8) else { continue }
            let text = stripHTMLTagsBackground(html)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chapters.append(("Chapter \(i + 1)", text))
            }
        }

        return chapters.isEmpty ? extractTextFromAllHTMLBackground(in: tempDir, entries: entries) : chapters
    }

    nonisolated private static func extractTextFromAllHTMLBackground(in directory: URL, entries: [String]) -> [(label: String, text: String)] {
        var results: [(String, String)] = []
        let htmlEntries = entries.filter { $0.hasSuffix(".xhtml") || $0.hasSuffix(".html") || $0.hasSuffix(".htm") }
            .sorted()

        for (i, entry) in htmlEntries.enumerated() {
            let fileURL = directory.appendingPathComponent(entry)
            guard let data = try? Data(contentsOf: fileURL),
                  let html = String(data: data, encoding: .utf8) else { continue }
            let text = stripHTMLTagsBackground(html)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(("Section \(i + 1)", text))
            }
        }
        return results
    }

    nonisolated private static func parseOPFPathBackground(from xml: String) -> String? {
        guard let range = xml.range(of: "full-path=\"[^\"]+\"", options: .regularExpression) else { return nil }
        let match = String(xml[range])
        return match.replacingOccurrences(of: "full-path=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
    }

    nonisolated private static func parseSpineFilesBackground(from opf: String) -> [String] {
        var manifest: [String: String] = [:]
        let itemPattern = "<item[^>]*>"
        if let itemRegex = try? NSRegularExpression(pattern: itemPattern) {
            let matches = itemRegex.matches(in: opf, range: NSRange(opf.startIndex..., in: opf))
            for match in matches {
                guard let range = Range(match.range, in: opf) else { continue }
                let tag = String(opf[range])
                let idValue = extractAttributeBackground("id", from: tag)
                let hrefValue = extractAttributeBackground("href", from: tag)
                if let id = idValue, let href = hrefValue {
                    manifest[id] = href
                }
            }
        }

        var spineIDs: [String] = []
        let itemrefPattern = "<itemref[^>]*>"
        if let itemrefRegex = try? NSRegularExpression(pattern: itemrefPattern) {
            let matches = itemrefRegex.matches(in: opf, range: NSRange(opf.startIndex..., in: opf))
            for match in matches {
                guard let range = Range(match.range, in: opf) else { continue }
                let tag = String(opf[range])
                if let idref = extractAttributeBackground("idref", from: tag) {
                    spineIDs.append(idref)
                }
            }
        }

        return spineIDs.compactMap { manifest[$0] }
    }

    nonisolated private static func extractAttributeBackground(_ name: String, from tag: String) -> String? {
        let pattern = "\(name)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    nonisolated private static func stripHTMLTagsBackground(_ html: String) -> String {
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

    nonisolated private static func extractZIPBackground(at url: URL, to destination: URL) throws -> [String] {
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
                    guard let decompressed = decompressBackground(compressed, expectedSize: uncompressedSize) else {
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

    nonisolated private static func decompressBackground(_ data: Data, expectedSize: Int) -> Data? {
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

    /// Background-safe chunking (nonisolated static).
    nonisolated private static func chunkTextBackground(
        _ text: String,
        locationLabel: String,
        knowledgeBaseID: UUID,
        startIndex: inout Int
    ) -> [DocumentChunk] {
        let config = Self.chunkingConfig
        var chunks: [DocumentChunk] = []
        let paragraphs = text.components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var currentChunk = ""

        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if currentChunk.count + trimmed.count + 2 > config.targetCharacters
                && currentChunk.count >= config.minChunkCharacters {
                let keywords = Array(SharedDataManager.extractKeywords(from: currentChunk, limit: 8))
                chunks.append(DocumentChunk(
                    knowledgeBaseID: knowledgeBaseID,
                    content: currentChunk.trimmingCharacters(in: .whitespacesAndNewlines),
                    keywords: keywords,
                    locationLabel: locationLabel,
                    index: startIndex
                ))
                startIndex += 1

                let overlapStart = max(0, currentChunk.count - config.overlapCharacters)
                let overlapIdx = currentChunk.index(currentChunk.startIndex, offsetBy: overlapStart)
                currentChunk = String(currentChunk[overlapIdx...]) + "\n\n" + trimmed
            } else {
                if !currentChunk.isEmpty { currentChunk += "\n\n" }
                currentChunk += trimmed
            }
        }

        let remaining = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if remaining.count >= config.minChunkCharacters {
            let keywords = Array(SharedDataManager.extractKeywords(from: remaining, limit: 8))
            chunks.append(DocumentChunk(
                knowledgeBaseID: knowledgeBaseID,
                content: remaining,
                keywords: keywords,
                locationLabel: locationLabel,
                index: startIndex
            ))
            startIndex += 1
        } else if !remaining.isEmpty, let last = chunks.indices.last {
            chunks[last] = DocumentChunk(
                knowledgeBaseID: knowledgeBaseID,
                content: chunks[last].content + "\n\n" + remaining,
                keywords: Array(SharedDataManager.extractKeywords(
                    from: chunks[last].content + " " + remaining, limit: 8
                )),
                locationLabel: chunks[last].locationLabel,
                index: chunks[last].index
            )
        }

        return chunks
    }

    // MARK: - Chunking

    nonisolated private static let chunkingConfig = ChunkingConfig()

    private struct ChunkingConfig: Sendable {
        /// ~600 chars ≈ ~170 tokens — small enough for 2-3 chunks to fit
        /// inside the RAG context budget while remaining topically focused.
        let targetCharacters = 600
        /// ~100 chars of overlap prevents hard cuts mid-thought.
        let overlapCharacters = 100
        let minChunkCharacters = 150
    }

    private func chunkText(
        _ text: String,
        locationLabel: String,
        knowledgeBaseID: UUID,
        startIndex: inout Int
    ) -> [DocumentChunk] {
        let config = Self.chunkingConfig
        var chunks: [DocumentChunk] = []
        let paragraphs = text.components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var currentChunk = ""

        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if currentChunk.count + trimmed.count + 2 > config.targetCharacters
                && currentChunk.count >= config.minChunkCharacters {
                // Emit current chunk
                let keywords = Array(SharedDataManager.extractKeywords(from: currentChunk, limit: 8))
                chunks.append(DocumentChunk(
                    knowledgeBaseID: knowledgeBaseID,
                    content: currentChunk.trimmingCharacters(in: .whitespacesAndNewlines),
                    keywords: keywords,
                    locationLabel: locationLabel,
                    index: startIndex
                ))
                startIndex += 1

                // Start new chunk with overlap from the tail of the previous
                let overlapStart = max(0, currentChunk.count - config.overlapCharacters)
                let overlapIdx = currentChunk.index(currentChunk.startIndex, offsetBy: overlapStart)
                currentChunk = String(currentChunk[overlapIdx...]) + "\n\n" + trimmed
            } else {
                if !currentChunk.isEmpty { currentChunk += "\n\n" }
                currentChunk += trimmed
            }
        }

        // Emit remaining text
        let remaining = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if remaining.count >= config.minChunkCharacters {
            let keywords = Array(SharedDataManager.extractKeywords(from: remaining, limit: 8))
            chunks.append(DocumentChunk(
                knowledgeBaseID: knowledgeBaseID,
                content: remaining,
                keywords: keywords,
                locationLabel: locationLabel,
                index: startIndex
            ))
            startIndex += 1
        } else if !remaining.isEmpty, let last = chunks.indices.last {
            // Merge short tail into last chunk
            chunks[last] = DocumentChunk(
                knowledgeBaseID: knowledgeBaseID,
                content: chunks[last].content + "\n\n" + remaining,
                keywords: Array(SharedDataManager.extractKeywords(
                    from: chunks[last].content + " " + remaining, limit: 8
                )),
                locationLabel: chunks[last].locationLabel,
                index: chunks[last].index
            )
        }

        return chunks
    }

    // MARK: - Retrieval (Accelerate-optimized)

    /// Pre-computed keyword sets for each chunk (used as fallback when embeddings are unavailable).
    private var chunkKeywordCache: [UUID: Set<String>] = [:]

    /// Inverted keyword index: word → set of chunk UUIDs that contain that word.
    /// Used for fast two-phase retrieval (keyword pre-filter → semantic re-rank).
    private var invertedKeywordIndex: [String: Set<UUID>] = [:]

    /// Rebuild the embedding matrix from the current chunk cache.
    /// Call this after chunks are loaded, added, removed, or re-embedded.
    private func rebuildEmbeddingMatrix() {
        let dim = EmbeddingService.shared.dimension
        guard dim > 0 else {
            embeddingMatrix = nil
            return
        }
        embeddingMatrix = EmbeddingMatrix.build(from: chunkCache, dimension: dim)
    }

    /// Invalidate the embedding matrix so it will be rebuilt on next retrieval.
    private func invalidateEmbeddingMatrix() {
        embeddingMatrix = nil
    }

    /// Rebuild the inverted keyword index from the current chunk cache.
    private func rebuildInvertedIndex() {
        invertedKeywordIndex.removeAll()
        for (_, chunks) in chunkCache {
            for chunk in chunks {
                let words: Set<String>
                if let cached = chunkKeywordCache[chunk.id] {
                    words = cached
                } else {
                    let computed = Set(chunk.keywords).union(SharedDataManager.tokenize(chunk.content))
                    chunkKeywordCache[chunk.id] = computed
                    words = computed
                }
                for word in words {
                    invertedKeywordIndex[word, default: []].insert(chunk.id)
                }
            }
        }
    }

    /// Retrieve the most relevant document chunks for a query.
    ///
    /// **Primary path:** Batch cosine similarity via Accelerate/vDSP against the
    /// pre-computed embedding matrix. With many chunks, uses a two-phase approach:
    /// keyword pre-filter → semantic re-rank on the smaller candidate set.
    ///
    /// **Fallback:** Keyword overlap (used when embedding assets aren't downloaded yet
    /// or chunks were imported before embeddings were available).
    func retrieve(for query: String, limit: Int = 3) -> [DocumentChunk] {
        ensureAllChunksLoaded()

        let embeddingService = EmbeddingService.shared

        // Try semantic retrieval first
        if let queryVector = embeddingService.embed(query) {
            return retrieveBySimilarity(queryVector: queryVector, query: query, limit: limit)
        }

        // Fallback: keyword matching
        return retrieveByKeywords(query: query, limit: limit)
    }

    /// Semantic retrieval using Accelerate-powered batch cosine similarity.
    ///
    /// For small corpora (< 200 chunks), does a full matrix scan — this is extremely
    /// fast with vDSP/BLAS (~microseconds for 1000 × 512 matrix).
    ///
    /// For larger corpora (≥ 200 chunks), uses two-phase retrieval:
    /// 1. **Keyword pre-filter:** Use the inverted index to find candidate chunks
    ///    that share at least one keyword with the query.
    /// 2. **Semantic re-rank:** Score only the candidate subset using cosine similarity.
    ///
    /// This avoids scoring thousands of irrelevant chunks while maintaining recall.
    private func retrieveBySimilarity(queryVector: [Double], query: String, limit: Int) -> [DocumentChunk] {
        // Ensure the embedding matrix is built
        if embeddingMatrix == nil {
            rebuildEmbeddingMatrix()
        }
        guard let matrix = embeddingMatrix, matrix.rowCount > 0 else {
            return [] // No embedded chunks available
        }

        // Determine total chunk count for strategy selection
        let totalChunks = matrix.rowCount

        // Two-phase for large corpora
        if totalChunks >= 200 {
            return twoPhaseRetrieval(queryVector: queryVector, query: query, limit: limit, matrix: matrix)
        }

        // Full matrix scan for small corpora — fast enough with Accelerate
        return fullMatrixRetrieval(queryVector: queryVector, limit: limit, matrix: matrix)
    }

    /// Full matrix batch cosine similarity — scores all chunks at once via BLAS.
    private func fullMatrixRetrieval(queryVector: [Double], limit: Int, matrix: EmbeddingMatrix) -> [DocumentChunk] {
        let similarities = EmbeddingService.batchCosineSimilarity(
            query: queryVector,
            matrix: matrix.data,
            norms: matrix.norms,
            dimension: matrix.dimension
        )

        // Top-K selection using partial sort (faster than full sort for small K)
        return topK(similarities: similarities, matrix: matrix, limit: limit, threshold: 0.3)
    }

    /// Two-phase retrieval: keyword pre-filter → semantic re-rank.
    private func twoPhaseRetrieval(queryVector: [Double], query: String, limit: Int, matrix: EmbeddingMatrix) -> [DocumentChunk] {
        // Build inverted index if needed
        if invertedKeywordIndex.isEmpty {
            rebuildInvertedIndex()
        }

        // Phase 1: Keyword pre-filter — find candidate chunk IDs
        let queryWords = SharedDataManager.tokenize(query)
        var candidateChunkIDs = Set<UUID>()
        for word in queryWords {
            if let chunkIDs = invertedKeywordIndex[word] {
                candidateChunkIDs.formUnion(chunkIDs)
            }
            // Also check prefix matches for longer words
            if word.count >= 5 {
                for (indexWord, chunkIDs) in invertedKeywordIndex where indexWord.count >= 5 {
                    if indexWord.hasPrefix(word) || word.hasPrefix(indexWord) {
                        candidateChunkIDs.formUnion(chunkIDs)
                    }
                }
            }
        }

        // If keyword filter finds very few candidates or none, fall back to full scan
        // (the query might use different vocabulary than the documents)
        let minCandidates = max(limit * 3, 20)
        if candidateChunkIDs.count < minCandidates {
            return fullMatrixRetrieval(queryVector: queryVector, limit: limit, matrix: matrix)
        }

        // Phase 2: Build a smaller matrix from candidates and score with Accelerate
        let dim = matrix.dimension
        var subMatrix: [Double] = []
        var subNorms: [Double] = []
        var subRowMap: [(UUID, Int)] = []

        subMatrix.reserveCapacity(candidateChunkIDs.count * dim)

        for (rowIdx, mapping) in matrix.rowMap.enumerated() {
            let chunk = chunkCache[mapping.knowledgeBaseID]?[mapping.chunkIndex]
            guard let chunk, candidateChunkIDs.contains(chunk.id) else { continue }

            // Copy this row's embedding from the full matrix
            let start = rowIdx * dim
            let end = start + dim
            subMatrix.append(contentsOf: matrix.data[start ..< end])
            subNorms.append(matrix.norms[rowIdx])
            subRowMap.append(mapping)
        }

        guard !subRowMap.isEmpty else {
            return fullMatrixRetrieval(queryVector: queryVector, limit: limit, matrix: matrix)
        }

        let similarities = EmbeddingService.batchCosineSimilarity(
            query: queryVector,
            matrix: subMatrix,
            norms: subNorms,
            dimension: dim
        )

        // Use the sub-matrix row map for resolution
        let subEmbeddingMatrix = EmbeddingMatrix(
            data: subMatrix,
            norms: subNorms,
            dimension: dim,
            rowCount: subRowMap.count,
            rowMap: subRowMap
        )

        return topK(similarities: similarities, matrix: subEmbeddingMatrix, limit: limit, threshold: 0.3)
    }

    /// Extract the top-K results from a similarity array using partial sort.
    /// More efficient than full sort when K << N.
    private func topK(similarities: [Double], matrix: EmbeddingMatrix, limit: Int, threshold: Double) -> [DocumentChunk] {
        // Use a min-heap approach: maintain the K best scores
        // For typical K=3 and N=1000+, this is O(N log K) vs O(N log N) for full sort
        struct ScoredRow: Comparable {
            let rowIndex: Int
            let score: Double
            static func < (lhs: ScoredRow, rhs: ScoredRow) -> Bool { lhs.score < rhs.score }
        }

        var heap: [ScoredRow] = []
        heap.reserveCapacity(limit + 1)

        for i in 0 ..< similarities.count {
            let score = similarities[i]
            guard score > threshold else { continue }

            if heap.count < limit {
                heap.append(ScoredRow(rowIndex: i, score: score))
                // Maintain min-heap order: sift up
                var idx = heap.count - 1
                while idx > 0 {
                    let parent = (idx - 1) / 2
                    if heap[idx] < heap[parent] {
                        heap.swapAt(idx, parent)
                        idx = parent
                    } else { break }
                }
            } else if score > heap[0].score {
                // Replace the minimum (root) with new higher score
                heap[0] = ScoredRow(rowIndex: i, score: score)
                // Sift down to restore heap
                var idx = 0
                while true {
                    let left = 2 * idx + 1
                    let right = 2 * idx + 2
                    var smallest = idx
                    if left < heap.count && heap[left] < heap[smallest] { smallest = left }
                    if right < heap.count && heap[right] < heap[smallest] { smallest = right }
                    if smallest == idx { break }
                    heap.swapAt(idx, smallest)
                    idx = smallest
                }
            }
        }

        // Sort the heap by score descending for final output
        let sorted = heap.sorted { $0.score > $1.score }

        // Resolve row indices back to DocumentChunks
        return sorted.compactMap { scored in
            let mapping = matrix.rowMap[scored.rowIndex]
            return chunkCache[mapping.knowledgeBaseID]?[mapping.chunkIndex]
        }
    }

    /// Keyword fallback: normalized word overlap scoring.
    private func retrieveByKeywords(query: String, limit: Int) -> [DocumentChunk] {
        let queryWords = SharedDataManager.tokenize(query)
        guard !queryWords.isEmpty else { return [] }
        let queryCount = Double(queryWords.count)

        var allScored: [(DocumentChunk, Double)] = []

        for (_, chunks) in chunkCache {
            for chunk in chunks {
                let allWords: Set<String>
                if let cached = chunkKeywordCache[chunk.id] {
                    allWords = cached
                } else {
                    let computed = Set(chunk.keywords).union(SharedDataManager.tokenize(chunk.content))
                    chunkKeywordCache[chunk.id] = computed
                    allWords = computed
                }

                var matchedWords = 0.0
                for word in queryWords {
                    if allWords.contains(word) {
                        matchedWords += 1.0
                    } else if word.count >= 5 {
                        for entryWord in allWords where entryWord.count >= 5
                            && (entryWord.hasPrefix(word) || word.hasPrefix(entryWord)) {
                            matchedWords += 0.5
                            break
                        }
                    }
                }

                let normalizedScore = matchedWords / queryCount
                if normalizedScore >= 0.30 {
                    allScored.append((chunk, normalizedScore))
                }
            }
        }

        return allScored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    func previewChunks(for kbID: UUID, limit: Int = 5) -> [DocumentChunk] {
        let chunks = chunkCache[kbID] ?? loadChunks(for: kbID)
        return Array(chunks.prefix(limit))
    }

    // MARK: - Storage Statistics

    /// Total original file size of all imported documents.
    var totalOriginalFileSize: Int64 {
        knowledgeBases.reduce(0) { $0 + $1.fileSize }
    }

    /// Total number of chunks across all knowledge bases.
    var totalChunkCount: Int {
        knowledgeBases.reduce(0) { $0 + $1.chunkCount }
    }

    /// Total size of chunk JSON files on disk (includes embeddings).
    var totalChunkStorageSize: Int64 {
        guard let dir = SharedDataManager.chunksDirectoryURL else { return 0 }
        var total: Int64 = 0
        for kb in knowledgeBases {
            let fileURL = dir.appendingPathComponent("\(kb.id.uuidString).json")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    // MARK: - Management

    func deleteKnowledgeBase(_ kb: KnowledgeBase) {
        // Invalidate keyword caches for deleted chunks
        if let chunks = chunkCache[kb.id] {
            for chunk in chunks {
                chunkKeywordCache.removeValue(forKey: chunk.id)
            }
        }
        knowledgeBases.removeAll { $0.id == kb.id }
        chunkCache.removeValue(forKey: kb.id)
        invalidateEmbeddingMatrix()
        invertedKeywordIndex.removeAll()
        if let dir = SharedDataManager.chunksDirectoryURL {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(kb.id.uuidString).json"))
        }
        saveMetadata()
    }

    func deleteAllKnowledgeBases() {
        for kb in knowledgeBases {
            if let dir = SharedDataManager.chunksDirectoryURL {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(kb.id.uuidString).json"))
            }
        }
        knowledgeBases.removeAll()
        chunkCache.removeAll()
        chunkKeywordCache.removeAll()
        invalidateEmbeddingMatrix()
        invertedKeywordIndex.removeAll()
        saveMetadata()
    }

    func renameKnowledgeBase(_ kb: KnowledgeBase, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = knowledgeBases.firstIndex(where: { $0.id == kb.id }) else { return }
        knowledgeBases[index].name = trimmed
        knowledgeBases[index].updatedAt = Date()
        saveMetadata()
    }

    func deleteChunk(chunkID: UUID, from kbID: UUID) {
        // Update in-memory cache
        guard var chunks = chunkCache[kbID] else { return }
        chunkKeywordCache.removeValue(forKey: chunkID)
        chunks.removeAll { $0.id == chunkID }
        chunkCache[kbID] = chunks

        // Update KB metadata
        if let index = knowledgeBases.firstIndex(where: { $0.id == kbID }) {
            knowledgeBases[index].chunkCount = chunks.count
            knowledgeBases[index].updatedAt = Date()
        }

        // Invalidate matrices
        invalidateEmbeddingMatrix()
        invertedKeywordIndex.removeAll()

        // Persist changes
        saveChunks(chunks, for: kbID)
        saveMetadata()
    }

    /// Re-import a document for an existing KB, replacing all chunks but keeping the same KB identity.
    func updateDocument(for kb: KnowledgeBase, from url: URL) {
        let job = IngestionJob(
            id: UUID(),
            url: url,
            fileName: "\(kb.name) (Update)",
            status: .queued
        )
        ingestionQueue.append(job)

        Task {
            guard let jobIndex = ingestionQueue.firstIndex(where: { $0.id == job.id }) else { return }
            ingestionQueue[jobIndex].status = .processing
            isProcessing = true

            let accessing = job.url.startAccessingSecurityScopedResource()

            let outcome = await Task.detached(priority: .userInitiated) {
                await Self.ingestSingleDocument(url: job.url)
            }.value

            if accessing { job.url.stopAccessingSecurityScopedResource() }

            if let idx = ingestionQueue.firstIndex(where: { $0.id == job.id }) {
                switch outcome {
                case .success(let result):
                    ingestionQueue[idx].status = .completed

                    // Replace chunks for existing KB
                    if let kbIndex = knowledgeBases.firstIndex(where: { $0.id == kb.id }) {
                        // Clean old keyword caches
                        if let oldChunks = chunkCache[kb.id] {
                            for chunk in oldChunks {
                                chunkKeywordCache.removeValue(forKey: chunk.id)
                            }
                        }

                        // Re-key chunks to use the existing KB ID
                        let rekeyedChunks = result.chunks.map { original in
                            DocumentChunk(
                                knowledgeBaseID: kb.id,
                                content: original.content,
                                keywords: original.keywords,
                                locationLabel: original.locationLabel,
                                index: original.index,
                                embedding: original.embedding
                            )
                        }

                        chunkCache[kb.id] = rekeyedChunks
                        knowledgeBases[kbIndex].chunkCount = rekeyedChunks.count
                        knowledgeBases[kbIndex].updatedAt = Date()
                        knowledgeBases[kbIndex].embeddingModelID = result.kb.embeddingModelID

                        invalidateEmbeddingMatrix()
                        invertedKeywordIndex.removeAll()
                        saveChunks(rekeyedChunks, for: kb.id)
                        saveMetadata()
                    }

                case .failure(let reason):
                    ingestionQueue[idx].status = .failed(reason)
                }
            }
            isProcessing = false
        }
    }

    /// Ingest plain text directly (no file needed) — creates a new KB from pasted text.
    func ingestText(name: String, text: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedText.isEmpty else { return }

        isProcessing = true
        processingError = nil

        let kbID = UUID()

        Task.detached(priority: .userInitiated) { [trimmedName, trimmedText] in
            let result = await Self.ingestPlainText(
                kbID: kbID,
                name: trimmedName,
                text: trimmedText
            )

            await MainActor.run {
                switch result {
                case .success(let ingestionResult):
                    self.knowledgeBases.insert(ingestionResult.kb, at: 0)
                    self.chunkCache[ingestionResult.kb.id] = ingestionResult.chunks
                    self.invalidateEmbeddingMatrix()
                    self.invertedKeywordIndex.removeAll()
                    self.saveMetadata()
                    print("[KBStore] Ingested text '\(trimmedName)' — \(ingestionResult.chunks.count) chunks")
                case .failure(let reason):
                    self.processingError = reason
                    print("[KBStore] Text ingestion failed: \(reason)")
                }
                self.isProcessing = false
            }
        }
    }

    /// Background-safe plain text ingestion pipeline.
    nonisolated private static func ingestPlainText(
        kbID: UUID,
        name: String,
        text: String
    ) async -> IngestionOutcome {
        let sections = [("Full Text", text)]

        var allChunks: [DocumentChunk] = []
        var chunkIndex = 0

        for section in sections {
            let sectionChunks = chunkTextBackground(
                section.1,
                locationLabel: section.0,
                knowledgeBaseID: kbID,
                startIndex: &chunkIndex
            )
            allChunks.append(contentsOf: sectionChunks)
        }

        guard !allChunks.isEmpty else {
            return .failure("Text too short to create chunks")
        }

        let embeddingService = EmbeddingService.shared
        if embeddingService.isAvailable {
            for i in allChunks.indices {
                allChunks[i].embedding = embeddingService.embed(allChunks[i].content)
            }
        }

        let fileSize = Int64(text.utf8.count)
        let kb = KnowledgeBase(
            id: kbID,
            name: name,
            documentType: .text,
            chunkCount: allChunks.count,
            fileSize: fileSize,
            embeddingModelID: embeddingService.isAvailable ? embeddingService.modelIdentifier : nil
        )

        SharedDataManager.ensureDirectoriesExist()
        guard let dir = SharedDataManager.chunksDirectoryURL else {
            return .failure("Storage directory unavailable")
        }
        let fileURL = dir.appendingPathComponent("\(kbID.uuidString).json")
        do {
            let data = try JSONEncoder().encode(allChunks)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return .failure("Failed to save: \(error.localizedDescription)")
        }

        return .success(IngestionResult(kb: kb, chunks: allChunks))
    }

    /// Load all chunks for a knowledge base (full set, not just preview).
    func allChunks(for kbID: UUID) -> [DocumentChunk] {
        if let cached = chunkCache[kbID] {
            return cached
        }
        let loaded = loadChunks(for: kbID)
        chunkCache[kbID] = loaded
        return loaded
    }

    /// Calculate actual disk usage for a single knowledge base's chunk file.
    func storageSize(for kb: KnowledgeBase) -> Int64 {
        guard let dir = SharedDataManager.chunksDirectoryURL else { return 0 }
        let fileURL = dir.appendingPathComponent("\(kb.id.uuidString).json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    // MARK: - Persistence (file-based, hardened)

    private func saveMetadata() {
        SharedDataManager.ensureDirectoriesExist()
        guard let url = SharedDataManager.documentsURL?.appendingPathComponent(Self.metadataFilename) else {
            print("[KBStore] ERROR: Cannot resolve metadata file URL for save")
            return
        }
        do {
            let data = try JSONEncoder().encode(knowledgeBases)
            try data.write(to: url, options: .atomic)
            print("[KBStore] Saved \(knowledgeBases.count) knowledge bases (\(data.count) bytes)")
        } catch {
            print("[KBStore] ERROR saving metadata: \(error.localizedDescription)")
        }
    }

    private func loadMetadata() {
        guard let url = SharedDataManager.documentsURL?.appendingPathComponent(Self.metadataFilename) else {
            print("[KBStore] WARNING: Cannot resolve metadata file URL during load")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[KBStore] No metadata file found — starting fresh")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([KnowledgeBase].self, from: data)
            knowledgeBases = decoded
            print("[KBStore] Loaded \(decoded.count) knowledge bases from disk")
        } catch {
            print("[KBStore] ERROR loading metadata: \(error.localizedDescription)")
            knowledgeBases = []
        }
    }

    /// Verify that chunk files exist for all metadata entries.
    /// Removes orphaned metadata entries that have no chunk file on disk.
    private func verifyDataIntegrity() {
        guard let dir = SharedDataManager.chunksDirectoryURL else { return }
        var orphaned: [UUID] = []
        for kb in knowledgeBases {
            let fileURL = dir.appendingPathComponent("\(kb.id.uuidString).json")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                print("[KBStore] INTEGRITY: Chunk file missing for '\(kb.name)' (\(kb.id)) — removing entry")
                orphaned.append(kb.id)
            }
        }
        if !orphaned.isEmpty {
            knowledgeBases.removeAll { orphaned.contains($0.id) }
            saveMetadata()
            print("[KBStore] Removed \(orphaned.count) orphaned metadata entries")
        }
    }

    private func saveChunks(_ chunks: [DocumentChunk], for kbID: UUID) {
        SharedDataManager.ensureDirectoriesExist()
        guard let dir = SharedDataManager.chunksDirectoryURL else {
            print("[KBStore] ERROR: Cannot resolve chunks directory for save")
            return
        }
        let fileURL = dir.appendingPathComponent("\(kbID.uuidString).json")
        do {
            let data = try JSONEncoder().encode(chunks)
            try data.write(to: fileURL, options: .atomic)
            print("[KBStore] Saved \(chunks.count) chunks for KB \(kbID) (\(data.count) bytes)")
        } catch {
            print("[KBStore] ERROR saving chunks for \(kbID): \(error.localizedDescription)")
        }
    }

    private func loadChunks(for kbID: UUID) -> [DocumentChunk] {
        guard let dir = SharedDataManager.chunksDirectoryURL else {
            print("[KBStore] WARNING: Cannot resolve chunks directory for load")
            return []
        }
        let fileURL = dir.appendingPathComponent("\(kbID.uuidString).json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("[KBStore] WARNING: No chunk file found for KB \(kbID)")
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([DocumentChunk].self, from: data)
            return decoded
        } catch {
            print("[KBStore] ERROR loading chunks for \(kbID): \(error.localizedDescription)")
            return []
        }
    }

    private func ensureAllChunksLoaded() {
        var didLoad = false
        for kb in knowledgeBases where chunkCache[kb.id] == nil {
            chunkCache[kb.id] = loadChunks(for: kb.id)
            didLoad = true
        }
        if didLoad {
            invalidateEmbeddingMatrix()
            invertedKeywordIndex.removeAll()
        }
    }
}
