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
    /// Stored raw so unknown values from older / future builds decode cleanly.
    var providerIDRaw: String?

    var providerID: ChatProviderID {
        get { providerIDRaw.flatMap(ChatProviderID.init(rawValue:)) ?? .foundationModels }
        set { providerIDRaw = newValue.rawValue }
    }

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        messages: [Message],
        customSystemPrompt: String? = nil,
        providerIDRaw: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.messages = messages
        self.customSystemPrompt = customSystemPrompt
        self.providerIDRaw = providerIDRaw
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        customSystemPrompt = try c.decodeIfPresent(String.self, forKey: .customSystemPrompt)
        providerIDRaw = try c.decodeIfPresent(String.self, forKey: .providerIDRaw)
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

    /// Reference to the shared wiki engine for knowledge retrieval and extraction
    var wikiEngine: WikiEngine?

    /// RAG configuration
    var ragSettings: RAGSettings = .default

    /// Reference to the shared agent orchestrator for Manager-Worker pattern
    var orchestrator: AgentOrchestrator?

    /// Provider this conversation routes through. `.foundationModels` uses
    /// the on-device path; others stream via the matching ChatProvider.
    var providerID: ChatProviderID = .foundationModels

    /// Reference to the shared provider registry — used to resolve remote
    /// providers from Keychain credentials. Set by ConversationStore.
    var providerRegistry: ProviderRegistry?

    private static let maxTurnsBeforeRotation = 6
    private static let estimatedMaxTokens = 4096.0
    private static let charsPerToken = 3.5

    /// Concise system prompt optimised for the small on-device model.
    /// Shorter instructions leave more context for the actual conversation.
    static let defaultInstructions = "Be helpful, friendly, and concise. Answer directly."

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
                "\(inst)\nContext: \(summary)"
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
        self.providerID = data.providerID
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
            providerIDRaw: providerID.rawValue
        )
    }

    // MARK: - Availability

    func checkAvailability() {
        // Remote providers are available iff a key is stored.
        if providerID != .foundationModels {
            if providerRegistry?.isConfigured(providerID) == true {
                isAvailable = true
                unavailableReason = nil
            } else {
                isAvailable = false
                unavailableReason = "No API key configured for \(providerID.displayName). Add one in Settings → Providers."
            }
            return
        }

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

    /// Build an enriched prompt by prepending relevant wiki pages and document chunks.
    /// Returns the prompt string and a RAGContext describing what was injected.
    private func buildEnrichedPrompt(for userText: String) -> (prompt: String, context: RAGContext) {
        let maxContextChars = ragSettings.contextBudgetCharacters
        var contextBlocks: [String] = []
        var usedChars = 0
        var wikiPageCount = 0
        var chunkCount = 0
        var docNames: Set<String> = []

        // Retrieve wiki pages (scoped to conversation's domain)
        if ragSettings.wikiRetrievalEnabled, let engine = wikiEngine {
            let (wikiContext, pageCount) = engine.buildWikiContext(for: userText)
            if !wikiContext.isEmpty {
                wikiPageCount = pageCount
                contextBlocks.append("Knowledge from your wiki:\n\(wikiContext)")
                usedChars += wikiContext.count
            }
        }

        let ragContext = RAGContext(
            wikiPageCount: wikiPageCount,
            documentChunkCount: chunkCount,
            documentNames: docNames.sorted()
        )

        guard !contextBlocks.isEmpty else {
            return (userText, ragContext)
        }

        let enriched = """
        \(userText)

        ---
        Note: The following is supplementary reference material that MAY be relevant. \
        Only use it if it directly relates to the question above. \
        Otherwise rely on your own knowledge.

        \(contextBlocks.joined(separator: "\n\n"))
        """
        return (enriched, ragContext)
    }

    // MARK: - Private

    private func streamResponse(to prompt: String) async throws {
        if providerID != .foundationModels,
           let registry = providerRegistry,
           let remote = registry.resolve(providerID) {
            try await streamRemoteResponse(prompt: prompt, provider: remote)
            return
        }

        let stream = session.streamResponse(to: prompt)
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

    /// Stream a reply from a remote provider (Anthropic / OpenAI / Gemini).
    /// We rebuild the conversation history each call because remote APIs
    /// are stateless. The just-appended user turn is replaced with the
    /// RAG-enriched `prompt` so retrieved context reaches the model.
    private func streamRemoteResponse(
        prompt enrichedPrompt: String,
        provider: ChatProvider
    ) async throws {
        var history: [ProviderMessage] = []
        for message in messages.dropLast() {
            switch message.role {
            case .user:
                history.append(ProviderMessage(role: .user, content: message.content))
            case .assistant:
                history.append(ProviderMessage(role: .assistant, content: message.content))
            case .system:
                // System messages from context-rotation events stay local;
                // remote providers receive the actual system prompt below.
                continue
            }
        }
        history.append(ProviderMessage(role: .user, content: enrichedPrompt))

        let systemPrompt: String? = {
            let custom = customSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let custom, !custom.isEmpty { return custom }
            return Self.defaultInstructions
        }()

        let options = ProviderGenerationOptions(
            maxOutputTokens: 4096,
            temperature: 1.0
        )

        let stream = provider.streamReply(
            history: history,
            systemPrompt: systemPrompt,
            options: options
        )

        var fullText = ""
        for try await delta in stream {
            try Task.checkCancellation()
            if isWaitingForFirstToken {
                isWaitingForFirstToken = false
            }
            fullText += delta
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
        // Only summarise the most recent turns — keeps the summary focused
        let recentMessages = messages.suffix(6)
        let transcript = recentMessages.map { msg in
            let label = msg.role == .user ? "User" : "Assistant"
            return "\(label): \(msg.content)"
        }.joined(separator: "\n")

        // Extract knowledge into wiki pages from the conversation being rotated out
        if ragSettings.autoExtractKnowledge, let engine = wikiEngine {
            await engine.extractKnowledge(
                from: transcript,
                conversationID: id,
                conversationTitle: title
            )
        }

        // Summarise for the new session — use greedy sampling for a deterministic, focused summary
        let summarySession = LanguageModelSession {
            "Summarize this conversation in 2 concise sentences. State only topics discussed and decisions made."
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

        messages.append(Message(role: .system, content: "Context refreshed — I still remember the key points."))
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
    let wikiPageCount: Int
    let documentChunkCount: Int
    let documentNames: [String]

    var isEmpty: Bool { wikiPageCount == 0 && documentChunkCount == 0 }

    var summary: String {
        var parts: [String] = []
        if wikiPageCount > 0 {
            parts.append("\(wikiPageCount) wiki page\(wikiPageCount == 1 ? "" : "s")")
        }
        if documentChunkCount > 0 {
            let names = documentNames.joined(separator: ", ")
            parts.append("\(documentChunkCount) chunk\(documentChunkCount == 1 ? "" : "s") from \(names)")
        }
        return parts.joined(separator: " · ")
    }
}

struct RAGSettings: Codable, Sendable {
    var wikiRetrievalEnabled: Bool = true
    var contextBudgetCharacters: Int = 1500
    var autoExtractKnowledge: Bool = true
    /// Run the structural lint pass after every successful extraction.
    var lintAfterExtractions: Bool = false
    /// Allow iOS to schedule a daily background structural lint pass.
    var dailyBackgroundLintEnabled: Bool = false
    /// Cosine-similarity cutoff (0...1) for flagging duplicate-candidate
    /// page pairs. Lower = more flags (noisier), higher = fewer.
    var lintSimilarityThreshold: Double = 0.85

    static let `default` = RAGSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wikiRetrievalEnabled = try c.decodeIfPresent(Bool.self, forKey: .wikiRetrievalEnabled) ?? true
        contextBudgetCharacters = try c.decodeIfPresent(Int.self, forKey: .contextBudgetCharacters) ?? 1500
        autoExtractKnowledge = try c.decodeIfPresent(Bool.self, forKey: .autoExtractKnowledge) ?? true
        lintAfterExtractions = try c.decodeIfPresent(Bool.self, forKey: .lintAfterExtractions) ?? false
        dailyBackgroundLintEnabled = try c.decodeIfPresent(Bool.self, forKey: .dailyBackgroundLintEnabled) ?? false
        lintSimilarityThreshold = try c.decodeIfPresent(Double.self, forKey: .lintSimilarityThreshold) ?? 0.85
    }
}

@Observable
final class ConversationStore {
    var conversations: [ChatViewModel] = []
    var selectedConversationID: UUID?
    let wikiStore = WikiStore()
    let wikiEngine: WikiEngine
    let wikiLinter: WikiLinter
    let documentImporter = DocumentImporter()
    let providers = ProviderRegistry()
    var ragSettings: RAGSettings = .default
    var defaultSystemPrompt: String = ChatViewModel.defaultInstructions
    let orchestrator = AgentOrchestrator()

    private static let saveKey = "saved_conversations"
    private static let ragSettingsKey = "rag_settings"
    private static let defaultSystemPromptKey = "default_system_prompt"

    init() {
        self.wikiEngine = WikiEngine(wikiStore: wikiStore)
        self.wikiLinter = WikiLinter(wikiStore: wikiStore)
        self.wikiEngine.providerRegistry = providers
        self.wikiLinter.providerRegistry = providers
        SharedDataManager.migrateIfNeeded()
        loadRAGSettings()
        loadDefaultSystemPrompt()
        loadFromDisk()
        if conversations.isEmpty {
            _ = createConversation()
        } else {
            for conversation in conversations {
                conversation.wikiEngine = wikiEngine
                conversation.ragSettings = ragSettings
                conversation.orchestrator = orchestrator
                conversation.providerRegistry = providers
                conversation.onChange { [weak self] in self?.saveToDisk() }
            }
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

    /// Provide the SwiftData ModelContainer to the document importer.
    func configureDocumentImporter(with modelContext: ModelContext) {
        documentImporter.configure(with: modelContext.container, wikiEngine: wikiEngine)
    }

    /// Apply the current similarity threshold to the linter and run a
    /// structural pass. Does not invoke the LLM.
    func runStructuralLint() {
        wikiLinter.similarityThreshold = ragSettings.lintSimilarityThreshold
        wikiLinter.runStructuralLint()
    }

    /// Provide the SwiftData ModelContainer to the wiki store. Call from the view layer.
    func configureWikiStore(with modelContext: ModelContext) {
        wikiStore.configure(with: modelContext.container)
    }

    func createConversation() -> ChatViewModel {
        let conversation = ChatViewModel()
        // Seed from the routing rule for chat — falls back to the global
        // default if the user hasn't pinned a chat-specific provider.
        conversation.providerID = providers.providerID(for: .chat)
        conversation.providerRegistry = providers
        conversation.checkAvailability()
        conversation.wikiEngine = wikiEngine
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

    /// Check for and process any pending shared text from the Share Extension or Siri.
    func processPendingSharedContent() {
        // Handle shared text from Share Extension
        if let (text, action) = SharedDataManager.consumePendingSharedText() {
            switch action {
            case .saveAsMemory:
                Task {
                    await wikiStore.createPage(
                        title: String(text.prefix(60)),
                        body: text,
                        tags: Array(SharedDataManager.extractKeywords(from: text, limit: 5)),
                        sourceConversationID: nil
                    )
                }

            case .startConversation:
                let conversation = createConversation()
                Task {
                    await conversation.send(text)
                }
            }
        }

        // Handle pending wiki page from Siri intent
        if let pending = SharedDataManager.consumePendingWikiPage() {
            Task {
                await wikiStore.createPage(
                    title: pending.title,
                    body: pending.body,
                    tags: pending.tags,
                    sourceConversationID: nil
                )
            }
        }
    }

    // MARK: - Storage Statistics

    /// Estimated byte size of persisted conversation data.
    var conversationDataSize: Int {
        let data = try? JSONEncoder().encode(conversations.map { $0.conversationData })
        return data?.count ?? 0
    }

    /// Number of wiki pages in the store.
    var wikiPageCount: Int {
        wikiStore.pages.count
    }

    /// Total approximate on-disk footprint (conversations + imported documents).
    var totalStorageBytes: Int64 {
        Int64(conversationDataSize) + documentImporter.imports.reduce(0) { $0 + $1.fileSize }
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
