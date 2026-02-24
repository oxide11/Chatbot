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
    /// Instructions and descriptions are kept concise to minimise context usage
    /// on the ~3B parameter on-device model (4096 token window).
    static let all: [Preset] = [
        // --- Writing Tools equivalents ---

        Preset(
            name: "Proofread",
            icon: "text.badge.checkmark",
            triggerDescription: "Proofread, spell-check, or fix grammar.",
            systemInstructions: "Fix all grammar, spelling, and punctuation errors. Preserve meaning and tone. Return corrected text, then briefly list changes."
        ),

        Preset(
            name: "Summarize",
            icon: "doc.text.magnifyingglass",
            triggerDescription: "Summarize or condense long text.",
            systemInstructions: "Produce a concise summary capturing key points. Use 2-3 sentences or bullet points. Never add information not in the original."
        ),

        Preset(
            name: "Rewrite",
            icon: "pencil.and.outline",
            triggerDescription: "Rewrite or rephrase text for clarity.",
            systemInstructions: "Rewrite the text to be clearer and more polished. Preserve core meaning. Match any tone the user requests."
        ),

        // --- Practical utility workers ---

        Preset(
            name: "Code Reviewer",
            icon: "terminal",
            triggerDescription: "Review code for bugs or improvements.",
            systemInstructions: "Review the code for bugs, performance, and best practices. Be specific. List critical issues first, then suggestions."
        ),

        Preset(
            name: "Translator",
            icon: "globe",
            triggerDescription: "Translate text between languages.",
            systemInstructions: "Translate accurately, preserving meaning and tone. Provide only the translation unless asked for notes."
        ),

        Preset(
            name: "Explain Simply",
            icon: "lightbulb",
            triggerDescription: "Explain a concept in simple terms.",
            systemInstructions: "Explain in clear, plain language. Use analogies and short sentences. No jargon."
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
