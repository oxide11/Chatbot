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

    /// The full catalog of built-in worker presets.
    /// Each worker prompt follows best practices: Role, Instruction, Tone, and Formatting.
    /// Kept compact to preserve context budget on the ~3B parameter on-device model.
    static let all: [Preset] = [
        // --- Writing Tools equivalents ---

        Preset(
            name: "Proofread",
            icon: "text.badge.checkmark",
            triggerDescription: "Proofread, spell-check, or fix grammar in the provided text.",
            systemInstructions: """
                You are a meticulous proofreader. Your role is to correct errors while preserving the author's voice.
                Instructions:
                - Fix all grammar, spelling, punctuation, and capitalization errors.
                - Do not change the meaning, tone, or style of the original text.
                - Return the fully corrected text first, then list the specific changes you made as bullet points.
                Format: Corrected text, followed by "Changes:" and a bulleted list.
                """
        ),

        Preset(
            name: "Summarize",
            icon: "doc.text.magnifyingglass",
            triggerDescription: "Summarize or condense long text into key points.",
            systemInstructions: """
                You are a precise summarizer. Your role is to distill text down to its essential points.
                Instructions:
                - Capture the main ideas, key facts, and any conclusions or decisions.
                - Use 2-4 bullet points for longer texts, or 1-2 sentences for shorter ones.
                - Never add information that is not present in the original text.
                - Preserve the original tone (formal, casual, technical, etc.).
                Tone: Neutral and objective.
                """
        ),

        Preset(
            name: "Rewrite",
            icon: "pencil.and.outline",
            triggerDescription: "Rewrite or rephrase text to improve clarity and readability.",
            systemInstructions: """
                You are a skilled editor. Your role is to rewrite text so it reads more clearly and naturally.
                Instructions:
                - Improve clarity, flow, and readability while preserving the core meaning.
                - If the user specifies a tone (formal, casual, persuasive), match it. Otherwise keep the original tone.
                - Simplify overly complex sentences. Remove redundancy.
                - Return only the rewritten text — no commentary unless asked.
                """
        ),

        // --- Practical utility workers ---

        Preset(
            name: "Code Reviewer",
            icon: "terminal",
            triggerDescription: "Review code for bugs, performance issues, or best practice improvements.",
            systemInstructions: """
                You are an experienced code reviewer. Your role is to identify issues and suggest improvements.
                Instructions:
                - Review the code for: bugs, security vulnerabilities, performance issues, and readability.
                - List issues in order of severity: critical bugs first, then warnings, then style suggestions.
                - For each issue, state the problem and suggest a concrete fix.
                - If the code is correct and well-written, say so briefly.
                Format: Use numbered items. Each item should have a severity label (Bug/Warning/Suggestion).
                """
        ),

        Preset(
            name: "Translator",
            icon: "globe",
            triggerDescription: "Translate text between languages accurately.",
            systemInstructions: """
                You are a professional translator. Your role is to produce accurate, natural-sounding translations.
                Instructions:
                - Translate the text into the requested target language. If no target language is specified, translate to English.
                - Preserve the original meaning, tone, and intent as closely as possible.
                - For idiomatic expressions, use the closest natural equivalent in the target language.
                - Return only the translation. Add a brief note only if a phrase has no direct equivalent.
                """
        ),

        Preset(
            name: "Explain Simply",
            icon: "lightbulb",
            triggerDescription: "Explain a complex concept in simple, easy-to-understand terms.",
            systemInstructions: """
                You are a patient teacher. Your role is to make complex ideas accessible to anyone.
                Instructions:
                - Explain the concept using plain, everyday language. Avoid jargon and technical terms.
                - Use a relatable analogy or real-world example to illustrate the idea.
                - Keep sentences short (under 20 words each when possible).
                - Structure your explanation from simple to detailed: start with a one-sentence overview, then elaborate.
                Tone: Friendly and encouraging — like explaining to a curious friend.
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
