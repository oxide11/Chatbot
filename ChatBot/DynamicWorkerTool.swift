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
    /// The specific task or question to delegate to this worker.
    @Guide(description: "The task, question, or content to send to the specialized worker for processing.")
    var task: String
}

/// A dynamic tool that wraps a user-defined WorkerProfile.
/// When called, it creates an ephemeral LanguageModelSession with the worker's
/// system instructions, executes the task, and returns the result.
struct DynamicWorkerTool: Tool {
    /// Sanitized tool name derived from the worker profile name.
    let workerName: String

    /// The trigger description — tells the Manager when to use this worker.
    let workerDescription: String

    /// The worker's full system instructions / persona.
    private let workerSystemInstructions: String

    // MARK: - Tool Protocol

    var name: String { workerName }
    var description: String { workerDescription }

    typealias Arguments = WorkerTaskArguments

    init(from profile: WorkerProfile) {
        // Sanitize name for use as a tool identifier
        self.workerName = profile.name
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        self.workerDescription = profile.triggerDescription
        self.workerSystemInstructions = profile.systemInstructions
    }

    func call(arguments: WorkerTaskArguments) async throws -> String {
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
            return "Worker '\(workerName)' encountered an error: \(error.localizedDescription)"
        }
        // workerSession is deallocated here — ephemeral by design
    }
}
