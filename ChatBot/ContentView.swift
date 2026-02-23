import SwiftUI
import SwiftData
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Custom Colors

extension Color {
    static var userBubbleColor: Color {
        #if os(iOS) || os(tvOS) || os(visionOS)
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.35, green: 0.58, blue: 1.0, alpha: 1.0)
                : UIColor(red: 0.16, green: 0.47, blue: 1.0, alpha: 1.0)
        })
        #elseif os(macOS)
        return Color(NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.35, green: 0.58, blue: 1.0, alpha: 1.0)
                : NSColor(calibratedRed: 0.16, green: 0.47, blue: 1.0, alpha: 1.0)
        }))
        #else
        return Color(red: 0.16, green: 0.47, blue: 1.0)
        #endif
    }
}

// MARK: - App Constants

enum AppInfo {
    static let name = "Engram"
    static let version = "1.0.0"
    static let build = "1"
}

// MARK: - Content View

struct ContentView: View {
    var store: ConversationStore
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var showingSettings = false
    @State private var renamingConversationID: UUID?
    @State private var renameDraft = ""
    @State private var deletingConversationID: UUID?

    private var groupedConversations: [(String, [ChatViewModel])] {
        let filtered = searchText.isEmpty
            ? store.conversations
            : store.conversations.filter { conversation in
                conversation.title.localizedCaseInsensitiveContains(searchText)
                || conversation.messages.contains {
                    $0.content.localizedCaseInsensitiveContains(searchText)
                }
            }

        let calendar = Calendar.current
        let now = Date()
        var today: [ChatViewModel] = []
        var yesterday: [ChatViewModel] = []
        var thisWeek: [ChatViewModel] = []
        var thisMonth: [ChatViewModel] = []
        var older: [ChatViewModel] = []

        for conversation in filtered {
            if calendar.isDateInToday(conversation.createdAt) {
                today.append(conversation)
            } else if calendar.isDateInYesterday(conversation.createdAt) {
                yesterday.append(conversation)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      conversation.createdAt > weekAgo {
                thisWeek.append(conversation)
            } else if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now),
                      conversation.createdAt > monthAgo {
                thisMonth.append(conversation)
            } else {
                older.append(conversation)
            }
        }

        var groups: [(String, [ChatViewModel])] = []
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { groups.append(("This Week", thisWeek)) }
        if !thisMonth.isEmpty { groups.append(("This Month", thisMonth)) }
        if !older.isEmpty { groups.append(("Older", older)) }
        return groups
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onAppear {
            store.conversations.first?.checkAvailability()
            store.configureOrchestrator(with: modelContext)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(
            get: { store.selectedConversationID },
            set: { store.selectedConversationID = $0 }
        )) {
            ForEach(groupedConversations, id: \.0) { section, conversations in
                Section(section) {
                    ForEach(conversations) { conversation in
                        NavigationLink(value: conversation.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conversation.title)
                                    .lineLimit(1)
                                    .font(.body)
                                HStack(spacing: 4) {
                                    Text(conversation.createdAt, style: .relative)
                                    if !conversation.messages.isEmpty {
                                        Text("·")
                                        Text("\(conversation.messages.count) messages")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button {
                                renameDraft = conversation.title
                                renamingConversationID = conversation.id
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                deletingConversationID = conversation.id
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { conversations[$0].id }
                        let storeOffsets = IndexSet(
                            store.conversations.indices.filter { ids.contains(store.conversations[$0].id) }
                        )
                        store.deleteConversation(at: storeOffsets)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search chats")
        #if os(iOS) || os(tvOS) || os(visionOS)
        .searchToolbarBehavior(.minimize)
        #endif
        .navigationTitle("Chats")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarBottomBar
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store)
        }
        .alert("Rename Chat", isPresented: Binding(
            get: { renamingConversationID != nil },
            set: { if !$0 { renamingConversationID = nil } }
        )) {
            TextField("Chat name", text: $renameDraft)
            Button("Rename") {
                if let id = renamingConversationID {
                    store.renameConversation(id: id, to: renameDraft)
                }
                renamingConversationID = nil
            }
            Button("Cancel", role: .cancel) {
                renamingConversationID = nil
            }
        } message: {
            Text("Enter a new name for this conversation.")
        }
        .alert("Delete Chat?", isPresented: Binding(
            get: { deletingConversationID != nil },
            set: { if !$0 { deletingConversationID = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = deletingConversationID {
                    store.deleteConversation(id: id)
                }
                deletingConversationID = nil
            }
            Button("Cancel", role: .cancel) {
                deletingConversationID = nil
            }
        } message: {
            Text("This conversation will be permanently deleted.")
        }
    }

    private var sidebarBottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")

                Spacer()

                Button {
                    _ = store.createConversation()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                        Text("New Chat")
                            .font(.body.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut("n", modifiers: .command)
                .help("New Chat (⌘N)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let conversation = store.selectedConversation() {
            ChatDetailView(viewModel: conversation)
        } else {
            ContentUnavailableView {
                Label("No Chat Selected", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Select a conversation or create a new one.")
            }
        }
    }
}

// MARK: - Chat Detail View

struct ChatDetailView: View {
    var viewModel: ChatViewModel
    @State private var inputText = ""
    @State private var showingSystemPrompt = false
    @State private var systemPromptDraft = ""
    @State private var showScrollToBottom = false
    @State private var copiedMessageID: UUID?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        Group {
            if !viewModel.isAvailable {
                unavailableView
            } else {
                chatView
            }
        }
        .navigationTitle(viewModel.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                chatMenu
            }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                chatMenu
            }
        }
        #endif
        .sheet(isPresented: $showingSystemPrompt) {
            SystemPromptEditor(
                draft: $systemPromptDraft,
                onSave: { prompt in
                    viewModel.updateSystemPrompt(prompt.isEmpty ? nil : prompt)
                    showingSystemPrompt = false
                },
                onCancel: {
                    showingSystemPrompt = false
                }
            )
        }
        .onAppear {
            viewModel.checkAvailability()
            isInputFocused = true
        }
    }

    private var chatMenu: some View {
        Menu {
            Button {
                systemPromptDraft = viewModel.customSystemPrompt ?? ""
                showingSystemPrompt = true
            } label: {
                Label("System Prompt", systemImage: "person.text.rectangle")
            }

            if !viewModel.messages.isEmpty {
                ShareLink(
                    item: viewModel.exportAsText(),
                    subject: Text(viewModel.title),
                    message: Text("Chat export from \(AppInfo.name)")
                ) {
                    Label("Export Chat", systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            Label("Options", systemImage: "ellipsis.circle")
        }
    }

    private var unavailableView: some View {
        ContentUnavailableView {
            Label("AI Unavailable", systemImage: "cpu")
        } description: {
            Text(viewModel.unavailableReason ?? "On-device AI is not available.")
        }
    }

    private var chatView: some View {
        VStack(spacing: 0) {
            messageList
            workerIndicator
            contextBar
            inputBar
        }
    }

    // MARK: - Worker Indicator

    @ViewBuilder
    private var workerIndicator: some View {
        if let orchestrator = viewModel.orchestrator, orchestrator.hasActiveWorkers {
            HStack(spacing: 4) {
                Image(systemName: "person.2.badge.gearshape")
                    .font(.system(size: 9))
                Text("\(orchestrator.activeTools.count) worker\(orchestrator.activeTools.count == 1 ? "" : "s") available")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.fill.quaternary, in: .capsule)
            .padding(.top, 4)
        }
    }

    // MARK: - Context Bar

    private var contextBar: some View {
        Group {
            if viewModel.contextUsage > 0 {
                VStack(spacing: 2) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 3)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(contextColor)
                                    .frame(width: geo.size.width * viewModel.contextUsage, height: 3)
                                    .animation(.easeInOut(duration: 0.3), value: viewModel.contextUsage)
                            }
                    }
                    .frame(height: 3)

                    if viewModel.contextUsage > 0.6 {
                        Text(contextLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
            }
        }
    }

    private var contextColor: Color {
        if viewModel.contextUsage > 0.85 { return .red }
        if viewModel.contextUsage > 0.6 { return .orange }
        return .accentColor
    }

    private var contextLabel: String {
        let pct = Int(viewModel.contextUsage * 100)
        if viewModel.contextUsage > 0.85 {
            return "Context nearly full (\(pct)%) — will refresh soon"
        }
        return "Context: \(pct)%"
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.messages.isEmpty && viewModel.streamingText.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 12) {
                        if let prompt = viewModel.customSystemPrompt, !prompt.isEmpty {
                            HStack {
                                Image(systemName: "person.text.rectangle")
                                    .font(.caption2)
                                Text(prompt)
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }

                        ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                            let isLastAssistant = message.role == .assistant
                                && index == viewModel.messages.lastIndex(where: { $0.role == .assistant })

                            VStack(spacing: 0) {
                                // Date separator between messages on different days
                                if shouldShowDateSeparator(at: index) {
                                    Text(message.timestamp, format: .dateTime.month(.wide).day().year())
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .padding(.vertical, 8)
                                }

                                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                                    MessageBubble(message: message)

                                    // Timestamp
                                    Text(message.timestamp, format: .dateTime.hour().minute())
                                        .font(.system(size: 10))
                                        .foregroundStyle(.quaternary)
                                        .padding(.horizontal, 4)

                                    // Action row for last assistant message
                                    if isLastAssistant, !viewModel.isResponding {
                                        HStack(spacing: 12) {
                                            // Copy button
                                            Button {
                                                copyToClipboard(message.content)
                                                copiedMessageID = message.id
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                                    if copiedMessageID == message.id {
                                                        copiedMessageID = nil
                                                    }
                                                }
                                            } label: {
                                                Label(
                                                    copiedMessageID == message.id ? "Copied" : "Copy",
                                                    systemImage: copiedMessageID == message.id ? "checkmark" : "doc.on.doc"
                                                )
                                                .font(.caption2)
                                                .foregroundStyle(copiedMessageID == message.id ? .green : .secondary)
                                            }
                                            .buttonStyle(.plain)

                                            // Regenerate button
                                            Button {
                                                let task = Task { await viewModel.regenerateLastResponse() }
                                                viewModel.currentStreamingTask = task
                                            } label: {
                                                Label("Regenerate", systemImage: "arrow.trianglehead.2.clockwise")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.top, 2)
                                    }

                                    // RAG indicator
                                    if isLastAssistant,
                                       let rag = viewModel.lastRAGContext, !rag.isEmpty {
                                        RAGIndicatorView(context: rag)
                                    }
                                }
                            }
                            .id(message.id)
                            .contextMenu {
                                Button {
                                    copyToClipboard(message.content)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }

                                if message.role != .system {
                                    ShareLink(item: message.content) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                }

                                if message.role == .assistant {
                                    Divider()
                                    Button {
                                        let task = Task { await viewModel.regenerateLastResponse() }
                                        viewModel.currentStreamingTask = task
                                    } label: {
                                        Label("Regenerate", systemImage: "arrow.trianglehead.2.clockwise")
                                    }
                                    .disabled(viewModel.isResponding)
                                }
                            }
                        }

                        if viewModel.isWaitingForFirstToken {
                            TypingIndicator()
                                .id("typing")
                        }

                        if !viewModel.streamingText.isEmpty {
                            MessageBubble(message: Message(role: .assistant, content: viewModel.streamingText))
                                .id("streaming")
                        }

                        // Invisible anchor at the very bottom
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding()
                }
            }
            .onChange(of: viewModel.messages.count) {
                showScrollToBottom = false
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.streamingText) {
                if !showScrollToBottom {
                    scrollToBottom(proxy: proxy)
                }
            }
            .onChange(of: viewModel.isWaitingForFirstToken) {
                if viewModel.isWaitingForFirstToken {
                    showScrollToBottom = false
                    scrollToBottom(proxy: proxy)
                }
            }
            .overlay(alignment: .bottom) {
                if showScrollToBottom {
                    Button {
                        showScrollToBottom = false
                        scrollToBottom(proxy: proxy)
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .background(.ultraThickMaterial, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                // true when user has scrolled up significantly
                let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                return distanceFromBottom > 100
            } action: { _, isScrolledUp in
                withAnimation(.easeInOut(duration: 0.2)) {
                    showScrollToBottom = isScrolledUp
                }
            }
        }
    }

    private func shouldShowDateSeparator(at index: Int) -> Bool {
        guard index > 0 else {
            // Always show for the first message
            return true
        }
        let current = viewModel.messages[index].timestamp
        let previous = viewModel.messages[index - 1].timestamp
        return !Calendar.current.isDate(current, inSameDayAs: previous)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if !viewModel.streamingText.isEmpty {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if viewModel.isWaitingForFirstToken {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let last = viewModel.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Start a conversation")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Messages are processed entirely on-device.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if viewModel.customSystemPrompt == nil {
                Button("Set a custom persona") {
                    systemPromptDraft = ""
                    showingSystemPrompt = true
                }
                .buttonStyle(.glass)
                .font(.caption)
                .padding(.top, 4)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Input

    private var inputBar: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                TextField("Message", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .disabled(viewModel.isResponding)
                    .onSubmit { sendMessage() }
                    #if os(macOS)
                    .onKeyPress(.return, phases: .down) { event in
                        if event.modifiers.contains(.command) {
                            sendMessage()
                            return .handled
                        }
                        return .ignored
                    }
                    #endif
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                if viewModel.isResponding {
                    Button {
                        viewModel.stopGenerating()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .symbolEffect(.pulse)
                    }
                    .glassEffect(.regular.tint(.red).interactive(), in: .circle)
                    .help("Stop Generating")
                } else {
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    #if os(macOS)
                    .keyboardShortcut(.return, modifiers: .command)
                    #endif
                    .help("Send (⌘Return)")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !viewModel.isResponding else { return }
        inputText = ""
        let task = Task {
            await viewModel.send(text)
        }
        viewModel.currentStreamingTask = task
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS) || os(tvOS) || os(visionOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .scaleEffect(dotScale(for: index))
                        .opacity(dotOpacity(for: index))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.fill.tertiary, in: .rect(cornerRadius: 18))

            Spacer(minLength: 48)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = 1.0
            }
        }
    }

    private func dotScale(for index: Int) -> Double {
        let delay = Double(index) * 0.15
        let adjusted = max(0, phase - delay)
        return 0.5 + adjusted * 0.5
    }

    private func dotOpacity(for index: Int) -> Double {
        let delay = Double(index) * 0.15
        let adjusted = max(0, phase - delay)
        return 0.3 + adjusted * 0.7
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            if message.role == .system {
                systemBubble
            } else {
                messageContent
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground, in: .rect(cornerRadius: 18))
                    .foregroundStyle(message.role == .user ? .white : .primary)
            }

            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        if let attributed = try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
                .textSelection(.enabled)
        } else {
            Text(message.content)
                .textSelection(.enabled)
        }
    }

    private var bubbleBackground: some ShapeStyle {
        if message.role == .user {
            return AnyShapeStyle(Color.userBubbleColor)
        } else {
            return AnyShapeStyle(.fill.tertiary)
        }
    }

    private var systemBubble: some View {
        HStack(spacing: 6) {
            Image(systemName: message.content.contains("Context refreshed")
                  ? "arrow.triangle.2.circlepath"
                  : "info.circle")
                .font(.caption2)
            Text(message.content)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.fill.quaternary, in: .capsule)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

// MARK: - RAG Indicator

struct RAGIndicatorView: View {
    let context: RAGContext

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 9))
            Text(context.summary)
                .font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.fill.quaternary, in: .capsule)
    }
}

// MARK: - System Prompt Editor

struct SystemPromptEditor: View {
    @Binding var draft: String
    var onSave: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. You are a Python tutor...", text: $draft, axis: .vertical)
                        .lineLimit(3...10)
                } header: {
                    Text("Custom Instructions")
                } footer: {
                    Text("Defines the assistant's personality and behavior for this conversation. Changing this resets the model's context.")
                }
            }
            .navigationTitle("System Prompt")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft) }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Settings View

struct SettingsView: View {
    var store: ConversationStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteAllConfirmation = false
    @State private var showingMemories = false
    @State private var showingKnowledgeBases = false
    @State private var showingWorkers = false
    @State private var defaultPromptDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Intelligence
                Section {
                    Button {
                        showingMemories = true
                    } label: {
                        HStack {
                            Label("Memories", systemImage: "brain")
                            Spacer()
                            Text("\(store.memoryStore.memories.count)")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        showingKnowledgeBases = true
                    } label: {
                        HStack {
                            Label("Knowledge Bases", systemImage: "books.vertical")
                            Spacer()
                            Text("\(store.knowledgeBaseStore.knowledgeBases.count)")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        showingWorkers = true
                    } label: {
                        HStack {
                            Label("Workers", systemImage: "person.2.badge.gearshape")
                            Spacer()
                            Text("\(store.orchestrator.activeTools.count)")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Intelligence")
                } footer: {
                    Text("Memories are extracted from conversations. Knowledge bases are imported documents. Workers are specialized AI personas for task delegation.")
                }

                // MARK: Retrieval
                Section {
                    Toggle("Memory Retrieval", isOn: Binding(
                        get: { store.ragSettings.memoryRetrievalEnabled },
                        set: { newValue in
                            store.ragSettings.memoryRetrievalEnabled = newValue
                            store.applyRAGSettings()
                        }
                    ))

                    Toggle("Document Retrieval", isOn: Binding(
                        get: { store.ragSettings.knowledgeBaseRetrievalEnabled },
                        set: { newValue in
                            store.ragSettings.knowledgeBaseRetrievalEnabled = newValue
                            store.applyRAGSettings()
                        }
                    ))

                    Toggle("Auto-Extract Memories", isOn: Binding(
                        get: { store.ragSettings.autoExtractMemories },
                        set: { newValue in
                            store.ragSettings.autoExtractMemories = newValue
                            store.applyRAGSettings()
                        }
                    ))

                    Stepper(
                        "Memory results: \(store.ragSettings.maxMemoryResults)",
                        value: Binding(
                            get: { store.ragSettings.maxMemoryResults },
                            set: { newValue in
                                store.ragSettings.maxMemoryResults = newValue
                                store.applyRAGSettings()
                            }
                        ),
                        in: 1...10
                    )

                    Stepper(
                        "Document chunks: \(store.ragSettings.maxDocumentChunks)",
                        value: Binding(
                            get: { store.ragSettings.maxDocumentChunks },
                            set: { newValue in
                                store.ragSettings.maxDocumentChunks = newValue
                                store.applyRAGSettings()
                            }
                        ),
                        in: 1...5
                    )
                } header: {
                    Text("Retrieval")
                } footer: {
                    Text("More results use more of the limited context window.")
                }

                // MARK: System Prompt
                Section {
                    TextField("e.g. You are a helpful coding assistant...", text: $defaultPromptDraft, axis: .vertical)
                        .lineLimit(2...6)
                        .onChange(of: defaultPromptDraft) { oldValue, newValue in
                            // Skip the initial set from onAppear
                            guard oldValue != newValue, !oldValue.isEmpty || !newValue.isEmpty else { return }
                            store.defaultSystemPrompt = newValue
                            store.applyDefaultSystemPrompt()
                        }
                } header: {
                    Text("Default System Prompt")
                } footer: {
                    Text("Applied to new conversations. Individual chats can override this.")
                }

                // MARK: Data
                Section {
                    Button(role: .destructive) {
                        showingDeleteAllConfirmation = true
                    } label: {
                        Label("Delete All Chats", systemImage: "trash")
                    }
                    .disabled(store.conversations.isEmpty)
                } header: {
                    Text("Data")
                }

                // MARK: About
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        HStack {
                            Label("About \(AppInfo.name)", systemImage: "info.circle")
                            Spacer()
                            Text("v\(AppInfo.version)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                defaultPromptDraft = store.defaultSystemPrompt
            }
            .alert("Delete All Chats?", isPresented: $showingDeleteAllConfirmation) {
                Button("Delete All", role: .destructive) {
                    store.deleteAllConversations()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all conversations. Memories and knowledge bases will be kept.")
            }
            .sheet(isPresented: $showingMemories) {
                MemoryListView(memoryStore: store.memoryStore)
            }
            .sheet(isPresented: $showingKnowledgeBases) {
                KnowledgeBaseListView(knowledgeBaseStore: store.knowledgeBaseStore)
            }
            .sheet(isPresented: $showingWorkers) {
                WorkerLibraryView(orchestrator: store.orchestrator)
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 540, idealHeight: 600)
        #endif
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)

                    Text(AppInfo.name)
                        .font(.title.bold())

                    Text("v\(AppInfo.version) (\(AppInfo.build))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section {
                Text("\(AppInfo.name) is an on-device AI assistant powered by Apple Intelligence. All conversations are processed entirely on your device — nothing is sent to external servers.")
                    .font(.subheadline)
            } header: {
                Text("What is \(AppInfo.name)?")
            }

            Section {
                FeatureRow(icon: "lock.shield", title: "Fully Private", detail: "All AI processing happens on-device using Apple Foundation Models")
                FeatureRow(icon: "brain", title: "Persistent Memory", detail: "Remembers key facts across conversations using RAG")
                FeatureRow(icon: "books.vertical", title: "Knowledge Bases", detail: "Import PDF and ePUB documents as reference material")
                FeatureRow(icon: "bubble.left.and.bubble.right", title: "Multi-Conversation", detail: "Manage multiple independent chat threads")
                FeatureRow(icon: "arrow.triangle.2.circlepath", title: "Smart Context", detail: "Automatic context rotation with summarization when nearing limits")
                FeatureRow(icon: "person.text.rectangle", title: "Custom Personas", detail: "Set per-conversation or default system prompts")
                FeatureRow(icon: "square.and.arrow.up", title: "Share Extension", detail: "Send text from any app directly into a chat or memory")
                FeatureRow(icon: "wand.and.stars", title: "Siri Integration", detail: "Ask questions or save memories via Siri Shortcuts")
            } header: {
                Text("Key Features")
            }

            Section {
                ChangelogEntry(version: "1.0.0", date: "February 2026", changes: [
                    "Initial release",
                    "On-device AI chat with Apple Foundation Models",
                    "Multi-conversation management with sidebar",
                    "RAG memory system with keyword-based retrieval",
                    "PDF and ePUB document ingestion for knowledge bases",
                    "iOS 26 Liquid Glass design",
                    "Share Extension and Siri Shortcuts",
                    "Cross-platform support (iOS, iPadOS, macOS)"
                ])
            } header: {
                Text("Changelog")
            }

            Section {
                HStack {
                    Text("AI Processing")
                    Spacer()
                    Text("On-Device Only")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Framework")
                    Spacer()
                    Text("Apple Foundation Models")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Platform")
                    Spacer()
                    Text(platformName)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Technical")
            } footer: {
                Text("No data ever leaves your device. \(AppInfo.name) requires Apple Intelligence to be enabled.")
            }
        }
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var platformName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ChangelogEntry: View {
    let version: String
    let date: String
    let changes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("v\(version)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(changes, id: \.self) { change in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(change)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Memory Editor View (Add & Edit)

struct MemoryEditorView: View {
    var memoryStore: MemoryStore
    var existing: MemoryEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var keywordsText = ""
    @State private var autoKeywords: [String] = []

    private var isEditing: Bool { existing != nil }
    private var title: String { isEditing ? "Edit Memory" : "New Memory" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What would you like to remember?", text: $content, axis: .vertical)
                        .lineLimit(3...10)
                        .onChange(of: content) {
                            updateAutoKeywords()
                        }
                } header: {
                    Text("Content")
                }

                Section {
                    #if os(iOS) || os(tvOS) || os(visionOS)
                    TextField("swift, coding, preference", text: $keywordsText)
                        .textInputAutocapitalization(.never)
                    #else
                    TextField("swift, coding, preference", text: $keywordsText)
                    #endif
                } header: {
                    Text("Keywords")
                } footer: {
                    if keywordsText.trimmingCharacters(in: .whitespaces).isEmpty {
                        if !autoKeywords.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Auto-detected keywords:")
                                FlowLayout(spacing: 4) {
                                    ForEach(autoKeywords, id: \.self) { keyword in
                                        Text(keyword)
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(.fill.tertiary, in: .capsule)
                                    }
                                }
                            }
                        } else {
                            Text("Leave blank to auto-detect from content.")
                        }
                    }
                }

                if isEditing, let entry = existing {
                    Section {
                        LabeledContent("Source", value: entry.sourceConversationTitle)
                        LabeledContent("Created", value: entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    } header: {
                        Text("Info")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .bold()
                        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let entry = existing {
                    content = entry.content
                    keywordsText = entry.keywords.joined(separator: ", ")
                }
                updateAutoKeywords()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func updateAutoKeywords() {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 10 {
            autoKeywords = SharedDataManager.extractKeywords(from: text, limit: 5)
        } else {
            autoKeywords = []
        }
    }

    private func save() {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }

        let keywords: [String]
        let trimmedKeywords = keywordsText.trimmingCharacters(in: .whitespaces)
        if trimmedKeywords.isEmpty {
            keywords = SharedDataManager.extractKeywords(from: trimmedContent, limit: 5)
        } else {
            keywords = trimmedKeywords.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        }

        if let entry = existing {
            memoryStore.updateMemory(entry, content: trimmedContent, keywords: keywords)
        } else {
            memoryStore.addMemory(trimmedContent, keywords: keywords, source: "Manual Entry")
        }
        dismiss()
    }
}

// MARK: - Flow Layout (for keyword pills)

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? 0, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}

// MARK: - Memory List View

struct MemoryListView: View {
    var memoryStore: MemoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteAllConfirmation = false
    @State private var showingAddMemory = false
    @State private var editingMemory: MemoryEntry?

    var body: some View {
        NavigationStack {
            memoryContent
                .navigationTitle("Memories")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAddMemory = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("Add Memory")
                    }
                    ToolbarItem(placement: .automatic) {
                        if !memoryStore.memories.isEmpty {
                            Button(role: .destructive) {
                                showingDeleteAllConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("Clear All Memories")
                        }
                    }
                }
                .alert("Clear All Memories?", isPresented: $showingDeleteAllConfirmation) {
                    Button("Clear All", role: .destructive) {
                        memoryStore.deleteAllMemories()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently delete all saved memories.")
                }
                .sheet(isPresented: $showingAddMemory) {
                    MemoryEditorView(memoryStore: memoryStore)
                }
                .sheet(item: $editingMemory) { memory in
                    MemoryEditorView(memoryStore: memoryStore, existing: memory)
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 400, idealHeight: 560)
        #endif
    }

    @ViewBuilder
    private var memoryContent: some View {
        if memoryStore.memories.isEmpty {
            ContentUnavailableView {
                Label("No Memories", systemImage: "brain")
            } description: {
                Text("Memories are automatically created when conversations get long, or you can add them manually.")
            } actions: {
                Button {
                    showingAddMemory = true
                } label: {
                    Text("Add Memory")
                }
            }
        } else {
            List {
                ForEach(memoryStore.memories) { memory in
                    Button {
                        editingMemory = memory
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(memory.content)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(3)

                            if !memory.keywords.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(memory.keywords.prefix(4), id: \.self) { keyword in
                                        Text(keyword)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.fill.tertiary, in: .capsule)
                                    }
                                }
                            }

                            HStack(spacing: 4) {
                                Text(memory.sourceConversationTitle)
                                Text("·")
                                Text(memory.createdAt, style: .relative)
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                    .contextMenu {
                        Button {
                            editingMemory = memory
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            memoryStore.deleteMemory(memory)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    let toDelete = offsets.map { memoryStore.memories[$0] }
                    for entry in toDelete {
                        memoryStore.deleteMemory(entry)
                    }
                }
            }
        }
    }
}

// MARK: - Knowledge Base List View

struct KnowledgeBaseListView: View {
    var knowledgeBaseStore: KnowledgeBaseStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingImporter = false
    @State private var showingDeleteAllConfirmation = false

    var body: some View {
        NavigationStack {
            kbContent
                .navigationTitle("Knowledge Bases")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingImporter = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(knowledgeBaseStore.isProcessing)
                        .help("Import Document")
                    }
                    ToolbarItem(placement: .automatic) {
                        if !knowledgeBaseStore.knowledgeBases.isEmpty {
                            Button(role: .destructive) {
                                showingDeleteAllConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("Delete All Knowledge Bases")
                        }
                    }
                }
                .fileImporter(
                    isPresented: $showingImporter,
                    allowedContentTypes: [.pdf, .epub],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        Task {
                            await knowledgeBaseStore.ingestDocument(from: url)
                        }
                    }
                }
                .alert("Delete All Knowledge Bases?", isPresented: $showingDeleteAllConfirmation) {
                    Button("Delete All", role: .destructive) {
                        knowledgeBaseStore.deleteAllKnowledgeBases()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently delete all imported documents and their chunks.")
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 400, idealHeight: 560)
        #endif
    }

    @ViewBuilder
    private var kbContent: some View {
        if knowledgeBaseStore.knowledgeBases.isEmpty && !knowledgeBaseStore.isProcessing {
            ContentUnavailableView {
                Label("No Knowledge Bases", systemImage: "books.vertical")
            } description: {
                Text("Import PDF or ePUB documents to give the assistant knowledge about specific topics.")
            } actions: {
                Button {
                    showingImporter = true
                } label: {
                    Text("Import Document")
                }
            }
        } else {
            List {
                if knowledgeBaseStore.isProcessing {
                    Section {
                        VStack(spacing: 8) {
                            ProgressView(value: knowledgeBaseStore.processingProgress)
                            Text("Processing document…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let error = knowledgeBaseStore.processingError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                ForEach(knowledgeBaseStore.knowledgeBases) { kb in
                    NavigationLink {
                        KnowledgeBaseDetailView(kb: kb, store: knowledgeBaseStore)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kb.documentType.icon)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(kb.name)
                                    .font(.body)
                                    .lineLimit(1)

                                HStack(spacing: 4) {
                                    Text(kb.documentType.label)
                                    Text("·")
                                    Text("\(kb.chunkCount) chunks")
                                    Text("·")
                                    Text(ByteCountFormatter.string(fromByteCount: kb.fileSize, countStyle: .file))
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            knowledgeBaseStore.deleteKnowledgeBase(kb)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    let toDelete = offsets.map { knowledgeBaseStore.knowledgeBases[$0] }
                    for kb in toDelete {
                        knowledgeBaseStore.deleteKnowledgeBase(kb)
                    }
                }
            }
        }
    }
}

// MARK: - Knowledge Base Detail View

struct KnowledgeBaseDetailView: View {
    let kb: KnowledgeBase
    var store: KnowledgeBaseStore

    var body: some View {
        List {
            Section {
                LabeledContent("Type", value: kb.documentType.label)
                LabeledContent("Chunks", value: "\(kb.chunkCount)")
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: kb.fileSize, countStyle: .file))
                LabeledContent("Imported", value: kb.createdAt.formatted(date: .abbreviated, time: .shortened))
            } header: {
                Text("Details")
            }

            Section {
                let chunks = store.previewChunks(for: kb.id, limit: 5)
                if chunks.isEmpty {
                    Text("No chunks available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(chunks) { chunk in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chunk.locationLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(chunk.content)
                                .font(.caption2)
                                .lineLimit(4)
                            if !chunk.keywords.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(chunk.keywords.prefix(4), id: \.self) { kw in
                                        Text(kw)
                                            .font(.system(size: 9))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(.fill.tertiary, in: .capsule)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Content Preview")
            }
        }
        .navigationTitle(kb.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Preview

#Preview {
    ContentView(store: ConversationStore())
}
