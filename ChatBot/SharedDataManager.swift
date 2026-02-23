import Foundation

/// Centralized access to the App Group shared UserDefaults.
/// Used by both the main app and the Share Extension to exchange data.
enum SharedDataManager {
    static let suiteName = "group.com.polygoncyber.ChatBot"

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

    private static let stopWords: Set<String> = [
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
    static func tokenize(_ text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
        return Set(words)
    }

    /// Extract keywords from text, filtering stop words.
    static func extractKeywords(from text: String, limit: Int = 5) -> [String] {
        Array(tokenize(text).prefix(limit))
    }

    // MARK: - App Group Container (file-based storage)

    /// Root directory for the App Group shared container.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }

    /// Documents directory inside the App Group container.
    static var documentsURL: URL? {
        containerURL?.appendingPathComponent("Documents", isDirectory: true)
    }

    /// Chunks directory for knowledge base storage.
    static var chunksDirectoryURL: URL? {
        documentsURL?.appendingPathComponent("chunks", isDirectory: true)
    }

    /// Ensure the file-based storage directories exist.
    static func ensureDirectoriesExist() {
        guard let chunksURL = chunksDirectoryURL else { return }
        try? FileManager.default.createDirectory(at: chunksURL, withIntermediateDirectories: true)
    }
}
