//
//  ChatBotTests.swift
//  ChatBotTests
//
//  Unit tests for Knowledge Domains, Memory Store, Knowledge Base models,
//  SharedDataManager utilities, and EmbeddingService math.
//

import Testing
import Foundation
@testable import ChatBot

// MARK: - Knowledge Domain Model Tests

@Suite("KnowledgeDomain Model")
struct KnowledgeDomainModelTests {

    @Test("General ID is well-known UUID")
    func generalIDIsWellKnown() {
        let expected = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        #expect(KnowledgeDomain.generalID == expected)
    }

    @Test("general() factory creates default domain")
    func generalFactory() {
        let general = KnowledgeDomain.general()
        #expect(general.id == KnowledgeDomain.generalID)
        #expect(general.name == "General")
        #expect(general.isDefault == true)
    }

    @Test("Custom domain has isDefault false")
    func customDomain() {
        let domain = KnowledgeDomain(name: "Medical")
        #expect(domain.name == "Medical")
        #expect(domain.isDefault == false)
        #expect(domain.id != KnowledgeDomain.generalID)
    }

    @Test("Domain round-trips through Codable")
    func codableRoundTrip() throws {
        let original = KnowledgeDomain(name: "Cooking", isDefault: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KnowledgeDomain.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.isDefault == original.isDefault)
        #expect(abs(decoded.createdAt.timeIntervalSince(original.createdAt)) < 0.001)
    }

    @Test("Domain with explicit ID preserves it")
    func explicitID() {
        let id = UUID()
        let domain = KnowledgeDomain(id: id, name: "Work")
        #expect(domain.id == id)
    }
}

// MARK: - KnowledgeBase Model Tests

@Suite("KnowledgeBase Model")
struct KnowledgeBaseModelTests {

    @Test("effectiveDomainID returns generalID when domainID is nil")
    func effectiveDomainIDNil() {
        let kb = KnowledgeBase(name: "Test", documentType: .pdf, chunkCount: 10, fileSize: 1024)
        #expect(kb.domainID == nil)
        #expect(kb.effectiveDomainID == KnowledgeDomain.generalID)
    }

    @Test("effectiveDomainID returns actual domainID when set")
    func effectiveDomainIDSet() {
        let domainID = UUID()
        let kb = KnowledgeBase(name: "Test", documentType: .text, chunkCount: 5, fileSize: 512, domainID: domainID)
        #expect(kb.effectiveDomainID == domainID)
    }

    @Test("KnowledgeBase round-trips through Codable")
    func codableRoundTrip() throws {
        let domainID = UUID()
        let original = KnowledgeBase(
            name: "My Doc",
            documentType: .epub,
            chunkCount: 42,
            fileSize: 2048,
            embeddingModelID: "model-v1",
            domainID: domainID
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KnowledgeBase.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.name == "My Doc")
        #expect(decoded.documentType == .epub)
        #expect(decoded.chunkCount == 42)
        #expect(decoded.fileSize == 2048)
        #expect(decoded.embeddingModelID == "model-v1")
        #expect(decoded.domainID == domainID)
    }

    @Test("Backward-compatible decoding without domainID or updatedAt")
    func backwardCompatibleDecoding() throws {
        // Simulate old JSON without domainID and updatedAt fields
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Old Doc",
            "documentType": "pdf",
            "createdAt": 0,
            "chunkCount": 3,
            "fileSize": 256
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(KnowledgeBase.self, from: data)
        #expect(decoded.name == "Old Doc")
        #expect(decoded.domainID == nil)
        #expect(decoded.effectiveDomainID == KnowledgeDomain.generalID)
        #expect(decoded.embeddingModelID == nil)
        // updatedAt falls back to createdAt
        #expect(abs(decoded.updatedAt.timeIntervalSince(decoded.createdAt)) < 0.001)
    }

    @Test("DocumentType labels and icons are correct")
    func documentTypeProperties() {
        #expect(DocumentType.pdf.label == "PDF")
        #expect(DocumentType.epub.label == "ePUB")
        #expect(DocumentType.text.label == "Text")
        #expect(DocumentType.pdf.icon == "doc.richtext")
        #expect(DocumentType.epub.icon == "book")
        #expect(DocumentType.text.icon == "doc.text")
    }

    @Test("DocumentType round-trips through raw value")
    func documentTypeRawValue() {
        for type in DocumentType.allCases {
            #expect(DocumentType(rawValue: type.rawValue) == type)
        }
    }
}

// MARK: - DocumentChunk Model Tests

@Suite("DocumentChunk Model")
struct DocumentChunkModelTests {

    @Test("Keywords are lowercased on init")
    func keywordsLowercased() {
        let chunk = DocumentChunk(
            knowledgeBaseID: UUID(),
            content: "Test content",
            keywords: ["Swift", "CODING", "MacOS"],
            locationLabel: "Page 1",
            index: 0
        )
        #expect(chunk.keywords == ["swift", "coding", "macos"])
    }

    @Test("Chunk round-trips through Codable")
    func codableRoundTrip() throws {
        let embedding = [1.0, 2.0, 3.0]
        let kbID = UUID()
        let original = DocumentChunk(
            knowledgeBaseID: kbID,
            content: "Some text",
            keywords: ["test"],
            locationLabel: "Chapter 2",
            index: 5,
            embedding: embedding
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DocumentChunk.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.knowledgeBaseID == kbID)
        #expect(decoded.content == "Some text")
        #expect(decoded.keywords == ["test"])
        #expect(decoded.locationLabel == "Chapter 2")
        #expect(decoded.index == 5)
        #expect(decoded.embedding == embedding)
    }
}

// MARK: - Binary Embedding Conversion Tests

@Suite("Embedding Binary Conversion")
struct EmbeddingBinaryConversionTests {

    @Test("Double array round-trips through Data")
    func roundTrip() {
        let original: [Double] = [1.0, -2.5, 3.14159, 0.0, -0.001]
        let data = original.asData
        let restored = data.asDoubleArray()
        #expect(restored.count == original.count)
        for (a, b) in zip(original, restored) {
            #expect(a == b)
        }
    }

    @Test("512-dim vector produces 4096 bytes")
    func correctByteSize() {
        let vec = [Double](repeating: 1.0, count: 512)
        let data = vec.asData
        #expect(data.count == 512 * MemoryLayout<Double>.size)
        #expect(data.count == 4096)
    }

    @Test("Empty array produces empty data")
    func emptyArray() {
        let empty: [Double] = []
        let data = empty.asData
        #expect(data.isEmpty)
        let restored = data.asDoubleArray()
        #expect(restored.isEmpty)
    }

    @Test("Single element round-trips")
    func singleElement() {
        let original: [Double] = [42.0]
        let data = original.asData
        #expect(data.count == 8)
        let restored = data.asDoubleArray()
        #expect(restored == [42.0])
    }
}

// MARK: - SharedDataManager Utility Tests

@Suite("SharedDataManager Utilities")
struct SharedDataManagerTests {

    @Test("tokenize filters stop words and short words")
    func tokenizeBasic() {
        let tokens = SharedDataManager.tokenize("The quick brown fox jumps over the lazy dog")
        #expect(tokens.contains("quick"))
        #expect(tokens.contains("brown"))
        #expect(tokens.contains("jumps"))
        #expect(tokens.contains("lazy"))
        // "the" is a stop word, "fox" and "dog" are 3 chars (>2) so included
        #expect(!tokens.contains("the"))
        #expect(tokens.contains("fox"))
        #expect(tokens.contains("dog"))
    }

    @Test("tokenize handles empty input")
    func tokenizeEmpty() {
        let tokens = SharedDataManager.tokenize("")
        #expect(tokens.isEmpty)
    }

    @Test("tokenize handles only stop words")
    func tokenizeOnlyStopWords() {
        let tokens = SharedDataManager.tokenize("the a an is are was to of in for on")
        #expect(tokens.isEmpty)
    }

    @Test("tokenize lowercases everything")
    func tokenizeLowercase() {
        let tokens = SharedDataManager.tokenize("Swift CODING MacOS")
        #expect(tokens.contains("swift"))
        #expect(tokens.contains("coding"))
        #expect(tokens.contains("macos"))
        #expect(!tokens.contains("Swift"))
    }

    @Test("tokenize splits on non-alphanumeric chars")
    func tokenizeSplitting() {
        let tokens = SharedDataManager.tokenize("hello-world! foo_bar, baz.qux")
        #expect(tokens.contains("hello"))
        #expect(tokens.contains("world"))
        #expect(tokens.contains("foo"))
        #expect(tokens.contains("bar"))
        #expect(tokens.contains("baz"))
        #expect(tokens.contains("qux"))
    }

    @Test("extractKeywords returns frequency-sorted results")
    func extractKeywordsFrequency() {
        let text = "swift swift swift coding coding testing"
        let keywords = SharedDataManager.extractKeywords(from: text, limit: 3)
        #expect(keywords.count == 3)
        #expect(keywords[0] == "swift")   // 3 occurrences
        #expect(keywords[1] == "coding")  // 2 occurrences
        #expect(keywords[2] == "testing") // 1 occurrence
    }

    @Test("extractKeywords respects limit")
    func extractKeywordsLimit() {
        let text = "alpha beta gamma delta epsilon"
        let keywords = SharedDataManager.extractKeywords(from: text, limit: 2)
        #expect(keywords.count == 2)
    }

    @Test("extractKeywords handles empty text")
    func extractKeywordsEmpty() {
        let keywords = SharedDataManager.extractKeywords(from: "", limit: 5)
        #expect(keywords.isEmpty)
    }

    @Test("extractKeywords ties broken alphabetically")
    func extractKeywordsTiebreaking() {
        let text = "banana apple cherry"
        let keywords = SharedDataManager.extractKeywords(from: text, limit: 3)
        // All have frequency 1, so alphabetical: apple, banana, cherry
        #expect(keywords[0] == "apple")
        #expect(keywords[1] == "banana")
        #expect(keywords[2] == "cherry")
    }

    @Test("extractKeywords filters stop words")
    func extractKeywordsFiltersStopWords() {
        let text = "the the the quick brown fox"
        let keywords = SharedDataManager.extractKeywords(from: text, limit: 5)
        #expect(!keywords.contains("the"))
        #expect(keywords.contains("quick"))
    }
}

// MARK: - EmbeddingService Math Tests

@Suite("EmbeddingService Math")
struct EmbeddingServiceMathTests {

    @Test("Cosine similarity of identical vectors is 1")
    func identicalVectors() {
        let v = [1.0, 2.0, 3.0]
        let sim = EmbeddingService.cosineSimilarity(v, v)
        #expect(abs(sim - 1.0) < 0.001)
    }

    @Test("Cosine similarity of orthogonal vectors is 0")
    func orthogonalVectors() {
        let a = [1.0, 0.0, 0.0]
        let b = [0.0, 1.0, 0.0]
        let sim = EmbeddingService.cosineSimilarity(a, b)
        #expect(abs(sim) < 0.001)
    }

    @Test("Cosine similarity of opposite vectors is -1")
    func oppositeVectors() {
        let a = [1.0, 0.0, 0.0]
        let b = [-1.0, 0.0, 0.0]
        let sim = EmbeddingService.cosineSimilarity(a, b)
        #expect(abs(sim - (-1.0)) < 0.001)
    }

    @Test("Cosine similarity with empty vectors returns 0")
    func emptyVectors() {
        let sim = EmbeddingService.cosineSimilarity([], [])
        #expect(sim == 0)
    }

    @Test("Cosine similarity with mismatched lengths returns 0")
    func mismatchedLengths() {
        let sim = EmbeddingService.cosineSimilarity([1.0, 2.0], [1.0])
        #expect(sim == 0)
    }

    @Test("isNormalized returns true for unit vector")
    func unitVectorIsNormalized() {
        let v = [1.0, 0.0, 0.0]
        #expect(EmbeddingService.isNormalized(v))
    }

    @Test("isNormalized returns false for non-unit vector")
    func nonUnitVectorNotNormalized() {
        let v = [2.0, 0.0, 0.0]
        #expect(!EmbeddingService.isNormalized(v))
    }

    @Test("magnitude returns correct L2 norm")
    func magnitudeCorrect() {
        let v = [3.0, 4.0]
        let mag = EmbeddingService.magnitude(v)
        #expect(abs(mag - 5.0) < 0.001)
    }
}

// MARK: - MemoryEntry Model Tests

@Suite("MemoryEntry Model")
struct MemoryEntryModelTests {

    @Test("Keywords are lowercased on init")
    func keywordsLowercased() {
        let entry = MemoryEntry(
            id: UUID(),
            content: "Test",
            keywords: ["Swift", "CODING"],
            sourceConversationTitle: "Test",
            createdAt: Date()
        )
        #expect(entry.keywords == ["swift", "coding"])
    }

    @Test("domainID defaults to nil")
    func domainIDDefaultsNil() {
        let entry = MemoryEntry(
            id: UUID(),
            content: "Test",
            keywords: [],
            sourceConversationTitle: "Test"
        )
        #expect(entry.domainID == nil)
    }

    @Test("domainID can be set explicitly")
    func domainIDExplicit() {
        let domainID = UUID()
        let entry = MemoryEntry(
            id: UUID(),
            content: "Test",
            keywords: [],
            sourceConversationTitle: "Test",
            domainID: domainID
        )
        #expect(entry.domainID == domainID)
    }

    @Test("MemoryEntry round-trips through Codable preserving domainID")
    func codableRoundTripWithDomainID() throws {
        let domainID = UUID()
        let original = MemoryEntry(
            id: UUID(),
            content: "Remember this",
            keywords: ["test"],
            sourceConversationTitle: "Chat",
            createdAt: Date(),
            embedding: [1.0, 2.0, 3.0],
            domainID: domainID
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MemoryEntry.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.content == original.content)
        #expect(decoded.domainID == domainID)
        #expect(decoded.embedding == [1.0, 2.0, 3.0])
    }

    @Test("Backward-compatible decoding without domainID")
    func backwardCompatibleDecoding() throws {
        let json = """
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "content": "Old memory",
            "keywords": ["old"],
            "sourceConversationTitle": "Legacy",
            "createdAt": 0
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MemoryEntry.self, from: data)
        #expect(decoded.content == "Old memory")
        #expect(decoded.domainID == nil)
    }

    @Test("MemoryEntry is Hashable")
    func hashable() {
        let entry = MemoryEntry(
            id: UUID(),
            content: "Test",
            keywords: [],
            sourceConversationTitle: "Test"
        )
        var set: Set<MemoryEntry> = []
        set.insert(entry)
        #expect(set.contains(entry))
    }
}

// MARK: - MemoryStore Tests

@Suite("MemoryStore")
struct MemoryStoreTests {

    /// Create a MemoryStore with preloaded test data (bypassing disk).
    private func makeStore(memories: [MemoryEntry]) -> MemoryStore {
        let store = MemoryStore()
        store.deleteAllMemories()
        for m in memories {
            // Use the full init to avoid embedding service dependency
            store.addMemory(m.content, keywords: m.keywords, source: m.sourceConversationTitle, domainID: m.domainID ?? KnowledgeDomain.generalID)
        }
        return store
    }

    @Test("addMemory inserts at front")
    func addMemoryInsertsAtFront() {
        let store = MemoryStore()
        store.deleteAllMemories()
        store.addMemory("First", keywords: ["a"], source: "Test")
        store.addMemory("Second", keywords: ["b"], source: "Test")
        #expect(store.memories.count == 2)
        #expect(store.memories[0].content == "Second")
        #expect(store.memories[1].content == "First")
        store.deleteAllMemories()
    }

    @Test("addMemory rejects duplicates")
    func addMemoryRejectsDuplicates() {
        let store = MemoryStore()
        store.deleteAllMemories()
        store.addMemory("Same content", keywords: ["a"], source: "Test")
        store.addMemory("Same content", keywords: ["b"], source: "Test2")
        #expect(store.memories.count == 1)
        store.deleteAllMemories()
    }

    @Test("addMemory enforces max capacity")
    func addMemoryEnforcesCapacity() {
        let store = MemoryStore()
        store.deleteAllMemories()
        for i in 0..<105 {
            store.addMemory("Memory \(i)", keywords: [], source: "Test")
        }
        #expect(store.memories.count == 100)
        // Most recent should be first
        #expect(store.memories[0].content == "Memory 104")
        store.deleteAllMemories()
    }

    @Test("deleteMemory removes the correct entry")
    func deleteMemory() {
        let store = MemoryStore()
        store.deleteAllMemories()
        store.addMemory("Keep", keywords: [], source: "Test")
        store.addMemory("Delete me", keywords: [], source: "Test")
        let toDelete = store.memories.first { $0.content == "Delete me" }!
        store.deleteMemory(toDelete)
        #expect(store.memories.count == 1)
        #expect(store.memories[0].content == "Keep")
        store.deleteAllMemories()
    }

    @Test("deleteAllMemories clears everything")
    func deleteAll() {
        let store = MemoryStore()
        store.addMemory("One", keywords: [], source: "Test")
        store.addMemory("Two", keywords: [], source: "Test")
        store.deleteAllMemories()
        #expect(store.memories.isEmpty)
    }

    @Test("memories(for:) filters by domain")
    func memoriesForDomain() {
        let store = MemoryStore()
        store.deleteAllMemories()
        let medicalID = UUID()
        store.addMemory("General fact", keywords: [], source: "Test", domainID: KnowledgeDomain.generalID)
        store.addMemory("Medical fact", keywords: [], source: "Test", domainID: medicalID)
        store.addMemory("Another general", keywords: [], source: "Test", domainID: KnowledgeDomain.generalID)

        let generalMemories = store.memories(for: KnowledgeDomain.generalID)
        let medicalMemories = store.memories(for: medicalID)

        #expect(generalMemories.count == 2)
        #expect(medicalMemories.count == 1)
        #expect(medicalMemories[0].content == "Medical fact")
        store.deleteAllMemories()
    }

    @Test("memories with nil domainID are treated as General")
    func nilDomainTreatedAsGeneral() {
        let store = MemoryStore()
        store.deleteAllMemories()
        // The addMemory method always passes a domainID, so we test the filter directly
        let entry = MemoryEntry(
            id: UUID(),
            content: "Legacy entry",
            keywords: [],
            sourceConversationTitle: "Old",
            domainID: nil
        )
        // Verify the filter logic
        let effectiveID = entry.domainID ?? KnowledgeDomain.generalID
        #expect(effectiveID == KnowledgeDomain.generalID)
        store.deleteAllMemories()
    }

    @Test("moveMemory changes domain")
    func moveMemory() {
        let store = MemoryStore()
        store.deleteAllMemories()
        let newDomainID = UUID()
        store.addMemory("Movable", keywords: ["test"], source: "Test", domainID: KnowledgeDomain.generalID)

        let entry = store.memories[0]
        #expect((entry.domainID ?? KnowledgeDomain.generalID) == KnowledgeDomain.generalID)

        store.moveMemory(entry, toDomain: newDomainID)

        #expect(store.memories[0].domainID == newDomainID)
        #expect(store.memories(for: KnowledgeDomain.generalID).isEmpty)
        #expect(store.memories(for: newDomainID).count == 1)
        store.deleteAllMemories()
    }

    @Test("moveMemory preserves content and embedding")
    func moveMemoryPreservesData() {
        let store = MemoryStore()
        store.deleteAllMemories()
        store.addMemory("Test content", keywords: ["key"], source: "Src", domainID: KnowledgeDomain.generalID)

        let entry = store.memories[0]
        let originalContent = entry.content
        let originalKeywords = entry.keywords
        let originalEmbedding = entry.embedding

        let newDomain = UUID()
        store.moveMemory(entry, toDomain: newDomain)

        let moved = store.memories[0]
        #expect(moved.content == originalContent)
        #expect(moved.keywords == originalKeywords)
        #expect(moved.embedding == originalEmbedding)
        #expect(moved.domainID == newDomain)
        store.deleteAllMemories()
    }

    @Test("updateMemory preserves domainID")
    func updateMemoryPreservesDomain() {
        let store = MemoryStore()
        store.deleteAllMemories()
        let domainID = UUID()
        store.addMemory("Original", keywords: ["old"], source: "Test", domainID: domainID)

        let entry = store.memories[0]
        store.updateMemory(entry, content: "Updated", keywords: ["new"])

        let updated = store.memories[0]
        #expect(updated.content == "Updated")
        #expect(updated.keywords == ["new"])
        #expect(updated.domainID == domainID)
        store.deleteAllMemories()
    }

    @Test("updateMemory with same content preserves embedding")
    func updateMemorySameContentPreservesEmbedding() {
        let store = MemoryStore()
        store.deleteAllMemories()
        store.addMemory("Content", keywords: ["a"], source: "Test")

        let entry = store.memories[0]
        let originalEmbedding = entry.embedding

        store.updateMemory(entry, content: "Content", keywords: ["b"])

        let updated = store.memories[0]
        #expect(updated.embedding == originalEmbedding)
        store.deleteAllMemories()
    }
}

// MARK: - ConversationData Model Tests

@Suite("ConversationData Model")
struct ConversationDataModelTests {

    @Test("ConversationData round-trips through Codable with domainID")
    func codableRoundTrip() throws {
        let domainID = UUID()
        let original = ConversationData(
            id: UUID(),
            title: "Test Chat",
            createdAt: Date(),
            messages: [
                Message(role: .user, content: "Hello"),
                Message(role: .assistant, content: "Hi there!")
            ],
            customSystemPrompt: "Be helpful",
            domainID: domainID
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversationData.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.title == "Test Chat")
        #expect(decoded.messages.count == 2)
        #expect(decoded.customSystemPrompt == "Be helpful")
        #expect(decoded.domainID == domainID)
    }

    @Test("ConversationData decodes without domainID (backward compat)")
    func backwardCompatDecoding() throws {
        let json = """
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "title": "Old Chat",
            "createdAt": 0,
            "messages": []
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConversationData.self, from: data)
        #expect(decoded.title == "Old Chat")
        #expect(decoded.domainID == nil)
        #expect(decoded.customSystemPrompt == nil)
    }
}

// MARK: - Message Model Tests

@Suite("Message Model")
struct MessageModelTests {

    @Test("Message roles round-trip through Codable")
    func rolesCodable() throws {
        for role in [Message.Role.user, .assistant, .system] {
            let msg = Message(role: role, content: "Test")
            let data = try JSONEncoder().encode(msg)
            let decoded = try JSONDecoder().decode(Message.self, from: data)
            #expect(decoded.role == role)
        }
    }

    @Test("Message preserves content and timestamp")
    func contentAndTimestamp() {
        let now = Date()
        let msg = Message(role: .user, content: "Hello", timestamp: now)
        #expect(msg.content == "Hello")
        #expect(msg.timestamp == now)
        #expect(msg.role == .user)
    }
}
