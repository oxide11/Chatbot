//
//  ChatBotTests.swift
//  ChatBotTests
//
//  Unit tests for Knowledge Domains, Wiki Store, Knowledge Base models,
//  SharedDataManager utilities, and EmbeddingService math.
//

import Testing
import Foundation
import SwiftData
@testable import ChatBot


// MARK: - KnowledgeBase Model Tests

@Suite("KnowledgeBase Model")
struct KnowledgeBaseModelTests {

    @Test("KnowledgeBase round-trips through Codable")
    func codableRoundTrip() throws {
        let original = KnowledgeBase(
            name: "My Doc",
            documentType: .epub,
            chunkCount: 42,
            fileSize: 2048,
            embeddingModelID: "model-v1"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KnowledgeBase.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.name == "My Doc")
        #expect(decoded.documentType == .epub)
        #expect(decoded.chunkCount == 42)
        #expect(decoded.fileSize == 2048)
        #expect(decoded.embeddingModelID == "model-v1")
    }

    @Test("Backward-compatible decoding without updatedAt")
    func backwardCompatibleDecoding() throws {
        // Simulate old JSON without updatedAt
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

// MARK: - WikiPage Model Tests

@Suite("WikiPage Model")
struct WikiPageModelTests {

    @Test("Tags are preserved through init")
    func tagsPreserved() {
        let page = WikiPage(
            id: UUID(),
            title: "Test",
            body: "Body",
            tags: ["swift", "concurrency"],
            createdAt: Date(),
            updatedAt: Date(),
            sourceConversationIDs: [],
            linkedPageIDs: [],
            accessCount: 0,
            lastAccessedAt: Date(),
            embedding: nil
        )
        #expect(page.tags == ["swift", "concurrency"])
    }

    @Test("WikiPage round-trips through Codable preserving all fields")
    func codableRoundTripPreservesFields() throws {
        let convID = UUID()
        let linkedID = UUID()
        let original = WikiPage(
            id: UUID(),
            title: "Swift Concurrency",
            body: "Structured concurrency in Swift.",
            tags: ["swift", "concurrency"],
            createdAt: Date(),
            updatedAt: Date(),
            sourceConversationIDs: [convID],
            linkedPageIDs: [linkedID],
            accessCount: 5,
            lastAccessedAt: Date(),
            embedding: [1.0, 2.0, 3.0]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WikiPage.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.title == original.title)
        #expect(decoded.body == original.body)
        #expect(decoded.tags == ["swift", "concurrency"])
        #expect(decoded.sourceConversationIDs == [convID])
        #expect(decoded.linkedPageIDs == [linkedID])
        #expect(decoded.accessCount == 5)
        #expect(decoded.embedding == [1.0, 2.0, 3.0])
    }

    @Test("Backward-compatible decoding without optional fields")
    func backwardCompatibleDecoding() throws {
        let json = """
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "title": "Old Page",
            "body": "Legacy content",
            "tags": ["old"],
            "createdAt": 0,
            "updatedAt": 0,
            "sourceConversationIDs": [],
            "linkedPageIDs": [],
            "accessCount": 0,
            "lastAccessedAt": 0
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WikiPage.self, from: data)
        #expect(decoded.title == "Old Page")
        #expect(decoded.embedding == nil)
    }

    @Test("WikiPage conforms to Identifiable")
    func identifiable() {
        let id = UUID()
        let page = WikiPage(
            id: id,
            title: "Test",
            body: "Body",
            tags: [],
            createdAt: Date(),
            updatedAt: Date(),
            sourceConversationIDs: [],
            linkedPageIDs: [],
            accessCount: 0,
            lastAccessedAt: Date(),
            embedding: nil
        )
        #expect(page.id == id)
    }
}

// MARK: - WikiStore Tests

@Suite("WikiStore")
struct WikiStoreTests {

    private func makeStore() throws -> WikiStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SDWikiPage.self, configurations: config)
        let store = WikiStore()
        store.configure(with: container)
        return store
    }

    @Test("createPage inserts and loads page")
    @MainActor
    func createPageInserts() async throws {
        let store = try makeStore()

        let page = await store.createPage(
            title: "Test Page",
            body: "Content here",
            tags: ["test"],
            sourceConversationID: nil
        )
        #expect(page != nil)
        #expect(store.pages.count == 1)
        #expect(store.pages[0].title == "Test Page")
    }

    @Test("deletePage removes the correct page")
    @MainActor
    func deletePage() async throws {
        let store = try makeStore()

        await store.createPage(title: "Keep", body: "A", tags: [], sourceConversationID: nil)
        let toDelete = await store.createPage(title: "Delete Me", body: "B", tags: [], sourceConversationID: nil)
        #expect(store.pages.count == 2)

        await store.deletePage(id: toDelete!.id)
        #expect(store.pages.count == 1)
        #expect(store.pages[0].title == "Keep")
    }

    @Test("deleteAllPages clears everything")
    @MainActor
    func deleteAll() async throws {
        let store = try makeStore()

        await store.createPage(title: "One", body: "A", tags: [], sourceConversationID: nil)
        await store.createPage(title: "Two", body: "B", tags: [], sourceConversationID: nil)
        #expect(store.pages.count == 2)

        await store.deleteAllPages()
        #expect(store.pages.isEmpty)
    }

    @Test("findPageByTitle finds exact match case-insensitively")
    @MainActor
    func findByTitle() async throws {
        let store = try makeStore()

        await store.createPage(title: "Swift Concurrency", body: "Content", tags: [], sourceConversationID: nil)

        #expect(store.findPageByTitle("Swift Concurrency") != nil)
        #expect(store.findPageByTitle("swift concurrency") != nil)
        #expect(store.findPageByTitle("Nonexistent") == nil)
    }

    @Test("findPages(withTag:) filters by tag")
    @MainActor
    func findByTag() async throws {
        let store = try makeStore()

        await store.createPage(title: "Page A", body: "A", tags: ["swift", "ios"], sourceConversationID: nil)
        await store.createPage(title: "Page B", body: "B", tags: ["python"], sourceConversationID: nil)

        let swiftPages = store.findPages(withTag: "swift")
        #expect(swiftPages.count == 1)
        #expect(swiftPages[0].title == "Page A")

        let pythonPages = store.findPages(withTag: "python")
        #expect(pythonPages.count == 1)
        #expect(pythonPages[0].title == "Page B")
    }

    @Test("updatePage changes body and tags")
    @MainActor
    func updatePage() async throws {
        let store = try makeStore()

        let page = await store.createPage(title: "Original", body: "Old body", tags: ["old"], sourceConversationID: nil)
        await store.updatePage(id: page!.id, body: "New body", tags: ["new"])

        let updated = store.pages.first { $0.id == page!.id }
        #expect(updated?.body == "New body")
        #expect(updated?.tags == ["new"])
    }

}

// MARK: - ConversationData Model Tests

@Suite("ConversationData Model")
struct ConversationDataModelTests {

    @Test("ConversationData round-trips through Codable")
    func codableRoundTrip() throws {
        let original = ConversationData(
            id: UUID(),
            title: "Test Chat",
            createdAt: Date(),
            messages: [
                Message(role: .user, content: "Hello"),
                Message(role: .assistant, content: "Hi there!")
            ],
            customSystemPrompt: "Be helpful"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversationData.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.title == "Test Chat")
        #expect(decoded.messages.count == 2)
        #expect(decoded.customSystemPrompt == "Be helpful")
    }

    @Test("ConversationData decodes minimal JSON (backward compat)")
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
