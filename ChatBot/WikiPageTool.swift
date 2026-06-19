//
//  WikiPageTool.swift
//  ChatBot
//
//  Tool-calling integration for the on-device LanguageModelSession.
//  Exposes the wiki to the model as two tools — `searchWiki` for keyword
//  follow-ups and `getWikiPage` for fetching a page by title — gated by
//  the active `WikiContextBudget`.
//
//  The model sees a TOC at session creation time and decides when to
//  fetch which page; the per-turn `pageFetchCap` keeps a chatty model
//  from burning the 8192-token window.
//

import Foundation
import FoundationModels
import Synchronization

// MARK: - Per-turn Usage Tracker

/// Thread-safe per-turn tracker for the wiki tool layer. Tracks two
/// things: the fetch count (used by `getWikiPage` to enforce
/// `WikiContextBudget.pageFetchCap`) and the titles of pages the model
/// actually pulled (so the chat UI can surface "used [[X]], [[Y]]"
/// after the reply, instead of just "saw N TOC entries"). Reset by
/// `ChatViewModel` at the start of each turn; drained at the end.
nonisolated final class WikiToolUsageTracker: Sendable {
    private let _count = Mutex<Int>(0)
    private let _titles = Mutex<[String]>([])

    nonisolated func reset() {
        _count.withLock { $0 = 0 }
        _titles.withLock { $0 = [] }
    }

    /// Returns the new count after incrementing. Called before any
    /// store work so the cap check is honoured even on lookup failure.
    nonisolated func incrementFetchCount() -> Int {
        _count.withLock { count in
            count += 1
            return count
        }
    }

    /// Record a successful page fetch (after the cap check passed and
    /// the page was found). Deduplicates so a model that fetches the
    /// same page twice only shows once in the chip.
    nonisolated func recordFetched(title: String) {
        _titles.withLock { titles in
            if !titles.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
                titles.append(title)
            }
        }
    }

    /// Snapshot the titles fetched this turn (does not reset).
    nonisolated func fetchedTitles() -> [String] {
        _titles.withLock { $0 }
    }

    nonisolated func currentFetchCount() -> Int {
        _count.withLock { $0 }
    }
}

// MARK: - Tool Arguments

@Generable
struct WikiSearchArguments: Hashable {
    @Guide(description: "A short search query phrased the way you'd describe what you're looking for. Will return up to 5 matching wiki page titles with their one-line summaries.")
    var query: String
}

@Generable
struct WikiGetPageArguments: Hashable {
    @Guide(description: "The exact title of the wiki page to fetch (e.g. \"Adam Optimizer\"). Use the title shown in the table of contents — case-insensitive but spelling-sensitive.")
    var title: String
}

// MARK: - searchWiki Tool

/// Re-search the wiki when the model needs to phrase a query
/// differently than the user's question. The model already sees a TOC
/// at session start; this tool is for the "I want to look at something
/// adjacent" case.
struct WikiSearchTool: Tool {
    let name = "searchWiki"
    let description = """
    Search the user's personal wiki for pages matching a query. Returns up to \
    5 matching page titles with their one-line summaries. Use this when the \
    table of contents you saw at the start of the conversation doesn't have \
    an obvious match and you want to phrase the search differently than the \
    user did.
    """

    typealias Arguments = WikiSearchArguments

    private let store: WikiStore
    private let budget: WikiContextBudget
    private let tracker: WikiToolUsageTracker

    init(store: WikiStore, budget: WikiContextBudget, tracker: WikiToolUsageTracker) {
        self.store = store
        self.budget = budget
        self.tracker = tracker
    }

    func call(arguments: WikiSearchArguments) async throws -> String {
        let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Search needs a non-empty query."
        }

        let results = await MainActor.run {
            store.findRelevantPages(for: query, limit: 5)
        }

        guard !results.isEmpty else {
            return "No wiki pages matched '\(query)'."
        }

        let lines = results.map { page -> String in
            let summary = page.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty
                ? "- [[\(page.title)]]"
                : "- [[\(page.title)]] — \(summary)"
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - getWikiPage Tool

/// Fetch the body of a wiki page by title. Bounded by the active
/// budget's `pageFetchCap` so a chatty model can't burn the window.
struct WikiGetPageTool: Tool {
    let name = "getWikiPage"
    let description = """
    Fetch the full body of a wiki page by exact title. Use after the table \
    of contents (or `searchWiki`) tells you which page is relevant. Returns \
    the body and tags. Limited to a small number of fetches per turn — the \
    response will tell you how many remain.
    """

    typealias Arguments = WikiGetPageArguments

    private let store: WikiStore
    private let budget: WikiContextBudget
    private let tracker: WikiToolUsageTracker

    init(store: WikiStore, budget: WikiContextBudget, tracker: WikiToolUsageTracker) {
        self.store = store
        self.budget = budget
        self.tracker = tracker
    }

    func call(arguments: WikiGetPageArguments) async throws -> String {
        let title = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return "Page title is required."
        }

        // Enforce the per-turn fetch cap before doing any work.
        let count = tracker.incrementFetchCount()
        if count > budget.pageFetchCap {
            return "Page fetch limit reached for this turn (\(budget.pageFetchCap)). Answer with what you already have."
        }

        let page = await MainActor.run {
            store.toolPageBody(forTitle: title, budget: budget)
        }

        guard let page else {
            return "No wiki page titled '\(title)'. Use the table of contents or searchWiki to find similar titles."
        }

        // Record both for the chat-UI usage chip and for the recency
        // boost that prioritises frequently-used pages in retrieval.
        tracker.recordFetched(title: page.title)
        await MainActor.run {
            store.recordAccess(pageID: page.id)
        }

        let remaining = max(0, budget.pageFetchCap - count)
        let tagsLine = page.tags.isEmpty ? "" : "\nTags: \(page.tags.joined(separator: ", "))"
        let footer = remaining > 0
            ? "\n\n(\(remaining) fetch\(remaining == 1 ? "" : "es") remaining this turn.)"
            : "\n\n(No fetches remaining this turn.)"

        return """
        # \(page.title)

        \(page.body)\(tagsLine)\(footer)
        """
    }
}
