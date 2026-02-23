import SwiftUI
import FoundationModels

// MARK: - Message Model

struct Message: Identifiable, Codable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date

    enum Role: String, Codable {
        case user, assistant, system
    }

    init(id: UUID = UUID(), role: Role, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

// MARK: - Persisted Conversation Data

struct ConversationData: Identifiable, Codable {
    let id: UUID
    var title: String
    let createdAt: Date
    var messages: [Message]
    var customSystemPrompt: String?
}

// MARK: - Memory Entry (RAG)

struct MemoryEntry: Identifiable, Codable {
    let id: UUID
    let content: String
    let keywords: [String]
    let sourceConversationTitle: String
    let createdAt: Date

    init(content: String, keywords: [String], sourceConversationTitle: String) {
        self.id = UUID()
        self.content = content
        self.keywords = keywords.map { $0.lowercased() }
        self.sourceConversationTitle = sourceConversationTitle
        self.createdAt = Date()
    }

    init(id: UUID = UUID(), content: String, keywords: [String], sourceConversationTitle: String, createdAt: Date = Date()) {
        self.id = id
        self.content = content
        self.keywords = keywords.map { $0.lowercased() }
        self.sourceConversationTitle = sourceConversationTitle
        self.createdAt = createdAt
    }
}

// MARK: - Memory Store (RAG)

/// A lightweight keyword-based retrieval system that persists facts across conversations.
/// When the context window rotates, key facts are extracted and stored as memories.
/// Before each response, relevant memories are retrieved and injected into the prompt.
@Observable
final class MemoryStore {
    private(set) var memories: [MemoryEntry] = []

    private static let saveKey = "saved_memories"
    private static let maxMemories = 100

    init() {
        loadFromDisk()
    }

    /// Store a new memory extracted from a conversation
    func addMemory(_ content: String, keywords: [String], source: String) {
        // Avoid exact duplicates
        guard !memories.contains(where: { $0.content == content }) else { return }

        let entry = MemoryEntry(content: content, keywords: keywords, sourceConversationTitle: source)
        memories.insert(entry, at: 0)

        // Evict oldest if over capacity
        if memories.count > Self.maxMemories {
            memories = Array(memories.prefix(Self.maxMemories))
        }
        saveToDisk()
    }

    /// Retrieve memories relevant to a query using keyword matching
    func retrieve(for query: String, limit: Int = 5) -> [MemoryEntry] {
        let queryWords = tokenize(query)
        guard !queryWords.isEmpty else { return [] }

        // Score each memory by keyword overlap
        let scored = memories.map { entry -> (MemoryEntry, Double) in
            let entryWords = Set(entry.keywords)
            let contentWords = tokenize(entry.content)
            let allEntryWords = entryWords.union(contentWords)

            var score = 0.0
            for word in queryWords {
                if allEntryWords.contains(word) {
                    score += 1.0
                } else {
                    // Partial prefix match (e.g. "python" matches "pythonic")
                    for entryWord in allEntryWords where entryWord.hasPrefix(word) || word.hasPrefix(entryWord) {
                        score += 0.5
                        break
                    }
                }
            }

            // Boost by recency: newer memories get a small bonus
            let ageInDays = max(1, -entry.createdAt.timeIntervalSinceNow / 86400)
            let recencyBonus = 1.0 / log2(ageInDays + 1)
            score += recencyBonus * 0.2

            return (entry, score)
        }

        return scored
            .filter { $0.1 > 0.3 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    func updateMemory(_ entry: MemoryEntry, content: String, keywords: [String]) {
        guard let index = memories.firstIndex(where: { $0.id == entry.id }) else { return }
        memories[index] = MemoryEntry(
            id: entry.id,
            content: content,
            keywords: keywords,
            sourceConversationTitle: entry.sourceConversationTitle,
            createdAt: entry.createdAt
        )
        saveToDisk()
    }

    func deleteMemory(_ entry: MemoryEntry) {
        memories.removeAll { $0.id == entry.id }
        saveToDisk()
    }

    func deleteAllMemories() {
        memories.removeAll()
        saveToDisk()
    }

    /// Extract memories from a conversation summary using the on-device model
    func extractMemories(from transcript: String, conversationTitle: String) async {
        let extractionSession = LanguageModelSession {
            """
            Extract 1-3 important facts, preferences, or decisions from this conversation.
            Format each fact on its own line, prefixed with keywords in brackets.
            Example: [python, coding, preference] User prefers Python for scripting tasks.
            Only extract genuinely useful information. If nothing notable, respond with NONE.
            """
        }

        do {
            let response = try await extractionSession.respond(to: transcript)
            let lines = response.content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

            for line in lines {
                if line.trimmingCharacters(in: .whitespaces).uppercased() == "NONE" { continue }

                // Parse "[keyword1, keyword2] fact text"
                if let bracketEnd = line.firstIndex(of: "]") {
                    let bracketStart = line.index(after: line.startIndex)
                    let keywordsStr = String(line[bracketStart..<bracketEnd])
                    let keywords = keywordsStr.components(separatedBy: ",").map {
                        $0.trimmingCharacters(in: .whitespaces).lowercased()
                    }.filter { !$0.isEmpty }

                    let factStart = line.index(after: bracketEnd)
                    let fact = String(line[factStart...]).trimmingCharacters(in: .whitespaces)

                    if !fact.isEmpty && !keywords.isEmpty {
                        addMemory(fact, keywords: keywords, source: conversationTitle)
                    }
                } else {
                    // No bracket format — store the whole line with auto-extracted keywords
                    let words = tokenize(line)
                    if !line.isEmpty {
                        addMemory(line, keywords: Array(words.prefix(5)), source: conversationTitle)
                    }
                }
            }
        } catch {
            // Extraction failed silently — not critical
        }
    }

    // MARK: - Tokenization (internal for reuse by AddMemoryView)

    func tokenize(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "shall", "can", "to", "of", "in", "for",
            "on", "with", "at", "by", "from", "as", "into", "about", "that",
            "this", "it", "its", "and", "or", "but", "not", "no", "so", "if",
            "i", "me", "my", "you", "your", "we", "our", "they", "them", "their",
            "what", "which", "who", "how", "when", "where", "why"
        ]

        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }

        return Set(words)
    }

    private func saveToDisk() {
        SharedDataManager.saveMemories(memories)
    }

    private func loadFromDisk() {
        memories = SharedDataManager.loadMemories()
    }
}

// MARK: - Chat View Model

@Observable
final class ChatViewModel: Identifiable {
    let id: UUID
    var title: String
    let createdAt: Date
    var customSystemPrompt: String?

    private(set) var messages: [Message] = []
    private(set) var streamingText = ""
    private(set) var isResponding = false
    private(set) var isWaitingForFirstToken = false
    private(set) var isAvailable = false
    private(set) var unavailableReason: String?

    /// Approximate context usage as a fraction (0.0 – 1.0)
    private(set) var contextUsage: Double = 0

    private var session: LanguageModelSession
    private var turnCount = 0
    private var conversationSummary: String?
    private var hasAutoTitle = false
    private var onChanged: (() -> Void)?

    /// Reference to the shared memory store for RAG retrieval
    var memoryStore: MemoryStore?

    /// Reference to the shared knowledge base store for document RAG retrieval
    var knowledgeBaseStore: KnowledgeBaseStore?

    /// RAG configuration
    var ragSettings: RAGSettings = .default

    private static let maxTurnsBeforeRotation = 6
    private static let estimatedMaxTokens = 4096.0
    private static let charsPerToken = 3.5
    static let defaultInstructions = "You are a helpful, friendly assistant. Be concise."

    var activeInstructions: String {
        customSystemPrompt?.isEmpty == false
            ? customSystemPrompt!
            : Self.defaultInstructions
    }

    // MARK: - Init

    init() {
        self.id = UUID()
        self.title = "New Chat"
        self.createdAt = Date()
        session = LanguageModelSession {
            Self.defaultInstructions
        }
    }

    /// Restore from persisted data
    init(from data: ConversationData) {
        self.id = data.id
        self.title = data.title
        self.createdAt = data.createdAt
        self.messages = data.messages
        self.customSystemPrompt = data.customSystemPrompt
        self.hasAutoTitle = !data.messages.isEmpty

        let instructions = data.customSystemPrompt?.isEmpty == false
            ? data.customSystemPrompt!
            : Self.defaultInstructions
        session = LanguageModelSession {
            instructions
        }

        turnCount = min(data.messages.filter { $0.role != .system }.count / 2, Self.maxTurnsBeforeRotation)
        updateContextEstimate()
    }

    /// Set a callback for persistence notifications
    func onChange(_ handler: @escaping () -> Void) {
        self.onChanged = handler
    }

    /// Snapshot for persistence
    var conversationData: ConversationData {
        ConversationData(
            id: id,
            title: title,
            createdAt: createdAt,
            messages: messages,
            customSystemPrompt: customSystemPrompt
        )
    }

    // MARK: - Availability

    func checkAvailability() {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            isAvailable = true
            unavailableReason = nil
        case .unavailable(let reason):
            isAvailable = false
            switch reason {
            case .appleIntelligenceNotEnabled:
                unavailableReason = "Enable Apple Intelligence in Settings to use this feature."
            case .deviceNotEligible:
                unavailableReason = "This device does not support on-device AI."
            case .modelNotReady:
                unavailableReason = "The AI model is still downloading. Please try again later."
            @unknown default:
                unavailableReason = "On-device AI is currently unavailable."
            }
        @unknown default:
            isAvailable = false
            unavailableReason = "On-device AI is currently unavailable."
        }
    }

    // MARK: - Send

    func send(_ text: String) async {
        let userMessage = Message(role: .user, content: text)
        messages.append(userMessage)

        if !hasAutoTitle {
            hasAutoTitle = true
            let trimmed = text.prefix(30)
            title = trimmed.count < text.count ? "\(trimmed)..." : String(trimmed)
        }

        isResponding = true
        isWaitingForFirstToken = true
        streamingText = ""

        defer {
            isResponding = false
            isWaitingForFirstToken = false
            updateContextEstimate()
            notifyChanged()
        }

        do {
            if turnCount >= Self.maxTurnsBeforeRotation {
                await rotateSession()
            }

            // Build prompt with RAG-retrieved memories
            let enrichedPrompt = buildEnrichedPrompt(for: text)

            try await streamResponse(to: enrichedPrompt)
            turnCount += 1
            triggerHaptic()
        } catch let error as LanguageModelSession.GenerationError {
            await handleGenerationError(error, originalPrompt: text)
        } catch {
            messages.append(Message(role: .system, content: "Something went wrong: \(error.localizedDescription)"))
        }

        streamingText = ""
    }

    // MARK: - Chat Management

    func startNewChat() {
        messages.removeAll()
        streamingText = ""
        turnCount = 0
        conversationSummary = nil
        hasAutoTitle = false
        title = "New Chat"
        contextUsage = 0
        let instructions = activeInstructions
        session = LanguageModelSession {
            instructions
        }
        notifyChanged()
    }

    func updateSystemPrompt(_ prompt: String?) {
        customSystemPrompt = prompt
        let instructions = activeInstructions
        session = LanguageModelSession {
            instructions
        }
        turnCount = 0
        contextUsage = 0
        notifyChanged()
    }

    func deleteMessage(_ message: Message) {
        messages.removeAll { $0.id == message.id }
        notifyChanged()
    }

    /// Export conversation as plain text
    func exportAsText() -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("Date: \(createdAt.formatted(date: .long, time: .shortened))")
        if let prompt = customSystemPrompt, !prompt.isEmpty {
            lines.append("System: \(prompt)")
        }
        lines.append("")
        for msg in messages {
            let label: String
            switch msg.role {
            case .user: label = "You"
            case .assistant: label = "Assistant"
            case .system: label = "System"
            }
            lines.append("[\(msg.timestamp.formatted(date: .omitted, time: .shortened))] \(label):")
            lines.append(msg.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - RAG Integration

    /// Build an enriched prompt by prepending relevant memories and document chunks
    private func buildEnrichedPrompt(for userText: String) -> String {
        let maxContextChars = ragSettings.contextBudgetCharacters
        var contextBlocks: [String] = []
        var usedChars = 0

        // Retrieve memories
        if ragSettings.memoryRetrievalEnabled, let store = memoryStore {
            let relevantMemories = store.retrieve(for: userText, limit: ragSettings.maxMemoryResults)
            if !relevantMemories.isEmpty {
                let block = relevantMemories.map { "- \($0.content)" }.joined(separator: "\n")
                contextBlocks.append("Remembered context from previous conversations:\n\(block)")
                usedChars += block.count
            }
        }

        // Retrieve document chunks
        if ragSettings.knowledgeBaseRetrievalEnabled, let kbStore = knowledgeBaseStore, usedChars < maxContextChars {
            let budget = maxContextChars - usedChars
            let relevantChunks = kbStore.retrieve(for: userText, limit: ragSettings.maxDocumentChunks)
            if !relevantChunks.isEmpty {
                var chunkTexts: [String] = []
                var chunkChars = 0
                for chunk in relevantChunks {
                    let text = "[\(chunk.locationLabel)] \(chunk.content)"
                    if chunkChars + text.count > budget { break }
                    chunkTexts.append(text)
                    chunkChars += text.count
                }
                if !chunkTexts.isEmpty {
                    contextBlocks.append("Relevant knowledge base excerpts:\n\(chunkTexts.joined(separator: "\n---\n"))")
                }
            }
        }

        guard !contextBlocks.isEmpty else { return userText }

        return """
        [\(contextBlocks.joined(separator: "\n\n"))]

        \(userText)
        """
    }

    // MARK: - Private

    private func streamResponse(to prompt: String) async throws {
        let stream = session.streamResponse(to: prompt)
        var fullText = ""
        for try await partial in stream {
            if isWaitingForFirstToken {
                isWaitingForFirstToken = false
            }
            fullText = partial.content
            streamingText = fullText
        }
        if !fullText.isEmpty {
            messages.append(Message(role: .assistant, content: fullText))
        }
    }

    private func handleGenerationError(
        _ error: LanguageModelSession.GenerationError,
        originalPrompt: String
    ) async {
        switch error {
        case .exceededContextWindowSize:
            await rotateSession()
            do {
                try await streamResponse(to: originalPrompt)
                turnCount = 1
            } catch {
                messages.append(Message(role: .system, content: "Unable to continue — the message may be too long for on-device AI."))
            }
        default:
            messages.append(Message(role: .system, content: "Error: \(error.localizedDescription)"))
        }
    }

    private func rotateSession() async {
        let recentMessages = messages.suffix(8)
        let transcript = recentMessages.map { msg in
            let label = msg.role == .user ? "User" : "Assistant"
            return "\(label): \(msg.content)"
        }.joined(separator: "\n")

        // Extract memories from the conversation being rotated out (RAG ingestion)
        if ragSettings.autoExtractMemories, let store = memoryStore {
            await store.extractMemories(from: transcript, conversationTitle: title)
        }

        // Summarize for the new session
        let summarySession = LanguageModelSession {
            "Summarize the following conversation in 2-3 short sentences. Capture key topics and decisions."
        }

        let summary: String
        do {
            let response = try await summarySession.respond(to: transcript)
            summary = response.content
        } catch {
            summary = conversationSummary ?? "Previous conversation context unavailable."
        }

        conversationSummary = summary

        let instructions = activeInstructions
        session = LanguageModelSession {
            """
            \(instructions)

            Previous conversation context: \(summary)
            Continue the conversation naturally.
            """
        }
        turnCount = 0

        messages.append(Message(role: .system, content: "Context refreshed — I still remember the key points."))
    }

    private func updateContextEstimate() {
        let instructionChars = Double(activeInstructions.count)
        let summaryChars = Double(conversationSummary?.count ?? 0)

        let sessionMessageCount = turnCount * 2
        let recentMessages = messages.suffix(sessionMessageCount)
        let messageChars = recentMessages.reduce(0.0) { $0 + Double($1.content.count) }

        let totalEstimatedTokens = (instructionChars + summaryChars + messageChars) / Self.charsPerToken
        contextUsage = min(totalEstimatedTokens / Self.estimatedMaxTokens, 1.0)
    }

    private func triggerHaptic() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif
    }

    private func notifyChanged() {
        onChanged?()
    }
}

// MARK: - Conversation Store (Persistence)

// MARK: - RAG Settings

struct RAGSettings: Codable {
    var memoryRetrievalEnabled: Bool = true
    var knowledgeBaseRetrievalEnabled: Bool = true
    var maxMemoryResults: Int = 3
    var maxDocumentChunks: Int = 2
    var contextBudgetCharacters: Int = 3500
    var autoExtractMemories: Bool = true

    static let `default` = RAGSettings()
}

@Observable
final class ConversationStore {
    var conversations: [ChatViewModel] = []
    var selectedConversationID: UUID?
    let memoryStore = MemoryStore()
    let knowledgeBaseStore = KnowledgeBaseStore()
    var ragSettings: RAGSettings = .default
    var defaultSystemPrompt: String = ChatViewModel.defaultInstructions

    private static let saveKey = "saved_conversations"
    private static let ragSettingsKey = "rag_settings"
    private static let defaultSystemPromptKey = "default_system_prompt"

    init() {
        SharedDataManager.migrateIfNeeded()
        loadRAGSettings()
        loadDefaultSystemPrompt()
        loadFromDisk()
        if conversations.isEmpty {
            let initial = ChatViewModel()
            conversations.append(initial)
        }
        for conversation in conversations {
            conversation.memoryStore = memoryStore
            conversation.knowledgeBaseStore = knowledgeBaseStore
            conversation.ragSettings = ragSettings
            conversation.onChange { [weak self] in self?.saveToDisk() }
        }
    }

    func createConversation() -> ChatViewModel {
        let conversation = ChatViewModel()
        conversation.checkAvailability()
        conversation.memoryStore = memoryStore
        conversation.knowledgeBaseStore = knowledgeBaseStore
        conversation.ragSettings = ragSettings
        conversation.onChange { [weak self] in self?.saveToDisk() }
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        saveToDisk()
        return conversation
    }

    func deleteConversation(at offsets: IndexSet) {
        let idsToDelete = offsets.map { conversations[$0].id }
        conversations.remove(atOffsets: offsets)
        if let selected = selectedConversationID, idsToDelete.contains(selected) {
            selectedConversationID = conversations.first?.id
        }
        saveToDisk()
    }

    func deleteConversation(id: UUID) {
        conversations.removeAll { $0.id == id }
        if selectedConversationID == id {
            selectedConversationID = conversations.first?.id
        }
        saveToDisk()
    }

    func deleteAllConversations() {
        conversations.removeAll()
        selectedConversationID = nil
        let fresh = ChatViewModel()
        fresh.checkAvailability()
        fresh.memoryStore = memoryStore
        fresh.knowledgeBaseStore = knowledgeBaseStore
        fresh.ragSettings = ragSettings
        fresh.onChange { [weak self] in self?.saveToDisk() }
        conversations.append(fresh)
        selectedConversationID = fresh.id
        saveToDisk()
    }

    func selectedConversation() -> ChatViewModel? {
        guard let id = selectedConversationID else { return nil }
        return conversations.first { $0.id == id }
    }

    // MARK: - Pending Shared Content (from Share Extension)

    /// Check for and process any pending shared text from the Share Extension.
    func processPendingSharedContent() {
        guard let (text, action) = SharedDataManager.consumePendingSharedText() else { return }

        switch action {
        case .saveAsMemory:
            let keywords = Array(SharedDataManager.extractKeywords(from: text, limit: 5))
            memoryStore.addMemory(text, keywords: keywords, source: "Shared Content")

        case .startConversation:
            let conversation = createConversation()
            Task {
                await conversation.send(text)
            }
        }
    }

    // MARK: - Persistence

    private func saveToDisk() {
        SharedDataManager.saveConversations(conversations.map { $0.conversationData })
    }

    private func loadFromDisk() {
        let decoded = SharedDataManager.loadConversations()
        guard !decoded.isEmpty else { return }
        conversations = decoded.map { ChatViewModel(from: $0) }
    }

    /// Call after changing ragSettings to persist and propagate to conversations.
    func applyRAGSettings() {
        if let data = try? JSONEncoder().encode(ragSettings) {
            SharedDataManager.sharedDefaults.set(data, forKey: Self.ragSettingsKey)
        }
        for conversation in conversations {
            conversation.ragSettings = ragSettings
        }
    }

    private func loadRAGSettings() {
        guard let data = SharedDataManager.sharedDefaults.data(forKey: Self.ragSettingsKey),
              let decoded = try? JSONDecoder().decode(RAGSettings.self, from: data) else { return }
        ragSettings = decoded
    }

    /// Call after changing defaultSystemPrompt to persist.
    func applyDefaultSystemPrompt() {
        SharedDataManager.sharedDefaults.set(defaultSystemPrompt, forKey: Self.defaultSystemPromptKey)
    }

    private func loadDefaultSystemPrompt() {
        if let saved = SharedDataManager.sharedDefaults.string(forKey: Self.defaultSystemPromptKey), !saved.isEmpty {
            defaultSystemPrompt = saved
        }
    }
}
