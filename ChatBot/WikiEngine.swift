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

    /// Set by ConversationStore. When the user has bound a remote provider
    /// to the `.extraction` task, extraction calls route through it; otherwise
    /// we fall back to the on-device LanguageModelSession path.
    var providerRegistry: ProviderRegistry?

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

        let prompt = WikiExtractionPrompts.extractionPrompt(
            transcript: transcript,
            existingPageTitles: wikiStore.pages.map(\.title)
        )

        do {
            let responseText = try await respondOnce(
                systemPrompt: WikiExtractionPrompts.systemPrompt,
                userPrompt: prompt,
                maxTokens: 500,
                task: .extraction
            )
            let extracted = WikiExtractionPrompts.parse(responseText)

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

    // MARK: - Provider Routing

    /// Run a single prompt through whichever provider the user has bound
    /// to `task`. Falls back to the on-device LanguageModelSession when no
    /// remote provider is configured for the task. Used by both
    /// extraction paths and the lint semantic pass.
    func respondOnce(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        task: ProviderTask
    ) async throws -> String {
        if let provider = providerRegistry?.resolve(for: task) {
            return try await provider.respond(
                history: [ProviderMessage(role: .user, content: userPrompt)],
                systemPrompt: systemPrompt,
                options: ProviderGenerationOptions(
                    maxOutputTokens: maxTokens,
                    temperature: 1.0
                )
            )
        }
        let session = LanguageModelSession { systemPrompt }
        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: maxTokens
        )
        let response = try await session.respond(to: userPrompt, options: options)
        return response.content
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

// MARK: - Document → Wiki Extraction

struct WikiDocumentExtractionProgress: Sendable, Equatable {
    var chunkIndex: Int
    var chunkCount: Int
    var pagesCreated: Int
    var pagesMerged: Int

    var fractionComplete: Double {
        chunkCount > 0 ? Double(chunkIndex) / Double(chunkCount) : 0
    }
}

struct WikiDocumentExtractionSummary: Sendable, Equatable {
    var chunksProcessed: Int
    var chunkCount: Int
    var pagesCreated: Int
    var pagesMerged: Int
    var cancelled: Bool
    var failedChunks: Int
}

extension WikiEngine {

    /// Maximum characters per LLM call. Comfortably under the 4096-token
    /// budget once the prompt scaffolding is added.
    private static var extractionChunkTarget: Int { 3000 }
    private static var extractionChunkOverlap: Int { 200 }

    /// Extract wiki pages from arbitrary document text. Honors cancellation
    /// (call `Task.cancel()` on the launching task) and reports progress
    /// after each chunk completes.
    func extractKnowledgeFromDocument(
        text: String,
        sourceName: String,
        sourceDocumentID: UUID?,
        domainID: UUID?,
        onProgress: @MainActor @Sendable (WikiDocumentExtractionProgress) -> Void = { _ in }
    ) async -> WikiDocumentExtractionSummary {
        guard extractionEnabled else {
            return WikiDocumentExtractionSummary(
                chunksProcessed: 0, chunkCount: 0,
                pagesCreated: 0, pagesMerged: 0,
                cancelled: false, failedChunks: 0
            )
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return WikiDocumentExtractionSummary(
                chunksProcessed: 0, chunkCount: 0,
                pagesCreated: 0, pagesMerged: 0,
                cancelled: false, failedChunks: 0
            )
        }

        let chunks = Self.chunkForExtraction(trimmed)

        var pagesCreated = 0
        var pagesMerged = 0
        var failedChunks = 0
        var processed = 0

        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled {
                return WikiDocumentExtractionSummary(
                    chunksProcessed: processed,
                    chunkCount: chunks.count,
                    pagesCreated: pagesCreated,
                    pagesMerged: pagesMerged,
                    cancelled: true,
                    failedChunks: failedChunks
                )
            }

            let prompt = WikiExtractionPrompts.documentExtractionPrompt(
                text: chunk,
                sourceName: sourceName,
                existingPageTitles: wikiStore.pages.map(\.title)
            )

            do {
                let responseText = try await respondOnce(
                    systemPrompt: WikiExtractionPrompts.systemPrompt,
                    userPrompt: prompt,
                    maxTokens: 600,
                    task: .extraction
                )
                let extracted = WikiExtractionPrompts.parse(responseText)

                for item in extracted {
                    let referencedTitles = WikiExtractionPrompts.extractWikilinks(from: item.body)
                    let linkedIDs = referencedTitles.compactMap { title in
                        wikiStore.findPageByTitle(title)?.id
                    }

                    if let existing = wikiStore.findPageByTitle(item.title) {
                        let mergedBody = mergeContent(existing: existing.body, new: item.body)
                        let mergedTags = Array(Set(existing.tags + item.tags))
                        let mergedLinks = Array(Set(existing.linkedPageIDs + linkedIDs))
                        await wikiStore.updatePage(
                            id: existing.id,
                            body: mergedBody,
                            tags: mergedTags,
                            linkedPageIDs: mergedLinks,
                            sourceDocumentID: sourceDocumentID
                        )
                        pagesMerged += 1
                    } else {
                        await wikiStore.createPage(
                            title: item.title,
                            body: item.body,
                            tags: item.tags,
                            domainID: domainID,
                            sourceDocumentID: sourceDocumentID
                        )
                        pagesCreated += 1
                    }
                }
            } catch {
                failedChunks += 1
                AppLogger.wiki.error("Wiki extraction chunk \(index + 1)/\(chunks.count) failed: \(error.localizedDescription)")
            }

            processed = index + 1
            let progress = WikiDocumentExtractionProgress(
                chunkIndex: processed,
                chunkCount: chunks.count,
                pagesCreated: pagesCreated,
                pagesMerged: pagesMerged
            )
            await onProgress(progress)
        }

        AppLogger.wiki.info("Document extraction done: \(pagesCreated) created, \(pagesMerged) merged across \(chunks.count) chunks (\(sourceName))")

        return WikiDocumentExtractionSummary(
            chunksProcessed: processed,
            chunkCount: chunks.count,
            pagesCreated: pagesCreated,
            pagesMerged: pagesMerged,
            cancelled: false,
            failedChunks: failedChunks
        )
    }

    /// Split document text into chunks suitable for LLM extraction.
    /// Prefers paragraph (`\n\n`) boundaries; falls back to a hard split
    /// only when a single paragraph dwarfs the target.
    static func chunkForExtraction(_ text: String) -> [String] {
        let target = extractionChunkTarget
        let overlap = extractionChunkOverlap
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > target else { return trimmed.isEmpty ? [] : [trimmed] }

        let paragraphs = trimmed.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            // A single paragraph that itself exceeds 2× target — hard-split it.
            if paragraph.count > target * 2 {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: hardSplit(paragraph, target: target, overlap: overlap))
                continue
            }

            if current.isEmpty {
                current = paragraph
            } else if current.count + paragraph.count + 2 <= target {
                current += "\n\n" + paragraph
            } else {
                chunks.append(current)
                let tail = String(current.suffix(overlap))
                current = tail.isEmpty ? paragraph : tail + "\n\n" + paragraph
            }
        }
        if !current.isEmpty { chunks.append(current) }

        return chunks
    }

    /// Hard-split a single oversized paragraph at sentence-ish boundaries.
    private static func hardSplit(_ text: String, target: Int, overlap: Int) -> [String] {
        var chunks: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            let end = text.index(i, offsetBy: target, limitedBy: text.endIndex) ?? text.endIndex
            // Back off to the last sentence terminator near `end` if possible.
            let window = text[i..<end]
            let stop: String.Index
            if let lastPeriod = window.lastIndex(where: { ".!?\n".contains($0) }),
               lastPeriod > text.index(i, offsetBy: target / 2, limitedBy: text.endIndex) ?? i {
                stop = text.index(after: lastPeriod)
            } else {
                stop = end
            }
            chunks.append(String(text[i..<stop]).trimmingCharacters(in: .whitespacesAndNewlines))
            // Advance with overlap.
            let nextStart = text.index(stop, offsetBy: -overlap, limitedBy: i) ?? stop
            if nextStart == i { break } // safety
            i = nextStart
            if i >= text.endIndex { break }
        }
        return chunks.filter { !$0.isEmpty }
    }
}