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

    init(wikiStore: WikiStore) {
        self.wikiStore = wikiStore
    }

    // MARK: - Knowledge Extraction

    /// Extract knowledge from a conversation transcript and create/update wiki pages.
    /// Runs asynchronously — never blocks the UI.
    func extractKnowledge(
        from transcript: String,
        conversationID: UUID,
        conversationTitle: String
    ) async {
        guard extractionEnabled else { return }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let prompt = WikiExtractionPrompts.extractionPrompt(
            transcript: transcript,
            existingPageTitles: wikiStore.pages.map(\.title)
        )

        do {
            let draft = try await respondGenerable(
                systemPrompt: WikiExtractionPrompts.systemPrompt,
                userPrompt: prompt,
                maxTokens: 500,
                task: .extraction,
                generating: WikiExtractionDraft.self,
                decodeText: WikiExtractionPrompts.parseExtraction
            )

            guard !draft.nothingExtracted, !draft.pages.isEmpty else {
                AppLogger.wiki.debug("No knowledge extracted from '\(conversationTitle)'")
                return
            }

            for page in draft.pages {
                await applyExtractedPage(
                    page,
                    sourceConversationID: conversationID,
                    sourceDocumentID: nil
                )
            }

            // Reconcile so a page created here links cleanly to any
            // pages a previous extraction left as orphan targets, and
            // vice versa.
            await reconcileWikilinks()

            AppLogger.wiki.info("Extracted \(draft.pages.count) wiki page(s) from '\(conversationTitle)'")
        } catch {
            AppLogger.wiki.error("Wiki extraction failed: \(error.localizedDescription)")
        }
    }

    enum AppliedPageResult {
        case created
        case merged
    }

    /// Apply a single extracted page draft to the store: either merge into
    /// an existing same-title page or create a new one. Resolves [[wikilinks]]
    /// in the body to page ids. Used by both extraction paths.
    @discardableResult
    private func applyExtractedPage(
        _ page: WikiPageDraft,
        sourceConversationID: UUID?,
        sourceDocumentID: UUID?
    ) async -> AppliedPageResult {
        let referencedTitles = WikiExtractionPrompts.extractWikilinks(from: page.body)
        let linkedIDs = referencedTitles.compactMap { title in
            wikiStore.findPageByTitle(title)?.id
        }

        if let existing = wikiStore.findPageByTitle(page.title) {
            let mergedBody = mergeContent(existing: existing.body, new: page.body)
            let mergedTags = Array(Set(existing.tags + page.tags))
            let mergedLinks = Array(Set(existing.linkedPageIDs + linkedIDs))
            // Prefer the freshly extracted summary; fall back to the
            // existing one so a model that forgets the field doesn't
            // wipe a good summary on merge.
            let mergedSummary = page.summary.isEmpty ? existing.summary : page.summary

            await wikiStore.updatePage(
                id: existing.id,
                body: mergedBody,
                tags: mergedTags,
                summary: mergedSummary,
                linkedPageIDs: mergedLinks,
                sourceConversationID: sourceConversationID,
                sourceDocumentID: sourceDocumentID
            )
            AppLogger.wiki.info("Merged into existing wiki page '\(page.title)'")
            return .merged
        } else {
            // Persist the model's summary as-is (may be empty if the
            // model dropped the field). `WikiStore.tableOfContents`
            // derives a fallback at display time, and the backfill in
            // Settings can upgrade empty summaries to LLM quality.
            await wikiStore.createPage(
                title: page.title,
                body: page.body,
                tags: page.tags,
                summary: page.summary,
                sourceConversationID: sourceConversationID,
                sourceDocumentID: sourceDocumentID
            )
            AppLogger.wiki.info("Created new wiki page '\(page.title)'")
            return .created
        }
    }

    // MARK: - Wikilink Reconciliation
    //
    // `applyExtractedPage` resolves a page's `[[wikilinks]]` to ids at
    // the moment that page is saved. For multi-chunk document extraction
    // that's not enough: chunk 5 may reference `[[Chunk 9 Topic]]` before
    // chunk 9 has created the page, leaving the link orphaned even after
    // both pages exist. The same shape catches orphans from prior
    // extractions whose targets only got written today.

    /// Walk every page, re-resolve its `[[wikilinks]]` against the
    /// current title index, and persist the updated `linkedPageIDs`
    /// when it differs. Returns the number of pages whose link set
    /// actually changed (zero on a no-op pass). Cheap: title→id lookup
    /// is O(1) via a one-shot dictionary, so the whole pass is O(pages
    /// × links/page).
    @discardableResult
    func reconcileWikilinks() async -> Int {
        let allPages = wikiStore.pages
        guard !allPages.isEmpty else { return 0 }

        // Title→id index. If two pages share a title (case-insensitive)
        // we keep the first — same behaviour as `findPageByTitle`.
        var titleToID: [String: UUID] = [:]
        for page in allPages {
            let key = page.title.lowercased()
            if titleToID[key] == nil { titleToID[key] = page.id }
        }

        var changedCount = 0
        for page in allPages {
            let references = WikiExtractionPrompts.extractWikilinks(from: page.body)
            let resolved = references.compactMap { titleToID[$0.lowercased()] }
            let resolvedSet = Set(resolved)
            let existingSet = Set(page.linkedPageIDs)
            if resolvedSet != existingSet {
                await wikiStore.setLinkedPageIDs(
                    pageID: page.id,
                    linkedPageIDs: Array(resolvedSet)
                )
                changedCount += 1
            }
        }

        if changedCount > 0 {
            AppLogger.wiki.info("Reconciled wikilinks on \(changedCount) page(s)")
        }
        return changedCount
    }

    // MARK: - Context Injection

    /// Query the wiki for relevant pages and format them for injection into
    /// the prompt as full-page blocks. Used by the pre-injection path
    /// (remote providers); the on-device tool path uses
    /// `WikiStore.tableOfContents` instead.
    func buildWikiContext(
        for query: String,
        budget: WikiContextBudget
    ) -> (context: String, pageCount: Int, titles: [String]) {
        guard injectionEnabled else { return ("", 0, []) }

        let relevantPages = wikiStore.findRelevantPages(
            for: query,
            limit: budget.preInjectPageLimit
        )

        guard !relevantPages.isEmpty else { return ("", 0, []) }

        var context = ""
        var usedChars = 0
        var includedTitles: [String] = []

        for page in relevantPages {
            let formatted = "## \(page.title)\n\(page.body)"
            if usedChars + formatted.count > budget.preInjectCharBudget { break }
            context += formatted + "\n\n"
            usedChars += formatted.count
            includedTitles.append(page.title)

            wikiStore.recordAccess(pageID: page.id)
        }

        return (
            context.trimmingCharacters(in: .whitespacesAndNewlines),
            includedTitles.count,
            includedTitles
        )
    }

    // MARK: - Summary Backfill
    //
    // New pages created via extraction get their `summary` from the
    // model directly (it's a `WikiPageDraft` field). Pre-existing pages
    // — created before the field was added, or via lint stubs / manual
    // creation — store an empty summary; `WikiStore.tableOfContents`
    // derives a first-line fallback at display time so the TOC still
    // works. This backfill upgrades them to LLM-quality summaries
    // when the user explicitly runs it from Settings.

    /// True while `runSummaryBackfill` is in flight. Drives the spinner
    /// and "Cancel" button in Settings → Wiki Maintenance.
    private(set) var isBackfillingSummaries: Bool = false

    /// Progress through the current backfill, or nil when idle.
    private(set) var summaryBackfillProgress: (processed: Int, total: Int, failed: Int)?

    /// Cached so the user can request cancellation from the UI.
    private var summaryBackfillTask: Task<Void, Never>?

    /// Run an LLM-quality summary backfill across every page that
    /// doesn't have a stored summary yet. Routes through whichever
    /// provider the user has bound to the `.extraction` task (on-device
    /// by default — free; remote will incur per-page cost). Serialised
    /// — one page at a time — so it doesn't thrash rate limits or burn
    /// a phone battery. Honours `Task.cancel()`.
    @discardableResult
    func runSummaryBackfill() -> Task<Void, Never> {
        if let existing = summaryBackfillTask {
            return existing
        }

        // Observable state lives on WikiEngine, which isn't @MainActor —
        // pin the task body to main so the mutations don't race UI reads.
        // The actual `respondGenerable` await hops off main on its own.
        let task = Task { @MainActor [self] in
            let needsBackfill = wikiStore.pages.filter {
                $0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !needsBackfill.isEmpty else {
                summaryBackfillTask = nil
                return
            }

            isBackfillingSummaries = true
            summaryBackfillProgress = (processed: 0, total: needsBackfill.count, failed: 0)
            defer {
                isBackfillingSummaries = false
                summaryBackfillProgress = nil
                summaryBackfillTask = nil
            }

            var processed = 0
            var failed = 0
            for page in needsBackfill {
                if Task.isCancelled { break }

                do {
                    let draft = try await respondGenerable(
                        systemPrompt: Self.summarySystemPrompt,
                        userPrompt: WikiExtractionPrompts.summaryPrompt(
                            title: page.title,
                            body: page.body
                        ),
                        maxTokens: 80,
                        task: .extraction,
                        generating: WikiSummaryDraft.self,
                        decodeText: WikiExtractionPrompts.parseSummary
                    )
                    let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !summary.isEmpty {
                        await wikiStore.setSummary(pageID: page.id, summary: summary)
                    } else {
                        failed += 1
                    }
                } catch {
                    failed += 1
                    AppLogger.wiki.error("Summary backfill failed for '\(page.title)': \(error.localizedDescription)")
                }

                processed += 1
                summaryBackfillProgress = (processed: processed, total: needsBackfill.count, failed: failed)
            }

            AppLogger.wiki.info("Summary backfill done: \(processed)/\(needsBackfill.count) processed, \(failed) failed")
        }

        summaryBackfillTask = task
        return task
    }

    /// Cancel an in-flight backfill. Safe to call when none is running.
    func cancelSummaryBackfill() {
        summaryBackfillTask?.cancel()
    }

    /// Count of pages that would be touched if backfill were started
    /// now. Drives the "X pages need summaries" affordance in Settings.
    var pagesMissingSummary: Int {
        wikiStore.pages.filter {
            $0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    private static let summarySystemPrompt = """
        You write one-sentence wiki page summaries for a table of contents. \
        Each summary names the key concept (≤120 chars, no quotes, no \
        markdown). Output exactly one line.
        """

    // MARK: - Provider Routing

    /// Run a single prompt through whichever provider the user has bound to
    /// `task` and decode the response into a `Generable` type. The on-device
    /// FoundationModels path returns the typed value directly — no parser,
    /// no malformed-output failure mode. Remote providers (Anthropic /
    /// OpenAI / Gemini) still emit text, so the caller-supplied `decodeText`
    /// adapter wraps the response via the existing `WikiExtractionPrompts.parse*`
    /// helpers.
    func respondGenerable<T: Generable & Sendable>(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        task: ProviderTask,
        generating type: T.Type,
        decodeText: (String) -> T
    ) async throws -> T {
        if let provider = providerRegistry?.resolve(for: task) {
            let text = try await provider.respond(
                history: [ProviderMessage(role: .user, content: userPrompt)],
                systemPrompt: systemPrompt,
                options: ProviderGenerationOptions(
                    maxOutputTokens: maxTokens,
                    temperature: 1.0
                )
            )
            return decodeText(text)
        }
        let session = LanguageModelSession { systemPrompt }
        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: maxTokens
        )
        let response = try await session.respond(
            to: userPrompt,
            generating: type,
            options: options
        )
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
                // Run reconciliation even on cancellation — partial
                // extraction may have created targets that earlier
                // chunks referenced as orphans.
                await reconcileWikilinks()
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
                let draft = try await respondGenerable(
                    systemPrompt: WikiExtractionPrompts.systemPrompt,
                    userPrompt: prompt,
                    maxTokens: 600,
                    task: .extraction,
                    generating: WikiExtractionDraft.self,
                    decodeText: WikiExtractionPrompts.parseExtraction
                )

                if !draft.nothingExtracted {
                    for page in draft.pages {
                        let result = await applyExtractedPage(
                            page,
                            sourceConversationID: nil,
                            sourceDocumentID: sourceDocumentID
                        )
                        switch result {
                        case .created: pagesCreated += 1
                        case .merged:  pagesMerged += 1
                        }
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
            onProgress(progress)
        }

        // Reconcile wikilinks now that every chunk's pages exist:
        // earlier chunks that referenced [[Title]] targets created by
        // later chunks would otherwise stay orphaned. Also catches
        // orphans from previous extractions whose targets only got
        // written this round.
        await reconcileWikilinks()

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