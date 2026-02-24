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
            // Keep the coordinator preamble minimal — the tool names and descriptions
            // are already included in the tool schema by the framework, so we only need
            // a short behavioural instruction here to save context tokens.
            fullInstructions += "\nYou have worker tools. Answer simple questions directly. Delegate specialised tasks to the matching tool."
        }

        if let summary = conversationSummary, !summary.isEmpty {
            fullInstructions += "\nContext: \(summary)"
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
