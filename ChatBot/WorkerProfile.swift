//
//  WorkerProfile.swift
//  ChatBot
//
//  Manager-Worker Agentic Pattern: SwiftData persistence for user-defined worker profiles.
//

import Foundation
import SwiftData

@Model
final class WorkerProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var icon: String
    var triggerDescription: String
    var systemInstructions: String
    var isEnabled: Bool
    var isBuiltIn: Bool
    var createdAt: Date

    init(
        name: String,
        icon: String = "person.crop.circle",
        triggerDescription: String,
        systemInstructions: String,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.triggerDescription = triggerDescription
        self.systemInstructions = systemInstructions
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.createdAt = Date()
    }
}

// MARK: - Built-In Worker Presets

/// Definitions for built-in workers that ship with the app.
/// These mirror common Apple Intelligence Writing Tools capabilities
/// and other practical use cases, powered by the on-device model.
enum BuiltInWorkers {

    /// A single preset definition (not persisted — used to seed SwiftData).
    struct Preset {
        let name: String
        let icon: String
        let triggerDescription: String
        let systemInstructions: String
    }

    /// The full catalogue of built-in worker presets.
    ///
    /// Each prompt follows the same compact shape so the on-device 3B model
    /// gets consistent structure across delegated tasks:
    ///
    /// ```
    /// ROLE — one-sentence statement of who the worker is.
    /// RULES:
    /// - 3 to 5 imperative bullets covering edge cases.
    /// OUTPUT: explicit description of what the response should contain
    /// (and what it should *not* contain).
    /// ```
    static let all: [Preset] = [
        // --- Writing Tools equivalents ---

        Preset(
            name: "Proofread",
            icon: "text.badge.checkmark",
            triggerDescription: "Proofread, spell-check, or fix grammar in the provided text.",
            systemInstructions: """
                You are a meticulous proofreader. Correct errors without changing the author's voice.
                RULES:
                - Fix grammar, spelling, punctuation, and capitalisation only.
                - Do not change meaning, tone, or style.
                - List the specific changes you made as bullet points after the corrected text.
                OUTPUT: the corrected text, then a blank line, then `Changes:` followed by a bulleted list of edits. Nothing else.
                """
        ),

        Preset(
            name: "Summarize",
            icon: "doc.text.magnifyingglass",
            triggerDescription: "Summarize or condense long text into key points.",
            systemInstructions: """
                You are a precise summariser. Distil text down to its essential points.
                RULES:
                - Capture main ideas, key facts, and any conclusions or decisions.
                - Use 2–4 bullets for longer texts; 1–2 sentences for short ones.
                - Never add information that isn't in the source.
                - Preserve the original tone (formal, casual, technical).
                OUTPUT: the summary itself in neutral, objective voice. No preamble, no headings.
                """
        ),

        Preset(
            name: "Rewrite",
            icon: "pencil.and.outline",
            triggerDescription: "Rewrite or rephrase text to improve clarity and readability.",
            systemInstructions: """
                You are a skilled editor. Rewrite text so it reads more clearly and naturally.
                RULES:
                - Improve clarity, flow, and readability while preserving meaning.
                - If the user specifies a tone (formal, casual, persuasive), match it. Otherwise keep the original tone.
                - Simplify complex sentences; remove redundancy.
                OUTPUT: only the rewritten text. No commentary, no list of changes.
                """
        ),

        // --- Practical utility workers ---

        Preset(
            name: "Code Reviewer",
            icon: "terminal",
            triggerDescription: "Review code for bugs, performance issues, or best practice improvements.",
            systemInstructions: """
                You are an experienced code reviewer. Identify issues and suggest concrete fixes.
                RULES:
                - Look for bugs, security issues, performance problems, and readability concerns.
                - List issues in severity order: Bug → Warning → Suggestion.
                - For each issue, state the problem and a concrete fix.
                - If the code is correct, say so in one line.
                OUTPUT: a numbered list. Each item begins with a `[Bug]` / `[Warning]` / `[Suggestion]` label.
                """
        ),

        Preset(
            name: "Translator",
            icon: "globe",
            triggerDescription: "Translate text between languages accurately.",
            systemInstructions: """
                You are a professional translator. Produce accurate, natural-sounding translations.
                RULES:
                - Translate into the requested target language; if none is specified, translate to English.
                - Preserve meaning, tone, and intent.
                - For idioms, use the closest natural equivalent in the target language.
                - Add a one-line translator's note only if a phrase has no direct equivalent.
                OUTPUT: only the translation (followed by an optional note prefixed `Note:` on a new line).
                """
        ),

        Preset(
            name: "Explain Simply",
            icon: "lightbulb",
            triggerDescription: "Explain a complex concept in simple, easy-to-understand terms.",
            systemInstructions: """
                You are a patient teacher. Make complex ideas accessible to anyone.
                RULES:
                - Use plain, everyday language. Avoid jargon. If a technical term is unavoidable, define it inline.
                - Open with a one-sentence overview, then elaborate.
                - Use a concrete analogy or real-world example.
                - Keep sentences short (under 20 words where possible).
                OUTPUT: the explanation in friendly, encouraging prose. No headings, no bullet labels.
                """
        ),
    ]

    /// Seed built-in workers into SwiftData if they don't already exist.
    /// Call once on first launch (or when the user wants to restore defaults).
    static func seedIfNeeded(in context: ModelContext) {
        // Check if any built-in workers already exist
        let descriptor = FetchDescriptor<WorkerProfile>(
            predicate: #Predicate { $0.isBuiltIn == true }
        )

        let existingCount = (try? context.fetchCount(descriptor)) ?? 0
        guard existingCount == 0 else { return }

        for preset in all {
            let profile = WorkerProfile(
                name: preset.name,
                icon: preset.icon,
                triggerDescription: preset.triggerDescription,
                systemInstructions: preset.systemInstructions,
                isEnabled: true,
                isBuiltIn: true
            )
            context.insert(profile)
        }
    }

    /// Add any missing built-in workers (e.g. after an app update adds new presets).
    /// Does not overwrite existing ones the user may have customized.
    static func addMissingPresets(in context: ModelContext) {
        let descriptor = FetchDescriptor<WorkerProfile>(
            predicate: #Predicate { $0.isBuiltIn == true }
        )

        let existing = (try? context.fetch(descriptor)) ?? []
        let existingNames = Set(existing.map(\.name))

        for preset in all where !existingNames.contains(preset.name) {
            let profile = WorkerProfile(
                name: preset.name,
                icon: preset.icon,
                triggerDescription: preset.triggerDescription,
                systemInstructions: preset.systemInstructions,
                isEnabled: true,
                isBuiltIn: true
            )
            context.insert(profile)
        }
    }
}
