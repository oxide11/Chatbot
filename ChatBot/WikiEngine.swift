//
//  WikiEngine.swift
//  ChatBot
//
//  Created by Moussa Noun on 2026-04-27.
//


//
//  WikiEngine.swift
//  ChatBot
//
//  Orchestrates the LLM Wiki lifecycle:
//  1. Extraction — after context rotation or conversation end, the LLM
//     reads the transcript and creates/updates wiki pages.
//  2. Injection — before generating a response, relevant wiki pages
//     are retrieved and formatted for inclusion in the prompt.
//
//  Replaces MemoryStore as the primary long-term knowledge system.
//

import Foundation
import FoundationModels
import os

@Observable
final class WikiEngine {
    let wikiStore: WikiStore

    /// Whether wiki extraction is enabled.
    var extractionEnabled: Bool = true

    /// Whether wiki injection into prompts is enabled.
    var injectionEnabled: Bool = true

    /// Max wiki pages to inject for on-device model (4096 token budget).
    var onDevicePageLimit: Int = 2

    /// Max characters of wiki context for on-device model.
    var onDeviceCharBudget: Int = 1750

    init(wikiStore: WikiStore) {
        self.wikiStore = wikiStore
    }

    // MARK: - Knowledge Extraction

    /// Extract knowledge from a conversation transcript and create/update wiki pages.
    /// Runs asynchronously — never blocks the UI.
    func extractKnowledge(
        from transcript: String,
        conversationID: UUID,
        conversationTitle: String,
        domainID: UUID?
    ) async {
        guard extractionEnabled else { return }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let extractionSession = LanguageModelSession {
            WikiExtractionPrompts.systemPrompt
        }

        let prompt = WikiExtractionPrompts.extractionPrompt(
            transcript: transcript,
            existingPageTitles: wikiStore.pages.map(\.title)
        )

        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: 500
        )

        do {
            let response = try await extractionSession.respond(to: prompt, options: options)
            let extracted = WikiExtractionPrompts.parse(response.content)

            guard !extracted.isEmpty else {
                AppLogger.wiki.debug("No knowledge extracted from '\(conversationTitle)'")
                return
            }

            for item in extracted {
                // Resolve [[wikilinks]] in the body to actual page IDs
                let referencedTitles = WikiExtractionPrompts.extractWikilinks(from: item.body)
                let linkedIDs = referencedTitles.compactMap { title in
                    wikiStore.findPageByTitle(title)?.id
                }

                if let existing = wikiStore.findPageByTitle(item.title) {
                    // Merge into existing page
                    let mergedBody = mergeContent(existing: existing.body, new: item.body)
                    let mergedTags = Array(Set(existing.tags + item.tags))
                    let mergedLinks = Array(Set(existing.linkedPageIDs + linkedIDs))

                    await wikiStore.updatePage(
                        id: existing.id,
                        body: mergedBody,
                        tags: mergedTags,
                        linkedPageIDs: mergedLinks,
                        sourceConversationID: conversationID
                    )
                    AppLogger.wiki.info("Merged into existing wiki page '\(item.title)'")
                } else {
                    // Create new page
                    await wikiStore.createPage(
                        title: item.title,
                        body: item.body,
                        tags: item.tags,
                        domainID: domainID,
                        sourceConversationID: conversationID
                    )
                    AppLogger.wiki.info("Created new wiki page '\(item.title)'")
                }
            }

            AppLogger.wiki.info("Extracted \(extracted.count) wiki page(s) from '\(conversationTitle)'")
        } catch {
            AppLogger.wiki.error("Wiki extraction failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Context Injection

    /// Query the wiki for relevant pages and format them for injection into the prompt.
    /// Returns a formatted context string and the number of pages included.
    func buildWikiContext(
        for query: String,
        domainID: UUID?
    ) -> (context: String, pageCount: Int) {
        guard injectionEnabled else { return ("", 0) }

        let budgetChars = onDeviceCharBudget
        let maxPages = onDevicePageLimit

        let relevantPages = wikiStore.findRelevantPages(
            for: query,
            domainID: domainID,
            limit: maxPages
        )

        guard !relevantPages.isEmpty else { return ("", 0) }

        var context = ""
        var usedChars = 0
        var includedCount = 0

        for page in relevantPages {
            let formatted = "## \(page.title)\n\(page.body)"
            if usedChars + formatted.count > budgetChars { break }
            context += formatted + "\n\n"
            usedChars += formatted.count
            includedCount += 1

            wikiStore.recordAccess(pageID: page.id)
        }

        return (context.trimmingCharacters(in: .whitespacesAndNewlines), includedCount)
    }

    // MARK: - Merge Logic

    /// Merge new content into an existing page body.
    /// Appends new bullet points that don't already exist in the page.
    private func mergeContent(existing: String, new: String) -> String {
        let existingLines = Set(
            existing.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )

        let newLines = new.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !existingLines.contains($0.lowercased()) }

        if newLines.isEmpty { return existing }

        return existing + "\n" + newLines.joined(separator: "\n")
    }
}