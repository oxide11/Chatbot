//
//  WikiActor.swift
//  ChatBot
//
//  Thread-safe SwiftData access for Wiki page persistence.
//  @ModelActor with a dedicated ModelContext on its own serial executor.
//
//  All methods accept and return lightweight structs (WikiPage),
//  never @Model objects, since those cannot cross actor boundaries.
//

import Foundation
import SwiftData
import os

@ModelActor
actor WikiActor {

    // MARK: - Create

    /// Insert a new wiki page.
    func insertPage(_ page: WikiPage) throws {
        let sd = SDWikiPage(from: page)
        modelContext.insert(sd)
        try modelContext.save()
        AppLogger.wiki.info("Inserted wiki page '\(page.title)' (\(page.id))")
    }

    // MARK: - Read

    /// Load all wiki pages as lightweight structs.
    func loadAllPages() throws -> [WikiPage] {
        let descriptor = FetchDescriptor<SDWikiPage>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { $0.toStruct() }
    }

    /// Find a page by title (case-insensitive).
    func findPage(byTitle title: String) throws -> WikiPage? {
        let lowered = title.lowercased()
        let descriptor = FetchDescriptor<SDWikiPage>()
        let all = try modelContext.fetch(descriptor)
        return all.first { $0.title.lowercased() == lowered }?.toStruct()
    }

    // MARK: - Update

    /// Update a wiki page's body, tags, summary, and linked pages.
    /// Pass `summary: nil` to leave the existing summary alone (e.g. for
    /// updates from the lint pipeline that don't regenerate one).
    func updatePage(
        id: UUID,
        body: String,
        tags: [String],
        summary: String? = nil,
        linkedPageIDs: [UUID],
        sourceConversationID: UUID? = nil,
        sourceDocumentID: UUID? = nil
    ) throws {
        let predicate = #Predicate<SDWikiPage> { $0.id == id }
        let descriptor = FetchDescriptor<SDWikiPage>(predicate: predicate)
        guard let sd = try modelContext.fetch(descriptor).first else { return }

        sd.body = body
        sd.tags = tags
        sd.linkedPageIDs = linkedPageIDs
        sd.updatedAt = Date()
        if let summary, !summary.isEmpty {
            sd.summary = summary
        }

        if let convID = sourceConversationID {
            var ids = sd.sourceConversationIDs
            if !ids.contains(convID) {
                ids.append(convID)
                sd.sourceConversationIDs = ids
            }
        }

        if let docID = sourceDocumentID {
            var ids = sd.sourceDocumentIDs
            if !ids.contains(docID) {
                ids.append(docID)
                sd.sourceDocumentIDs = ids
            }
        }

        // Recompute embedding with updated content
        sd.embedding = EmbeddingService.shared.embed("\(sd.title)\n\(body)")

        try modelContext.save()
        AppLogger.wiki.info("Updated wiki page '\(sd.title)' (\(id))")
    }

    /// Persist a freshly generated summary for a page (used by lazy
    /// backfill of legacy pages that don't have one yet).
    func setSummary(pageID: UUID, summary: String) throws {
        let predicate = #Predicate<SDWikiPage> { $0.id == pageID }
        let descriptor = FetchDescriptor<SDWikiPage>(predicate: predicate)
        guard let sd = try modelContext.fetch(descriptor).first else { return }
        sd.summary = summary
        try modelContext.save()
    }

    /// Record an access (for retrieval prioritization).
    func recordAccess(pageID: UUID) throws {
        let predicate = #Predicate<SDWikiPage> { $0.id == pageID }
        let descriptor = FetchDescriptor<SDWikiPage>(predicate: predicate)
        guard let sd = try modelContext.fetch(descriptor).first else { return }

        sd.accessCount += 1
        sd.lastAccessedAt = Date()
        try modelContext.save()
    }

    // MARK: - Delete

    /// Delete a wiki page by ID.
    func deletePage(id: UUID) throws {
        let predicate = #Predicate<SDWikiPage> { $0.id == id }
        let descriptor = FetchDescriptor<SDWikiPage>(predicate: predicate)
        if let sd = try modelContext.fetch(descriptor).first {
            let title = sd.title
            modelContext.delete(sd)
            try modelContext.save()
            AppLogger.wiki.info("Deleted wiki page '\(title)' (\(id))")
        }
    }

    /// Delete all wiki pages.
    func deleteAllPages() throws {
        let descriptor = FetchDescriptor<SDWikiPage>()
        let all = try modelContext.fetch(descriptor)
        for page in all {
            modelContext.delete(page)
        }
        try modelContext.save()
        AppLogger.wiki.info("Deleted all wiki pages (\(all.count) total)")
    }

    /// Total number of wiki pages.
    func pageCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<SDWikiPage>())
    }
}
