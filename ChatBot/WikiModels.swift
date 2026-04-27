//
//  WikiModels.swift
//  ChatBot
//
//  SwiftData persistence model and lightweight transfer struct for LLM Wiki pages.
//  Follows the same pattern as KnowledgeBaseModels.swift:
//  - @Model class (SDWikiPage) is the on-disk representation
//  - WikiPage struct is the in-memory transfer type used by the retrieval pipeline
//
//  Embeddings are stored as raw binary Data using @Attribute(.externalStorage)
//  so the SQLite table stays lean for queries.
//

import Foundation
import SwiftData

// MARK: - SwiftData Model: Wiki Page

@Model
final class SDWikiPage {
    @Attribute(.unique) var id: UUID
    var title: String
    var body: String

    /// Tags stored as JSON-encoded string (SwiftData doesn't natively support [String] in predicates).
    var tagsRaw: String

    var createdAt: Date
    var updatedAt: Date

    /// Which conversations contributed knowledge to this page.
    var sourceConversationIDsRaw: String

    /// Which imported documents (KnowledgeBase entries) contributed knowledge to this page.
    var sourceDocumentIDsRaw: String = "[]"

    /// IDs of other wiki pages this page references (simpler than self-referential relationships).
    var linkedPageIDsRaw: String

    /// Domain scoping (consistent with KnowledgeBase architecture).
    var domainID: UUID?

    /// Access tracking for retrieval prioritization.
    var accessCount: Int
    var lastAccessedAt: Date

    /// Semantic embedding of title+body for retrieval.
    @Attribute(.externalStorage)
    var embeddingData: Data?

    // MARK: - Ergonomic Accessors

    var tags: [String] {
        get { decodeJSONArray(tagsRaw) }
        set { tagsRaw = encodeJSONArray(newValue) }
    }

    var sourceConversationIDs: [UUID] {
        get { decodeJSONArray(sourceConversationIDsRaw) }
        set { sourceConversationIDsRaw = encodeJSONArray(newValue) }
    }

    var sourceDocumentIDs: [UUID] {
        get { decodeJSONArray(sourceDocumentIDsRaw) }
        set { sourceDocumentIDsRaw = encodeJSONArray(newValue) }
    }

    var linkedPageIDs: [UUID] {
        get { decodeJSONArray(linkedPageIDsRaw) }
        set { linkedPageIDsRaw = encodeJSONArray(newValue) }
    }

    var embedding: [Double]? {
        get { embeddingData?.asDoubleArray() }
        set { embeddingData = newValue?.asData }
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        tags: [String] = [],
        domainID: UUID? = nil,
        sourceConversationIDs: [UUID] = [],
        sourceDocumentIDs: [UUID] = [],
        linkedPageIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tagsRaw = encodeJSONArray(tags)
        self.createdAt = Date()
        self.updatedAt = Date()
        self.sourceConversationIDsRaw = encodeJSONArray(sourceConversationIDs)
        self.sourceDocumentIDsRaw = encodeJSONArray(sourceDocumentIDs)
        self.linkedPageIDsRaw = encodeJSONArray(linkedPageIDs)
        self.domainID = domainID
        self.accessCount = 0
        self.lastAccessedAt = Date()
        self.embeddingData = EmbeddingService.shared.embed("\(title)\n\(body)")?.asData
    }

    /// Create from the lightweight struct.
    convenience init(from page: WikiPage) {
        self.init(
            id: page.id,
            title: page.title,
            body: page.body,
            tags: page.tags,
            domainID: page.domainID,
            sourceConversationIDs: page.sourceConversationIDs,
            sourceDocumentIDs: page.sourceDocumentIDs,
            linkedPageIDs: page.linkedPageIDs
        )
        self.createdAt = page.createdAt
        self.updatedAt = page.updatedAt
        self.accessCount = page.accessCount
        self.lastAccessedAt = page.lastAccessedAt
        self.embeddingData = page.embedding?.asData
    }

    /// Convert to the lightweight struct for in-memory use.
    func toStruct() -> WikiPage {
        WikiPage(
            id: id,
            title: title,
            body: body,
            tags: tags,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sourceConversationIDs: sourceConversationIDs,
            sourceDocumentIDs: sourceDocumentIDs,
            linkedPageIDs: linkedPageIDs,
            domainID: domainID,
            accessCount: accessCount,
            lastAccessedAt: lastAccessedAt,
            embedding: embedding
        )
    }
}

// MARK: - Lightweight Transfer Struct

struct WikiPage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var body: String
    var tags: [String]
    let createdAt: Date
    var updatedAt: Date
    var sourceConversationIDs: [UUID]
    var sourceDocumentIDs: [UUID] = []
    var linkedPageIDs: [UUID]
    var domainID: UUID?
    var accessCount: Int
    var lastAccessedAt: Date
    var embedding: [Double]?
}

// MARK: - JSON Array Encoding Helpers

private func encodeJSONArray<T: Encodable>(_ array: [T]) -> String {
    (try? String(data: JSONEncoder().encode(array), encoding: .utf8)) ?? "[]"
}

private func decodeJSONArray<T: Decodable>(_ raw: String) -> [T] {
    guard let data = raw.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([T].self, from: data)) ?? []
}
