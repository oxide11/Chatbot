//
//  WikiLintModels.swift
//  ChatBot
//
//  Types describing wiki health issues surfaced by the linter.
//  Findings are ephemeral (recomputed each lint pass) and never persisted —
//  the source of truth is always the current WikiStore state.
//

import Foundation

// MARK: - Finding Kind

enum WikiLintFindingKind: String, Codable, Hashable, CaseIterable, Sendable {
    /// `[[Foo]]` referenced from a body but no page titled "Foo" exists.
    case brokenLink
    /// Page that no other page links to (it's reachable only via search).
    case orphan
    /// Page with no outbound `[[wikilinks]]` — nothing connects out from it.
    case deadEnd
    /// Two pages whose embeddings are too similar — likely the same concept.
    case duplicateCandidate
    /// Page that's been around for a while and never read.
    case stalePage
    /// Concept mentioned across multiple pages but never has its own page.
    case missingPage
    /// Two related pages that the LLM flagged as factually contradicting.
    /// Only produced by the semantic pass.
    case contradiction

    var displayName: String {
        switch self {
        case .brokenLink:         return "Broken Links"
        case .orphan:             return "Orphan Pages"
        case .deadEnd:            return "Dead-End Pages"
        case .duplicateCandidate: return "Duplicate Candidates"
        case .stalePage:          return "Stale Pages"
        case .missingPage:        return "Missing Pages"
        case .contradiction:      return "Contradictions"
        }
    }

    var iconSystemName: String {
        switch self {
        case .brokenLink:         return "link.badge.plus"
        case .orphan:             return "leaf"
        case .deadEnd:            return "arrow.left.to.line"
        case .duplicateCandidate: return "rectangle.on.rectangle"
        case .stalePage:          return "clock.badge.exclamationmark"
        case .missingPage:        return "doc.badge.plus"
        case .contradiction:      return "exclamationmark.triangle"
        }
    }

    /// Whether the LLM is needed to produce a useful suggestion.
    var requiresSemanticReview: Bool {
        switch self {
        case .duplicateCandidate, .missingPage, .contradiction: return true
        case .brokenLink, .orphan, .deadEnd, .stalePage:        return false
        }
    }
}

// MARK: - Suggestion (LLM output)

enum WikiLintSuggestion: Codable, Hashable, Sendable {
    /// Combine two pages into one. The merged content is the LLM's draft,
    /// which the user can accept, edit, or reject.
    case mergePages(title: String, body: String, tags: [String])
    /// Create a brand-new page (used for missing-page and broken-link findings).
    case createStub(title: String, body: String, tags: [String])
    /// Rewrite a `[[broken]]` link to point at an existing page.
    case rewriteLink(from: String, to: String)
    /// LLM explanation only — no automated action proposed.
    case noAction(rationale: String)
}

// MARK: - Finding

struct WikiLintFinding: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: WikiLintFindingKind
    /// Primary page implicated. For brokenLink / missingPage this is the
    /// page where the broken reference lives. For orphan / stalePage /
    /// deadEnd this is the page itself. For duplicates it's "page A".
    let primaryPageID: UUID
    /// Secondary page for pair-based findings (duplicates / contradictions).
    let secondaryPageID: UUID?
    /// Specific link target (e.g. "Adam Optimizer") for link-related findings.
    let linkTarget: String?
    /// Confidence (0...1). Used for sorting and threshold filtering.
    let confidence: Double
    /// Short human-readable summary computed at find time.
    let summary: String
    /// LLM-proposed action, populated only after the semantic pass.
    var suggestion: WikiLintSuggestion?
    /// User dismissed this finding for the current pass — kept around so
    /// the inbox remembers it within a single session, but not persisted.
    var isDismissed: Bool

    init(
        id: UUID = UUID(),
        kind: WikiLintFindingKind,
        primaryPageID: UUID,
        secondaryPageID: UUID? = nil,
        linkTarget: String? = nil,
        confidence: Double = 0.5,
        summary: String,
        suggestion: WikiLintSuggestion? = nil,
        isDismissed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.primaryPageID = primaryPageID
        self.secondaryPageID = secondaryPageID
        self.linkTarget = linkTarget
        self.confidence = confidence
        self.summary = summary
        self.suggestion = suggestion
        self.isDismissed = isDismissed
    }
}

// MARK: - Report

struct WikiLintReport: Sendable, Hashable {
    var findings: [WikiLintFinding]
    var generatedAt: Date
    var pagesAnalyzed: Int
    var semanticReviewComplete: Bool
    var semanticReviewProgress: SemanticProgress?

    struct SemanticProgress: Sendable, Hashable {
        var processed: Int
        var total: Int
    }

    static let empty = WikiLintReport(
        findings: [],
        generatedAt: .distantPast,
        pagesAnalyzed: 0,
        semanticReviewComplete: false,
        semanticReviewProgress: nil
    )

    /// Findings grouped by kind, with dismissed items filtered out.
    var grouped: [(kind: WikiLintFindingKind, findings: [WikiLintFinding])] {
        let active = findings.filter { !$0.isDismissed }
        let kinds = WikiLintFindingKind.allCases
        return kinds.compactMap { kind in
            let bucket = active.filter { $0.kind == kind }
            return bucket.isEmpty ? nil : (kind, bucket)
        }
    }

    var activeCount: Int { findings.filter { !$0.isDismissed }.count }
}

// MARK: - User Action

/// What the user chose to do with a finding. Concrete merge / stub bodies
/// can carry user edits made in the detail view.
enum WikiLintAction: Sendable {
    /// Merge two pages into one with the supplied final title / body / tags
    /// and delete the secondary page. Used for duplicateCandidate.
    case mergeIntoPrimary(title: String, body: String, tags: [String], deletePageID: UUID)
    /// Keep both pages — record that the user reviewed this pair.
    case keepBoth
    /// Create a new page from a stub draft (missingPage / brokenLink).
    case createPage(title: String, body: String, tags: [String])
    /// Rewrite occurrences of `[[from]]` → `[[to]]` in the primary page.
    case rewriteLink(from: String, to: String)
    /// Strip the broken `[[from]]` markup, leaving the visible text.
    case stripBrokenLink(target: String)
    /// Delete the primary page (orphan or stale cleanup).
    case deletePrimary
    /// Mark the finding handled without changing the wiki.
    case dismiss
}
