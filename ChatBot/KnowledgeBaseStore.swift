import Foundation
import PDFKit
import Compression

// MARK: - Data Models

enum DocumentType: String, Codable, CaseIterable {
    case pdf
    case epub

    var icon: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .epub: return "book"
        }
    }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .epub: return "ePUB"
        }
    }
}

struct KnowledgeBase: Identifiable, Codable {
    let id: UUID
    var name: String
    let documentType: DocumentType
    let createdAt: Date
    var chunkCount: Int
    let fileSize: Int64

    init(id: UUID = UUID(), name: String, documentType: DocumentType, chunkCount: Int, fileSize: Int64) {
        self.id = id
        self.name = name
        self.documentType = documentType
        self.createdAt = Date()
        self.chunkCount = chunkCount
        self.fileSize = fileSize
    }
}

struct DocumentChunk: Identifiable, Codable {
    let id: UUID
    let knowledgeBaseID: UUID
    let content: String
    let keywords: [String]
    let locationLabel: String
    let index: Int

    init(knowledgeBaseID: UUID, content: String, keywords: [String], locationLabel: String, index: Int) {
        self.id = UUID()
        self.knowledgeBaseID = knowledgeBaseID
        self.content = content
        self.keywords = keywords.map { $0.lowercased() }
        self.locationLabel = locationLabel
        self.index = index
    }
}

// MARK: - Knowledge Base Store

@Observable
final class KnowledgeBaseStore {
    private(set) var knowledgeBases: [KnowledgeBase] = []
    private(set) var isProcessing = false
    private(set) var processingProgress: Double = 0
    private(set) var processingError: String?

    private var chunkCache: [UUID: [DocumentChunk]] = [:]

    private static let metadataFilename = "knowledge_bases.json"

    init() {
        loadMetadata()
    }

    // MARK: - Ingestion Pipeline

    func ingestDocument(from url: URL) async {
        await MainActor.run {
            isProcessing = true
            processingProgress = 0
            processingError = nil
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard ext == "pdf" || ext == "epub" else {
            await MainActor.run {
                processingError = "Unsupported file type: .\(ext)"
                isProcessing = false
            }
            return
        }

        let docType: DocumentType = ext == "pdf" ? .pdf : .epub
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let kbID = UUID()

        await MainActor.run { processingProgress = 0.05 }

        // Extract text
        let sections: [(label: String, text: String)]
        if docType == .pdf {
            sections = extractTextFromPDF(at: url)
        } else {
            sections = (try? extractTextFromEPUB(at: url)) ?? []
        }

        guard !sections.isEmpty else {
            await MainActor.run {
                processingError = "No text content found in this document."
                isProcessing = false
            }
            return
        }

        await MainActor.run { processingProgress = 0.2 }

        // Chunk all sections
        var allChunks: [DocumentChunk] = []
        var chunkIndex = 0
        let totalSections = Double(sections.count)

        for (i, section) in sections.enumerated() {
            let sectionChunks = chunkText(
                section.text,
                locationLabel: section.label,
                knowledgeBaseID: kbID,
                startIndex: &chunkIndex
            )
            allChunks.append(contentsOf: sectionChunks)

            await MainActor.run {
                processingProgress = 0.2 + (Double(i + 1) / totalSections) * 0.6
            }
        }

        guard !allChunks.isEmpty else {
            await MainActor.run {
                processingError = "Could not create any chunks from this document."
                isProcessing = false
            }
            return
        }

        // Save
        let kb = KnowledgeBase(
            id: kbID,
            name: url.deletingPathExtension().lastPathComponent,
            documentType: docType,
            chunkCount: allChunks.count,
            fileSize: fileSize
        )

        saveChunks(allChunks, for: kbID)

        await MainActor.run {
            processingProgress = 0.95
            knowledgeBases.insert(kb, at: 0)
            chunkCache[kbID] = allChunks
            saveMetadata()
            processingProgress = 1.0
            isProcessing = false
        }
    }

    // MARK: - PDF Extraction

    private func extractTextFromPDF(at url: URL) -> [(label: String, text: String)] {
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

    // MARK: - ePUB Extraction

    private func extractTextFromEPUB(at url: URL) throws -> [(label: String, text: String)] {
        // Copy to temp to ensure file access
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Extract ZIP contents
        let entries = try extractZIP(at: url, to: tempDir)
        guard !entries.isEmpty else { return [] }

        // Find container.xml → OPF path
        let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: containerURL),
              let containerStr = String(data: containerData, encoding: .utf8),
              let opfPath = parseOPFPath(from: containerStr) else {
            // Fallback: find all .xhtml/.html files
            return extractTextFromAllHTML(in: tempDir, entries: entries)
        }

        // Parse OPF manifest for spine order
        let opfURL = tempDir.appendingPathComponent(opfPath)
        let opfDir = opfURL.deletingLastPathComponent()
        guard let opfData = try? Data(contentsOf: opfURL),
              let opfStr = String(data: opfData, encoding: .utf8) else {
            return extractTextFromAllHTML(in: tempDir, entries: entries)
        }

        let spineFiles = parseSpineFiles(from: opfStr)
        guard !spineFiles.isEmpty else {
            return extractTextFromAllHTML(in: tempDir, entries: entries)
        }

        // Extract text from spine-ordered XHTML files
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

        return chapters.isEmpty ? extractTextFromAllHTML(in: tempDir, entries: entries) : chapters
    }

    private func extractTextFromAllHTML(in directory: URL, entries: [String]) -> [(label: String, text: String)] {
        var results: [(String, String)] = []
        let htmlEntries = entries.filter { $0.hasSuffix(".xhtml") || $0.hasSuffix(".html") || $0.hasSuffix(".htm") }
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

    /// Parse the OPF file path from container.xml
    private func parseOPFPath(from xml: String) -> String? {
        // Look for: <rootfile ... full-path="OEBPS/content.opf" .../>
        guard let range = xml.range(of: "full-path=\"[^\"]+\"", options: .regularExpression) else { return nil }
        let match = String(xml[range])
        return match.replacingOccurrences(of: "full-path=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
    }

    /// Parse the spine-ordered content file list from OPF
    private func parseSpineFiles(from opf: String) -> [String] {
        // 1. Build manifest id → href map
        var manifest: [String: String] = [:]
        let itemPattern = "<item[^>]*>"
        if let itemRegex = try? NSRegularExpression(pattern: itemPattern) {
            let matches = itemRegex.matches(in: opf, range: NSRange(opf.startIndex..., in: opf))
            for match in matches {
                guard let range = Range(match.range, in: opf) else { continue }
                let tag = String(opf[range])

                let idValue = extractAttribute("id", from: tag)
                let hrefValue = extractAttribute("href", from: tag)
                if let id = idValue, let href = hrefValue {
                    manifest[id] = href
                }
            }
        }

        // 2. Parse spine order
        var spineIDs: [String] = []
        let itemrefPattern = "<itemref[^>]*>"
        if let itemrefRegex = try? NSRegularExpression(pattern: itemrefPattern) {
            let matches = itemrefRegex.matches(in: opf, range: NSRange(opf.startIndex..., in: opf))
            for match in matches {
                guard let range = Range(match.range, in: opf) else { continue }
                let tag = String(opf[range])
                if let idref = extractAttribute("idref", from: tag) {
                    spineIDs.append(idref)
                }
            }
        }

        // 3. Resolve to file paths
        return spineIDs.compactMap { manifest[$0] }
    }

    private func extractAttribute(_ name: String, from tag: String) -> String? {
        let pattern = "\(name)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    /// Strip HTML tags using regex (safe for background threads, unlike NSAttributedString)
    private func stripHTMLTags(_ html: String) -> String {
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

    // MARK: - Minimal ZIP Extractor

    private func extractZIP(at url: URL, to destination: URL) throws -> [String] {
        let fileData = try Data(contentsOf: url)
        var extractedPaths: [String] = []
        var offset = 0

        while offset + 30 <= fileData.count {
            // Local file header signature: 0x04034b50
            let sig = fileData.subdata(in: offset..<offset + 4)
            guard sig == Data([0x50, 0x4B, 0x03, 0x04]) else { break }

            let compressionMethod = fileData.subdata(in: offset + 8..<offset + 10).withUnsafeBytes { $0.load(as: UInt16.self) }
            let compressedSize = Int(fileData.subdata(in: offset + 18..<offset + 22).withUnsafeBytes { $0.load(as: UInt32.self) })
            let uncompressedSize = Int(fileData.subdata(in: offset + 22..<offset + 26).withUnsafeBytes { $0.load(as: UInt32.self) })
            let nameLength = Int(fileData.subdata(in: offset + 26..<offset + 28).withUnsafeBytes { $0.load(as: UInt16.self) })
            let extraLength = Int(fileData.subdata(in: offset + 28..<offset + 30).withUnsafeBytes { $0.load(as: UInt16.self) })

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

            // Skip directories
            if !name.hasSuffix("/") {
                let entryData: Data
                if compressionMethod == 0 {
                    // Stored (no compression)
                    entryData = fileData.subdata(in: dataStart..<dataEnd)
                } else if compressionMethod == 8 {
                    // Deflate
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

    /// Decompress deflate data using the Compression framework
    private func decompress(_ data: Data, expectedSize: Int) -> Data? {
        // Raw deflate (no zlib header) — use COMPRESSION_ZLIB with raw flag
        let bufferSize = max(expectedSize, 1024)
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

    // MARK: - Chunking

    private struct ChunkingConfig {
        let targetCharacters = 3000
        let overlapCharacters = 300
        let minChunkCharacters = 200
    }

    private func chunkText(
        _ text: String,
        locationLabel: String,
        knowledgeBaseID: UUID,
        startIndex: inout Int
    ) -> [DocumentChunk] {
        let config = ChunkingConfig()
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

    // MARK: - Retrieval

    func retrieve(for query: String, limit: Int = 2) -> [DocumentChunk] {
        let queryWords = SharedDataManager.tokenize(query)
        guard !queryWords.isEmpty else { return [] }

        ensureAllChunksLoaded()

        var allScored: [(DocumentChunk, Double)] = []

        for (_, chunks) in chunkCache {
            for chunk in chunks {
                let entryWords = Set(chunk.keywords)
                let contentWords = SharedDataManager.tokenize(chunk.content)
                let allWords = entryWords.union(contentWords)

                var score = 0.0
                for word in queryWords {
                    if allWords.contains(word) {
                        score += 1.0
                    } else {
                        for entryWord in allWords where entryWord.hasPrefix(word) || word.hasPrefix(entryWord) {
                            score += 0.5
                            break
                        }
                    }
                }

                if score > 0.3 {
                    allScored.append((chunk, score))
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

    // MARK: - Management

    func deleteKnowledgeBase(_ kb: KnowledgeBase) {
        knowledgeBases.removeAll { $0.id == kb.id }
        chunkCache.removeValue(forKey: kb.id)
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
        saveMetadata()
    }

    // MARK: - Persistence (file-based)

    private func saveMetadata() {
        SharedDataManager.ensureDirectoriesExist()
        guard let url = SharedDataManager.documentsURL?.appendingPathComponent(Self.metadataFilename) else { return }
        try? JSONEncoder().encode(knowledgeBases).write(to: url)
    }

    private func loadMetadata() {
        guard let url = SharedDataManager.documentsURL?.appendingPathComponent(Self.metadataFilename),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([KnowledgeBase].self, from: data) else { return }
        knowledgeBases = decoded
    }

    private func saveChunks(_ chunks: [DocumentChunk], for kbID: UUID) {
        SharedDataManager.ensureDirectoriesExist()
        guard let dir = SharedDataManager.chunksDirectoryURL else { return }
        let fileURL = dir.appendingPathComponent("\(kbID.uuidString).json")
        try? JSONEncoder().encode(chunks).write(to: fileURL)
    }

    private func loadChunks(for kbID: UUID) -> [DocumentChunk] {
        guard let dir = SharedDataManager.chunksDirectoryURL else { return [] }
        let fileURL = dir.appendingPathComponent("\(kbID.uuidString).json")
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DocumentChunk].self, from: data) else { return [] }
        return decoded
    }

    private func ensureAllChunksLoaded() {
        for kb in knowledgeBases where chunkCache[kb.id] == nil {
            chunkCache[kb.id] = loadChunks(for: kb.id)
        }
    }
}
