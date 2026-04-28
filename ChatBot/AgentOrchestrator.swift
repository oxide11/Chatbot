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

    /// Create a `LanguageModelSession` configured as the Manager with all
    /// active worker tools, plus any extra tools (e.g. wiki search/fetch)
    /// the caller wants mounted alongside.
    ///
    /// - Parameters:
    ///   - baseInstructions: The conversation's system prompt (custom or default).
    ///   - conversationSummary: Optional summary from a previous context rotation.
    ///   - extraTools: Additional tools to expose to the Manager — typically
    ///     `WikiSearchTool` / `WikiGetPageTool` when wiki retrieval is on.
    ///   - extraInstructions: Behavioural guidance for the extra tools,
    ///     appended after the worker-tool guidance.
    /// - Returns: A configured `LanguageModelSession`.
    func createManagerSession(
        baseInstructions: String,
        conversationSummary: String? = nil,
        extraTools: [any Tool] = [],
        extraInstructions: String = ""
    ) -> LanguageModelSession {
        let workerTools: [any Tool] = activeTools
        let allTools: [any Tool] = workerTools + extraTools

        var fullInstructions = baseInstructions

        if !workerTools.isEmpty {
            // Tool schemas are already injected by the framework; this section
            // is purely behavioural guidance for *when* to delegate and *how*
            // to integrate the worker's output.
            fullInstructions += """


            ## Worker Tools
            Specialist tools are available. Use this decision rule:
            - Greetings, follow-ups, and general questions: answer directly. Do not invoke a tool.
            - Tasks that match a tool's specialty (proofreading, summarising, translating, code review, simple explanations): invoke the matching tool, passing the user's text as `task`.
            - Invoke at most one tool per turn unless the user explicitly asks for multiple steps.

            When a tool returns:
            - Present its output as your own answer in plain prose.
            - Never name the tool, mention "delegating", or write phrases like "I used a tool" / "the proofreader said".
            - Do not echo the tool's output verbatim if a one-line introduction would help — but do not pad it.
            """
        }

        if !extraInstructions.isEmpty {
            fullInstructions += "\n\n\(extraInstructions)"
        }

        if let summary = conversationSummary, !summary.isEmpty {
            fullInstructions += "\n\n## Prior Context\n\(summary)\n\nContinue the conversation naturally from where it left off."
        }

        let instructions = fullInstructions

        if allTools.isEmpty {
            return LanguageModelSession {
                instructions
            }
        } else {
            return LanguageModelSession(tools: allTools) {
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
