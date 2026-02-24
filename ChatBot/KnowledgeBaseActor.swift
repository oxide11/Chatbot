//
//  KnowledgeBaseActor.swift
//  ChatBot
//
//  Thread-safe SwiftData access for Knowledge Base persistence.
//  Uses @ModelActor to get a dedicated ModelContext on its own serial executor,
//  so all database operations can run safely from any thread (including Task.detached).
//
//  All methods accept and return lightweight structs (KnowledgeBase, DocumentChunk),
//  never @Model objects, since those cannot cross actor boundaries.
//

import Foundation
import SwiftData
import os

@ModelActor
actor KnowledgeBaseActor {

    // MARK: - Domain CRUD

    /// Insert a new knowledge domain.
    func insertDomain(_ domain: KnowledgeDomain) throws {
        let sd = SDKnowledgeDomain(from: domain)
        modelContext.insert(sd)
        try modelContext.save()
        AppLogger.kbActor.info("Inserted domain '\(domain.name)' (\(domain.id))")
    }

    /// Load all domains as lightweight structs.
    func loadAllDomains() throws -> [KnowledgeDomain] {
        let descriptor = FetchDescriptor<SDKnowledgeDomain>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try modelContext.fetch(descriptor).map { $0.toStruct() }
    }

    /// Rename a domain.
    func renameDomain(id: UUID, to newName: String) throws {
        let predicate = #Predicate<SDKnowledgeDomain> { $0.id == id }
        let descriptor = FetchDescriptor<SDKnowledgeDomain>(predicate: predicate)
        if let sd = try modelContext.fetch(descriptor).first {
            sd.name = newName
            try modelContext.save()
            AppLogger.kbActor.info("Renamed domain \(id) to '\(newName)'")
        }
    }

    /// Delete a domain. KBs cascade-delete via the relationship.
    func deleteDomain(id: UUID) throws {
        let predicate = #Predicate<SDKnowledgeDomain> { $0.id == id }
        let descriptor = FetchDescriptor<SDKnowledgeDomain>(predicate: predicate)
        if let sd = try modelContext.fetch(descriptor).first {
            let name = sd.name
            modelContext.delete(sd)
            try modelContext.save()
            AppLogger.kbActor.info("Deleted domain '\(name)' (\(id))")
        }
    }

    /// Move a knowledge base to a different domain.
    func moveKnowledgeBase(kbID: UUID, toDomainID: UUID) throws {
        let kbPredicate = #Predicate<SDKnowledgeBase> { $0.id == kbID }
        let kbDescriptor = FetchDescriptor<SDKnowledgeBase>(predicate: kbPredicate)

        let domainPredicate = #Predicate<SDKnowledgeDomain> { $0.id == toDomainID }
        let domainDescriptor = FetchDescriptor<SDKnowledgeDomain>(predicate: domainPredicate)

        if let sdKB = try modelContext.fetch(kbDescriptor).first,
           let sdDomain = try modelContext.fetch(domainDescriptor).first {
            sdKB.domain = sdDomain
            try modelContext.save()
            AppLogger.kbActor.info("Moved KB \(kbID) to domain '\(sdDomain.name)'")
        }
    }

    /// Assign all KBs with nil domain to the specified domain (migration helper).
    func assignOrphanKBsToDomain(domainID: UUID) throws {
        let domainPredicate = #Predicate<SDKnowledgeDomain> { $0.id == domainID }
        let domainDescriptor = FetchDescriptor<SDKnowledgeDomain>(predicate: domainPredicate)
        guard let sdDomain = try modelContext.fetch(domainDescriptor).first else { return }

        let allDescriptor = FetchDescriptor<SDKnowledgeBase>()
        let allKBs = try modelContext.fetch(allDescriptor)
        var count = 0
        for sdKB in allKBs where sdKB.domain == nil {
            sdKB.domain = sdDomain
            count += 1
        }

        if count > 0 {
            try modelContext.save()
            AppLogger.kbActor.info("Assigned \(count) orphan KBs to domain '\(sdDomain.name)'")
        }
    }

    // MARK: - Insert

    /// Insert a new knowledge base with all its chunks, optionally in a domain.
    func insertKnowledgeBase(_ kb: KnowledgeBase, chunks: [DocumentChunk], domainID: UUID? = nil) throws {
        let sdKB = SDKnowledgeBase(from: kb)

        // Assign to domain if provided
        if let domainID {
            let predicate = #Predicate<SDKnowledgeDomain> { $0.id == domainID }
            let descriptor = FetchDescriptor<SDKnowledgeDomain>(predicate: predicate)
            sdKB.domain = try modelContext.fetch(descriptor).first
        }

        modelContext.insert(sdKB)

        for chunk in chunks {
            let sdChunk = SDDocumentChunk(from: chunk, knowledgeBase: sdKB)
            modelContext.insert(sdChunk)
        }

        try modelContext.save()
        AppLogger.kbActor.info("Inserted KB '\(kb.name)' with \(chunks.count) chunks")
    }

    // MARK: - Delete

    /// Delete a knowledge base and all its chunks (cascade).
    func deleteKnowledgeBase(id: UUID) throws {
        let predicate = #Predicate<SDKnowledgeBase> { $0.id == id }
        let descriptor = FetchDescriptor<SDKnowledgeBase>(predicate: predicate)
        if let sdKB = try modelContext.fetch(descriptor).first {
            let name = sdKB.name
            modelContext.delete(sdKB) // cascade deletes chunks
            try modelContext.save()
            AppLogger.kbActor.info("Deleted KB '\(name)' (\(id))")
        }
    }

    /// Delete all knowledge bases.
    func deleteAllKnowledgeBases() throws {
        let descriptor = FetchDescriptor<SDKnowledgeBase>()
        let all = try modelContext.fetch(descriptor)
        for sdKB in all {
            modelContext.delete(sdKB)
        }
        try modelContext.save()
        AppLogger.kbActor.info("Deleted all \(all.count) knowledge bases")
    }

    /// Delete a single chunk from a knowledge base.
    func deleteChunk(id chunkID: UUID, from kbID: UUID) throws {
        let chunkPredicate = #Predicate<SDDocumentChunk> { $0.id == chunkID }
        let chunkDescriptor = FetchDescriptor<SDDocumentChunk>(predicate: chunkPredicate)
        if let sdChunk = try modelContext.fetch(chunkDescriptor).first {
            modelContext.delete(sdChunk)
        }

        // Update parent's chunk count
        let kbPredicate = #Predicate<SDKnowledgeBase> { $0.id == kbID }
        let kbDescriptor = FetchDescriptor<SDKnowledgeBase>(predicate: kbPredicate)
        if let sdKB = try modelContext.fetch(kbDescriptor).first {
            sdKB.chunkCount = sdKB.chunks.count - 1 // -1 because delete hasn't flushed yet
            sdKB.updatedAt = Date()
        }

        try modelContext.save()
        AppLogger.kbActor.info("Deleted chunk \(chunkID) from KB \(kbID)")
    }

    // MARK: - Update

    /// Rename a knowledge base.
    func renameKnowledgeBase(id: UUID, to newName: String) throws {
        let predicate = #Predicate<SDKnowledgeBase> { $0.id == id }
        let descriptor = FetchDescriptor<SDKnowledgeBase>(predicate: predicate)
        if let sdKB = try modelContext.fetch(descriptor).first {
            sdKB.name = newName
            sdKB.updatedAt = Date()
            try modelContext.save()
            AppLogger.kbActor.info("Renamed KB \(id) to '\(newName)'")
        }
    }

    /// Replace all chunks for a KB (used for re-import / document update).
    func replaceChunks(
        for kbID: UUID,
        newChunks: [DocumentChunk],
        embeddingModelID: String?
    ) throws {
        let predicate = #Predicate<SDKnowledgeBase> { $0.id == kbID }
        let descriptor = FetchDescriptor<SDKnowledgeBase>(predicate: predicate)
        guard let sdKB = try modelContext.fetch(descriptor).first else { return }

        // Delete old chunks
        for chunk in sdKB.chunks {
            modelContext.delete(chunk)
        }

        // Insert new chunks
        for chunk in newChunks {
            let sdChunk = SDDocumentChunk(from: chunk, knowledgeBase: sdKB)
            modelContext.insert(sdChunk)
        }

        sdKB.chunkCount = newChunks.count
        sdKB.updatedAt = Date()
        sdKB.embeddingModelID = embeddingModelID

        try modelContext.save()
        AppLogger.kbActor.info("Replaced chunks for KB \(kbID) — \(newChunks.count) new chunks")
    }

    /// Update embeddings for all chunks in a KB (re-embedding after model update).
    func updateEmbeddings(
        for kbID: UUID,
        embeddings: [UUID: [Double]?],
        embeddingModelID: String
    ) throws {
        let predicate = #Predicate<SDKnowledgeBase> { $0.id == kbID }
        let descriptor = FetchDescriptor<SDKnowledgeBase>(predicate: predicate)
        guard let sdKB = try modelContext.fetch(descriptor).first else { return }

        for sdChunk in sdKB.chunks {
            if let newEmbedding = embeddings[sdChunk.id] {
                sdChunk.embeddingData = newEmbedding?.asData
            }
        }

        sdKB.embeddingModelID = embeddingModelID
        try modelContext.save()
        AppLogger.kbActor.info("Updated embeddings for KB \(kbID) (\(embeddings.count) chunks)")
    }

    // MARK: - Load

    /// Load all knowledge base metadata as lightweight structs.
    func loadAllKnowledgeBases() throws -> [KnowledgeBase] {
        let descriptor = FetchDescriptor<SDKnowledgeBase>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let sdKBs = try modelContext.fetch(descriptor)
        return sdKBs.map { $0.toStruct() }
    }

    /// Load all chunks for a knowledge base as lightweight structs.
    func loadChunks(for kbID: UUID) throws -> [DocumentChunk] {
        let predicate = #Predicate<SDDocumentChunk> { $0.knowledgeBase?.id == kbID }
        let descriptor = FetchDescriptor<SDDocumentChunk>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.index)]
        )
        let sdChunks = try modelContext.fetch(descriptor)
        return sdChunks.map { $0.toStruct(knowledgeBaseID: kbID) }
    }

    // MARK: - Migration

    /// Import knowledge bases and chunks from the old JSON-based storage.
    /// Called once during migration. Existing data with the same IDs is skipped.
    func migrateFromJSON(
        knowledgeBases: [KnowledgeBase],
        chunksByKB: [UUID: [DocumentChunk]]
    ) throws {
        for kb in knowledgeBases {
            // Skip if already exists (idempotent migration)
            let predicate = #Predicate<SDKnowledgeBase> { $0.id == kb.id }
            let descriptor = FetchDescriptor<SDKnowledgeBase>(predicate: predicate)
            if let existing = try? modelContext.fetch(descriptor), !existing.isEmpty {
                continue
            }

            let sdKB = SDKnowledgeBase(from: kb)
            modelContext.insert(sdKB)

            if let chunks = chunksByKB[kb.id] {
                for chunk in chunks {
                    let sdChunk = SDDocumentChunk(from: chunk, knowledgeBase: sdKB)
                    modelContext.insert(sdChunk)
                }
            }
        }

        try modelContext.save()
        AppLogger.kbActor.info("Migration complete — imported \(knowledgeBases.count) knowledge bases")
    }
}
