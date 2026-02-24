import AppIntents
import FoundationModels

// MARK: - Ask Engram Intent

struct AskChatBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Engram"
    static let description = IntentDescription("Ask an on-device AI question and get a response.")

    @Parameter(title: "Question")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Engram \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = LanguageModelSession {
            "You are a helpful, friendly assistant. Be concise."
        }

        let response = try await session.respond(to: question)
        return .result(dialog: IntentDialog(stringLiteral: response.content))
    }
}

// MARK: - Save Memory Intent

struct SaveMemoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Save a Memory"
    static let description = IntentDescription("Save a piece of information to Engram's memory for future reference.")

    @Parameter(title: "Content")
    var content: String

    @Parameter(title: "Keywords", default: "")
    var keywordsText: String

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$content) to Engram memory") {
            \.$keywordsText
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let keywords: [String]
        if keywordsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keywords = SharedDataManager.extractKeywords(from: content, limit: 5)
        } else {
            keywords = keywordsText.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        }

        let entry = MemoryEntry(content: content, keywords: keywords, sourceConversationTitle: "Siri Shortcut")
        var memories = SharedDataManager.loadMemoriesFromFile()
        guard !memories.contains(where: { $0.content == content }) else {
            return .result(dialog: "This memory already exists.")
        }
        memories.insert(entry, at: 0)
        if memories.count > 100 {
            memories = Array(memories.prefix(100))
        }
        SharedDataManager.saveMemoriesToFile(memories)

        return .result(dialog: "Memory saved with \(keywords.count) keywords.")
    }
}

// MARK: - App Shortcuts Provider

struct ChatBotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskChatBotIntent(),
            phrases: [
                "Ask \(.applicationName) a question"
            ],
            shortTitle: "Ask Engram",
            systemImageName: "bubble.left.and.text.bubble.right"
        )

        AppShortcut(
            intent: SaveMemoryIntent(),
            phrases: [
                "Save a memory in \(.applicationName)"
            ],
            shortTitle: "Save Memory",
            systemImageName: "brain"
        )
    }
}
