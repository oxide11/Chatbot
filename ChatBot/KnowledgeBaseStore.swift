import Foundation
import FoundationModels
import PDFKit
import Compression
import SwiftData
import os

// MARK: - Data Models

enum DocumentType: String, Codable, CaseIterable, Sendable {
    case pdf
    case epub
    case text
    case markdown

    var icon: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .epub: return "book"
        case .text: return "doc.text"
        case .markdown: return "text.badge.star"
        }
    }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .epub: return "ePUB"
        case .text: return "Text"
        case .markdown: return "Markdown"
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

    /// The domain this KB belongs to (nil treated as General).
    var domainID: UUID?

    nonisolated init(id: UUID = UUID(), name: String, documentType: DocumentType, chunkCount: Int, fileSize: Int64, embeddingModelID: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), domainID: UUID? = nil) {
        self.id = id
        self.name = name
        self.documentType = documentType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.chunkCount = chunkCount
        self.fileSize = fileSize
        self.embeddingModelID = embeddingModelID
        self.domainID = domainID
    }

    /// Backward-compatible decoding: old data without `updatedAt`/`domainID` uses defaults.
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
        domainID = try container.decodeIfPresent(UUID.self, forKey: .domainID)
    }
}

extension KnowledgeBase {
    /// Domain ID for filtering, treating nil as General.
    var effectiveDomainID: UUID {
        domainID ?? KnowledgeDomain.generalID
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

    /// LLM-generated 1-2 sentence summary of this chunk's content.
    /// Used for dense context injection — summaries are ~5x smaller than raw chunks.
    var summary: String?

    nonisolated init(id: UUID = UUID(), knowledgeBaseID: UUID, content: String, keywords: [String], locationLabel: String, index: Int, embedding: [Double]? = nil, summary: String? = nil) {
        self.id = id
        self.knowledgeBaseID = knowledgeBaseID
        self.content = content
        self.keywords = keywords.map { $0.lowercased() }
        self.locationLabel = locationLabel
        self.index = index
        self.embedding = embedding
        self.summary = summary
    }
}

// MARK: - Ingestion Job

struct IngestionJob: Identifiable {
    let id: UUID
    let url: URL
    let fileName: String
    var status: IngestionStatus
    let domainID: UUID

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

    /// All knowledge domains.
    private(set) var domains: [KnowledgeDomain] = []

    /// Batch ingestion queue
    private(set) var ingestionQueue: [IngestionJob] = []
    private var isQueueRunning = false

    private var chunkCache: [UUID: [DocumentChunk]] = [:]

    /// Per-domain embedding matrices for fast batch similarity scoring.
    /// Keyed by domain UUID. Invalidated per-domain when chunks change.
    private var embeddingMatrices: [UUID: EmbeddingMatrix] = [:]

    /// SwiftData actor for thread-safe persistence. Created via `configure(with:)`.
    private var dbActor: KnowledgeBaseActor?

    /// Whether `configure(with:)` has been called and initial data loaded.
    private(set) var isConfigured = false

    /// Legacy metadata filename — used only during one-time migration.
    private static let legacyMetadataFilename = "knowledge_bases.json"

    init() {
        // Lightweight init — actual data loading happens in configure(with:)
    }

    // MARK: - Configuration (SwiftData)

    /// Provide the SwiftData model container. Call once from the view layer.
    /// Creates the background actor, runs one-time JSON → SwiftData migration,
    /// loads all KB metadata and chunks, then runs re-embedding if needed.
    func configure(with modelContainer: ModelContainer) {
        guard !isConfigured else { return }
        let actor = KnowledgeBaseActor(modelContainer: modelContainer)
        self.dbActor = actor

        Task {
            // One-time migration from old JSON files
            await performMigrationIfNeeded(actor: actor)

            // Load all data from SwiftData
            await loadFromSwiftData(actor: actor)

            // Ensure domains exist (auto-create "General" on first launch)
            await ensureDomainsExist(actor: actor)

            // Re-embed stale chunks if the OS embedding model has changed
            await reembedStaleKnowledgeBasesIfNeeded(actor: actor)

            isConfigured = true
            AppLogger.kbStore.info("Configuration complete — \(self.domains.count) domains, \(self.knowledgeBases.count) KBs, \(self.chunkCache.values.reduce(0) { $0 + $1.count }) chunks loaded")
        }
    }

    /// Ensure at least the "General" domain exists. Assigns orphan KBs to it.
    private func ensureDomainsExist(actor: KnowledgeBaseActor) async {
        do {
            let loaded = try await actor.loadAllDomains()
            if loaded.isEmpty {
                let general = KnowledgeDomain.general()
                try await actor.insertDomain(general)
                try await actor.assignOrphanKBsToDomain(domainID: general.id)
                self.domains = [general]
                // Update in-memory KBs to reflect the domain assignment
                for i in knowledgeBases.indices where knowledgeBases[i].domainID == nil {
                    knowledgeBases[i].domainID = general.id
                }
            } else {
                self.domains = loaded
                // If there are orphan KBs (nil domain), assign to General
                let generalID = loaded.first(where: { $0.isDefault })?.id ?? KnowledgeDomain.generalID
                let hasOrphans = knowledgeBases.contains { $0.domainID == nil }
                if hasOrphans {
                    try await actor.assignOrphanKBsToDomain(domainID: generalID)
                    for i in knowledgeBases.indices where knowledgeBases[i].domainID == nil {
                        knowledgeBases[i].domainID = generalID
                    }
                }
            }
        } catch {
            AppLogger.kbStore.error("Failed loading domains: \(error.localizedDescription)")
        }
    }

    /// Load all knowledge bases and their chunks from SwiftData into memory.
    private func loadFromSwiftData(actor: KnowledgeBaseActor) async {
        do {
            let kbs = try await actor.loadAllKnowledgeBases()
            self.knowledgeBases = kbs
            AppLogger.kbStore.info("Loaded \(kbs.count) knowledge bases from SwiftData")

            // Eagerly load all chunks into the in-memory cache
            for kb in kbs {
                let chunks = try await actor.loadChunks(for: kb.id)
                chunkCache[kb.id] = chunks
            }

            invalidateAllEmbeddingMatrices()
            invertedKeywordIndex.removeAll()
        } catch {
            AppLogger.kbStore.error("Failed loading from SwiftData: \(error.localizedDescription)")
        }
    }

    /// One-time migration: read old JSON files → insert into SwiftData.
    private func performMigrationIfNeeded(actor: KnowledgeBaseActor) async {
        let migrationKey = "kb_migrated_to_swiftdata"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        AppLogger.kbStore.info("Starting one-time JSON → SwiftData migration…")

        // Read old metadata file
        SharedDataManager.ensureDirectoriesExist()
        guard let url = SharedDataManager.documentsURL?.appendingPathComponent(Self.legacyMetadataFilename),
              FileManager.default.fileExists(atPath: url.path) else {
            // No old data to migrate — mark as done
            UserDefaults.standard.set(true, forKey: migrationKey)
            AppLogger.kbStore.info("No legacy data found — migration skipped")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let oldKBs = try JSONDecoder().decode([KnowledgeBase].self, from: data)

            var chunksByKB: [UUID: [DocumentChunk]] = [:]
            for kb in oldKBs {
                if let dir = SharedDataManager.chunksDirectoryURL {
                    let chunkURL = dir.appendingPathComponent("\(kb.id.uuidString).json")
                    if FileManager.default.fileExists(atPath: chunkURL.path),
                       let chunkData = try? Data(contentsOf: chunkURL) {
                        let chunks = (try? JSONDecoder().decode([DocumentChunk].self, from: chunkData)) ?? []
                        chunksByKB[kb.id] = chunks
                    }
                }
            }

            try await actor.migrateFromJSON(knowledgeBases: oldKBs, chunksByKB: chunksByKB)
            UserDefaults.standard.set(true, forKey: migrationKey)
            AppLogger.kbStore.info("Migration complete — \(oldKBs.count) KBs migrated")
        } catch {
            AppLogger.kbStore.error("Migration failed: \(error.localizedDescription)")
            // Don't set the flag — retry on next launch
        }
    }

    // MARK: - Embedding Maintenance

    /// Re-embed any knowledge bases whose stored model ID doesn't match
    /// the current device's embedding model (e.g. after an OS update).
    /// Also embeds chunks that were imported before embeddings were available.
    private func reembedStaleKnowledgeBasesIfNeeded(actor: KnowledgeBaseActor) async {
        let service = EmbeddingService.shared
        guard service.isAvailable else { return }
        let currentModelID = service.modelIdentifier

        for i in knowledgeBases.indices {
            let kb = knowledgeBases[i]

            // Skip if already embedded with the current model
            if kb.embeddingModelID == currentModelID { continue }

            // Re-embed cached chunks
            guard var chunks = chunkCache[kb.id], !chunks.isEmpty else { continue }

            var embeddingUpdates: [UUID: [Double]?] = [:]
            for j in chunks.indices {
                let newEmbedding = service.embed(chunks[j].content)
                chunks[j].embedding = newEmbedding
                embeddingUpdates[chunks[j].id] = newEmbedding
            }

            chunkCache[kb.id] = chunks
            invalidateEmbeddingMatrix(for: kb.effectiveDomainID)
            invertedKeywordIndex.removeAll()

            // Persist updated embeddings to SwiftData
            do {
                try await actor.updateEmbeddings(
                    for: kb.id,
                    embeddings: embeddingUpdates,
                    embeddingModelID: currentModelID
                )
            } catch {
                AppLogger.kbStore.error("Failed persisting re-embeddings for '\(kb.name)': \(error.localizedDescription)")
            }

            // Update the model stamp in memory
            knowledgeBases[i].embeddingModelID = currentModelID
        }
    }

    // MARK: - Ingestion Pipeline

    /// Queue one or more documents for ingestion. Processing runs sequentially.
    func queueDocuments(from urls: [URL], domainID: UUID = KnowledgeDomain.generalID) {
        for url in urls {
            let job = IngestionJob(
                id: UUID(),
                url: url,
                fileName: url.deletingPathExtension().lastPathComponent,
                status: .queued,
                domainID: domainID
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

            // Run all heavy work (extraction, chunking, embedding) off the main actor
            let outcome = await Task.detached(priority: .userInitiated) {
                await Self.ingestSingleDocument(url: job.url)
            }.value

            if accessing { job.url.stopAccessingSecurityScopedResource() }

            // Update UI state back on MainActor
            if let idx = ingestionQueue.firstIndex(where: { $0.id == job.id }) {
                switch outcome {
                case .success(var result):
                    ingestionQueue[idx].status = .completed
                    result.kb.domainID = job.domainID
                    knowledgeBases.insert(result.kb, at: 0)
                    chunkCache[result.kb.id] = result.chunks
                    invalidateEmbeddingMatrix(for: job.domainID)
                    invertedKeywordIndex.removeAll()

                    // Persist to SwiftData (fire-and-forget — in-memory state is already updated)
                    if let actor = dbActor {
                        let domainID = job.domainID
                        Task {
                            do {
                                try await actor.insertKnowledgeBase(result.kb, chunks: result.chunks, domainID: domainID)
                            } catch {
                                AppLogger.kbStore.error("Failed persisting ingestion result: \(error.localizedDescription)")
                            }
                        }
                    }

                    // Regenerate the domain summary now that new content has been added
                    Task { [weak self] in
                        await self?.regenerateDomainSummary(for: job.domainID)
                    }
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
        var kb: KnowledgeBase
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
        guard ext == "pdf" || ext == "epub" || ext == "txt" || ext == "md" || ext == "markdown" else {
            return .failure("Unsupported: .\(ext)")
        }

        let docType: DocumentType
        if ext == "pdf" { docType = .pdf }
        else if ext == "epub" { docType = .epub }
        else if ext == "md" || ext == "markdown" { docType = .markdown }
        else { docType = .text }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let kbID = UUID()

        // Extract text (CPU-heavy)
        let sections: [(label: String, text: String)]
        if docType == .pdf {
            sections = extractTextFromPDFBackground(at: url)
        } else if docType == .epub {
            sections = (try? extractTextFromEPUBBackground(at: url)) ?? []
        } else if docType == .markdown {
            if let textContent = try? String(contentsOf: url, encoding: .utf8),
               !textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections = extractSectionsFromMarkdown(textContent)
            } else {
                sections = []
            }
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

        // Chunk all sections (CPU-heavy).
        // Markdown uses structure-aware chunking; other types use general paragraph-based chunking.
        var allChunks: [DocumentChunk] = []
        var chunkIndex = 0

        if docType == .markdown {
            for section in sections {
                let sectionChunks = chunkMarkdownSectionBackground(
                    section.text,
                    locationLabel: section.label,
                    knowledgeBaseID: kbID,
                    startIndex: &chunkIndex
                )
                allChunks.append(contentsOf: sectionChunks)
            }
        } else {
            for section in sections {
                let sectionChunks = chunkTextBackground(
                    section.text,
                    locationLabel: section.label,
                    knowledgeBaseID: kbID,
                    startIndex: &chunkIndex
                )
                allChunks.append(contentsOf: sectionChunks)
            }
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

        // Generate chunk summaries using the on-device LLM.
        // Each summary is 1-2 sentences — ~5x smaller than the raw chunk.
        // This runs serially to avoid overwhelming the on-device model.
        await generateChunkSummaries(for: &allChunks)

        // Build the KB metadata (persistence happens on the MainActor after return)
        let kb = KnowledgeBase(
            id: kbID,
            name: url.deletingPathExtension().lastPathComponent,
            documentType: docType,
            chunkCount: allChunks.count,
            fileSize: fileSize,
            embeddingModelID: embeddingService.isAvailable ? embeddingService.modelIdentifier : nil
        )

        return .success(IngestionResult(kb: kb, chunks: allChunks))
    }

    /// Generate concise summaries for each chunk using the on-device LLM.
    /// Runs during ingestion — one LLM call per chunk with greedy sampling for consistency.
    nonisolated private static func generateChunkSummaries(for chunks: inout [DocumentChunk]) async {
        // Only summarize chunks with enough content to warrant it
        let minContentLength = 80
        for i in chunks.indices {
            let content = chunks[i].content
            guard content.count >= minContentLength else { continue }

            do {
                let session = LanguageModelSession {
                    """
                    You are a concise summarizer. Given a text passage, write exactly 1-2 sentences \
                    that capture the key facts and main point. Do not add commentary or opinions. \
                    If the passage contains code, describe what the code does.
                    """
                }
                let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 80)
                let response = try await session.respond(to: content, options: options)
                let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !summary.isEmpty {
                    chunks[i].summary = summary
                }
            } catch {
                // Non-fatal — chunk still works without a summary
                AppLogger.kbStore.warning("Chunk summary generation failed for chunk \(chunks[i].index): \(error.localizedDescription)")
            }
        }
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

    // MARK: - Markdown Extraction & Chunking

    /// Parse a Markdown document into sections based on heading hierarchy.
    /// Each section gets a descriptive label derived from the heading path
    /// (e.g. "Installation > Prerequisites") for better retrieval context.
    nonisolated private static func extractSectionsFromMarkdown(_ text: String) -> [(label: String, text: String)] {
        let lines = text.components(separatedBy: "\n")
        var sections: [(label: String, text: String)] = []
        var currentLabel = "Introduction"
        var currentLines: [String] = []

        // Track the heading hierarchy for breadcrumb labels
        var headingStack: [(level: Int, title: String)] = []

        for line in lines {
            // Detect ATX-style headings: # Title, ## Title, etc.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let headingMatch = parseMarkdownHeading(trimmed) {
                // Flush the current section
                let sectionText = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !sectionText.isEmpty {
                    sections.append((currentLabel, sectionText))
                }

                // Update heading stack: pop any headings at the same or deeper level
                while let last = headingStack.last, last.level >= headingMatch.level {
                    headingStack.removeLast()
                }
                headingStack.append((headingMatch.level, headingMatch.title))

                // Build breadcrumb label from heading stack
                currentLabel = headingStack.map(\.title).joined(separator: " > ")
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }

        // Flush final section
        let finalText = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            sections.append((currentLabel, finalText))
        }

        // If no headings were found, return the whole document as a single section
        if sections.isEmpty {
            let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !whole.isEmpty {
                sections.append(("Full Text", whole))
            }
        }

        return sections
    }

    /// Parse a Markdown ATX heading line (e.g. "## My Title") into its level and title.
    /// Returns nil if the line is not a heading.
    nonisolated private static func parseMarkdownHeading(_ line: String) -> (level: Int, title: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for char in line {
            if char == "#" { level += 1 }
            else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let title = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (level, title)
    }

    /// Strip Markdown formatting syntax for cleaner text used in keyword extraction.
    /// Preserves the readable text content but removes: headings markers, bold/italic,
    /// links, images, code fences, and HTML tags.
    nonisolated private static func stripMarkdownFormatting(_ text: String) -> String {
        text
            // Remove code fences (```...```) — keep the code content
            .replacingOccurrences(of: "```[a-zA-Z]*\\n?", with: "", options: .regularExpression)
            // Remove inline code backticks
            .replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
            // Remove images: ![alt](url)
            .replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
            // Convert links [text](url) to just text
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
            // Remove bold **text** or __text__
            .replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "__([^_]+)__", with: "$1", options: .regularExpression)
            // Remove italic *text* or _text_ (single markers)
            .replacingOccurrences(of: "(?<![*])\\*([^*]+)\\*(?![*])", with: "$1", options: .regularExpression)
            // Remove heading markers
            .replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            // Remove blockquote markers
            .replacingOccurrences(of: "^>\\s?", with: "", options: [.regularExpression, .anchorsMatchLines])
            // Remove horizontal rules
            .replacingOccurrences(of: "^[-*_]{3,}$", with: "", options: [.regularExpression, .anchorsMatchLines])
            // Remove HTML tags
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Structure-aware Markdown chunking: respects block boundaries (paragraphs,
    /// code blocks, lists) rather than splitting purely by character count.
    ///
    /// Key differences from general chunking:
    /// - Code blocks (``` fenced) are never split mid-block
    /// - Paragraph boundaries are preserved as chunk boundaries
    /// - Keywords are extracted from stripped Markdown (no syntax noise)
    /// - Overlap uses the last complete paragraph instead of raw character slicing
    nonisolated private static func chunkMarkdownSectionBackground(
        _ text: String,
        locationLabel: String,
        knowledgeBaseID: UUID,
        startIndex: inout Int
    ) -> [DocumentChunk] {
        let config = chunkingConfig
        var chunks: [DocumentChunk] = []

        // Split into logical blocks: paragraphs and fenced code blocks
        let blocks = splitMarkdownIntoBlocks(text)

        var currentChunk = ""
        var lastBlock = ""  // Track last block for paragraph-aligned overlap

        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if currentChunk.count + trimmed.count + 2 > config.targetCharacters
                && currentChunk.count >= config.minChunkCharacters {
                // Emit current chunk
                let strippedForKeywords = stripMarkdownFormatting(currentChunk)
                let keywords = Array(SharedDataManager.extractKeywords(from: strippedForKeywords, limit: 8))
                chunks.append(DocumentChunk(
                    knowledgeBaseID: knowledgeBaseID,
                    content: currentChunk.trimmingCharacters(in: .whitespacesAndNewlines),
                    keywords: keywords,
                    locationLabel: locationLabel,
                    index: startIndex
                ))
                startIndex += 1

                // Paragraph-aligned overlap: start new chunk with the last complete block
                if lastBlock.count <= config.overlapCharacters {
                    currentChunk = lastBlock + "\n\n" + trimmed
                } else {
                    currentChunk = trimmed
                }
            } else {
                if !currentChunk.isEmpty { currentChunk += "\n\n" }
                currentChunk += trimmed
            }
            lastBlock = trimmed
        }

        // Emit remaining text
        let remaining = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if remaining.count >= config.minChunkCharacters {
            let strippedForKeywords = stripMarkdownFormatting(remaining)
            let keywords = Array(SharedDataManager.extractKeywords(from: strippedForKeywords, limit: 8))
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
            let merged = chunks[last].content + "\n\n" + remaining
            let strippedForKeywords = stripMarkdownFormatting(merged)
            chunks[last] = DocumentChunk(
                knowledgeBaseID: knowledgeBaseID,
                content: merged,
                keywords: Array(SharedDataManager.extractKeywords(from: strippedForKeywords, limit: 8)),
                locationLabel: chunks[last].locationLabel,
                index: chunks[last].index
            )
        }

        return chunks
    }

    /// Split Markdown text into logical blocks, keeping fenced code blocks intact.
    /// Regular paragraphs are split on double newlines; code fences are preserved whole.
    nonisolated private static func splitMarkdownIntoBlocks(_ text: String) -> [String] {
        var blocks: [String] = []
        let lines = text.components(separatedBy: "\n")
        var currentBlock = ""
        var inCodeFence = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeFence {
                    // End of code fence — emit the whole code block as one block
                    currentBlock += "\n" + line
                    blocks.append(currentBlock)
                    currentBlock = ""
                    inCodeFence = false
                } else {
                    // Start of code fence — flush any preceding text first
                    let pending = currentBlock.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !pending.isEmpty {
                        // Split pending text on double newlines (paragraph boundaries)
                        let paragraphs = pending.components(separatedBy: "\n\n")
                            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        blocks.append(contentsOf: paragraphs)
                    }
                    currentBlock = line
                    inCodeFence = true
                }
            } else if inCodeFence {
                currentBlock += "\n" + line
            } else if trimmed.isEmpty {
                // Paragraph boundary
                let pending = currentBlock.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty {
                    blocks.append(pending)
                    currentBlock = ""
                }
            } else {
                if !currentBlock.isEmpty { currentBlock += "\n" }
                currentBlock += line
            }
        }

        // Flush final block
        let pending = currentBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty {
            blocks.append(pending)
        }

        return blocks
    }

    // MARK: - ZIP Extraction

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
    /// Uses paragraph-aligned overlap instead of raw character slicing to avoid
    /// cutting mid-word/mid-sentence, which degrades embedding quality.
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
        var lastParagraph = ""  // Track last paragraph for clean overlap

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

                // Paragraph-aligned overlap: use the last complete paragraph instead of
                // slicing at a raw character offset (which can cut mid-word/sentence).
                if lastParagraph.count <= config.overlapCharacters {
                    currentChunk = lastParagraph + "\n\n" + trimmed
                } else {
                    // Last paragraph itself exceeds overlap budget — use sentence-boundary fallback
                    let overlapText = sentenceBoundaryOverlap(lastParagraph, maxChars: config.overlapCharacters)
                    currentChunk = overlapText + "\n\n" + trimmed
                }
            } else {
                if !currentChunk.isEmpty { currentChunk += "\n\n" }
                currentChunk += trimmed
            }
            lastParagraph = trimmed
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

    /// Extract the last complete sentence(s) from a paragraph, up to maxChars.
    /// Falls back to word-boundary slicing if no sentence boundary is found.
    nonisolated private static func sentenceBoundaryOverlap(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }

        // Look for the last sentence boundary (. ! ? followed by space or end) within the tail
        let tail = String(text.suffix(maxChars + 50))  // slight overshoot to find boundary
        let sentenceEndings = CharacterSet(charactersIn: ".!?")

        // Scan from the start of tail to find a sentence boundary
        var bestCut = tail.startIndex
        var foundBoundary = false
        for i in tail.indices {
            let char = tail[i]
            if char.unicodeScalars.allSatisfy({ sentenceEndings.contains($0) }) {
                let next = tail.index(after: i)
                if next < tail.endIndex && tail[next] == " " {
                    bestCut = next
                    foundBoundary = true
                } else if next == tail.endIndex {
                    bestCut = next
                    foundBoundary = true
                }
            }
        }

        if foundBoundary {
            let result = String(tail[bestCut...]).trimmingCharacters(in: .whitespaces)
            if !result.isEmpty && result.count <= maxChars { return result }
        }

        // Fallback: word-boundary slicing (find the first space from the overlap start)
        let overlapStart = max(0, text.count - maxChars)
        let startIdx = text.index(text.startIndex, offsetBy: overlapStart)
        let tailSlice = text[startIdx...]
        if let firstSpace = tailSlice.firstIndex(of: " ") {
            return String(tailSlice[tailSlice.index(after: firstSpace)...])
        }
        return String(tailSlice)
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
        var lastParagraph = ""

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

                // Paragraph-aligned overlap instead of raw character slicing
                if lastParagraph.count <= config.overlapCharacters {
                    currentChunk = lastParagraph + "\n\n" + trimmed
                } else {
                    let overlapText = Self.sentenceBoundaryOverlap(lastParagraph, maxChars: config.overlapCharacters)
                    currentChunk = overlapText + "\n\n" + trimmed
                }
            } else {
                if !currentChunk.isEmpty { currentChunk += "\n\n" }
                currentChunk += trimmed
            }
            lastParagraph = trimmed
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

    /// Rebuild the embedding matrix for a specific domain from filtered chunk cache.
    private func rebuildEmbeddingMatrix(for domainID: UUID) {
        let dim = EmbeddingService.shared.dimension
        guard dim > 0 else {
            embeddingMatrices[domainID] = nil
            return
        }
        let filteredCache = chunkCache.filter { kbID, _ in
            knowledgeBases.first(where: { $0.id == kbID })?.effectiveDomainID == domainID
        }
        embeddingMatrices[domainID] = EmbeddingMatrix.build(from: filteredCache, dimension: dim)
    }

    /// Invalidate the embedding matrix for a specific domain.
    private func invalidateEmbeddingMatrix(for domainID: UUID) {
        embeddingMatrices.removeValue(forKey: domainID)
    }

    /// Invalidate all domain embedding matrices (used during bulk operations).
    private func invalidateAllEmbeddingMatrices() {
        embeddingMatrices.removeAll()
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

    // MARK: - BM25 Lexical Scoring

    /// Compute BM25 scores for all chunks in a domain against the given query.
    /// Returns a dictionary of chunk UUID → BM25 score.
    ///
    /// BM25 parameters:
    /// - k1 = 1.2 (term frequency saturation)
    /// - b = 0.75 (length normalization)
    ///
    /// This is a simplified BM25 that uses our existing keyword cache as the
    /// term-frequency source. Scores are normalized to [0, 1] for fusion with dense scores.
    private func computeBM25Scores(query: String, domainID: UUID) -> [UUID: Float] {
        // Ensure caches are built
        if invertedKeywordIndex.isEmpty {
            rebuildInvertedIndex()
        }

        let queryWords = SharedDataManager.tokenize(query)
        guard !queryWords.isEmpty else { return [:] }

        // Collect domain chunk IDs and compute average document length
        let domainKBIDs = Set(knowledgeBases.filter { $0.effectiveDomainID == domainID }.map(\.id))
        var domainChunkIDs: [UUID] = []
        var totalWordCount: Double = 0

        for (kbID, chunks) in chunkCache where domainKBIDs.contains(kbID) {
            for chunk in chunks {
                domainChunkIDs.append(chunk.id)
                let words = chunkKeywordCache[chunk.id] ?? Set(chunk.keywords).union(SharedDataManager.tokenize(chunk.content))
                if chunkKeywordCache[chunk.id] == nil {
                    chunkKeywordCache[chunk.id] = words
                }
                totalWordCount += Double(words.count)
            }
        }

        let n = Double(domainChunkIDs.count)
        guard n > 0 else { return [:] }
        let avgDL = totalWordCount / n

        // BM25 parameters
        let k1 = 1.2
        let b = 0.75

        // Compute IDF for each query term (using domain scope)
        let domainChunkSet = Set(domainChunkIDs)
        var termIDF: [String: Double] = [:]
        for word in queryWords {
            let docsContaining = invertedKeywordIndex[word]?.intersection(domainChunkSet).count ?? 0
            // IDF with smoothing: log((N - n(t) + 0.5) / (n(t) + 0.5) + 1)
            let idf = log((n - Double(docsContaining) + 0.5) / (Double(docsContaining) + 0.5) + 1.0)
            termIDF[word] = idf
        }

        // Score each chunk
        var scores: [UUID: Float] = [:]
        var maxScore: Float = 0

        for chunkID in domainChunkIDs {
            guard let words = chunkKeywordCache[chunkID] else { continue }
            let dl = Double(words.count)
            var score: Double = 0

            for queryWord in queryWords {
                guard let idf = termIDF[queryWord] else { continue }

                // Term frequency: 1 if word is present (our keyword sets are deduplicated)
                // For exact matches, tf=1. For prefix matches, tf=0.5.
                var tf: Double = 0
                if words.contains(queryWord) {
                    tf = 1.0
                } else if queryWord.count >= 4 {
                    // Prefix match for morphological variants
                    for w in words where w.count >= 4 {
                        if w.hasPrefix(queryWord) || queryWord.hasPrefix(w) {
                            tf = 0.5
                            break
                        }
                    }
                }
                guard tf > 0 else { continue }

                // BM25 formula: IDF * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * dl / avgDL))
                let numerator = tf * (k1 + 1.0)
                let denominator = tf + k1 * (1.0 - b + b * dl / avgDL)
                score += idf * (numerator / denominator)
            }

            if score > 0 {
                let floatScore = Float(score)
                scores[chunkID] = floatScore
                maxScore = max(maxScore, floatScore)
            }
        }

        // Normalize to [0, 1] for fusion with dense scores
        if maxScore > 0 {
            for (id, score) in scores {
                scores[id] = score / maxScore
            }
        }

        return scores
    }

    /// Retrieve the most relevant document chunks for a query, scoped to a domain.
    ///
    /// **Primary path:** Batch cosine similarity via Accelerate/vDSP against the
    /// per-domain embedding matrix. With many chunks, uses a two-phase approach:
    /// keyword pre-filter → semantic re-rank on the smaller candidate set.
    ///
    /// **Fallback:** Keyword overlap (used when embedding assets aren't downloaded yet
    /// or chunks were imported before embeddings were available).
    func retrieve(for query: String, domainID: UUID = KnowledgeDomain.generalID, limit: Int = 3, lexicalWeight: Float = 0.3) -> [DocumentChunk] {
        ensureAllChunksLoaded()

        let embeddingService = EmbeddingService.shared

        // Try hybrid retrieval (dense + lexical) first
        if let queryVector = embeddingService.embed(query) {
            // Compute BM25 lexical scores for score fusion
            let bm25Scores = computeBM25Scores(query: query, domainID: domainID)

            let results = retrieveBySimilarity(
                queryVector: queryVector, query: query, domainID: domainID,
                limit: limit, bm25Scores: bm25Scores, lexicalWeight: lexicalWeight
            )

            // Cross-domain fallback: if the current domain yields no results and other domains
            // have summaries, find the best-matching domain via embedding similarity and search there.
            if results.isEmpty && domains.count > 1 {
                if let bestDomain = bestDomainForQuery(queryVector: queryVector, excludingDomain: domainID) {
                    let crossBM25 = computeBM25Scores(query: query, domainID: bestDomain)
                    return retrieveBySimilarity(
                        queryVector: queryVector, query: query, domainID: bestDomain,
                        limit: limit, bm25Scores: crossBM25, lexicalWeight: lexicalWeight
                    )
                }
            }

            return results
        }

        // Fallback: keyword matching (when embeddings unavailable)
        return retrieveByKeywords(query: query, domainID: domainID, limit: limit)
    }

    /// Find the domain whose summary best matches the query, excluding the given domain.
    /// Returns nil if no domain has a summary or if no match exceeds the threshold.
    private func bestDomainForQuery(queryVector: [Double], excludingDomain: UUID) -> UUID? {
        let embeddingService = EmbeddingService.shared
        guard embeddingService.isAvailable else { return nil }

        var bestScore: Double = 0.3 // Minimum threshold
        var bestDomainID: UUID?

        for domain in domains where domain.id != excludingDomain {
            guard let summary = domain.summary, !summary.isEmpty else { continue }
            guard let summaryVector = embeddingService.embed(summary) else { continue }
            let score = EmbeddingService.cosineSimilarity(queryVector, summaryVector)
            if score > bestScore {
                bestScore = score
                bestDomainID = domain.id
            }
        }

        return bestDomainID
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
    private func retrieveBySimilarity(queryVector: [Double], query: String, domainID: UUID, limit: Int, bm25Scores: [UUID: Float] = [:], lexicalWeight: Float = 0.3) -> [DocumentChunk] {
        // Ensure the per-domain embedding matrix is built
        if embeddingMatrices[domainID] == nil {
            rebuildEmbeddingMatrix(for: domainID)
        }
        guard let matrix = embeddingMatrices[domainID], matrix.rowCount > 0 else {
            return [] // No embedded chunks available for this domain
        }

        // Determine total chunk count for strategy selection
        let totalChunks = matrix.rowCount

        // Two-phase for large corpora
        if totalChunks >= 200 {
            return twoPhaseRetrieval(queryVector: queryVector, query: query, domainID: domainID, limit: limit, matrix: matrix, bm25Scores: bm25Scores, lexicalWeight: lexicalWeight)
        }

        // Full matrix scan for small corpora — fast enough with Accelerate
        return fullMatrixRetrieval(queryVector: queryVector, limit: limit, matrix: matrix, bm25Scores: bm25Scores, lexicalWeight: lexicalWeight)
    }

    /// Full matrix batch dot product — scores all chunks at once via Float32 BLAS.
    /// Since embeddings are pre-normalized, dot product = cosine similarity.
    /// When BM25 scores are provided, fuses dense and lexical scores for hybrid retrieval.
    private func fullMatrixRetrieval(queryVector: [Double], limit: Int, matrix: EmbeddingMatrix, bm25Scores: [UUID: Float] = [:], lexicalWeight: Float = 0.3) -> [DocumentChunk] {
        let floatQuery = EmbeddingMatrix.prepareQuery(queryVector, dimension: matrix.dimension)

        var similarities = EmbeddingService.batchDotProduct(
            query: floatQuery,
            matrix: matrix.data,
            count: matrix.rowCount,
            dimension: matrix.dimension
        )

        // Fuse dense + lexical scores when BM25 data is available
        if !bm25Scores.isEmpty {
            let denseWeight: Float = 1.0 - lexicalWeight
            for i in 0 ..< similarities.count {
                let mapping = matrix.rowMap[i]
                let chunk = chunkCache[mapping.knowledgeBaseID]?[mapping.chunkIndex]
                let bm25 = chunk.flatMap { bm25Scores[$0.id] } ?? 0
                // Hybrid score: weighted combination of dense cosine similarity and BM25
                similarities[i] = denseWeight * similarities[i] + lexicalWeight * bm25
            }
        }

        // Top-K selection using partial sort (faster than full sort for small K)
        return topK(similarities: similarities, matrix: matrix, limit: limit, threshold: 0.2)
    }

    /// Two-phase retrieval: keyword pre-filter → hybrid (dense + lexical) re-rank.
    private func twoPhaseRetrieval(queryVector: [Double], query: String, domainID: UUID, limit: Int, matrix: EmbeddingMatrix, bm25Scores: [UUID: Float] = [:], lexicalWeight: Float = 0.3) -> [DocumentChunk] {
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
            return fullMatrixRetrieval(queryVector: queryVector, limit: limit, matrix: matrix, bm25Scores: bm25Scores, lexicalWeight: lexicalWeight)
        }

        // Phase 2: Build a smaller Float32 matrix from candidates and score
        let dim = matrix.dimension
        var subMatrix: [Float] = []
        var subRowMap: [(UUID, Int)] = []

        subMatrix.reserveCapacity(candidateChunkIDs.count * dim)

        for (rowIdx, mapping) in matrix.rowMap.enumerated() {
            let chunk = chunkCache[mapping.knowledgeBaseID]?[mapping.chunkIndex]
            guard let chunk, candidateChunkIDs.contains(chunk.id) else { continue }

            // Copy this row's embedding from the full matrix
            let start = rowIdx * dim
            let end = start + dim
            subMatrix.append(contentsOf: matrix.data[start ..< end])
            subRowMap.append(mapping)
        }

        guard !subRowMap.isEmpty else {
            return fullMatrixRetrieval(queryVector: queryVector, limit: limit, matrix: matrix, bm25Scores: bm25Scores, lexicalWeight: lexicalWeight)
        }

        let floatQuery = EmbeddingMatrix.prepareQuery(queryVector, dimension: dim)

        var similarities = EmbeddingService.batchDotProduct(
            query: floatQuery,
            matrix: subMatrix,
            count: subRowMap.count,
            dimension: dim
        )

        // Fuse dense + lexical scores for the candidate subset
        if !bm25Scores.isEmpty {
            let denseWeight: Float = 1.0 - lexicalWeight
            for i in 0 ..< similarities.count {
                let mapping = subRowMap[i]
                let chunk = chunkCache[mapping.knowledgeBaseID]?[mapping.chunkIndex]
                let bm25 = chunk.flatMap { bm25Scores[$0.id] } ?? 0
                similarities[i] = denseWeight * similarities[i] + lexicalWeight * bm25
            }
        }

        // Use the sub-matrix row map for resolution
        let subEmbeddingMatrix = EmbeddingMatrix(
            data: subMatrix,
            dimension: dim,
            rowCount: subRowMap.count,
            rowMap: subRowMap
        )

        return topK(similarities: similarities, matrix: subEmbeddingMatrix, limit: limit, threshold: 0.2)
    }

    /// Extract the top-K results from a Float32 similarity array using partial sort.
    /// More efficient than full sort when K << N.
    private func topK(similarities: [Float], matrix: EmbeddingMatrix, limit: Int, threshold: Float) -> [DocumentChunk] {
        // Use a min-heap approach: maintain the K best scores
        // For typical K=3 and N=1000+, this is O(N log K) vs O(N log N) for full sort
        struct ScoredRow: Comparable {
            let rowIndex: Int
            let score: Float
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

    /// Keyword fallback: normalized word overlap scoring, scoped to a domain.
    private func retrieveByKeywords(query: String, domainID: UUID, limit: Int) -> [DocumentChunk] {
        let queryWords = SharedDataManager.tokenize(query)
        guard !queryWords.isEmpty else { return [] }
        let queryCount = Double(queryWords.count)

        // Filter chunk cache to the requested domain
        let domainKBIDs = Set(knowledgeBases.filter { $0.effectiveDomainID == domainID }.map { $0.id })

        var allScored: [(DocumentChunk, Double)] = []

        for (kbID, chunks) in chunkCache where domainKBIDs.contains(kbID) {
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
        let chunks = chunkCache[kbID] ?? []
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

    /// Estimated total storage used by all knowledge bases (content + embeddings).
    var totalChunkStorageSize: Int64 {
        var total: Int64 = 0
        for (_, chunks) in chunkCache {
            for chunk in chunks {
                total += Int64(chunk.content.utf8.count)
                if chunk.embedding != nil {
                    total += Int64(512 * MemoryLayout<Double>.size) // 4096 bytes per embedding
                }
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
        let affectedDomain = kb.effectiveDomainID
        knowledgeBases.removeAll { $0.id == kb.id }
        chunkCache.removeValue(forKey: kb.id)
        invalidateEmbeddingMatrix(for: affectedDomain)
        invertedKeywordIndex.removeAll()

        // Persist deletion to SwiftData
        if let actor = dbActor {
            Task {
                do { try await actor.deleteKnowledgeBase(id: kb.id) }
                catch { AppLogger.kbStore.error("Failed deleting KB from SwiftData: \(error.localizedDescription)") }
            }
        }
    }

    func deleteAllKnowledgeBases() {
        knowledgeBases.removeAll()
        chunkCache.removeAll()
        chunkKeywordCache.removeAll()
        invalidateAllEmbeddingMatrices()
        invertedKeywordIndex.removeAll()

        // Persist deletion to SwiftData
        if let actor = dbActor {
            Task {
                do { try await actor.deleteAllKnowledgeBases() }
                catch { AppLogger.kbStore.error("Failed deleting all KBs: \(error.localizedDescription)") }
            }
        }
    }

    func renameKnowledgeBase(_ kb: KnowledgeBase, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = knowledgeBases.firstIndex(where: { $0.id == kb.id }) else { return }
        knowledgeBases[index].name = trimmed
        knowledgeBases[index].updatedAt = Date()

        // Persist to SwiftData
        if let actor = dbActor {
            Task {
                do { try await actor.renameKnowledgeBase(id: kb.id, to: trimmed) }
                catch { AppLogger.kbStore.error("Failed renaming KB: \(error.localizedDescription)") }
            }
        }
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

        // Invalidate matrices for the affected domain
        let affectedDomain = knowledgeBases.first(where: { $0.id == kbID })?.effectiveDomainID ?? KnowledgeDomain.generalID
        invalidateEmbeddingMatrix(for: affectedDomain)
        invertedKeywordIndex.removeAll()

        // Persist to SwiftData
        if let actor = dbActor {
            Task {
                do { try await actor.deleteChunk(id: chunkID, from: kbID) }
                catch { AppLogger.kbStore.error("Failed deleting chunk: \(error.localizedDescription)") }
            }
        }
    }

    /// Re-import a document for an existing KB, replacing all chunks but keeping the same KB identity.
    func updateDocument(for kb: KnowledgeBase, from url: URL) {
        let job = IngestionJob(
            id: UUID(),
            url: url,
            fileName: "\(kb.name) (Update)",
            status: .queued,
            domainID: kb.effectiveDomainID
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

                        invalidateEmbeddingMatrix(for: kb.effectiveDomainID)
                        invertedKeywordIndex.removeAll()

                        // Persist to SwiftData
                        if let actor = dbActor {
                            Task {
                                do {
                                    try await actor.replaceChunks(
                                        for: kb.id,
                                        newChunks: rekeyedChunks,
                                        embeddingModelID: result.kb.embeddingModelID
                                    )
                                } catch {
                                    AppLogger.kbStore.error("Failed persisting re-import: \(error.localizedDescription)")
                                }
                            }
                        }
                    }

                case .failure(let reason):
                    ingestionQueue[idx].status = .failed(reason)
                }
            }
            isProcessing = false
        }
    }

    /// Ingest plain text directly (no file needed) — creates a new KB from pasted text.
    func ingestText(name: String, text: String, domainID: UUID = KnowledgeDomain.generalID) {
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
                case .success(var ingestionResult):
                    ingestionResult.kb.domainID = domainID
                    self.knowledgeBases.insert(ingestionResult.kb, at: 0)
                    self.chunkCache[ingestionResult.kb.id] = ingestionResult.chunks
                    self.invalidateEmbeddingMatrix(for: domainID)
                    self.invertedKeywordIndex.removeAll()
                    AppLogger.kbStore.info("Ingested text '\(trimmedName)' — \(ingestionResult.chunks.count) chunks")

                    // Persist to SwiftData
                    if let actor = self.dbActor {
                        Task {
                            do {
                                try await actor.insertKnowledgeBase(ingestionResult.kb, chunks: ingestionResult.chunks, domainID: domainID)
                            } catch {
                                AppLogger.kbStore.error("Failed persisting text ingestion: \(error.localizedDescription)")
                            }
                        }
                    }
                case .failure(let reason):
                    self.processingError = reason
                    AppLogger.kbStore.error("Text ingestion failed: \(reason)")
                }
                self.isProcessing = false
            }
        }
    }

    /// Background-safe plain text ingestion pipeline.
    /// No file I/O — just extraction, chunking, and embedding.
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

        return .success(IngestionResult(kb: kb, chunks: allChunks))
    }

    /// Load all chunks for a knowledge base (full set, not just preview).
    func allChunks(for kbID: UUID) -> [DocumentChunk] {
        return chunkCache[kbID] ?? []
    }

    /// Estimated storage size for a single knowledge base.
    func storageSize(for kb: KnowledgeBase) -> Int64 {
        guard let chunks = chunkCache[kb.id] else { return 0 }
        var total: Int64 = 0
        for chunk in chunks {
            total += Int64(chunk.content.utf8.count)
            if chunk.embedding != nil {
                total += Int64(512 * MemoryLayout<Double>.size)
            }
        }
        return total
    }

    // MARK: - Export

    /// Export a knowledge base as a JSON file for sharing.
    /// Returns a temporary file URL suitable for `ShareLink` or `UIActivityViewController`.
    func exportKnowledgeBase(_ kb: KnowledgeBase) -> URL? {
        let chunks = allChunks(for: kb.id)

        struct ExportData: Encodable {
            let knowledgeBase: KnowledgeBase
            let chunks: [DocumentChunk]
            let exportDate: Date
        }

        let export = ExportData(
            knowledgeBase: kb,
            chunks: chunks,
            exportDate: Date()
        )

        // Sanitize filename
        let safeName = kb.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(100)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).engram-kb.json")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(export)
            try data.write(to: tempURL, options: .atomic)
            AppLogger.kbStore.info("Exported KB '\(kb.name)' — \(data.count) bytes")
            return tempURL
        } catch {
            AppLogger.kbStore.error("Failed exporting KB: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Chunk Loading

    /// Ensure all knowledge bases have their chunks loaded into the in-memory cache.
    /// After `configure()`, all chunks are already loaded, so this is a fast no-op
    /// for normal operation. Only triggers a load for KBs that somehow missed caching.
    private func ensureAllChunksLoaded() {
        // All chunks are eagerly loaded during configure(). This check handles edge cases.
        let missingKBs = knowledgeBases.filter { chunkCache[$0.id] == nil }
        guard !missingKBs.isEmpty else { return }

        // Load missing chunks asynchronously via the actor
        if let actor = dbActor {
            Task {
                for kb in missingKBs {
                    do {
                        let chunks = try await actor.loadChunks(for: kb.id)
                        chunkCache[kb.id] = chunks
                    } catch {
                        AppLogger.kbStore.error("Failed lazy-loading chunks for '\(kb.name)': \(error.localizedDescription)")
                        chunkCache[kb.id] = []
                    }
                }
                invalidateAllEmbeddingMatrices()
                invertedKeywordIndex.removeAll()
            }
        }
    }

    // MARK: - Domain Management

    /// Return KBs filtered for a specific domain.
    func knowledgeBases(for domainID: UUID) -> [KnowledgeBase] {
        knowledgeBases.filter { $0.effectiveDomainID == domainID }
    }

    /// Create a new domain and persist it.
    func createDomain(name: String) -> KnowledgeDomain {
        let domain = KnowledgeDomain(name: name)
        domains.append(domain)
        if let actor = dbActor {
            Task {
                do { try await actor.insertDomain(domain) }
                catch { AppLogger.kbStore.error("Failed persisting new domain: \(error.localizedDescription)") }
            }
        }
        return domain
    }

    /// Rename an existing domain.
    func renameDomain(_ domain: KnowledgeDomain, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = domains.firstIndex(where: { $0.id == domain.id }) else { return }
        domains[index].name = trimmed
        if let actor = dbActor {
            Task {
                do { try await actor.renameDomain(id: domain.id, to: trimmed) }
                catch { AppLogger.kbStore.error("Failed renaming domain: \(error.localizedDescription)") }
            }
        }
    }

    /// Delete a domain, moving its KBs to the General domain first.
    func deleteDomain(_ domain: KnowledgeDomain) {
        guard !domain.isDefault else { return } // Cannot delete General

        let generalID = domains.first(where: { $0.isDefault })?.id ?? KnowledgeDomain.generalID

        // Capture IDs of KBs to move *before* the in-memory mutation.
        let kbIDsToMove = knowledgeBases
            .filter { $0.effectiveDomainID == domain.id }
            .map(\.id)

        // Move all KBs in this domain to General (in-memory)
        for i in knowledgeBases.indices where knowledgeBases[i].effectiveDomainID == domain.id {
            knowledgeBases[i].domainID = generalID
        }
        invalidateEmbeddingMatrix(for: generalID)
        invalidateEmbeddingMatrix(for: domain.id)

        domains.removeAll { $0.id == domain.id }

        if let actor = dbActor {
            let domainID = domain.id
            Task {
                do {
                    // Move KBs to General in SwiftData, then delete the domain.
                    for kbID in kbIDsToMove {
                        try await actor.moveKnowledgeBase(kbID: kbID, toDomainID: generalID)
                    }
                    try await actor.deleteDomain(id: domainID)
                } catch {
                    AppLogger.kbStore.error("Failed deleting domain: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Move a knowledge base to a different domain.
    func moveKnowledgeBase(_ kb: KnowledgeBase, toDomain targetDomainID: UUID) {
        guard let index = knowledgeBases.firstIndex(where: { $0.id == kb.id }) else { return }
        let oldDomainID = kb.effectiveDomainID
        knowledgeBases[index].domainID = targetDomainID
        invalidateEmbeddingMatrix(for: oldDomainID)
        invalidateEmbeddingMatrix(for: targetDomainID)
        invertedKeywordIndex.removeAll()

        if let actor = dbActor {
            Task {
                do { try await actor.moveKnowledgeBase(kbID: kb.id, toDomainID: targetDomainID) }
                catch { AppLogger.kbStore.error("Failed moving KB: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Domain Summary Generation

    /// Regenerate the LLM-generated summary for a domain based on its knowledge bases.
    /// Called after ingestion or KB deletion to keep the domain summary current.
    func regenerateDomainSummary(for domainID: UUID) async {
        let domainKBs = knowledgeBases(for: domainID)
        guard !domainKBs.isEmpty else {
            // No KBs — clear any existing summary
            if let idx = domains.firstIndex(where: { $0.id == domainID }) {
                domains[idx].summary = nil
                if let actor = dbActor {
                    Task { try? await actor.updateDomainSummary(id: domainID, summary: "") }
                }
            }
            return
        }

        // Collect chunk summaries (or first sentence of content) for each KB to build an overview
        var kbDescriptions: [String] = []
        for kb in domainKBs {
            var chunkPreviews: [String] = []
            if let cached = chunkCache[kb.id] {
                for chunk in cached.prefix(5) {
                    // Prefer the summary if available, otherwise use a truncated content preview
                    if let summary = chunk.summary, !summary.isEmpty {
                        chunkPreviews.append(summary)
                    } else {
                        let preview = String(chunk.content.prefix(150))
                        chunkPreviews.append(preview)
                    }
                }
            }
            let previews = chunkPreviews.joined(separator: " ")
            kbDescriptions.append("\(kb.name): \(previews)")
        }

        let input = kbDescriptions.joined(separator: "\n---\n")

        do {
            let session = LanguageModelSession {
                """
                You are a knowledge base cataloger. Given descriptions of documents in a knowledge domain, \
                write a concise 2-3 sentence summary of what this domain covers. \
                Focus on the main topics, subject areas, and types of information available. \
                Do not list individual documents — describe the domain as a whole.
                """
            }
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 120)
            let response = try await session.respond(to: input, options: options)
            let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

            if !summary.isEmpty, let idx = domains.firstIndex(where: { $0.id == domainID }) {
                domains[idx].summary = summary
                if let actor = dbActor {
                    try? await actor.updateDomainSummary(id: domainID, summary: summary)
                }
                AppLogger.kbStore.info("Generated domain summary for '\(domains[idx].name)': \(summary.prefix(80))...")
            }
        } catch {
            AppLogger.kbStore.warning("Domain summary generation failed: \(error.localizedDescription)")
        }
    }
}
