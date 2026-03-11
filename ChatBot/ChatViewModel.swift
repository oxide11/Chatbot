import SwiftUI
import SwiftData
import FoundationModels

// MARK: - Message Model

struct Message: Identifiable, Codable, Sendable {
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

struct ConversationData: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var messages: [Message]
    var customSystemPrompt: String?
    /// The knowledge domain assigned to this conversation (nil treated as General).
    var domainID: UUID?
}

// MARK: - Memory Entry (RAG)

struct MemoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let content: String
    let keywords: [String]
    let sourceConversationTitle: String
    let createdAt: Date

    /// Semantic embedding vector (512-dim from NLContextualEmbedding).
    var embedding: [Double]?

    /// The domain this memory belongs to (nil treated as General).
    var domainID: UUID?

    init(content: String, keywords: [String], sourceConversationTitle: String, domainID: UUID? = nil) {
        self.id = UUID()
        self.content = content
        self.keywords = keywords.map { $0.lowercased() }
        self.sourceConversationTitle = sourceConversationTitle
        self.createdAt = Date()
        self.embedding = EmbeddingService.shared.embed(content)
        self.domainID = domainID
    }

    init(id: UUID = UUID(), content: String, keywords: [String], sourceConversationTitle: String, createdAt: Date = Date(), embedding: [Double]? = nil, domainID: UUID? = nil) {
        self.id = id
        self.content = content
        self.keywords = keywords.map { $0.lowercased() }
        self.sourceConversationTitle = sourceConversationTitle
        self.createdAt = createdAt
        self.embedding = embedding
        self.domainID = domainID
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
    func addMemory(_ content: String, keywords: [String], source: String, domainID: UUID = KnowledgeDomain.generalID) {
        // Avoid exact duplicates
        guard !memories.contains(where: { $0.content == content }) else { return }

        let entry = MemoryEntry(content: content, keywords: keywords, sourceConversationTitle: source, domainID: domainID)
        memories.insert(entry, at: 0)

        // Evict oldest if over capacity
        if memories.count > Self.maxMemories {
            memories = Array(memories.prefix(Self.maxMemories))
        }
        saveToDisk()
    }

    /// Retrieve memories relevant to a query, scoped to a domain.
    ///
    /// **Primary path:** Embed the query and rank by cosine similarity.
    /// **Fallback:** Keyword overlap (for old memories without embeddings or when assets unavailable).
    func retrieve(for query: String, domainID: UUID = KnowledgeDomain.generalID, limit: Int = 5) -> [MemoryEntry] {
        let domainMemories = memories.filter { ($0.domainID ?? KnowledgeDomain.generalID) == domainID }

        // Try semantic retrieval first
        if let queryVector = EmbeddingService.shared.embed(query) {
            let scored = domainMemories.compactMap { entry -> (MemoryEntry, Double)? in
                guard let memVector = entry.embedding else { return nil }
                let similarity = EmbeddingService.cosineSimilarity(queryVector, memVector)
                guard similarity > 0.3 else { return nil }

                // Small recency tiebreaker
                let ageInDays = max(1, -entry.createdAt.timeIntervalSinceNow / 86400)
                let recencyBonus = 1.0 / log2(ageInDays + 1)
                return (entry, similarity + recencyBonus * 0.02)
            }

            let results = scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
            if !results.isEmpty { return results }
        }

        // Fallback: keyword matching
        return retrieveByKeywords(query: query, from: domainMemories, limit: limit)
    }

    /// Keyword-based fallback retrieval for memories without embeddings.
    private func retrieveByKeywords(query: String, from pool: [MemoryEntry], limit: Int) -> [MemoryEntry] {
        let queryWords = tokenize(query)
        guard !queryWords.isEmpty else { return [] }
        let queryCount = Double(queryWords.count)

        let scored = pool.compactMap { entry -> (MemoryEntry, Double)? in
            let allEntryWords = Set(entry.keywords).union(tokenize(entry.content))

            var matchedWords = 0.0
            for word in queryWords {
                if allEntryWords.contains(word) {
                    matchedWords += 1.0
                } else if word.count >= 5 {
                    for entryWord in allEntryWords where entryWord.count >= 5
                        && (entryWord.hasPrefix(word) || word.hasPrefix(entryWord)) {
                        matchedWords += 0.5
                        break
                    }
                }
            }

            let normalizedScore = matchedWords / queryCount
            guard normalizedScore >= 0.25 else { return nil }

            let ageInDays = max(1, -entry.createdAt.timeIntervalSinceNow / 86400)
            let recencyBonus = 1.0 / log2(ageInDays + 1)
            return (entry, normalizedScore + recencyBonus * 0.05)
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    func updateMemory(_ entry: MemoryEntry, content: String, keywords: [String]) {
        guard let index = memories.firstIndex(where: { $0.id == entry.id }) else { return }
        // Re-embed if content changed; preserve existing embedding otherwise.
        let newEmbedding = (content != entry.content)
            ? EmbeddingService.shared.embed(content)
            : entry.embedding
        memories[index] = MemoryEntry(
            id: entry.id,
            content: content,
            keywords: keywords,
            sourceConversationTitle: entry.sourceConversationTitle,
            createdAt: entry.createdAt,
            embedding: newEmbedding,
            domainID: entry.domainID
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

    /// Return memories filtered by domain.
    func memories(for domainID: UUID) -> [MemoryEntry] {
        memories.filter { ($0.domainID ?? KnowledgeDomain.generalID) == domainID }
    }

    /// Move a memory to a different domain.
    func moveMemory(_ entry: MemoryEntry, toDomain domainID: UUID) {
        guard let index = memories.firstIndex(where: { $0.id == entry.id }) else { return }
        memories[index] = MemoryEntry(
            id: entry.id,
            content: entry.content,
            keywords: entry.keywords,
            sourceConversationTitle: entry.sourceConversationTitle,
            createdAt: entry.createdAt,
            embedding: entry.embedding,
            domainID: domainID
        )
        saveToDisk()
    }

    /// Extract memories from a conversation summary using the on-device model.
    /// Uses few-shot prompting with explicit format examples for reliable structured output.
    func extractMemories(from transcript: String, conversationTitle: String, domainID: UUID = KnowledgeDomain.generalID) async {
        let extractionSession = LanguageModelSession {
            """
            You are a fact extractor. Your role is to identify 1-3 important facts, decisions, or preferences from a conversation transcript.

            Instructions:
            - Extract only concrete, reusable facts (e.g. preferences, decisions, names, dates, technical choices).
            - Ignore greetings, filler, and questions that were not answered.
            - Each fact must be a self-contained sentence that makes sense without the original conversation.
            - Format each fact on its own line as: [keyword1, keyword2] Fact sentence here.
            - If no notable facts exist, respond with exactly: NONE

            Examples:
            [python, preference] The user prefers Python for scripting tasks.
            [meeting, tuesday] Weekly team meeting is scheduled for Tuesdays at 10am.
            [api, openai] The project uses the OpenAI API with GPT-4 for summarization.
            """
        }

        let extractionOptions = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: 200
        )

        // Guard against empty or trivially short transcripts
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTranscript.count >= 20 else { return }

        do {
            let response = try await extractionSession.respond(to: trimmedTranscript, options: extractionOptions)
            let lines = response.content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

            for line in lines {
                // Strip leading bullets, dashes, or numbering (e.g. "- [kw] fact" or "1. [kw] fact")
                var trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if let firstBracket = trimmedLine.firstIndex(of: "["), firstBracket != trimmedLine.startIndex {
                    // Remove any prefix before the opening bracket (bullets, numbering, etc.)
                    trimmedLine = String(trimmedLine[firstBracket...])
                }
                trimmedLine = trimmedLine.trimmingCharacters(in: .whitespaces)

                if trimmedLine.uppercased().contains("NONE") || trimmedLine.isEmpty { continue }

                // Parse "[keyword1, keyword2] fact text"
                if trimmedLine.hasPrefix("["),
                   let bracketEnd = trimmedLine.firstIndex(of: "]") {
                    let keywordsStart = trimmedLine.index(after: trimmedLine.startIndex)
                    let keywordsStr = String(trimmedLine[keywordsStart..<bracketEnd])
                    let keywords = keywordsStr.components(separatedBy: ",").map {
                        $0.trimmingCharacters(in: .whitespaces).lowercased()
                    }.filter { !$0.isEmpty }

                    let factStart = trimmedLine.index(after: bracketEnd)
                    let fact = String(trimmedLine[factStart...]).trimmingCharacters(in: .whitespaces)

                    if !fact.isEmpty && !keywords.isEmpty {
                        addMemory(fact, keywords: keywords, source: conversationTitle, domainID: domainID)
                    }
                } else {
                    // No bracket format — store the whole line with auto-extracted keywords
                    let keywords = SharedDataManager.extractKeywords(from: trimmedLine, limit: 5)
                    if !keywords.isEmpty {
                        addMemory(trimmedLine, keywords: keywords, source: conversationTitle, domainID: domainID)
                    }
                }
            }
        } catch {
            AppLogger.chat.warning("Memory extraction failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Tokenization

    /// Delegates to SharedDataManager's canonical tokenizer.
    func tokenize(_ text: String) -> Set<String> {
        SharedDataManager.tokenize(text)
    }

    private func saveToDisk() {
        SharedDataManager.saveMemoriesToFile(memories)
    }

    private func loadFromDisk() {
        memories = SharedDataManager.loadMemoriesFromFile()

        // Recompute embeddings for any memories that don't have them
        let service = EmbeddingService.shared
        guard service.isAvailable else { return }
        var changed = false
        for i in memories.indices where memories[i].embedding == nil {
            memories[i].embedding = service.embed(memories[i].content)
            changed = true
        }
        if changed { saveToDisk() }
    }
}

// MARK: - Chat View Model

@Observable
final class ChatViewModel: Identifiable {
    let id: UUID
    var title: String
    let createdAt: Date
    var customSystemPrompt: String?

    /// The knowledge domain assigned to this conversation.
    var domainID: UUID = KnowledgeDomain.generalID

    private(set) var messages: [Message] = []
    private(set) var streamingText = ""
    private(set) var isResponding = false
    private(set) var isWaitingForFirstToken = false
    private(set) var isAvailable = false
    private(set) var unavailableReason: String?

    /// Approximate context usage as a fraction (0.0 – 1.0)
    private(set) var contextUsage: Double = 0

    /// RAG context that was used for the most recent response
    private(set) var lastRAGContext: RAGContext?

    /// Names of workers that were invoked during the most recent response
    private(set) var lastWorkerInvocations: [String] = []

    private var session: LanguageModelSession
    private var turnCount = 0
    private var conversationSummary: String?
    private var hasAutoTitle = false
    private var onChanged: (() -> Void)?
    var currentStreamingTask: Task<Void, Never>?

    /// Reference to the shared memory store for RAG retrieval
    var memoryStore: MemoryStore?

    /// Reference to the shared knowledge base store for document RAG retrieval
    var knowledgeBaseStore: KnowledgeBaseStore?

    /// RAG configuration
    var ragSettings: RAGSettings = .default

    /// Reference to the shared agent orchestrator for Manager-Worker pattern
    var orchestrator: AgentOrchestrator?

    private static let maxTurnsBeforeRotation = 6
    private static let estimatedMaxTokens = 4096.0
    private static let charsPerToken = 3.5

    /// System prompt optimised for the on-device model.
    /// Follows prompt engineering best practices: Role, Instruction, Tone, and Formatting.
    /// Kept compact to preserve context budget on the ~3B parameter model.
    static let defaultInstructions = """
        You are Engram, a knowledgeable and friendly on-device AI assistant. \
        Your role is to help the user by answering questions clearly, solving problems step by step, and assisting with everyday tasks. \
        When given reference material, use it only if directly relevant to the question. \
        Respond concisely in a warm, conversational tone. \
        Use short paragraphs and bullet points for clarity when listing multiple items. \
        If you are unsure about something, say so honestly rather than guessing.
        """

    var activeInstructions: String {
        customSystemPrompt?.isEmpty == false
            ? customSystemPrompt!
            : Self.defaultInstructions
    }

    /// Effective max turns before context rotation (reduced when workers consume context).
    private var effectiveMaxTurns: Int {
        if let orchestrator, orchestrator.hasActiveWorkers {
            return max(Self.maxTurnsBeforeRotation - 1, 3)
        }
        return Self.maxTurnsBeforeRotation
    }

    /// Create a LanguageModelSession, using the orchestrator's Manager-Worker tools when available.
    private func createSession(instructions: String, conversationSummary: String? = nil) -> LanguageModelSession {
        if let orchestrator, orchestrator.hasActiveWorkers {
            return orchestrator.createManagerSession(
                baseInstructions: instructions,
                conversationSummary: conversationSummary
            )
        } else if let summary = conversationSummary, !summary.isEmpty {
            let inst = instructions
            return LanguageModelSession {
                """
                \(inst)

                Conversation context (summary of prior messages): \(summary)
                Continue the conversation naturally from where it left off.
                """
            }
        } else {
            let inst = instructions
            return LanguageModelSession {
                inst
            }
        }
    }

    // MARK: - Init

    init() {
        self.id = UUID()
        self.title = "New Chat"
        self.createdAt = Date()
        session = LanguageModelSession {
            Self.defaultInstructions
        }
        // Eagerly load model weights + cache the system prompt prefix to reduce first-token latency
        session.prewarm()
    }

    /// Rebuild the session with current orchestrator tools.
    /// Call after the orchestrator is assigned to pick up worker tools.
    func rebuildSessionIfNeeded() {
        guard let orchestrator, orchestrator.hasActiveWorkers else { return }
        session = createSession(
            instructions: activeInstructions,
            conversationSummary: conversationSummary
        )
        session.prewarm()
    }

    /// Eagerly load model weights + cache the prompt prefix to reduce first-token latency.
    func prewarmSession() {
        session.prewarm()
    }

    /// Restore from persisted data
    init(from data: ConversationData) {
        self.id = data.id
        self.title = data.title
        self.createdAt = data.createdAt
        self.messages = data.messages
        self.customSystemPrompt = data.customSystemPrompt
        self.domainID = data.domainID ?? KnowledgeDomain.generalID
        self.hasAutoTitle = !data.messages.isEmpty

        // Initial session without tools — will be rebuilt after orchestrator is assigned
        let instructions = data.customSystemPrompt?.isEmpty == false
            ? data.customSystemPrompt!
            : Self.defaultInstructions
        session = LanguageModelSession {
            instructions
        }
        // Only prewarm the selected/most-recent conversation to avoid loading model N times
        // The caller (ConversationStore) will prewarm the active conversation explicitly

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
            customSystemPrompt: customSystemPrompt,
            domainID: domainID
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
        lastWorkerInvocations = []

        defer {
            isResponding = false
            isWaitingForFirstToken = false
            // Drain any worker invocations that occurred during this turn
            lastWorkerInvocations = orchestrator?.invocationTracker.drain() ?? []
            updateContextEstimate()
            notifyChanged()
        }

        do {
            if turnCount >= effectiveMaxTurns {
                await rotateSession()
            }

            // Build prompt with RAG-retrieved memories
            let (enrichedPrompt, ragContext) = buildEnrichedPrompt(for: text)
            lastRAGContext = ragContext

            try await streamResponse(to: enrichedPrompt)
            turnCount += 1
            triggerHaptic()
        } catch is CancellationError {
            // User stopped generation — save partial text if available
            if !streamingText.isEmpty {
                messages.append(Message(role: .assistant, content: streamingText))
            }
        } catch let error as LanguageModelSession.GenerationError {
            await handleGenerationError(error, originalPrompt: text)
        } catch {
            messages.append(Message(role: .system, content: "Something went wrong: \(error.localizedDescription)"))
        }

        streamingText = ""
    }

    /// Stop the current generation, preserving any partial response.
    func stopGenerating() {
        currentStreamingTask?.cancel()
        currentStreamingTask = nil
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
        session = createSession(instructions: activeInstructions)
        session.prewarm()
        notifyChanged()
    }

    func updateSystemPrompt(_ prompt: String?) {
        customSystemPrompt = prompt
        session = createSession(instructions: activeInstructions)
        session.prewarm()
        turnCount = 0
        contextUsage = 0
        notifyChanged()
    }

    func deleteMessage(_ message: Message) {
        messages.removeAll { $0.id == message.id }
        notifyChanged()
    }

    /// Edit a user message and resend it, removing the original message and everything after it.
    func editAndResend(_ message: Message, newContent: String) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        // Remove the edited message and all subsequent messages
        messages.removeSubrange(index...)
        notifyChanged()
        // Send the new content
        let task = Task {
            await send(newContent)
        }
        currentStreamingTask = task
    }

    /// Regenerate the last assistant response by re-sending the previous user message.
    func regenerateLastResponse() async {
        // Find the last assistant message and the user message before it
        guard let lastAssistantIndex = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        let precedingMessages = messages[..<lastAssistantIndex]
        guard let lastUserMessage = precedingMessages.last(where: { $0.role == .user }) else { return }

        let userText = lastUserMessage.content

        // Remove the last assistant message
        messages.remove(at: lastAssistantIndex)

        isResponding = true
        isWaitingForFirstToken = true
        streamingText = ""
        lastWorkerInvocations = []

        defer {
            isResponding = false
            isWaitingForFirstToken = false
            lastWorkerInvocations = orchestrator?.invocationTracker.drain() ?? []
            updateContextEstimate()
            notifyChanged()
        }

        do {
            let (enrichedPrompt, ragContext) = buildEnrichedPrompt(for: userText)
            lastRAGContext = ragContext
            try await streamResponse(to: enrichedPrompt)
            triggerHaptic()
        } catch is CancellationError {
            if !streamingText.isEmpty {
                messages.append(Message(role: .assistant, content: streamingText))
            }
        } catch {
            messages.append(Message(role: .system, content: "Regeneration failed: \(error.localizedDescription)"))
        }

        streamingText = ""
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

    /// Build an enriched prompt by prepending relevant memories and document chunks.
    /// Returns the prompt string and a RAGContext describing what was injected.
    private func buildEnrichedPrompt(for userText: String) -> (prompt: String, context: RAGContext) {
        let maxContextChars = ragSettings.contextBudgetCharacters
        var contextBlocks: [String] = []
        var usedChars = 0
        var memoryCount = 0
        var chunkCount = 0
        var docNames: Set<String> = []

        // Retrieve memories (scoped to conversation's domain)
        if ragSettings.memoryRetrievalEnabled, let store = memoryStore {
            let relevantMemories = store.retrieve(for: userText, domainID: domainID, limit: ragSettings.maxMemoryResults)
            if !relevantMemories.isEmpty {
                memoryCount = relevantMemories.count
                let block = relevantMemories.map { "- \($0.content)" }.joined(separator: "\n")
                contextBlocks.append("**Memories** (facts recalled from previous conversations):\n\(block)")
                usedChars += block.count
            }
        }

        // Retrieve document chunks (scoped to conversation's domain).
        // Strategy: inject chunk summaries for breadth (5x denser), then append
        // the top 1-2 full chunks for depth when the budget allows.
        if ragSettings.knowledgeBaseRetrievalEnabled, let kbStore = knowledgeBaseStore, usedChars < maxContextChars {
            let budget = maxContextChars - usedChars
            // Retrieve more chunks than usual — summaries are small, so we can fit more context
            let retrievalLimit = ragSettings.maxDocumentChunks * 2
            let relevantChunks = kbStore.retrieve(for: userText, domainID: domainID, limit: retrievalLimit)
            if !relevantChunks.isEmpty {
                let kbLookup = Dictionary(uniqueKeysWithValues: kbStore.knowledgeBases.map { ($0.id, $0.name) })
                var summaryTexts: [String] = []
                var fullTexts: [String] = []
                var totalChars = 0

                // Phase 1: Add chunk summaries for broad coverage
                for chunk in relevantChunks {
                    let text: String
                    if let summary = chunk.summary, !summary.isEmpty {
                        text = "[\(chunk.locationLabel)] \(summary)"
                    } else {
                        // No summary — use truncated content as fallback
                        text = "[\(chunk.locationLabel)] \(String(chunk.content.prefix(200)))"
                    }
                    if totalChars + text.count > budget { break }
                    summaryTexts.append(text)
                    totalChars += text.count
                    chunkCount += 1
                    if let name = kbLookup[chunk.knowledgeBaseID] {
                        docNames.insert(name)
                    }
                }

                // Phase 2: Append 1-2 full verbatim chunks for depth (top-ranked only)
                let fullChunkLimit = min(2, relevantChunks.count)
                for chunk in relevantChunks.prefix(fullChunkLimit) {
                    // Skip if the chunk is short enough that the summary IS the content
                    guard chunk.content.count > 200 else { continue }
                    let fullText = "[\(chunk.locationLabel)] \(chunk.content)"
                    if totalChars + fullText.count > budget { break }
                    fullTexts.append(fullText)
                    totalChars += fullText.count
                }

                var block = ""
                if !summaryTexts.isEmpty {
                    block += "**Knowledge Base Summaries** (condensed from imported documents):\n\(summaryTexts.joined(separator: "\n"))"
                }
                if !fullTexts.isEmpty {
                    if !block.isEmpty { block += "\n\n" }
                    block += "**Key Excerpts** (verbatim for reference):\n\(fullTexts.joined(separator: "\n---\n"))"
                }
                if !block.isEmpty {
                    contextBlocks.append(block)
                }
            }
        }

        let ragContext = RAGContext(
            memoryCount: memoryCount,
            documentChunkCount: chunkCount,
            documentNames: docNames.sorted()
        )

        guard !contextBlocks.isEmpty else {
            return (userText, ragContext)
        }

        // Format: user question FIRST, then structured reference context AFTER.
        // Clear RAG integration instructions help the model use retrieved content appropriately.
        let enriched = """
        \(userText)

        ---
        **Reference Material** (retrieved from your knowledge base and memory):
        Use the following information to support your answer when it is directly relevant to the question above. \
        If the reference material does not relate to the question, ignore it and rely on your own knowledge. \
        When you do use reference material, incorporate it naturally — do not simply repeat it verbatim. \
        Never mention that you are using "reference material" or "retrieved context" in your response.

        \(contextBlocks.joined(separator: "\n\n"))
        """
        return (enriched, ragContext)
    }

    // MARK: - Private

    private func streamResponse(to prompt: String) async throws {
        let options = ragSettings.chatGenerationOptions
        let stream = session.streamResponse(to: prompt, options: options)
        var fullText = ""
        for try await partial in stream {
            // Support cancellation — keep partial text
            try Task.checkCancellation()
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
                messages.append(Message(role: .system, content: "Unable to process this message — it may exceed the on-device model's context limit. Try breaking your message into smaller parts."))
            }
        default:
            messages.append(Message(role: .system, content: "Error: \(error.localizedDescription)"))
        }
    }

    private func rotateSession() async {
        // Only summarise the most recent turns — keeps the summary focused
        let recentMessages = messages.suffix(6)
        let transcript = recentMessages.map { msg in
            let label = msg.role == .user ? "User" : "Assistant"
            return "\(label): \(msg.content)"
        }.joined(separator: "\n")

        // Extract memories from the conversation being rotated out (RAG ingestion)
        if ragSettings.autoExtractMemories, let store = memoryStore {
            await store.extractMemories(from: transcript, conversationTitle: title, domainID: domainID)
        }

        // Summarise for the new session — use greedy sampling for a deterministic, focused summary.
        // Uses instructive prompting with clear formatting guidance for reliable continuation.
        let summarySession = LanguageModelSession {
            """
            You are a conversation summarizer. Your role is to create a brief context summary that allows a conversation to continue seamlessly.

            Instructions:
            - Write exactly 2-3 sentences summarizing the conversation so far.
            - Prioritize: (1) the main topic or question, (2) any decisions or conclusions reached, (3) the user's current need or next step.
            - Use third-person perspective (e.g. "The user asked about..." or "They discussed...").
            - Do not include greetings, filler, or meta-commentary.
            - The summary must be self-contained — a reader should understand the conversation state without seeing the original messages.
            """
        }

        let greedyOptions = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: 150
        )

        let summary: String
        do {
            let response = try await summarySession.respond(to: transcript, options: greedyOptions)
            summary = response.content
        } catch {
            summary = conversationSummary ?? ""
        }

        conversationSummary = summary

        session = createSession(
            instructions: activeInstructions,
            conversationSummary: summary
        )
        session.prewarm()
        turnCount = 0

        messages.append(Message(role: .system, content: "Context window refreshed. The conversation summary has been preserved so I can continue seamlessly."))
    }

    private func updateContextEstimate() {
        let instructionChars = Double(activeInstructions.count)
        let summaryChars = Double(conversationSummary?.count ?? 0)
        let toolSchemaChars = Double(orchestrator?.estimatedToolSchemaCharacters ?? 0)

        let sessionMessageCount = turnCount * 2
        let recentMessages = messages.suffix(sessionMessageCount)
        let messageChars = recentMessages.reduce(0.0) { $0 + Double($1.content.count) }

        let totalEstimatedTokens = (instructionChars + summaryChars + messageChars + toolSchemaChars) / Self.charsPerToken
        contextUsage = min(totalEstimatedTokens / Self.estimatedMaxTokens, 1.0)
    }

    private func triggerHaptic() {
        #if os(iOS)
        Task { @MainActor in
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        }
        #endif
    }

    func notifyChanged() {
        onChanged?()
    }
}

// MARK: - Conversation Store (Persistence)

// MARK: - RAG Settings

/// Describes what RAG context was injected for a given response.
struct RAGContext {
    let memoryCount: Int
    let documentChunkCount: Int
    let documentNames: [String]

    var isEmpty: Bool { memoryCount == 0 && documentChunkCount == 0 }

    var summary: String {
        var parts: [String] = []
        if memoryCount > 0 {
            parts.append("\(memoryCount) memor\(memoryCount == 1 ? "y" : "ies")")
        }
        if documentChunkCount > 0 {
            let names = documentNames.joined(separator: ", ")
            parts.append("\(documentChunkCount) chunk\(documentChunkCount == 1 ? "" : "s") from \(names)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Sampling Mode Setting

/// Persistent representation of the sampling strategy for the main chat.
enum SamplingModeSetting: String, Codable, CaseIterable, Sendable {
    case greedy   = "greedy"
    case topK     = "topK"
    case topP     = "topP"

    var label: String {
        switch self {
        case .greedy: return "Greedy"
        case .topK:   return "Top-K"
        case .topP:   return "Top-P"
        }
    }

    var description: String {
        switch self {
        case .greedy: return "Deterministic — always picks the most likely token"
        case .topK:   return "Samples from the K most probable tokens"
        case .topP:   return "Samples from tokens covering P% cumulative probability"
        }
    }
}

struct RAGSettings: Codable, Sendable {
    var memoryRetrievalEnabled: Bool = true
    var knowledgeBaseRetrievalEnabled: Bool = true
    var maxMemoryResults: Int = 2
    var maxDocumentChunks: Int = 3
    var contextBudgetCharacters: Int = 1500
    var autoExtractMemories: Bool = true

    // MARK: Generation Hyperparameters

    /// Temperature controls randomness (0 = focused, 2 = creative). Default 1.0.
    var temperature: Double = 1.0
    /// Sampling strategy for the main chat session.
    var samplingMode: SamplingModeSetting = .topK
    /// Top-K value: number of top tokens to sample from (used when samplingMode == .topK).
    var topKValue: Int = 40
    /// Top-P value: cumulative probability threshold (used when samplingMode == .topP).
    var topPValue: Double = 0.9

    static let `default` = RAGSettings()

    /// Backward-compatible decoding: old persisted settings without generation fields use defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memoryRetrievalEnabled = try container.decodeIfPresent(Bool.self, forKey: .memoryRetrievalEnabled) ?? true
        knowledgeBaseRetrievalEnabled = try container.decodeIfPresent(Bool.self, forKey: .knowledgeBaseRetrievalEnabled) ?? true
        maxMemoryResults = try container.decodeIfPresent(Int.self, forKey: .maxMemoryResults) ?? 2
        maxDocumentChunks = try container.decodeIfPresent(Int.self, forKey: .maxDocumentChunks) ?? 3
        contextBudgetCharacters = try container.decodeIfPresent(Int.self, forKey: .contextBudgetCharacters) ?? 1500
        autoExtractMemories = try container.decodeIfPresent(Bool.self, forKey: .autoExtractMemories) ?? true
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 1.0
        samplingMode = try container.decodeIfPresent(SamplingModeSetting.self, forKey: .samplingMode) ?? .topK
        topKValue = try container.decodeIfPresent(Int.self, forKey: .topKValue) ?? 40
        topPValue = try container.decodeIfPresent(Double.self, forKey: .topPValue) ?? 0.9
    }

    /// Build FoundationModels GenerationOptions from the current settings.
    var chatGenerationOptions: GenerationOptions {
        let sampling: GenerationOptions.SamplingMode
        switch samplingMode {
        case .greedy:
            sampling = .greedy
        case .topK:
            sampling = .random(top: topKValue)
        case .topP:
            sampling = .random(probabilityThreshold: topPValue)
        }
        return GenerationOptions(temperature: temperature, sampling: sampling)
    }
}

@Observable
final class ConversationStore {
    var conversations: [ChatViewModel] = []
    var selectedConversationID: UUID?
    let memoryStore = MemoryStore()
    let knowledgeBaseStore = KnowledgeBaseStore()
    var ragSettings: RAGSettings = .default
    var defaultSystemPrompt: String = ChatViewModel.defaultInstructions
    let orchestrator = AgentOrchestrator()

    private static let saveKey = "saved_conversations"
    private static let ragSettingsKey = "rag_settings"
    private static let defaultSystemPromptKey = "default_system_prompt"

    init() {
        SharedDataManager.migrateIfNeeded()
        loadRAGSettings()
        loadDefaultSystemPrompt()
        loadFromDisk()
        if conversations.isEmpty {
            // createConversation handles memoryStore, knowledgeBaseStore, ragSettings, defaultSystemPrompt, and onChange
            _ = createConversation()
        } else {
            for conversation in conversations {
                conversation.memoryStore = memoryStore
                conversation.knowledgeBaseStore = knowledgeBaseStore
                conversation.ragSettings = ragSettings
                conversation.orchestrator = orchestrator
                conversation.onChange { [weak self] in self?.saveToDisk() }
            }
            // Prewarm only the selected conversation for fast first response
            selectedConversation()?.prewarmSession()
        }
    }

    /// Provide the SwiftData ModelContext to the orchestrator. Call from the view layer.
    func configureOrchestrator(with modelContext: ModelContext) {
        orchestrator.configure(with: modelContext)
        // Rebuild sessions for existing conversations to pick up any enabled workers
        for conversation in conversations {
            conversation.rebuildSessionIfNeeded()
        }
    }

    /// Provide the SwiftData ModelContainer to the knowledge base store. Call from the view layer.
    func configureKnowledgeBaseStore(with modelContext: ModelContext) {
        knowledgeBaseStore.configure(with: modelContext.container)
    }

    func createConversation() -> ChatViewModel {
        let conversation = ChatViewModel()
        conversation.checkAvailability()
        conversation.memoryStore = memoryStore
        conversation.knowledgeBaseStore = knowledgeBaseStore
        conversation.ragSettings = ragSettings
        conversation.orchestrator = orchestrator
        // Apply the default system prompt if user has customized it
        if defaultSystemPrompt != ChatViewModel.defaultInstructions {
            conversation.updateSystemPrompt(defaultSystemPrompt)
        } else {
            // Rebuild session to pick up worker tools if orchestrator is configured
            conversation.rebuildSessionIfNeeded()
        }
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

    func renameConversation(id: UUID, to newTitle: String) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversation.title = trimmed
        saveToDisk()
    }

    func deleteAllConversations() {
        conversations.removeAll()
        selectedConversationID = nil
        let fresh = createConversation()
        selectedConversationID = fresh.id
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

    // MARK: - Storage Statistics

    /// Estimated byte size of persisted conversation data.
    var conversationDataSize: Int {
        let data = try? JSONEncoder().encode(conversations.map { $0.conversationData })
        return data?.count ?? 0
    }

    /// Estimated byte size of persisted memory data.
    var memoryDataSize: Int {
        let data = try? JSONEncoder().encode(memoryStore.memories)
        return data?.count ?? 0
    }

    /// Total approximate on-disk footprint (conversations + memories + knowledge bases).
    var totalStorageBytes: Int64 {
        Int64(conversationDataSize) + Int64(memoryDataSize) + knowledgeBaseStore.totalChunkStorageSize
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
