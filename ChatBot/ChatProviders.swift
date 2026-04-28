//
//  ChatProviders.swift
//  ChatBot
//
//  Identity, metadata, and registry for the chat backends Engram can use.
//  Apple's on-device Foundation Models is the default and requires no key.
//  Remote providers (Anthropic, OpenAI, Gemini) hold credentials in the
//  Keychain via KeychainManager and only become "configured" once a key
//  has been entered. The actual streaming implementations are added later;
//  this file is scaffolding for the settings UI and per-conversation routing.
//

import Foundation
import SwiftUI

// MARK: - Provider Identity

enum ChatProviderID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case foundationModels
    case anthropic
    case openAI
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .foundationModels: return "Apple Intelligence"
        case .anthropic:        return "Anthropic"
        case .openAI:           return "OpenAI"
        case .gemini:           return "Google Gemini"
        }
    }

    var shortName: String {
        switch self {
        case .foundationModels: return "On-Device"
        case .anthropic:        return "Claude"
        case .openAI:           return "ChatGPT"
        case .gemini:           return "Gemini"
        }
    }

    var iconSystemName: String {
        switch self {
        case .foundationModels: return "cpu"
        case .anthropic:        return "sparkle"
        case .openAI:           return "circle.hexagongrid"
        case .gemini:           return "diamond"
        }
    }

    var iconTint: Color {
        switch self {
        case .foundationModels: return .accentColor
        case .anthropic:        return .orange
        case .openAI:           return .green
        case .gemini:           return .blue
        }
    }

    var requiresAPIKey: Bool {
        self != .foundationModels
    }

    /// Subtitle shown under the provider row in Settings.
    var blurb: String {
        switch self {
        case .foundationModels:
            return "On-device Apple Foundation Models. No key required, fully private."
        case .anthropic:
            return "Claude via the Anthropic API. Best for reasoning, code, long context."
        case .openAI:
            return "GPT models via the OpenAI API."
        case .gemini:
            return "Google's Gemini family via the Generative Language API."
        }
    }

    /// Where to obtain a key. Used for the "Get a key" affordance.
    var keyConsoleURL: URL? {
        switch self {
        case .foundationModels: return nil
        case .anthropic:        return URL(string: "https://console.anthropic.com/settings/keys")
        case .openAI:           return URL(string: "https://platform.openai.com/api-keys")
        case .gemini:           return URL(string: "https://aistudio.google.com/apikey")
        }
    }

    /// Hint for the API-key text field.
    var keyPlaceholder: String {
        switch self {
        case .foundationModels: return ""
        case .anthropic:        return "sk-ant-..."
        case .openAI:           return "sk-..."
        case .gemini:           return "AIza..."
        }
    }

    /// Lightweight client-side validation. Doesn't hit the network.
    func validate(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return false }
        switch self {
        case .foundationModels: return true
        case .anthropic:        return trimmed.hasPrefix("sk-ant-")
        case .openAI:           return trimmed.hasPrefix("sk-") || trimmed.hasPrefix("sess-")
        case .gemini:           return trimmed.hasPrefix("AIza") || trimmed.count >= 32
        }
    }

    /// Account name used with KeychainManager.
    var keychainAccount: String { "provider.\(rawValue)" }

    /// Default model id sent to the provider. Can be overridden per-provider
    /// via ProviderRegistry.modelID(for:) — the value below is the fallback.
    var defaultModelID: String {
        switch self {
        case .foundationModels: return "" // unused
        case .anthropic:        return "claude-sonnet-4-5"
        case .openAI:           return "gpt-4.1"
        case .gemini:           return "gemini-2.5-pro"
        }
    }

    /// Suggestions a Picker can offer. Free-text override is always allowed
    /// in case Anthropic / OpenAI / Google ship a new alias before we update.
    var modelSuggestions: [String] {
        switch self {
        case .foundationModels: return []
        case .anthropic:
            return [
                "claude-sonnet-4-5",
                "claude-opus-4-1",
                "claude-haiku-4-5",
                "claude-sonnet-4-6",
                "claude-opus-4-7"
            ]
        case .openAI:
            return ["gpt-4.1", "gpt-4o", "o4-mini"]
        case .gemini:
            return ["gemini-2.5-pro", "gemini-2.5-flash"]
        }
    }

    var modelDefaultsKey: String { "provider_model_\(rawValue)" }
}

// MARK: - Provider Tasks

/// Where in the app a provider is invoked. Each task can route to a
/// different provider, so e.g. you can keep chat on-device while sending
/// extraction and lint to Claude.
enum ProviderTask: String, CaseIterable, Hashable, Sendable {
    /// Chat reply streaming.
    case chat
    /// Document → wiki extraction (one-shot, longer outputs, infrequent).
    case extraction
    /// Wiki lint semantic review (merge proposals, stub drafts, contradictions).
    case lint

    var displayName: String {
        switch self {
        case .chat:       return "Chat"
        case .extraction: return "Wiki Extraction"
        case .lint:       return "Wiki Lint Review"
        }
    }

    var iconSystemName: String {
        switch self {
        case .chat:       return "bubble.left.and.bubble.right"
        case .extraction: return "wand.and.stars"
        case .lint:       return "checkmark.seal"
        }
    }

    var blurb: String {
        switch self {
        case .chat:
            return "Where every-turn replies stream from. On-device is fast, private, and offline."
        case .extraction:
            return "Document → wiki page extraction. Quality matters more than speed; runs infrequently."
        case .lint:
            return "Merge proposals and stub drafts during AI Review. Same — quality over speed."
        }
    }

    var defaultsKey: String { "provider_id_for_\(rawValue)" }
}

// MARK: - Provider Registry

/// Tracks which providers have credentials stored and which is the default
/// for new conversations. Credentials live in the Keychain; everything else
/// is in UserDefaults.
@MainActor
@Observable
final class ProviderRegistry {

    /// The default provider for new conversations and any task that hasn't
    /// been overridden.
    private(set) var defaultProviderID: ChatProviderID

    /// Per-task overrides. Empty means "use the default for that task too."
    private(set) var taskOverrides: [ProviderTask: ChatProviderID] = [:]

    /// Set of providers that are currently usable (built-in is always in here;
    /// remote providers appear once a key is stored).
    private(set) var configuredIDs: Set<ChatProviderID> = [.foundationModels]

    private let defaultsKey = "default_provider_id"

    init() {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ChatProviderID.foundationModels.rawValue
        self.defaultProviderID = ChatProviderID(rawValue: raw) ?? .foundationModels
        for task in ProviderTask.allCases {
            if let storedRaw = UserDefaults.standard.string(forKey: task.defaultsKey),
               let id = ChatProviderID(rawValue: storedRaw) {
                taskOverrides[task] = id
            }
        }
        refreshConfigured()
    }

    func isConfigured(_ id: ChatProviderID) -> Bool {
        if !id.requiresAPIKey { return true }
        return KeychainManager.hasAPIKey(for: id.keychainAccount)
    }

    func refreshConfigured() {
        configuredIDs = Set(ChatProviderID.allCases.filter { isConfigured($0) })
        // Drop overrides that point at providers no longer configured.
        for (task, id) in taskOverrides where !configuredIDs.contains(id) {
            taskOverrides.removeValue(forKey: task)
            UserDefaults.standard.removeObject(forKey: task.defaultsKey)
        }
    }

    func setAPIKey(_ key: String, for id: ChatProviderID) throws {
        guard id.requiresAPIKey else { return }
        try KeychainManager.setAPIKey(key, for: id.keychainAccount)
        refreshConfigured()
    }

    func deleteAPIKey(for id: ChatProviderID) throws {
        guard id.requiresAPIKey else { return }
        try KeychainManager.deleteAPIKey(for: id.keychainAccount)
        if defaultProviderID == id {
            setDefault(.foundationModels)
        }
        refreshConfigured()
    }

    func setDefault(_ id: ChatProviderID) {
        guard isConfigured(id) else { return }
        defaultProviderID = id
        UserDefaults.standard.set(id.rawValue, forKey: defaultsKey)
    }

    // MARK: - Per-task routing

    /// Effective provider for a task — override if set, otherwise the
    /// global default.
    func providerID(for task: ProviderTask) -> ChatProviderID {
        if let overridden = taskOverrides[task], isConfigured(overridden) {
            return overridden
        }
        return defaultProviderID
    }

    /// Bind a specific provider to a task. Pass nil to clear the override
    /// and fall back to the global default.
    func setProvider(_ id: ChatProviderID?, for task: ProviderTask) {
        if let id, isConfigured(id) {
            taskOverrides[task] = id
            UserDefaults.standard.set(id.rawValue, forKey: task.defaultsKey)
        } else {
            taskOverrides.removeValue(forKey: task)
            UserDefaults.standard.removeObject(forKey: task.defaultsKey)
        }
    }

    /// True when the user has explicitly set a provider for this task
    /// (regardless of whether it matches the default).
    func hasOverride(for task: ProviderTask) -> Bool {
        taskOverrides[task] != nil
    }

    // MARK: - Model selection

    /// User-overridable model id for a provider, or the provider's built-in
    /// default if nothing has been chosen.
    func modelID(for id: ChatProviderID) -> String {
        if let stored = UserDefaults.standard.string(forKey: id.modelDefaultsKey),
           !stored.isEmpty {
            return stored
        }
        return id.defaultModelID
    }

    func setModelID(_ modelID: String, for id: ChatProviderID) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == id.defaultModelID {
            UserDefaults.standard.removeObject(forKey: id.modelDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: id.modelDefaultsKey)
        }
    }

    // MARK: - Resolution

    /// Build a `ChatProvider` for the given id if a key is stored.
    /// Returns nil for `foundationModels` (handled by the local
    /// LanguageModelSession path) or for providers without a key /
    /// without an implementation yet.
    func resolve(_ id: ChatProviderID) -> ChatProvider? {
        switch id {
        case .foundationModels:
            return nil
        case .anthropic:
            guard let key = KeychainManager.getAPIKey(for: id.keychainAccount),
                  !key.isEmpty else { return nil }
            return AnthropicProvider(apiKey: key, model: modelID(for: id))
        case .openAI:
            guard let key = KeychainManager.getAPIKey(for: id.keychainAccount),
                  !key.isEmpty else { return nil }
            return OpenAIProvider(apiKey: key, model: modelID(for: id))
        case .gemini:
            // Implementation to follow.
            return nil
        }
    }

    /// Resolve the active provider for a task. Returns nil if the task
    /// should run on-device (Foundation Models).
    func resolve(for task: ProviderTask) -> ChatProvider? {
        resolve(providerID(for: task))
    }
}
