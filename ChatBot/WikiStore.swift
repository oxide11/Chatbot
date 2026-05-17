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
//  Loads pages from SwiftData via WikiActor
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

    /// Resolves a `sourceDocumentIDs` entry to a human-readable file
    /// name. Set by `ConversationStore` to its `DocumentImporter`; nil
    /// in contexts that don't have one (previews, share extension).
    /// Returns nil for ids the importer no longer knows about (deleted).
    var documentTitleResolver: ((UUID) -> String?)?

    /// Resolves a `sourceConversationIDs` entry to a conversation title.
    /// Same lifecycle as `documentTitleResolver`. Returns nil for ids
    /// the store no longer knows about (deleted conversation).
    var conversationTitleResolver: ((UUID) -> String?)?

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
    /// `summary` is stored as-is — empty means "no LLM summary yet";
    /// `tableOfContents` derives a fallback inline at display time, and
    /// `WikiEngine.runSummaryBackfill` upgrades it to an LLM summary on
    /// demand. Storing only LLM-generated summaries lets the backfill
    /// know which pages still need work without an extra "quality" flag.
    @discardableResult
    func createPage(
        title: String,
        body: String,
        tags: [String],
        summary: String = "",
        sourceConversationID: UUID? = nil,
        sourceDocumentID: UUID? = nil
    ) async -> WikiPage? {
        let page = WikiPage(
            id: UUID(),
            title: title,
            body: body,
            summary: summary,
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
        summary: String? = nil,
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
                summary: summary,
                linkedPageIDs: linkedPageIDs,
                sourceConversationID: sourceConversationID,
                sourceDocumentID: sourceDocumentID
            )
            await loadAll()
        } catch {
            AppLogger.wiki.error("Failed to update wiki page \(id): \(error.localizedDescription)")
        }
    }

    /// Persist a summary for a page (used by lazy backfill). Patches the
    /// in-memory copy on the main actor so the next TOC pass sees it
    /// without a full reload.
    @MainActor
    func setSummary(pageID: UUID, summary: String) async {
        guard let actor else { return }
        do {
            try await actor.setSummary(pageID: pageID, summary: summary)
            if let i = pages.firstIndex(where: { $0.id == pageID }) {
                pages[i].summary = summary
            }
        } catch {
            AppLogger.wiki.error("Failed to set summary on \(pageID): \(error.localizedDescription)")
        }
    }

    /// Replace just the `linkedPageIDs` relationship for a page. Patches
    /// in-memory so the wiki UI reflects the new graph without a full
    /// reload. Used by `WikiEngine.reconcileWikilinks`.
    @MainActor
    func setLinkedPageIDs(pageID: UUID, linkedPageIDs: [UUID]) async {
        guard let actor else { return }
        do {
            try await actor.setLinkedPageIDs(pageID: pageID, linkedPageIDs: linkedPageIDs)
            if let i = pages.firstIndex(where: { $0.id == pageID }) {
                pages[i].linkedPageIDs = linkedPageIDs
            }
        } catch {
            AppLogger.wiki.error("Failed to set linked page IDs on \(pageID): \(error.localizedDescription)")
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

    /// Build a table-of-contents string for the model to scan before
    /// deciding which pages to fetch. When the wiki fits inside
    /// `budget.tocEntryLimit`, every page is included; otherwise we
    /// embedding-rank against the query and keep the top entries.
    /// Each line has the shape `[[Title]] — summary` (or `[[Title]]`
    /// alone for pages that haven't been summarised yet).
    func tableOfContents(
        for query: String,
        budget: WikiContextBudget
    ) -> (text: String, entryCount: Int) {
        let pool = pages
        guard !pool.isEmpty else { return ("", 0) }

        let selected: [WikiPage]
        if pool.count <= budget.tocEntryLimit {
            selected = pool
        } else if let queryVector = EmbeddingService.shared.embed(query) {
            let scored = pool.compactMap { page -> (WikiPage, Double)? in
                guard let pageVector = page.embedding else { return (page, 0) }
                let similarity = EmbeddingService.cosineSimilarity(queryVector, pageVector)
                return (page, similarity)
            }
            selected = scored
                .sorted { $0.1 > $1.1 }
                .prefix(budget.tocEntryLimit)
                .map { $0.0 }
        } else {
            selected = Array(pool.prefix(budget.tocEntryLimit))
        }

        let lines = selected.map { page -> String in
            let stored = page.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            // Fall back to a deterministic first-line summary at display
            // time when the LLM hasn't backfilled this page yet — keeps
            // the TOC useful without forcing a write.
            let summary = stored.isEmpty
                ? WikiExtractionPrompts.deriveSummary(fromBody: page.body, title: page.title)
                : stored
            if summary.isEmpty {
                return "- [[\(page.title)]]"
            }
            return "- [[\(page.title)]] — \(summary)"
        }
        return (lines.joined(separator: "\n"), selected.count)
    }

    /// Title-keyed lookup for the `getWikiPage` tool. Returns the page
    /// with body head-truncated to `budget.pageCharBudget` so a fat page
    /// doesn't blow the on-device window.
    func toolPageBody(forTitle title: String, budget: WikiContextBudget) -> WikiPage? {
        guard var page = findPageByTitle(title) else { return nil }
        if page.body.count > budget.pageCharBudget {
            let cutoff = page.body.index(page.body.startIndex, offsetBy: budget.pageCharBudget)
            page.body = String(page.body[..<cutoff]) + "\n…(page truncated)"
        }
        return page
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