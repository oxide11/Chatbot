//
//  DynamicWorkerTool.swift
//  ChatBot
//
//  Manager-Worker Agentic Pattern: Tool protocol conformance wrapping a WorkerProfile.
//  Each worker becomes a tool the Manager LLM can invoke to delegate specialized tasks.
//

import Foundation
import FoundationModels

/// The arguments the Manager model generates when invoking a worker tool.
@Generable
struct WorkerTaskArguments: Hashable {
    @Guide(description: "The task or text to process.")
    var task: String
}

/// A dynamic tool that wraps a user-defined WorkerProfile.
/// When called, it creates an ephemeral LanguageModelSession with the worker's
/// system instructions, executes the task, and returns the result.
struct DynamicWorkerTool: Tool {
    /// Sanitized tool name derived from the worker profile name.
    let workerName: String

    /// Human-readable display name for UI notifications.
    let displayName: String

    /// The trigger description — tells the Manager when to use this worker.
    let workerDescription: String

    /// The worker's full system instructions / persona.
    private let workerSystemInstructions: String

    /// Thread-safe tracker to record invocations for UI feedback.
    private let tracker: WorkerInvocationTracker?

    // MARK: - Tool Protocol

    var name: String { workerName }
    var description: String { workerDescription }

    typealias Arguments = WorkerTaskArguments

    init(from profile: WorkerProfile, tracker: WorkerInvocationTracker? = nil) {
        // Sanitize name for use as a tool identifier
        self.workerName = profile.name
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        self.displayName = profile.name
        self.workerDescription = profile.triggerDescription
        self.workerSystemInstructions = profile.systemInstructions
        self.tracker = tracker
    }

    func call(arguments: WorkerTaskArguments) async throws -> String {
        // Record this invocation for UI notification
        tracker?.record(displayName)

        // Create an ephemeral worker session — it lives only for this call
        let instructions = workerSystemInstructions
        let workerSession = LanguageModelSession {
            instructions
        }

        do {
            let response = try await workerSession.respond(to: arguments.task)
            return response.content
        } catch {
            // Return errors as text so the Manager can report gracefully
            return "Worker '\(displayName)' encountered an error: \(error.localizedDescription)"
        }
        // workerSession is deallocated here — ephemeral by design
    }
}
