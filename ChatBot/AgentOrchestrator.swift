//
//  AgentOrchestrator.swift
//  ChatBot
//
//  Manager-Worker Agentic Pattern: Fetches enabled WorkerProfiles from SwiftData,
//  builds DynamicWorkerTool instances, and creates Manager sessions with tools registered.
//

import Foundation
import Synchronization
import SwiftData
import FoundationModels

/// Thread-safe tracker for worker invocations during a single response turn.
/// Used by `DynamicWorkerTool.call()` (which may run off the MainActor) to
/// record which workers were invoked, so the UI can display it afterward.
///
/// Explicitly `nonisolated` so it can be called from any actor context;
/// internal synchronization is handled by `Mutex`.
nonisolated final class WorkerInvocationTracker: Sendable {
    private let _invocations = Mutex<[String]>([])

    /// Record a worker invocation (called from any thread).
    nonisolated func record(_ workerName: String) {
        _invocations.withLock { $0.append(workerName) }
    }

    /// Retrieve and clear all recorded invocations.
    nonisolated func drain() -> [String] {
        _invocations.withLock { invocations in
            let result = invocations
            invocations = []
            return result
        }
    }
}

@Observable
final class AgentOrchestrator {

    /// The active tools built from enabled WorkerProfiles.
    private(set) var activeTools: [DynamicWorkerTool] = []

    /// The SwiftData model context for fetching profiles.
    private var modelContext: ModelContext?

    /// Thread-safe tracker that workers write to when invoked.
    let invocationTracker = WorkerInvocationTracker()

    /// Whether any workers are currently enabled and available.
    var hasActiveWorkers: Bool { !activeTools.isEmpty }

    // MARK: - Configuration

    /// Provide the SwiftData model context. Call once from the view layer.
    /// Seeds built-in workers on first launch and loads enabled tools.
    func configure(with modelContext: ModelContext) {
        self.modelContext = modelContext
        BuiltInWorkers.seedIfNeeded(in: modelContext)
        BuiltInWorkers.addMissingPresets(in: modelContext)
        refreshTools()
    }

    /// Fetch enabled WorkerProfiles from SwiftData and rebuild the tools array.
    func refreshTools() {
        guard let modelContext else { return }

        let descriptor = FetchDescriptor<WorkerProfile>(
            predicate: #Predicate { $0.isEnabled },
            sortBy: [SortDescriptor(\.name)]
        )

        do {
            let profiles = try modelContext.fetch(descriptor)
            activeTools = profiles.map { DynamicWorkerTool(from: $0, tracker: invocationTracker) }
        } catch {
            activeTools = []
        }
    }

    // MARK: - Session Factory

    /// Create a `LanguageModelSession` configured as the Manager with all active worker tools.
    ///
    /// - Parameters:
    ///   - baseInstructions: The conversation's system prompt (custom or default).
    ///   - conversationSummary: Optional summary from a previous context rotation.
    /// - Returns: A configured `LanguageModelSession`.
    func createManagerSession(
        baseInstructions: String,
        conversationSummary: String? = nil
    ) -> LanguageModelSession {
        let tools = activeTools

        var fullInstructions = baseInstructions

        if !tools.isEmpty {
            // Provide clear delegation instructions so the Manager knows when and how
            // to use workers vs. answering directly. Tool schemas are already injected
            // by the framework, so we focus on behavioral guidance here.
            fullInstructions += """

            You have access to specialized worker tools. Follow these delegation rules:
            - For simple questions, greetings, or general conversation: answer directly without using any tool.
            - For tasks that match a worker's specialty (e.g. proofreading, summarizing, translating, code review): delegate to the appropriate worker tool by passing the relevant text as the task.
            - Use only one worker per response unless the user explicitly asks for multiple operations.
            - After receiving a worker's result, present it to the user naturally. Do not mention the worker by name or say "I used a tool."
            """
        }

        if let summary = conversationSummary, !summary.isEmpty {
            fullInstructions += "\nConversation context (summary of prior messages): \(summary)\nContinue the conversation naturally from where it left off."
        }

        let instructions = fullInstructions

        if tools.isEmpty {
            return LanguageModelSession {
                instructions
            }
        } else {
            return LanguageModelSession(tools: tools) {
                instructions
            }
        }
    }

    // MARK: - Context Budget

    /// Estimate how many characters the tool definitions consume in the context window.
    var estimatedToolSchemaCharacters: Int {
        activeTools.reduce(0) { total, tool in
            // Tool name + description + argument schema overhead
            total + tool.name.count + tool.description.count + 80
        }
    }
}
