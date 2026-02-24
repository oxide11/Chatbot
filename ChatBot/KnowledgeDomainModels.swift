//
//  KnowledgeDomainModels.swift
//  ChatBot
//
//  Lightweight struct + SwiftData @Model for Knowledge Domains.
//  A domain groups Memories and Knowledge Bases into a self-contained
//  RAG context that can be assigned per-conversation.
//

import Foundation
import SwiftData

// MARK: - Domain Struct (in-memory transfer type)

struct KnowledgeDomain: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var isDefault: Bool

    /// Well-known UUID for the auto-created "General" domain.
    nonisolated static let generalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Factory for the default "General" domain.
    static func general() -> KnowledgeDomain {
        KnowledgeDomain(
            id: generalID,
            name: "General",
            createdAt: Date(),
            isDefault: true
        )
    }

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.isDefault = isDefault
    }
}

// MARK: - SwiftData Model: Knowledge Domain

@Model
final class SDKnowledgeDomain {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var isDefault: Bool

    @Relationship(deleteRule: .cascade, inverse: \SDKnowledgeBase.domain)
    var knowledgeBases: [SDKnowledgeBase] = []

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.isDefault = isDefault
    }

    /// Create from the lightweight struct.
    convenience init(from domain: KnowledgeDomain) {
        self.init(
            id: domain.id,
            name: domain.name,
            createdAt: domain.createdAt,
            isDefault: domain.isDefault
        )
    }

    /// Convert to the lightweight struct for in-memory use.
    func toStruct() -> KnowledgeDomain {
        KnowledgeDomain(
            id: id,
            name: name,
            createdAt: createdAt,
            isDefault: isDefault
        )
    }
}
