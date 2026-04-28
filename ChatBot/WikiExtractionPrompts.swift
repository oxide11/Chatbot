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

enum WikiExtractionPrompts {

    /// Shared format spec used by both extraction modes. Kept in one place
    /// so updates to the page format only have to be made once.
    private static let pageBlockFormat = """
        ---PAGE---
        TITLE: <concise, capitalised, noun-phrase title>
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
            var tags: [String] = []
            var bodyLines: [String] = []
            var inBody = false

            for line in trimmedContent.components(separatedBy: "\n") {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)

                if trimmedLine.uppercased().hasPrefix("TITLE:") {
                    title = String(trimmedLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
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
                    results.append(ExtractionResult(title: title, body: body, tags: tags))
                }
            }
        }

        return results
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