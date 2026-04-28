//
//  WikiStore.swift
//  ChatBot
//
//  Created by Moussa Noun on 2026-04-27.
//


//
//  WikiStore.swift
//  ChatBot
//
//  In-memory cache + semantic retrieval for wiki pages.
//  Mirrors the KnowledgeBaseStore pattern: loads pages from SwiftData via WikiActor
//  into lightweight structs, then uses EmbeddingService for vector-based retrieval.
//
//  Replaces MemoryStore as the primary long-term knowledge system.
//

import Foundation
import SwiftData
import os

@Observable
final class WikiStore {
    private(set) var pages: [WikiPage] = []
    private(set) var isConfigured = false

    private var actor: WikiActor?

    // MARK: - Configuration

    /// Call once from the view layer to provide the SwiftData ModelContainer.
    func configure(with container: ModelContainer) {
        guard !isConfigured else { return }
        actor = WikiActor(modelContainer: container)
        isConfigured = true
        Task { await loadAll() }
    }

    // MARK: - Load

    /// Reload all pages from SwiftData into memory.
    @MainActor
    func loadAll() async {
        guard let actor else { return }
        do {
            pages = try await actor.loadAllPages()
            AppLogger.wiki.info("Loaded \(self.pages.count) wiki pages")
        } catch {
            AppLogger.wiki.error("Failed to load wiki pages: \(error.localizedDescription)")
        }
    }

    // MARK: - CRUD

    /// Create a new wiki page. Returns the created page.
    @discardableResult
    func createPage(
        title: String,
        body: String,
        tags: [String],
        sourceConversationID: UUID? = nil,
        sourceDocumentID: UUID? = nil
    ) async -> WikiPage? {
        let page = WikiPage(
            id: UUID(),
            title: title,
            body: body,
            tags: tags,
            createdAt: Date(),
            updatedAt: Date(),
            sourceConversationIDs: sourceConversationID.map { [$0] } ?? [],
            sourceDocumentIDs: sourceDocumentID.map { [$0] } ?? [],
            linkedPageIDs: [],
            accessCount: 0,
            lastAccessedAt: Date(),
            embedding: EmbeddingService.shared.embed("\(title)\n\(body)")
        )

        guard let actor else { return nil }
        do {
            try await actor.insertPage(page)
            await loadAll()
            return page
        } catch {
            AppLogger.wiki.error("Failed to create wiki page '\(title)': \(error.localizedDescription)")
            return nil
        }
    }

    /// Update a wiki page's body and tags.
    func updatePage(
        id: UUID,
        body: String,
        tags: [String],
        linkedPageIDs: [UUID] = [],
        sourceConversationID: UUID? = nil,
        sourceDocumentID: UUID? = nil
    ) async {
        guard let actor else { return }
        do {
            try await actor.updatePage(
                id: id,
                body: body,
                tags: tags,
                linkedPageIDs: linkedPageIDs,
                sourceConversationID: sourceConversationID,
                sourceDocumentID: sourceDocumentID
            )
            await loadAll()
        } catch {
            AppLogger.wiki.error("Failed to update wiki page \(id): \(error.localizedDescription)")
        }
    }

    /// Delete a wiki page.
    func deletePage(id: UUID) async {
        guard let actor else { return }
        do {
            try await actor.deletePage(id: id)
            await loadAll()
        } catch {
            AppLogger.wiki.error("Failed to delete wiki page \(id): \(error.localizedDescription)")
        }
    }

    /// Delete all wiki pages.
    func deleteAllPages() async {
        guard let actor else { return }
        do {
            try await actor.deleteAllPages()
            await loadAll()
        } catch {
            AppLogger.wiki.error("Failed to delete all wiki pages: \(error.localizedDescription)")
        }
    }

    // MARK: - Retrieval

    /// Find wiki pages relevant to a query, ranked by semantic similarity.
    /// Falls back to keyword matching if embeddings are unavailable.
    func findRelevantPages(
        for query: String,
        limit: Int = 3
    ) -> [WikiPage] {
        let pool = pages
        guard !pool.isEmpty else { return [] }

        // Semantic retrieval
        if let queryVector = EmbeddingService.shared.embed(query) {
            let scored = pool.compactMap { page -> (WikiPage, Double)? in
                guard let pageVector = page.embedding else { return nil }
                let similarity = EmbeddingService.cosineSimilarity(queryVector, pageVector)
                guard similarity > 0.25 else { return nil }

                // Boost by access frequency and recency
                let frequencyBonus = min(Double(page.accessCount) * 0.01, 0.05)
                let ageInDays = max(1, -page.lastAccessedAt.timeIntervalSinceNow / 86400)
                let recencyBonus = 1.0 / log2(ageInDays + 1) * 0.02

                return (page, similarity + frequencyBonus + recencyBonus)
            }

            let results = scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
            if !results.isEmpty { return results }
        }

        // Fallback: keyword matching
        return keywordMatch(query: query, pool: pool, limit: limit)
    }

    /// Find a page by exact title (case-insensitive).
    func findPageByTitle(_ title: String) -> WikiPage? {
        let lowered = title.lowercased()
        return pages.first { $0.title.lowercased() == lowered }
    }

    /// Find pages with a specific tag.
    func findPages(withTag tag: String) -> [WikiPage] {
        let lowered = tag.lowercased()
        return pages.filter { $0.tags.contains { $0.lowercased() == lowered } }
    }

    /// Record an access for prioritization.
    func recordAccess(pageID: UUID) {
        guard let actor else { return }
        Task {
            try? await actor.recordAccess(pageID: pageID)
        }
    }

    // MARK: - Keyword Fallback

    private func keywordMatch(query: String, pool: [WikiPage], limit: Int) -> [WikiPage] {
        let queryWords = SharedDataManager.tokenize(query)
        guard !queryWords.isEmpty else { return [] }
        let queryCount = Double(queryWords.count)

        let scored = pool.compactMap { page -> (WikiPage, Double)? in
            let pageWords = SharedDataManager.tokenize(page.title + " " + page.body)
                .union(Set(page.tags.map { $0.lowercased() }))

            var matchedWords = 0.0
            for word in queryWords {
                if pageWords.contains(word) {
                    matchedWords += 1.0
                } else if word.count >= 5 {
                    for pw in pageWords where pw.count >= 5
                        && (pw.hasPrefix(word) || word.hasPrefix(pw)) {
                        matchedWords += 0.5
                        break
                    }
                }
            }

            let score = matchedWords / queryCount
            guard score >= 0.2 else { return nil }
            return (page, score)
        }

        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }
}