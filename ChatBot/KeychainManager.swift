//
//  KeychainManager.swift
//  ChatBot
//
//  Secure storage for API keys and other secrets using iOS Keychain.
//  Non-secret provider configuration belongs in SwiftData — only actual
//  credentials go here.
//

import Foundation
import Security

enum KeychainManager {
    private static let service = "com.polygoncyber.Engram"

    /// Store an API key for a provider.
    static func setAPIKey(_ key: String, for providerID: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Delete any existing key first
        try? deleteAPIKey(for: providerID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// Retrieve an API key for a provider. Returns nil if not found.
    static func getAPIKey(for providerID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    /// Delete an API key for a provider.
    static func deleteAPIKey(for providerID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// Check if a key exists without retrieving it.
    static func hasAPIKey(for providerID: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: false,
        ]

        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    enum KeychainError: LocalizedError {
        case encodingFailed
        case unhandledError(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Failed to encode API key."
            case .unhandledError(let status):
                return "Keychain error: \(status)"
            }
        }
    }
}
