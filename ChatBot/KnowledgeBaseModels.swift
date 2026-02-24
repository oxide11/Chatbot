//
//  KnowledgeBaseModels.swift
//  ChatBot
//
//  SwiftData persistence models for the Knowledge Base system.
//  These @Model classes are the on-disk representation; the existing
//  KnowledgeBase / DocumentChunk structs remain the in-memory transfer types
//  used by the retrieval pipeline (EmbeddingMatrix, vDSP batch scoring, etc.).
//
//  Embeddings are stored as raw binary Data (4096 bytes for 512-dim [Double])
//  using @Attribute(.externalStorage) so the SQLite table stays lean for queries.
//

import Foundation
import SwiftData

// MARK: - SwiftData Model: Knowledge Base

@Model
final class SDKnowledgeBase {
    @Attribute(.unique) var id: UUID
    var name: String
    var documentTypeRaw: String
    var createdAt: Date
    var updatedAt: Date
    var chunkCount: Int
    var fileSize: Int64
    var embeddingModelID: String?

    @Relationship(deleteRule: .cascade, inverse: \SDDocumentChunk.knowledgeBase)
    var chunks: [SDDocumentChunk] = []

    /// Ergonomic accessor for the `DocumentType` enum.
    var documentType: DocumentType {
        get { DocumentType(rawValue: documentTypeRaw) ?? .text }
        set { documentTypeRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        documentType: DocumentType,
        chunkCount: Int,
        fileSize: Int64,
        embeddingModelID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.documentTypeRaw = documentType.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.chunkCount = chunkCount
        self.fileSize = fileSize
        self.embeddingModelID = embeddingModelID
    }

    /// Create from the lightweight struct used by the in-memory store.
    convenience init(from kb: KnowledgeBase) {
        self.init(
            id: kb.id,
            name: kb.name,
            documentType: kb.documentType,
            chunkCount: kb.chunkCount,
            fileSize: kb.fileSize,
            embeddingModelID: kb.embeddingModelID
        )
        self.createdAt = kb.createdAt
        self.updatedAt = kb.updatedAt
    }

    /// Convert to the lightweight struct for in-memory use.
    func toStruct() -> KnowledgeBase {
        KnowledgeBase(
            id: id,
            name: name,
            documentType: documentType,
            chunkCount: chunkCount,
            fileSize: fileSize,
            embeddingModelID: embeddingModelID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

// MARK: - SwiftData Model: Document Chunk

@Model
final class SDDocumentChunk {
    @Attribute(.unique) var id: UUID
    var content: String
    /// Keywords stored as JSON-encoded string (SwiftData doesn't natively support [String]).
    var keywordsRaw: String
    var locationLabel: String
    var index: Int

    /// Binary embedding data — stored outside the SQLite row via external storage.
    /// A 512-dim [Double] is exactly 4096 bytes as raw Data.
    @Attribute(.externalStorage)
    var embeddingData: Data?

    /// Back-pointer to the parent knowledge base (inverse of SDKnowledgeBase.chunks).
    var knowledgeBase: SDKnowledgeBase?

    /// Ergonomic accessor for keywords.
    var keywords: [String] {
        get {
            guard let data = keywordsRaw.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            keywordsRaw = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
        }
    }

    /// Ergonomic accessor for the embedding vector.
    var embedding: [Double]? {
        get { embeddingData?.asDoubleArray() }
        set { embeddingData = newValue?.asData }
    }

    init(
        id: UUID = UUID(),
        content: String,
        keywords: [String],
        locationLabel: String,
        index: Int,
        embedding: [Double]? = nil,
        knowledgeBase: SDKnowledgeBase? = nil
    ) {
        self.id = id
        self.content = content
        self.keywordsRaw = (try? String(data: JSONEncoder().encode(keywords), encoding: .utf8)) ?? "[]"
        self.locationLabel = locationLabel
        self.index = index
        self.embeddingData = embedding?.asData
        self.knowledgeBase = knowledgeBase
    }

    /// Create from the lightweight struct used by the in-memory store.
    convenience init(from chunk: DocumentChunk, knowledgeBase: SDKnowledgeBase? = nil) {
        self.init(
            id: chunk.id,
            content: chunk.content,
            keywords: chunk.keywords,
            locationLabel: chunk.locationLabel,
            index: chunk.index,
            embedding: chunk.embedding,
            knowledgeBase: knowledgeBase
        )
    }

    /// Convert to the lightweight struct for in-memory use.
    func toStruct(knowledgeBaseID: UUID) -> DocumentChunk {
        DocumentChunk(
            id: id,
            knowledgeBaseID: knowledgeBaseID,
            content: content,
            keywords: keywords,
            locationLabel: locationLabel,
            index: index,
            embedding: embedding
        )
    }
}

// MARK: - Binary Embedding Conversion

extension Array where Element == Double {
    /// Convert a [Double] embedding vector to raw binary Data (zero-copy).
    /// A 512-dim vector becomes exactly 4096 bytes.
    nonisolated var asData: Data {
        withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension Data {
    /// Convert raw binary Data back to a [Double] embedding vector.
    nonisolated func asDoubleArray() -> [Double] {
        withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
    }
}
