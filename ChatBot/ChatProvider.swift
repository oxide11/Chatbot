//
//  ChatProvider.swift
//  ChatBot
//
//  Provider-agnostic streaming interface used by ChatViewModel when the
//  active backend isn't Apple's on-device FoundationModels (which we
//  invoke directly through LanguageModelSession). Remote providers
//  (Anthropic, OpenAI, Gemini) implement this and yield text deltas.
//

import Foundation

// MARK: - Message Shape

struct ProviderMessage: Sendable, Hashable {
    enum Role: String, Sendable, Hashable {
        case user, assistant, system
    }
    let role: Role
    let content: String
}

// MARK: - Generation Options

struct ProviderGenerationOptions: Sendable {
    var maxOutputTokens: Int = 4096
    var temperature: Double = 1.0
}

// MARK: - Provider Protocol

protocol ChatProvider: Sendable {
    var id: ChatProviderID { get }

    /// Stream a reply from the provider given the full conversation history.
    /// The system prompt is passed separately because most APIs treat it as
    /// a top-level field. Implementations should yield raw text deltas
    /// (NOT cumulative content) so callers can append efficiently.
    func streamReply(
        history: [ProviderMessage],
        systemPrompt: String?,
        options: ProviderGenerationOptions
    ) -> AsyncThrowingStream<String, Error>
}

// MARK: - Errors

enum ChatProviderError: LocalizedError {
    case missingAPIKey(ChatProviderID)
    case invalidResponse(status: Int, message: String?)
    case decodingFailed(String)
    case providerUnavailable(ChatProviderID)
    case rateLimited(retryAfterSeconds: Double?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let id):
            return "No API key configured for \(id.displayName). Add one in Settings → Providers."
        case .invalidResponse(let status, let message):
            if let message { return "\(message) (HTTP \(status))" }
            return "Provider returned HTTP \(status)."
        case .decodingFailed(let detail):
            return "Couldn't read provider response: \(detail)"
        case .providerUnavailable(let id):
            return "\(id.displayName) isn't wired up yet."
        case .rateLimited(let after):
            if let after { return "Rate limited — retry in \(Int(after))s." }
            return "Rate limited by the provider."
        }
    }
}
