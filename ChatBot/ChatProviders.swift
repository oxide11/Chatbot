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
}

// MARK: - Provider Registry

/// Tracks which providers have credentials stored and which is the default
/// for new conversations. Credentials live in the Keychain; everything else
/// is in UserDefaults.
@MainActor
@Observable
final class ProviderRegistry {

    /// The provider used for new conversations.
    private(set) var defaultProviderID: ChatProviderID

    /// Set of providers that are currently usable (built-in is always in here;
    /// remote providers appear once a key is stored).
    private(set) var configuredIDs: Set<ChatProviderID> = [.foundationModels]

    private let defaultsKey = "default_provider_id"

    init() {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ChatProviderID.foundationModels.rawValue
        self.defaultProviderID = ChatProviderID(rawValue: raw) ?? .foundationModels
        refreshConfigured()
    }

    func isConfigured(_ id: ChatProviderID) -> Bool {
        if !id.requiresAPIKey { return true }
        return KeychainManager.hasAPIKey(for: id.keychainAccount)
    }

    func refreshConfigured() {
        configuredIDs = Set(ChatProviderID.allCases.filter { isConfigured($0) })
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
}
