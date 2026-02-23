//
//  AgentOrchestrator.swift
//  ChatBot
//
//  Manager-Worker Agentic Pattern: Fetches enabled WorkerProfiles from SwiftData,
//  builds DynamicWorkerTool instances, and creates Manager sessions with tools registered.
//

import Foundation
import SwiftData
import FoundationModels

/// Thread-safe tracker for worker invocations during a single response turn.
/// Used by `DynamicWorkerTool.call()` (which may run off the MainActor) to
/// record which workers were invoked, so the UI can display it afterward.
final class WorkerInvocationTracker: Sendable {
    private let lock = NSLock()
    private let _invocations = UnsafeMutableBufferPointer<[String]>.allocate(capacity: 1)

    init() {
        _invocations.initialize(repeating: [])
    }

    deinit {
        _invocations.deallocate()
    }

    /// Record a worker invocation (called from any thread).
    func record(_ workerName: String) {
        lock.lock()
        _invocations[0].append(workerName)
        lock.unlock()
    }

    /// Retrieve and clear all recorded invocations.
    func drain() -> [String] {
        lock.lock()
        let result = _invocations[0]
        _invocations[0] = []
        lock.unlock()
        return result
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
    func configure(with modelContext: ModelContext) {
        self.modelContext = modelContext
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
            let workerList = tools.map { "- \($0.name): \($0.description)" }
                .joined(separator: "\n")

            fullInstructions += """


            You are a Coordinator. You have access to a team of specialized workers via tools. \
            For simple questions, respond directly. For tasks that clearly match a worker's specialty, \
            delegate by calling the appropriate tool and then summarize their findings for the user. \
            Available workers:
            \(workerList)
            """
        }

        if let summary = conversationSummary {
            fullInstructions += "\n\nPrevious conversation context: \(summary)\nContinue the conversation naturally."
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
