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

    static let systemPrompt = """
        You are a knowledge extraction assistant. Your job is to identify \
        reusable factual knowledge from conversations and organize it into \
        wiki pages. Each page covers ONE concept, entity, or topic.
        """

    /// Build the extraction prompt, including existing page titles so the LLM
    /// can update existing pages rather than creating duplicates.
    static func extractionPrompt(
        transcript: String,
        existingPageTitles: [String]
    ) -> String {
        var prompt = """
        Extract key knowledge from this conversation into wiki pages.
        Each page covers ONE concept, entity, or topic.

        Format your response using exactly this structure:
        ---PAGE---
        TITLE: <concise page title>
        TAGS: <comma-separated tags>
        BODY:
        <page content as concise bullet points or short paragraphs>
        ---END---

        Rules:
        - Only extract factual, reusable knowledge (skip greetings and small talk)
        - If nothing notable was discussed, respond with exactly: NONE
        - Keep each page focused on a single topic
        - Use [[Page Title]] to reference other pages
        - Be specific — preserve exact names, numbers, dates, and details
        - Keep each page body under 100 words
        """

        if !existingPageTitles.isEmpty {
            let titles = existingPageTitles.prefix(30).joined(separator: ", ")
            prompt += "\n\nExisting wiki pages (update these titles if relevant instead of creating duplicates): \(titles)"
        }

        prompt += "\n\nConversation transcript:\n\(transcript)"
        return prompt
    }

    /// Build a document-mode extraction prompt. Tuned for monologue text
    /// (papers, chapters, manuals, ePub sections) rather than dialogue.
    /// Includes inline few-shot examples since the on-device 3B model
    /// produces meaningfully better results when shown the desired shape.
    static func documentExtractionPrompt(
        text: String,
        sourceName: String,
        existingPageTitles: [String]
    ) -> String {
        var prompt = """
        Read the document excerpt below and extract reusable knowledge into wiki pages.
        Each page covers ONE concept, entity, definition, claim, procedure, or parameter.

        Format your response using exactly this structure for each page:
        ---PAGE---
        TITLE: <concise page title>
        TAGS: <comma-separated tags, lowercase>
        BODY:
        <2-6 bullet points or short paragraphs; under 100 words>
        ---END---

        Rules:
        - Extract concrete, reusable facts: definitions, formulae, parameters, named entities, procedures, design rationale.
        - Preserve exact terminology, numbers, and identifiers from the source.
        - One topic per page. If the same concept appears later, return the same TITLE so it merges.
        - Use [[Page Title]] to cross-reference other pages you create.
        - Skip filler, transitions, and decorative prose.
        - If nothing in this excerpt is worth keeping, respond with exactly: NONE

        Example:
        ---PAGE---
        TITLE: Adam Optimizer
        TAGS: optimizer, deep-learning, adaptive
        BODY:
        - Combines momentum and RMSProp; tracks first and second moment estimates of the gradient.
        - Default hyperparameters: learning rate 1e-3, β₁=0.9, β₂=0.999, ε=1e-8.
        - Uses bias-corrected estimates so early steps aren't biased toward zero.
        - See [[RMSProp]], [[Momentum]] for component algorithms.
        ---END---
        """

        if !existingPageTitles.isEmpty {
            let titles = existingPageTitles.prefix(40).joined(separator: ", ")
            prompt += "\n\nExisting wiki pages (reuse these titles when relevant): \(titles)"
        }

        prompt += "\n\nSource: \(sourceName)\n\nDocument excerpt:\n\(text)"
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