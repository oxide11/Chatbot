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
        // Siri answers are spoken — keep them short and avoid markdown / code
        // blocks / LaTeX (Siri reads them literally). The chat-default
        // persona used inside the app is more permissive about formatting.
        let session = LanguageModelSession {
            """
            You are Engram, answering via Siri. Be concise — under 40 words. \
            Plain spoken English: no markdown, no code blocks, no LaTeX, no lists. \
            If you don't know, say so in one sentence.
            """
        }

        let response = try await session.respond(to: question)
        return .result(dialog: IntentDialog(stringLiteral: response.content))
    }
}

// MARK: - Save to Wiki Intent

struct SaveToWikiIntent: AppIntent {
    static let title: LocalizedStringResource = "Save to Wiki"
    static let description = IntentDescription("Save a piece of information to Engram's wiki for future reference.")

    @Parameter(title: "Title")
    var pageTitle: String

    @Parameter(title: "Content")
    var content: String

    @Parameter(title: "Tags", default: "")
    var tagsText: String

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$pageTitle) to Engram wiki") {
            \.$content
            \.$tagsText
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tags: [String]
        if tagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tags = SharedDataManager.extractKeywords(from: "\(pageTitle) \(content)", limit: 5)
        } else {
            tags = tagsText.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        }

        SharedDataManager.savePendingWikiPage(title: pageTitle, body: content, tags: tags)
        return .result(dialog: "Wiki page '\(pageTitle)' saved with \(tags.count) tags.")
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
            intent: SaveToWikiIntent(),
            phrases: [
                "Save to wiki in \(.applicationName)"
            ],
            shortTitle: "Save to Wiki",
            systemImageName: "book.pages"
        )
    }
}
