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

@ModelActor
actor KnowledgeBaseActor {

    // MARK: - Insert

    /// Insert a new knowledge base with all its chunks.
    func insertKnowledgeBase(_ kb: KnowledgeBase, chunks: [DocumentChunk]) throws {
        let sdKB = SDKnowledgeBase(from: kb)
        modelContext.insert(sdKB)

        for chunk in chunks {
            let sdChunk = SDDocumentChunk(from: chunk, knowledgeBase: sdKB)
            modelContext.insert(sdChunk)
        }

        try modelContext.save()
        print("[KBActor] Inserted KB '\(kb.name)' with \(chunks.count) chunks")
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
            print("[KBActor] Deleted KB '\(name)' (\(id))")
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
        print("[KBActor] Deleted all \(all.count) knowledge bases")
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
        print("[KBActor] Deleted chunk \(chunkID) from KB \(kbID)")
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
            print("[KBActor] Renamed KB \(id) to '\(newName)'")
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
        print("[KBActor] Replaced chunks for KB \(kbID) — \(newChunks.count) new chunks")
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
        print("[KBActor] Updated embeddings for KB \(kbID) (\(embeddings.count) chunks)")
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
        print("[KBActor] Migration complete — imported \(knowledgeBases.count) knowledge bases")
    }
}
