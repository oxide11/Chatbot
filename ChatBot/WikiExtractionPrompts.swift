//
//  WikiExtractionPrompts.swift
//  ChatBot
//
//  Created by Moussa Noun on 2026-04-27.
//


//
//  WikiExtractionPrompts.swift
//  ChatBot
//
//  Prompt templates and response parser for wiki knowledge extraction.
//  The LLM reads a conversation transcript and produces structured
//  ---PAGE--- / ---END--- blocks that the parser converts to wiki pages.
//

import Foundation
import FoundationModels

// MARK: - Generable Output Types

/// One wiki page as produced by the LLM during extraction or lint review.
/// Used directly by the FoundationModels Generable path; remote providers
/// emit the same shape via the `---PAGE---/---END---` text format and the
/// caller maps text → `WikiPageDraft` via `WikiExtractionPrompts.parse`.
@Generable
struct WikiPageDraft: Sendable, Hashable {
    @Guide(description: "Concise, capitalised, noun-phrase title (e.g. \"Adam Optimizer\"). One concept per page.")
    var title: String

    @Guide(description: "One sentence (≤120 chars) describing what the page covers. Used as a TOC entry when the model browses the wiki — should make it obvious whether this page answers a given question.")
    var summary: String

    @Guide(description: "2–6 bullet points or short paragraphs covering the concept. Under 100 words. Use [[Page Title]] markdown for cross-references to other wiki pages.")
    var body: String

    @Guide(description: "Lowercase keyword tags. Two to five entries.")
    var tags: [String]
}

/// Result of a single extraction pass. `nothingExtracted` signals the
/// "NONE" case from the text format — when true, `pages` is empty.
@Generable
struct WikiExtractionDraft: Sendable {
    @Guide(description: "True if the source has no reusable factual knowledge worth extracting (greetings, filler, off-topic). When true, leave pages empty.")
    var nothingExtracted: Bool

    @Guide(description: "Wiki pages extracted from the source. Empty when nothingExtracted is true.")
    var pages: [WikiPageDraft]
}

/// Lint output: should the two pages be merged?
@Generable
struct WikiMergeDecision: Sendable {
    @Guide(description: "True iff the two pages describe the same concept and should be merged into one. False if they are related but distinct (KEEP_BOTH).")
    var shouldMerge: Bool

    @Guide(description: "When shouldMerge is true, the merged page that preserves every distinct fact from both sources (deduplicated). When false, leave nil.")
    var mergedPage: WikiPageDraft?
}

/// Lint output: should we draft a stub for a missing wikilink target?
@Generable
struct WikiStubDecision: Sendable {
    @Guide(description: "True iff the surrounding context is rich enough to write a truthful stub page. False if the context is too thin (SKIP).")
    var canDraft: Bool

    @Guide(description: "When canDraft is true, the stub page grounded in the surrounding context. When false, leave nil.")
    var stub: WikiPageDraft?
}

/// Backfill output: a one-line summary for an existing wiki page that
/// pre-dates the `SUMMARY:` extraction field. Used as a TOC entry when
/// the model browses the wiki, so it has to be tight and informative.
@Generable
struct WikiSummaryDraft: Sendable {
    @Guide(description: "One sentence (≤120 chars) describing what the page covers — the key concept, not just the title restated. Used as a TOC entry, so it should make obvious whether the page would answer a related question.")
    var summary: String
}

// MARK: - Prompts

enum WikiExtractionPrompts {

    /// Shared format spec used by both extraction modes. Kept in one place
    /// so updates to the page format only have to be made once.
    private static let pageBlockFormat = """
        ---PAGE---
        TITLE: <concise, capitalised, noun-phrase title>
        SUMMARY: <one sentence; ≤120 chars; what this page covers>
        TAGS: <comma-separated, lowercase>
        BODY:
        <2–6 bullet points or short paragraphs; ≤100 words>
        ---END---
        """

    /// One-page worked example showing the exact shape we want.
    /// Reused across modes so the small model has a stable reference.
    private static let pageBlockExample = """
        ---PAGE---
        TITLE: Adam Optimizer
        SUMMARY: Adaptive optimizer combining momentum and RMSProp; the default choice for most deep nets.
        TAGS: optimizer, deep-learning, adaptive
        BODY:
        - Combines momentum and RMSProp; tracks first and second moment estimates of the gradient.
        - Default hyperparameters: learning rate 1e-3, β₁=0.9, β₂=0.999, ε=1e-8.
        - Bias-corrected estimates prevent early-step bias toward zero.
        - See [[RMSProp]], [[Momentum]] for the component algorithms.
        ---END---
        """

    static let systemPrompt = """
        You extract reusable factual knowledge into wiki pages. \
        One page per concept, entity, definition, procedure, or claim. \
        Preserve exact names, numbers, and identifiers from the source. \
        Output only `---PAGE---/---END---` blocks (or the literal word NONE) — no preamble, no commentary.
        """

    /// Build the extraction prompt for a conversation transcript. Includes
    /// the shared format spec and example so the on-device model follows
    /// the structure consistently.
    static func extractionPrompt(
        transcript: String,
        existingPageTitles: [String]
    ) -> String {
        var prompt = """
        Extract reusable knowledge from the conversation below into wiki pages.

        Format each page exactly like this:
        \(pageBlockFormat)

        Rules:
        - Extract concrete, reusable facts (preferences, decisions, names, numbers, technical choices). Skip greetings, filler, and questions that weren't answered.
        - One page per topic. If the same concept appears more than once, write a single merged page.
        - Use `[[Page Title]]` for cross-references.
        - If nothing notable was discussed, respond with exactly: NONE

        Example:
        \(pageBlockExample)
        """

        if !existingPageTitles.isEmpty {
            let titles = existingPageTitles.prefix(30).joined(separator: ", ")
            prompt += "\n\nExisting page titles (reuse the same TITLE to merge instead of creating duplicates): \(titles)"
        }

        prompt += "\n\nConversation transcript:\n\(transcript)"
        return prompt
    }

    /// Document-mode extraction. Tuned for monologue text (papers, chapters,
    /// manuals, ePub sections). Same format + example as conversation mode
    /// so the model's output shape is consistent across pipelines.
    static func documentExtractionPrompt(
        text: String,
        sourceName: String,
        existingPageTitles: [String]
    ) -> String {
        var prompt = """
        Extract reusable knowledge from the document excerpt below into wiki pages.

        Format each page exactly like this:
        \(pageBlockFormat)

        Rules:
        - Extract definitions, formulae, parameters, named entities, procedures, and design rationale.
        - Preserve exact terminology, numbers, and identifiers from the source.
        - One topic per page. If the same concept appears later, reuse the same TITLE so the entries merge.
        - Use `[[Page Title]]` for cross-references between concepts you've extracted.
        - Skip filler, transitions, and decorative prose.
        - If nothing in this excerpt is worth keeping, respond with exactly: NONE

        Example:
        \(pageBlockExample)
        """

        if !existingPageTitles.isEmpty {
            let titles = existingPageTitles.prefix(40).joined(separator: ", ")
            prompt += "\n\nExisting page titles (reuse the same TITLE to merge instead of creating duplicates): \(titles)"
        }

        prompt += "\n\nSource: \(sourceName)\n\nExcerpt:\n\(text)"
        return prompt
    }

    // MARK: - Parsing

    struct ExtractionResult {
        let title: String
        let summary: String
        let body: String
        let tags: [String]
    }

    /// Parse the LLM's response into structured extraction results.
    /// Handles the ---PAGE--- / ---END--- block format.
    static func parse(_ response: String) -> [ExtractionResult] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.uppercased() == "NONE" || trimmed.isEmpty {
            return []
        }

        var results: [ExtractionResult] = []
        let blocks = trimmed.components(separatedBy: "---PAGE---")

        for block in blocks {
            let content = block.components(separatedBy: "---END---").first ?? block
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedContent.isEmpty else { continue }

            var title: String?
            var summary: String = ""
            var tags: [String] = []
            var bodyLines: [String] = []
            var inBody = false

            for line in trimmedContent.components(separatedBy: "\n") {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)

                if trimmedLine.uppercased().hasPrefix("TITLE:") {
                    title = String(trimmedLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    inBody = false
                } else if trimmedLine.uppercased().hasPrefix("SUMMARY:") {
                    summary = String(trimmedLine.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    inBody = false
                } else if trimmedLine.uppercased().hasPrefix("TAGS:") {
                    let tagStr = String(trimmedLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    tags = tagStr.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty }
                    inBody = false
                } else if trimmedLine.uppercased().hasPrefix("BODY:") {
                    let inline = String(trimmedLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if !inline.isEmpty { bodyLines.append(inline) }
                    inBody = true
                } else if inBody {
                    bodyLines.append(line)
                }
            }

            if let title, !title.isEmpty {
                let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    results.append(ExtractionResult(title: title, summary: summary, body: body, tags: tags))
                }
            }
        }

        return results
    }

    /// Convert a parsed text-format page block into the typed Generable
    /// shape — used when a remote provider returned text (or to bridge
    /// between the legacy and Generable code paths).
    static func draft(from result: ExtractionResult) -> WikiPageDraft {
        WikiPageDraft(title: result.title, summary: result.summary, body: result.body, tags: result.tags)
    }

    /// Deterministic summary fallback for legacy pages that pre-date the
    /// `SUMMARY:` field. Takes the first non-empty body line, strips bullet
    /// markers and wikilink brackets, caps at 120 chars. Cheap (no LLM
    /// call) and safe to use when an async backfill isn't available.
    static func deriveSummary(fromBody body: String, title: String) -> String {
        let firstLine = body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
            ?? title

        var cleaned = firstLine
        for prefix in ["- ", "* ", "• "] where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
        }
        cleaned = cleaned
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")

        if cleaned.count > 120 {
            let cutoff = cleaned.index(cleaned.startIndex, offsetBy: 117)
            cleaned = cleaned[..<cutoff].trimmingCharacters(in: .whitespaces) + "…"
        }
        return cleaned
    }

    /// Build the prompt used by the summary backfill — a single short
    /// LLM call that produces a one-sentence TOC entry for a legacy
    /// page. Routed through the `.extraction` provider task so it
    /// honours whatever the user has bound there (on-device by default).
    static func summaryPrompt(title: String, body: String) -> String {
        // Cap the body slice we send to ~1500 chars — summaries don't
        // need the whole page, and even iOS 27's 8k on-device window
        // leaves us plenty of room without sending a wall of text.
        let trimmedBody: String
        if body.count > 1500 {
            let cutoff = body.index(body.startIndex, offsetBy: 1500)
            trimmedBody = String(body[..<cutoff]) + "\n…(truncated)"
        } else {
            trimmedBody = body
        }

        return """
        Write one sentence (≤120 chars) describing what this wiki page covers. \
        It will be used as a TOC entry — the reader is deciding whether to \
        click through, so name the key concept, not just restate the title. \
        No quotes, no leading "This page describes…", no markdown.

        Output exactly one line in this format (no preamble):
        SUMMARY: <your one sentence>

        --- Page: \(title) ---
        \(trimmedBody)
        """
    }

    // MARK: - Text → Generable Adapters
    //
    // The remote providers (Anthropic / OpenAI / Gemini) still emit the
    // text format described above. These adapters wrap the existing
    // `parse(_:)` so call-sites can stay generic over the response shape:
    // they ask for a `Generable` type and either get one directly from
    // FoundationModels, or get one decoded from text via these helpers.

    /// Parse a text-format response into a `WikiExtractionDraft`. Honors
    /// the literal "NONE" sentinel.
    static func parseExtraction(_ response: String) -> WikiExtractionDraft {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased() == "NONE" || trimmed.isEmpty {
            return WikiExtractionDraft(nothingExtracted: true, pages: [])
        }
        let pages = parse(trimmed).map(draft(from:))
        return WikiExtractionDraft(
            nothingExtracted: pages.isEmpty,
            pages: pages
        )
    }

    /// Parse a text-format summary backfill response. Tolerates a leading
    /// `SUMMARY:` label, surrounding quotes, and stray markdown bullet
    /// markers — small models drift on the format but the payload itself
    /// is usually fine. Caps the output at 120 chars to honour the TOC
    /// budget; returns an empty `WikiSummaryDraft` when there's nothing
    /// usable.
    static func parseSummary(_ response: String) -> WikiSummaryDraft {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip the optional SUMMARY: label.
        if let range = text.range(of: "SUMMARY:", options: .caseInsensitive) {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Take the first non-empty line — the model sometimes follows up
        // with explanation we don't want in the TOC entry.
        if let firstLine = text.components(separatedBy: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) {
            text = firstLine
        }

        // Strip surrounding quotes / markdown bullet markers.
        for prefix in ["- ", "* ", "• "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        if text.hasPrefix("'") && text.hasSuffix("'") && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }

        if text.count > 120 {
            let cutoff = text.index(text.startIndex, offsetBy: 117)
            text = text[..<cutoff].trimmingCharacters(in: .whitespaces) + "…"
        }

        return WikiSummaryDraft(summary: text)
    }

    /// Parse a text-format lint merge response. The literal "KEEP_BOTH"
    /// (case-insensitive substring) means "do not merge"; otherwise the
    /// first parsed page block is the proposed merge.
    static func parseMergeDecision(_ response: String) -> WikiMergeDecision {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().contains("KEEP_BOTH") {
            return WikiMergeDecision(shouldMerge: false, mergedPage: nil)
        }
        if let first = parse(trimmed).first {
            return WikiMergeDecision(shouldMerge: true, mergedPage: draft(from: first))
        }
        return WikiMergeDecision(shouldMerge: false, mergedPage: nil)
    }

    /// Parse a text-format lint stub response. The literal "SKIP" means
    /// "context too thin"; otherwise the first parsed page block is the
    /// proposed stub.
    static func parseStubDecision(_ response: String) -> WikiStubDecision {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().contains("SKIP") {
            return WikiStubDecision(canDraft: false, stub: nil)
        }
        if let first = parse(trimmed).first {
            return WikiStubDecision(canDraft: true, stub: draft(from: first))
        }
        return WikiStubDecision(canDraft: false, stub: nil)
    }

    /// Extract [[wikilink]] references from a page body and return the referenced titles.
    static func extractWikilinks(from body: String) -> [String] {
        var links: [String] = []
        var searchRange = body.startIndex..<body.endIndex

        while let openRange = body.range(of: "[[", range: searchRange),
              let closeRange = body.range(of: "]]", range: openRange.upperBound..<body.endIndex) {
            let linkTitle = String(body[openRange.upperBound..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !linkTitle.isEmpty {
                links.append(linkTitle)
            }
            searchRange = closeRange.upperBound..<body.endIndex
        }

        return links
    }
}