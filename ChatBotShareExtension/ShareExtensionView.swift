import SwiftUI

/// SwiftUI view presented inside the Share Extension.
/// Lets the user choose to save shared text as a memory or start a new conversation.
struct ShareExtensionView: View {
    let sharedText: String
    let onDone: () -> Void
    let onOpenApp: () -> Void

    @State private var selectedAction: SharedDataManager.SharedAction = .saveAsMemory
    @State private var keywordsText = ""
    @State private var autoKeywords: [String] = []
    @State private var isSaved = false

    var body: some View {
        NavigationStack {
            Form {
                // Preview of shared content
                Section {
                    Text(sharedText)
                        .font(.body)
                        .lineLimit(6)
                        .foregroundStyle(.primary)
                } header: {
                    Text("Shared Content")
                }

                // Action picker
                Section {
                    Picker("Action", selection: $selectedAction) {
                        Label("Save as Memory", systemImage: "brain")
                            .tag(SharedDataManager.SharedAction.saveAsMemory)
                        Label("Start Conversation", systemImage: "bubble.left.and.text.bubble.right")
                            .tag(SharedDataManager.SharedAction.startConversation)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("What would you like to do?")
                }

                // Keywords section (only for memory action)
                if selectedAction == .saveAsMemory {
                    Section {
                        TextField("e.g. article, research, topic", text: $keywordsText)
                            .textInputAutocapitalization(.never)

                        if !autoKeywords.isEmpty && keywordsText.trimmingCharacters(in: .whitespaces).isEmpty {
                            HStack(spacing: 4) {
                                Text("Suggested:")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                ForEach(autoKeywords, id: \.self) { keyword in
                                    Text(keyword)
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.fill.tertiary, in: .capsule)
                                }
                            }
                        }
                    } header: {
                        Text("Keywords (optional)")
                    } footer: {
                        Text("Comma-separated keywords help the assistant find this memory later.")
                    }
                }

                // Confirmation
                if isSaved {
                    Section {
                        Label(
                            selectedAction == .saveAsMemory
                                ? "Memory saved successfully!"
                                : "Content queued — open ChatBot to continue.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Share to ChatBot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selectedAction == .saveAsMemory ? "Save" : "Send") {
                        performAction()
                    }
                    .disabled(isSaved)
                }
            }
            .onAppear {
                // Auto-extract keywords from shared text
                autoKeywords = SharedDataManager.extractKeywords(from: sharedText, limit: 5)
            }
        }
    }

    private func performAction() {
        switch selectedAction {
        case .saveAsMemory:
            // Save directly to shared UserDefaults
            let keywords: [String]
            let trimmed = keywordsText.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                keywords = SharedDataManager.extractKeywords(from: sharedText, limit: 5)
            } else {
                keywords = trimmed.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
            }

            let entry = MemoryEntry(
                content: sharedText,
                keywords: keywords,
                sourceConversationTitle: "Shared Content"
            )
            var memories = SharedDataManager.loadMemories()
            guard !memories.contains(where: { $0.content == sharedText }) else {
                isSaved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { onDone() }
                return
            }
            memories.insert(entry, at: 0)
            if memories.count > 100 {
                memories = Array(memories.prefix(100))
            }
            SharedDataManager.saveMemories(memories)

            isSaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { onDone() }

        case .startConversation:
            // Queue text for main app to pick up
            SharedDataManager.setPendingSharedText(sharedText, action: .startConversation)
            isSaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onOpenApp() }
        }
    }
}
