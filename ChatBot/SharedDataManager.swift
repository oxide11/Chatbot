import Foundation
import os

/// Centralized access to the App Group shared UserDefaults.
/// Used by both the main app and the Share Extension to exchange data.
enum SharedDataManager {
    nonisolated static let suiteName = "group.com.polygoncyber.ChatBot"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: - Keys

    static let memoriesKey = "saved_memories"
    static let conversationsKey = "saved_conversations"
    static let pendingSharedTextKey = "pending_shared_text"
    static let pendingSharedActionKey = "pending_shared_action"

    // Legacy keys (pre-App Group, in UserDefaults.standard)
    static let legacyMemoriesKey = "saved_memories"
    static let legacyConversationsKey = "saved_conversations"

    // MARK: - Shared Action

    enum SharedAction: String, Codable {
        case saveAsMemory
        case startConversation
    }

    // MARK: - Memories

    static func loadMemories() -> [MemoryEntry] {
        guard let data = sharedDefaults.data(forKey: memoriesKey),
              let decoded = try? JSONDecoder().decode([MemoryEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    static func saveMemories(_ memories: [MemoryEntry]) {
        if let encoded = try? JSONEncoder().encode(memories) {
            sharedDefaults.set(encoded, forKey: memoriesKey)
        }
    }

    // MARK: - Conversations

    static func loadConversations() -> [ConversationData] {
        guard let data = sharedDefaults.data(forKey: conversationsKey),
              let decoded = try? JSONDecoder().decode([ConversationData].self, from: data) else {
            return []
        }
        return decoded
    }

    static func saveConversations(_ conversations: [ConversationData]) {
        if let encoded = try? JSONEncoder().encode(conversations) {
            sharedDefaults.set(encoded, forKey: conversationsKey)
        }
    }

    // MARK: - Pending Shared Content

    static func setPendingSharedText(_ text: String, action: SharedAction) {
        sharedDefaults.set(text, forKey: pendingSharedTextKey)
        sharedDefaults.set(action.rawValue, forKey: pendingSharedActionKey)
    }

    static func consumePendingSharedText() -> (String, SharedAction)? {
        guard let text = sharedDefaults.string(forKey: pendingSharedTextKey),
              let actionRaw = sharedDefaults.string(forKey: pendingSharedActionKey),
              let action = SharedAction(rawValue: actionRaw) else {
            return nil
        }
        sharedDefaults.removeObject(forKey: pendingSharedTextKey)
        sharedDefaults.removeObject(forKey: pendingSharedActionKey)
        return (text, action)
    }

    // MARK: - Migration from UserDefaults.standard to App Group

    static func migrateIfNeeded() {
        let standard = UserDefaults.standard

        // Migrate memories
        if let legacyData = standard.data(forKey: legacyMemoriesKey),
           sharedDefaults.data(forKey: memoriesKey) == nil {
            sharedDefaults.set(legacyData, forKey: memoriesKey)
            standard.removeObject(forKey: legacyMemoriesKey)
        }

        // Migrate conversations
        if let legacyData = standard.data(forKey: legacyConversationsKey),
           sharedDefaults.data(forKey: conversationsKey) == nil {
            sharedDefaults.set(legacyData, forKey: conversationsKey)
            standard.removeObject(forKey: legacyConversationsKey)
        }
    }

    // MARK: - Tokenization (shared utility)
    //
    // These are pure functions safe to call from any isolation context.

    nonisolated private static let stopWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "shall", "can", "to", "of", "in", "for",
        "on", "with", "at", "by", "from", "as", "into", "about", "that",
        "this", "it", "its", "and", "or", "but", "not", "no", "so", "if",
        "i", "me", "my", "you", "your", "we", "our", "they", "them", "their",
        "what", "which", "who", "how", "when", "where", "why"
    ]

    /// Tokenize text into significant words, filtering stop words.
    /// Used by MemoryStore, KnowledgeBaseStore, and keyword extraction.
    nonisolated static func tokenize(_ text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
        return Set(words)
    }

    /// Extract keywords from text, ranked by frequency.
    /// Returns a deterministic, frequency-sorted list of the most significant words.
    nonisolated static func extractKeywords(from text: String, limit: Int = 5) -> [String] {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }

        // Count frequency for ranking
        var frequency: [String: Int] = [:]
        for word in words {
            frequency[word, default: 0] += 1
        }

        return frequency
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(limit)
            .map(\.key)
    }

    // MARK: - App Group Container (file-based storage)
    //
    // Path lookups and directory creation are safe from any thread.
    // Falls back to the app's own Documents directory if the App Group
    // container is unavailable (e.g. simulator without entitlements).
    //
    // URLs are cached after first resolution to avoid repeated filesystem
    // lookups and eliminate race conditions on background threads.

    /// Cached container URL — resolved once and reused for the process lifetime.
    private nonisolated(unsafe) static var _cachedContainerURL: URL?
    private nonisolated(unsafe) static var _containerResolved = false

    /// Root directory for file-based storage.
    /// Prefers the App Group shared container; falls back to the app's Documents dir.
    /// Result is cached after first successful resolution.
    nonisolated static var containerURL: URL? {
        if _containerResolved { return _cachedContainerURL }

        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) {
            _cachedContainerURL = groupURL
            _containerResolved = true
            AppLogger.sharedData.info("Using App Group container: \(groupURL.path)")
            return groupURL
        }
        // Fallback: app-local Documents directory (still persists across launches)
        if let fallback = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            _cachedContainerURL = fallback
            _containerResolved = true
            AppLogger.sharedData.info("Using fallback Documents directory: \(fallback.path)")
            return fallback
        }

        AppLogger.sharedData.error("No container URL available — both App Group and Documents dir failed")
        return nil
    }

    /// Documents directory inside the container.
    nonisolated static var documentsURL: URL? {
        containerURL?.appendingPathComponent("Documents", isDirectory: true)
    }

    /// Legacy chunks directory — used only during one-time migration from JSON to SwiftData.
    /// Knowledge base chunks are now stored in SwiftData (Application Support/default.store).
    nonisolated static var chunksDirectoryURL: URL? {
        documentsURL?.appendingPathComponent("chunks", isDirectory: true)
    }

    /// Memories file for file-based memory persistence.
    nonisolated static var memoriesFileURL: URL? {
        documentsURL?.appendingPathComponent("memories.json")
    }

    /// Ensure the file-based storage directories exist.
    /// Safe to call from any thread. Only creates the Documents directory
    /// (used for memories.json). Knowledge base chunks now use SwiftData.
    nonisolated static func ensureDirectoriesExist() {
        guard let docsURL = documentsURL else {
            AppLogger.sharedData.error("Cannot resolve Documents URL — ensureDirectoriesExist() skipped")
            return
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: docsURL.path) {
            do {
                try fm.createDirectory(at: docsURL, withIntermediateDirectories: true)
                AppLogger.sharedData.info("Created Documents directory: \(docsURL.path)")
            } catch {
                AppLogger.sharedData.error("Failed creating Documents dir at \(docsURL.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - File-based Memory Persistence
    //
    // Memories are now stored as a JSON file instead of UserDefaults
    // to avoid the ~1MB size limit (embeddings are large).
    // Embeddings are stripped on save and recomputed on load.

    /// A lightweight version of MemoryEntry without the embedding vector,
    /// used for compact on-disk storage.
    private struct StoredMemory: Codable {
        let id: UUID
        let content: String
        let keywords: [String]
        let sourceConversationTitle: String
        let createdAt: Date
        let domainID: UUID?
    }

    static func loadMemoriesFromFile() -> [MemoryEntry] {
        ensureDirectoriesExist()

        // Try file-based storage first
        if let url = memoriesFileURL,
           let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([StoredMemory].self, from: data) {
            return stored.map { s in
                MemoryEntry(
                    id: s.id,
                    content: s.content,
                    keywords: s.keywords,
                    sourceConversationTitle: s.sourceConversationTitle,
                    createdAt: s.createdAt,
                    embedding: nil,  // Recomputed lazily or on access
                    domainID: s.domainID
                )
            }
        }

        // Fall back to legacy UserDefaults (one-time migration)
        if let data = sharedDefaults.data(forKey: memoriesKey),
           let decoded = try? JSONDecoder().decode([MemoryEntry].self, from: data) {
            // Migrate to file and remove from UserDefaults
            saveMemoriesToFile(decoded)
            sharedDefaults.removeObject(forKey: memoriesKey)
            return decoded
        }

        return []
    }

    static func saveMemoriesToFile(_ memories: [MemoryEntry]) {
        ensureDirectoriesExist()
        guard let url = memoriesFileURL else { return }

        // Strip embeddings for compact storage — they'll be recomputed on load
        let stored = memories.map { m in
            StoredMemory(
                id: m.id,
                content: m.content,
                keywords: m.keywords,
                sourceConversationTitle: m.sourceConversationTitle,
                createdAt: m.createdAt,
                domainID: m.domainID
            )
        }

        try? JSONEncoder().encode(stored).write(to: url)
    }
}
