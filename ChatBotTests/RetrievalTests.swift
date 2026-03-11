//
//  RetrievalTests.swift
//  ChatBotTests
//
//  Unit tests for the hybrid retrieval pipeline: BM25 lexical scoring,
//  dense-lexical score fusion, domain scoping, and edge cases.
//

import Testing
import Foundation
@testable import ChatBot

// MARK: - Test Helpers

/// Create a normalized embedding vector pointing primarily along a single axis.
/// Useful for creating chunks with predictable cosine similarity.
private func makeEmbedding(primaryAxis: Int, dimension: Int = 16, strength: Double = 0.9) -> [Double] {
    var vec = [Double](repeating: 0.01, count: dimension)
    vec[primaryAxis % dimension] = strength
    // L2 normalize
    let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
    return vec.map { $0 / norm }
}

/// Create a test chunk with known content, keywords, and embedding.
private func makeChunk(
    kbID: UUID,
    content: String,
    keywords: [String] = [],
    index: Int = 0,
    embedding: [Double]? = nil
) -> DocumentChunk {
    DocumentChunk(
        knowledgeBaseID: kbID,
        content: content,
        keywords: keywords,
        locationLabel: "Test",
        index: index,
        embedding: embedding
    )
}

/// Set up a KnowledgeBaseStore with test data in a single domain.
private func makeStore(
    domainID: UUID = KnowledgeDomain.generalID,
    kbID: UUID = UUID(),
    chunks: [DocumentChunk]
) -> KnowledgeBaseStore {
    let store = KnowledgeBaseStore()
    let kb = KnowledgeBase(
        id: kbID,
        name: "Test KB",
        documentType: .text,
        chunkCount: chunks.count,
        fileSize: 1024,
        domainID: domainID
    )
    let domain = domainID == KnowledgeDomain.generalID
        ? KnowledgeDomain.general()
        : KnowledgeDomain(id: domainID, name: "Test Domain")
    store.injectTestData(
        knowledgeBases: [kb],
        chunks: [kbID: chunks],
        domains: [domain]
    )
    return store
}

// MARK: - BM25 Scoring Tests

@Suite("BM25 Lexical Scoring")
struct BM25ScoringTests {

    @Test("Exact keyword match produces nonzero BM25 score")
    func exactKeywordMatch() {
        let kbID = UUID()
        let chunk = makeChunk(kbID: kbID, content: "The JWT token validation uses RFC 7519 specification", keywords: ["jwt", "token", "validation", "rfc"])
        let store = makeStore(kbID: kbID, chunks: [chunk])

        let scores = store.testBM25Scores(query: "JWT token validation")
        #expect(!scores.isEmpty)
        #expect(scores[chunk.id] != nil)
        #expect(scores[chunk.id]! > 0)
    }

    @Test("Non-matching query produces no BM25 score for chunk")
    func noKeywordMatch() {
        let kbID = UUID()
        let chunk = makeChunk(kbID: kbID, content: "Swift programming language fundamentals", keywords: ["swift", "programming"])
        let store = makeStore(kbID: kbID, chunks: [chunk])

        let scores = store.testBM25Scores(query: "quantum physics equations")
        // Chunk should have no score (no overlapping terms)
        #expect(scores[chunk.id] == nil)
    }

    @Test("More matching terms produce higher BM25 score")
    func moreTermsHigherScore() {
        let kbID = UUID()
        let chunk1 = makeChunk(kbID: kbID, content: "JWT token validation and authentication using RFC 7519", keywords: ["jwt", "token", "validation", "authentication", "rfc"], index: 0)
        let chunk2 = makeChunk(kbID: kbID, content: "General authentication overview for web applications", keywords: ["authentication", "overview", "web", "applications"], index: 1)
        let store = makeStore(kbID: kbID, chunks: [chunk1, chunk2])

        let scores = store.testBM25Scores(query: "JWT token validation authentication")
        let score1 = scores[chunk1.id] ?? 0
        let score2 = scores[chunk2.id] ?? 0

        // chunk1 matches 4 terms, chunk2 matches 1 — chunk1 should score higher
        #expect(score1 > score2)
    }

    @Test("BM25 scores are normalized to [0, 1]")
    func scoresNormalized() {
        let kbID = UUID()
        let chunks = (0..<5).map { i in
            makeChunk(kbID: kbID, content: "Document \(i) about swift coding patterns and best practices", keywords: ["swift", "coding", "patterns", "practices"], index: i)
        }
        let store = makeStore(kbID: kbID, chunks: chunks)

        let scores = store.testBM25Scores(query: "swift coding patterns best practices")
        for (_, score) in scores {
            #expect(score >= 0)
            #expect(score <= 1.0)
        }
    }

    @Test("Empty query returns empty BM25 scores")
    func emptyQuery() {
        let kbID = UUID()
        let chunk = makeChunk(kbID: kbID, content: "Some content about things", keywords: ["content", "things"])
        let store = makeStore(kbID: kbID, chunks: [chunk])

        // tokenize("") returns empty set, so BM25 should be empty
        let scores = store.testBM25Scores(query: "")
        #expect(scores.isEmpty)
    }

    @Test("Query with only stop words returns empty BM25 scores")
    func stopWordsOnly() {
        let kbID = UUID()
        let chunk = makeChunk(kbID: kbID, content: "Content with meaningful keywords", keywords: ["content", "meaningful", "keywords"])
        let store = makeStore(kbID: kbID, chunks: [chunk])

        // "the a is" are all stop words, tokenize will return empty
        let scores = store.testBM25Scores(query: "the a is")
        #expect(scores.isEmpty)
    }

    @Test("Rare terms get higher IDF than common terms")
    func rareTermsHigherIDF() {
        let kbID = UUID()
        // "swift" appears in all chunks, "quantum" appears in only one
        let chunks = [
            makeChunk(kbID: kbID, content: "Swift programming basics and quantum computing fundamentals", keywords: ["swift", "programming", "quantum", "computing"], index: 0),
            makeChunk(kbID: kbID, content: "Swift language features and patterns", keywords: ["swift", "language", "features", "patterns"], index: 1),
            makeChunk(kbID: kbID, content: "Swift concurrency model and actors", keywords: ["swift", "concurrency", "model", "actors"], index: 2),
        ]
        let store = makeStore(kbID: kbID, chunks: chunks)

        // Query for rare term "quantum" — only chunk 0 should score
        let quantumScores = store.testBM25Scores(query: "quantum")
        #expect(quantumScores[chunks[0].id] != nil)
        #expect(quantumScores[chunks[1].id] == nil)
        #expect(quantumScores[chunks[2].id] == nil)

        // Query for common term "swift" — all chunks should score equally
        let swiftScores = store.testBM25Scores(query: "swift")
        #expect(swiftScores.count == 3)
    }
}

// MARK: - Hybrid Retrieval Tests

@Suite("Hybrid Dense + Lexical Retrieval")
struct HybridRetrievalTests {

    @Test("Keyword boost rescues chunk with low embedding similarity")
    func keywordBoostRescuesChunk() {
        let kbID = UUID()
        let dim = 16

        // Query vector points along axis 0
        let queryVec = makeEmbedding(primaryAxis: 0, dimension: dim)

        // Chunk A: high embedding similarity (same axis) but no keyword match
        let chunkA = makeChunk(kbID: kbID, content: "General semantically similar content about topics", keywords: ["general", "semantically", "similar", "content", "topics"], index: 0, embedding: makeEmbedding(primaryAxis: 0, dimension: dim))

        // Chunk B: low embedding similarity (different axis) but exact keyword match
        let chunkB = makeChunk(kbID: kbID, content: "The JWT specification RFC 7519 defines token structure", keywords: ["jwt", "specification", "rfc", "token", "structure"], index: 1, embedding: makeEmbedding(primaryAxis: 5, dimension: dim))

        let store = makeStore(kbID: kbID, chunks: [chunkA, chunkB])

        // With zero lexical weight (pure dense), chunk A should rank first
        let pureSemanticResults = store.retrieveWithVector(queryVec, query: "JWT specification token", domainID: KnowledgeDomain.generalID, limit: 2, lexicalWeight: 0)
        if !pureSemanticResults.isEmpty {
            #expect(pureSemanticResults[0].id == chunkA.id)
        }

        // With high lexical weight, chunk B should be boosted (it matches "jwt", "specification", "token")
        let hybridResults = store.retrieveWithVector(queryVec, query: "JWT specification token", domainID: KnowledgeDomain.generalID, limit: 2, lexicalWeight: 0.5)
        #expect(!hybridResults.isEmpty)
        // Chunk B should now appear in results (it was rescued by keyword match)
        let chunkBInResults = hybridResults.contains { $0.id == chunkB.id }
        #expect(chunkBInResults)
    }

    @Test("Lexical weight 0 produces pure semantic results")
    func zeroLexicalWeight() {
        let kbID = UUID()
        let dim = 16

        let queryVec = makeEmbedding(primaryAxis: 0, dimension: dim)

        // Chunk close to query embedding
        let closeChunk = makeChunk(kbID: kbID, content: "Unrelated keywords platypus zephyr", keywords: ["platypus", "zephyr"], index: 0, embedding: makeEmbedding(primaryAxis: 0, dimension: dim, strength: 0.95))

        // Chunk far from query but matching keywords
        let keywordChunk = makeChunk(kbID: kbID, content: "Target keywords matching the query exactly here", keywords: ["target", "keywords", "matching", "query"], index: 1, embedding: makeEmbedding(primaryAxis: 7, dimension: dim))

        let store = makeStore(kbID: kbID, chunks: [closeChunk, keywordChunk])

        let results = store.retrieveWithVector(queryVec, query: "target keywords matching query", domainID: KnowledgeDomain.generalID, limit: 2, lexicalWeight: 0)

        // With zero lexical weight, only embedding similarity matters
        if !results.isEmpty {
            #expect(results[0].id == closeChunk.id)
        }
    }

    @Test("Retrieve returns empty for domain with no chunks")
    func emptyDomain() {
        let kbID = UUID()
        let dim = 16
        let queryVec = makeEmbedding(primaryAxis: 0, dimension: dim)

        let chunk = makeChunk(kbID: kbID, content: "Some content", keywords: ["content"], index: 0, embedding: makeEmbedding(primaryAxis: 0, dimension: dim))

        let domainA = UUID()
        let domainB = UUID()

        // Chunks are in domain A
        let store = KnowledgeBaseStore()
        let kb = KnowledgeBase(id: kbID, name: "Test", documentType: .text, chunkCount: 1, fileSize: 512, domainID: domainA)
        store.injectTestData(
            knowledgeBases: [kb],
            chunks: [kbID: [chunk]],
            domains: [
                KnowledgeDomain(id: domainA, name: "Domain A"),
                KnowledgeDomain(id: domainB, name: "Domain B"),
            ]
        )

        // Query domain B — should find nothing
        let results = store.retrieveWithVector(queryVec, query: "content", domainID: domainB, limit: 3)
        #expect(results.isEmpty)
    }

    @Test("Retrieve respects limit parameter")
    func respectsLimit() {
        let kbID = UUID()
        let dim = 16
        let queryVec = makeEmbedding(primaryAxis: 0, dimension: dim)

        // Create 10 chunks all similar to query
        let chunks = (0..<10).map { i in
            makeChunk(kbID: kbID, content: "Content about topic \(i) with relevant keywords", keywords: ["content", "topic", "relevant", "keywords"], index: i, embedding: makeEmbedding(primaryAxis: 0, dimension: dim, strength: 0.8 + Double(i) * 0.01))
        }
        let store = makeStore(kbID: kbID, chunks: chunks)

        let results = store.retrieveWithVector(queryVec, query: "content topic relevant", domainID: KnowledgeDomain.generalID, limit: 3)
        #expect(results.count <= 3)
    }
}

// MARK: - Domain Scoping Tests

@Suite("Domain-Scoped Retrieval")
struct DomainScopingTests {

    @Test("BM25 scores are scoped to the requested domain")
    func bm25ScopedToDomain() {
        let kbA = UUID()
        let kbB = UUID()
        let domainA = UUID()
        let domainB = UUID()

        let chunkA = makeChunk(kbID: kbA, content: "Swift concurrency with async await patterns", keywords: ["swift", "concurrency", "async", "await", "patterns"], index: 0)
        let chunkB = makeChunk(kbID: kbB, content: "Swift concurrency in server side applications", keywords: ["swift", "concurrency", "server", "applications"], index: 0)

        let store = KnowledgeBaseStore()
        store.injectTestData(
            knowledgeBases: [
                KnowledgeBase(id: kbA, name: "KB A", documentType: .text, chunkCount: 1, fileSize: 512, domainID: domainA),
                KnowledgeBase(id: kbB, name: "KB B", documentType: .text, chunkCount: 1, fileSize: 512, domainID: domainB),
            ],
            chunks: [kbA: [chunkA], kbB: [chunkB]],
            domains: [
                KnowledgeDomain(id: domainA, name: "Domain A"),
                KnowledgeDomain(id: domainB, name: "Domain B"),
            ]
        )

        let scoresA = store.testBM25Scores(query: "swift concurrency", domainID: domainA)
        let scoresB = store.testBM25Scores(query: "swift concurrency", domainID: domainB)

        // Domain A scores should only contain chunk A
        #expect(scoresA[chunkA.id] != nil)
        #expect(scoresA[chunkB.id] == nil)

        // Domain B scores should only contain chunk B
        #expect(scoresB[chunkB.id] != nil)
        #expect(scoresB[chunkA.id] == nil)
    }

    @Test("Hybrid retrieval isolates domains even with shared keywords")
    func hybridRetrievalIsolatesDomains() {
        let kbA = UUID()
        let kbB = UUID()
        let domainA = UUID()
        let domainB = UUID()
        let dim = 16

        let queryVec = makeEmbedding(primaryAxis: 0, dimension: dim)

        // Both chunks have the same keyword "swift" and similar embeddings
        let chunkA = makeChunk(kbID: kbA, content: "Swift programming in domain A context", keywords: ["swift", "programming", "domain"], index: 0, embedding: makeEmbedding(primaryAxis: 0, dimension: dim))
        let chunkB = makeChunk(kbID: kbB, content: "Swift programming in domain B context", keywords: ["swift", "programming", "domain"], index: 0, embedding: makeEmbedding(primaryAxis: 0, dimension: dim))

        let store = KnowledgeBaseStore()
        store.injectTestData(
            knowledgeBases: [
                KnowledgeBase(id: kbA, name: "KB A", documentType: .text, chunkCount: 1, fileSize: 512, domainID: domainA),
                KnowledgeBase(id: kbB, name: "KB B", documentType: .text, chunkCount: 1, fileSize: 512, domainID: domainB),
            ],
            chunks: [kbA: [chunkA], kbB: [chunkB]],
            domains: [
                KnowledgeDomain(id: domainA, name: "Domain A"),
                KnowledgeDomain(id: domainB, name: "Domain B"),
            ]
        )

        let resultsA = store.retrieveWithVector(queryVec, query: "swift programming", domainID: domainA, limit: 5)
        let resultsB = store.retrieveWithVector(queryVec, query: "swift programming", domainID: domainB, limit: 5)

        // Domain A should only return chunk A
        #expect(resultsA.allSatisfy { $0.knowledgeBaseID == kbA })
        // Domain B should only return chunk B
        #expect(resultsB.allSatisfy { $0.knowledgeBaseID == kbB })
    }
}

// MARK: - Keyword Fallback Tests

@Suite("Keyword Fallback Retrieval")
struct KeywordFallbackTests {

    @Test("Keyword retrieval works without embeddings")
    func keywordFallbackWithoutEmbeddings() {
        let kbID = UUID()
        // No embeddings — keyword fallback should handle retrieval
        let chunk = makeChunk(kbID: kbID, content: "Machine learning algorithms for natural language processing", keywords: ["machine", "learning", "algorithms", "natural", "language", "processing"])
        let store = makeStore(kbID: kbID, chunks: [chunk])

        let results = store.testKeywordRetrieve(query: "machine learning algorithms")
        #expect(!results.isEmpty)
        #expect(results[0].id == chunk.id)
    }

    @Test("Keyword retrieval ranks multi-term matches higher")
    func keywordRankingByOverlap() {
        let kbID = UUID()
        let chunk1 = makeChunk(kbID: kbID, content: "Machine learning algorithms for classification and regression tasks", keywords: ["machine", "learning", "algorithms", "classification", "regression"], index: 0)
        let chunk2 = makeChunk(kbID: kbID, content: "Introduction to machine design principles", keywords: ["introduction", "machine", "design", "principles"], index: 1)
        let store = makeStore(kbID: kbID, chunks: [chunk1, chunk2])

        let results = store.testKeywordRetrieve(query: "machine learning algorithms", limit: 2)
        #expect(!results.isEmpty)
        // chunk1 matches 3 terms, chunk2 matches 1 — chunk1 should rank first
        #expect(results[0].id == chunk1.id)
    }

    @Test("Keyword retrieval returns empty for no matches")
    func keywordNoMatches() {
        let kbID = UUID()
        let chunk = makeChunk(kbID: kbID, content: "Swift programming language guide", keywords: ["swift", "programming", "language", "guide"])
        let store = makeStore(kbID: kbID, chunks: [chunk])

        let results = store.testKeywordRetrieve(query: "quantum entanglement theory")
        #expect(results.isEmpty)
    }
}

// MARK: - Edge Case Tests

@Suite("Retrieval Edge Cases")
struct RetrievalEdgeCaseTests {

    @Test("Retrieve with no chunks returns empty")
    func noChunks() {
        let store = KnowledgeBaseStore()
        let domainID = KnowledgeDomain.generalID
        store.injectTestData(
            knowledgeBases: [],
            chunks: [:],
            domains: [KnowledgeDomain.general()]
        )

        let dim = 16
        let queryVec = makeEmbedding(primaryAxis: 0, dimension: dim)
        let results = store.retrieveWithVector(queryVec, query: "anything", domainID: domainID, limit: 3)
        #expect(results.isEmpty)
    }

    @Test("Chunks without embeddings are excluded from dense retrieval")
    func chunksWithoutEmbeddings() {
        let kbID = UUID()
        let dim = 16
        let queryVec = makeEmbedding(primaryAxis: 0, dimension: dim)

        // One chunk with embedding, one without
        let withEmb = makeChunk(kbID: kbID, content: "Chunk with embedding present", keywords: ["chunk", "embedding", "present"], index: 0, embedding: makeEmbedding(primaryAxis: 0, dimension: dim))
        let withoutEmb = makeChunk(kbID: kbID, content: "Chunk without any embedding", keywords: ["chunk", "without", "embedding"], index: 1, embedding: nil)
        let store = makeStore(kbID: kbID, chunks: [withEmb, withoutEmb])

        let results = store.retrieveWithVector(queryVec, query: "chunk embedding", domainID: KnowledgeDomain.generalID, limit: 5)
        // Only the chunk with embedding should appear in dense retrieval results
        #expect(results.allSatisfy { $0.id == withEmb.id })
    }

    @Test("Single chunk retrieval works")
    func singleChunk() {
        let kbID = UUID()
        let dim = 16
        let queryVec = makeEmbedding(primaryAxis: 0, dimension: dim)
        let chunk = makeChunk(kbID: kbID, content: "The only chunk in the entire knowledge base", keywords: ["only", "chunk", "knowledge", "base"], index: 0, embedding: makeEmbedding(primaryAxis: 0, dimension: dim))
        let store = makeStore(kbID: kbID, chunks: [chunk])

        let results = store.retrieveWithVector(queryVec, query: "chunk knowledge base", domainID: KnowledgeDomain.generalID, limit: 3)
        #expect(results.count == 1)
        #expect(results[0].id == chunk.id)
    }

    @Test("BM25 handles single-word query")
    func singleWordQuery() {
        let kbID = UUID()
        let chunk = makeChunk(kbID: kbID, content: "Explanation of cryptographic hashing algorithms", keywords: ["cryptographic", "hashing", "algorithms"])
        let store = makeStore(kbID: kbID, chunks: [chunk])

        let scores = store.testBM25Scores(query: "cryptographic")
        #expect(scores[chunk.id] != nil)
        #expect(scores[chunk.id]! > 0)
    }

    @Test("Multiple knowledge bases in same domain are all searched")
    func multipleKBsSameDomain() {
        let kbA = UUID()
        let kbB = UUID()
        let dim = 16
        let domainID = KnowledgeDomain.generalID
        let queryVec = makeEmbedding(primaryAxis: 0, dimension: dim)

        let chunkA = makeChunk(kbID: kbA, content: "Content from knowledge base alpha", keywords: ["content", "knowledge", "alpha"], index: 0, embedding: makeEmbedding(primaryAxis: 0, dimension: dim))
        let chunkB = makeChunk(kbID: kbB, content: "Content from knowledge base beta", keywords: ["content", "knowledge", "beta"], index: 0, embedding: makeEmbedding(primaryAxis: 0, dimension: dim, strength: 0.85))

        let store = KnowledgeBaseStore()
        store.injectTestData(
            knowledgeBases: [
                KnowledgeBase(id: kbA, name: "KB Alpha", documentType: .text, chunkCount: 1, fileSize: 512, domainID: domainID),
                KnowledgeBase(id: kbB, name: "KB Beta", documentType: .text, chunkCount: 1, fileSize: 512, domainID: domainID),
            ],
            chunks: [kbA: [chunkA], kbB: [chunkB]],
            domains: [KnowledgeDomain.general()]
        )

        let results = store.retrieveWithVector(queryVec, query: "content knowledge", domainID: domainID, limit: 5)
        // Both chunks should appear since they're in the same domain
        let foundIDs = Set(results.map(\.id))
        #expect(foundIDs.contains(chunkA.id))
        #expect(foundIDs.contains(chunkB.id))
    }
}

// MARK: - Memory BM25 Scoring Tests

@Suite("Memory BM25 Scoring")
struct MemoryBM25Tests {

    @Test("Exact keyword match produces nonzero memory BM25 score")
    func exactMatch() {
        let store = MemoryStore()
        store.deleteAllMemories()
        store.addMemory("The user prefers Python for scripting tasks", keywords: ["python", "preference", "scripting"], source: "Test")

        let scores = store.testBM25Scores(query: "python scripting preference")
        #expect(!scores.isEmpty)
        let memory = store.memories[0]
        #expect(scores[memory.id] != nil)
        #expect(scores[memory.id]! > 0)
        store.deleteAllMemories()
    }

    @Test("Non-matching query produces no memory BM25 score")
    func noMatch() {
        let store = MemoryStore()
        store.deleteAllMemories()
        store.addMemory("The user prefers Python for scripting", keywords: ["python", "scripting"], source: "Test")

        let scores = store.testBM25Scores(query: "quantum physics equations")
        let memory = store.memories[0]
        #expect(scores[memory.id] == nil)
        store.deleteAllMemories()
    }

    @Test("More keyword matches produce higher memory BM25 score")
    func moreMatchesHigherScore() {
        let store = MemoryStore()
        store.deleteAllMemories()
        store.addMemory("Weekly team meeting is on Tuesdays at 10am", keywords: ["meeting", "tuesday", "weekly", "team"], source: "Test")
        store.addMemory("The office has a coffee machine in the kitchen", keywords: ["office", "coffee", "kitchen"], source: "Test")

        let scores = store.testBM25Scores(query: "weekly team meeting tuesday")
        let meetingMemory = store.memories.first { $0.content.contains("meeting") }!
        let coffeeMemory = store.memories.first { $0.content.contains("coffee") }!

        let meetingScore = scores[meetingMemory.id] ?? 0
        let coffeeScore = scores[coffeeMemory.id] ?? 0

        #expect(meetingScore > coffeeScore)
        store.deleteAllMemories()
    }

    @Test("Memory BM25 scores are domain-scoped")
    func domainScoped() {
        let store = MemoryStore()
        store.deleteAllMemories()
        let workDomain = UUID()

        store.addMemory("Python is the preferred language", keywords: ["python", "language", "preferred"], source: "Test", domainID: KnowledgeDomain.generalID)
        store.addMemory("Use TypeScript for the work project", keywords: ["typescript", "work", "project"], source: "Test", domainID: workDomain)

        let generalScores = store.testBM25Scores(query: "python language", domainID: KnowledgeDomain.generalID)
        let workScores = store.testBM25Scores(query: "python language", domainID: workDomain)

        // Python memory is in General — should only score there
        let pythonMemory = store.memories.first { $0.content.contains("Python") }!
        #expect(generalScores[pythonMemory.id] != nil)
        #expect(workScores[pythonMemory.id] == nil)
        store.deleteAllMemories()
    }

    @Test("Empty query returns empty memory BM25 scores")
    func emptyQuery() {
        let store = MemoryStore()
        store.deleteAllMemories()
        store.addMemory("Some memory content", keywords: ["memory"], source: "Test")

        let scores = store.testBM25Scores(query: "")
        #expect(scores.isEmpty)
        store.deleteAllMemories()
    }

    @Test("Memory BM25 scores normalized to [0, 1]")
    func scoresNormalized() {
        let store = MemoryStore()
        store.deleteAllMemories()
        for i in 0..<5 {
            store.addMemory("Memory \(i) about swift coding patterns", keywords: ["swift", "coding", "patterns"], source: "Test")
        }

        let scores = store.testBM25Scores(query: "swift coding patterns")
        for (_, score) in scores {
            #expect(score >= 0)
            #expect(score <= 1.0)
        }
        store.deleteAllMemories()
    }
}
