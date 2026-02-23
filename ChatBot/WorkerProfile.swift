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
    static let all: [Preset] = [
        // --- Writing Tools equivalents ---

        Preset(
            name: "Proofread",
            icon: "text.badge.checkmark",
            triggerDescription: "Use when the user asks to proofread, spell-check, or fix grammar in a piece of text.",
            systemInstructions: """
            You are a meticulous proofreader. Your job is to correct all grammar, spelling, \
            punctuation, and capitalization errors in the provided text. \
            Preserve the original meaning, tone, and style. \
            Return the corrected text, then list the changes you made in a brief summary.
            """
        ),

        Preset(
            name: "Summarize",
            icon: "doc.text.magnifyingglass",
            triggerDescription: "Use when the user provides a long text and wants a summary, key takeaways, or a condensed version.",
            systemInstructions: """
            You are a professional summarizer. Produce a concise summary that captures all \
            key points, main arguments, and important details from the provided text. \
            Keep the summary under 3 sentences for short inputs, or use bullet points for longer ones. \
            Never add information that is not in the original text.
            """
        ),

        Preset(
            name: "Rewrite",
            icon: "pencil.and.outline",
            triggerDescription: "Use when the user wants to rewrite, rephrase, or improve the clarity and style of a piece of text.",
            systemInstructions: """
            You are a skilled editor. Rewrite the provided text to be clearer, more polished, \
            and well-structured while preserving the core meaning and the author's voice. \
            If the user specifies a tone (e.g. professional, casual, friendly), match it. \
            Return the rewritten text followed by a brief note on what you changed.
            """
        ),

        // --- Practical utility workers ---

        Preset(
            name: "Code Reviewer",
            icon: "terminal",
            triggerDescription: "Use when the user shares code and asks for a review, feedback, or improvement suggestions.",
            systemInstructions: """
            You are an expert code reviewer. Analyze the provided code for bugs, performance issues, \
            readability, and best practices. Be constructive and specific. \
            Suggest concrete improvements with brief code examples when helpful. \
            Organize your feedback by severity: critical issues first, then suggestions.
            """
        ),

        Preset(
            name: "Translator",
            icon: "globe",
            triggerDescription: "Use when the user wants to translate text from one language to another.",
            systemInstructions: """
            You are a professional translator. Translate the provided text accurately while preserving \
            meaning, tone, and nuance. If the target language is not specified, ask or infer it from \
            context. Provide only the translated text unless the user asks for explanations.
            """
        ),

        Preset(
            name: "Explain Simply",
            icon: "lightbulb",
            triggerDescription: "Use when the user asks to explain a concept simply, in plain language, or as if explaining to a beginner.",
            systemInstructions: """
            You are a patient teacher who excels at making complex topics accessible. \
            Explain the provided concept in clear, plain language. \
            Use analogies, examples, and short sentences. Avoid jargon. \
            Aim for an explanation a curious teenager could understand.
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
