//
//  WikiContextBudget.swift
//  ChatBot
//
//  Per-provider caps for wiki injection and tool use. The on-device model
//  has a 4096-token window, so wiki retrieval has to be tight: a 20-entry
//  TOC, ≤4 page fetches per turn, ~1750 chars of body per page, and a
//  pre-injection fallback of 2 full pages when tools aren't appropriate.
//
//  Remote providers (Anthropic / OpenAI / Gemini) have 100k+ token windows;
//  they currently don't support tool calls through our `ChatProvider`
//  abstraction so the on-device tool-loop doesn't apply, but they do get
//  generous pre-injection (8 pages / 12k chars) — see ChatViewModel's
//  `buildEnrichedPrompt`.
//
//  Centralised here so adding Gemini or finer per-model tuning (Haiku vs
//  Opus) only means adding a profile, not chasing scattered constants.
//

import Foundation

struct WikiContextBudget: Sendable, Equatable {
    /// How many TOC entries (`[[Title]] — summary`) we'll show the model
    /// in the system prompt. When the wiki has more pages than this, the
    /// TOC is embedding-prefiltered against the user's question.
    var tocEntryLimit: Int

    /// Hard cap on page fetches the model can make per turn via the
    /// `getWikiPage` tool. Prevents a chatty model from burning the
    /// context window or stalling time-to-first-token.
    var pageFetchCap: Int

    /// Max characters of body returned from a single tool call (or
    /// included in a single pre-injected page). Pages longer than this
    /// are head-truncated with an ellipsis.
    var pageCharBudget: Int

    /// How many full pages to pre-inject in the user's turn when the
    /// tool path isn't available (remote providers, or wiki injection
    /// disabled but TOC enabled).
    var preInjectPageLimit: Int

    /// Total character budget for the pre-injection block — separate
    /// from `pageCharBudget` because remote can absorb several pages at
    /// the larger per-page size.
    var preInjectCharBudget: Int

    /// Tight on-device profile — tuned for the 4096-token Foundation
    /// Models window. Tools active; pre-inject fallback is small.
    static let onDevice = WikiContextBudget(
        tocEntryLimit: 20,
        pageFetchCap: 4,
        pageCharBudget: 1750,
        preInjectPageLimit: 2,
        preInjectCharBudget: 1750
    )

    /// Generous remote profile — Anthropic / OpenAI / Gemini all have
    /// 100k+ token windows. Tool calls aren't yet supported through the
    /// `ChatProvider` abstraction so `pageFetchCap` is effectively
    /// unused, but the pre-injection caps are what matters.
    static let remote = WikiContextBudget(
        tocEntryLimit: .max,
        pageFetchCap: .max,
        pageCharBudget: 4000,
        preInjectPageLimit: 8,
        preInjectCharBudget: 12_000
    )

    /// Resolve the budget for a given chat provider. `.foundationModels`
    /// uses the tight on-device profile; everything else uses remote.
    /// Add per-model variation here later (e.g. Haiku → tighter than
    /// Opus) without touching call sites.
    static func forProvider(_ id: ChatProviderID) -> WikiContextBudget {
        id == .foundationModels ? .onDevice : .remote
    }

    /// True when the consumer should mount on-device wiki tools instead
    /// of pre-injecting full pages. Today this is gated on the provider
    /// being on-device — remote providers don't get tool calls yet.
    var prefersToolPath: Bool {
        pageFetchCap < .max
    }
}
