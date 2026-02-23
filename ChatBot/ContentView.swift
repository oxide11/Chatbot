import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Custom Colors

extension ShapeStyle where Self == Color {
    static var userBubble: Color { Color("UserBubble", bundle: nil) }
}

// Fallback if asset color isn't set — define it programmatically
extension Color {
    // Cross-platform dynamic color without relying on UIColor/NSColor initializers
    static var userBubbleColor: Color {
        #if os(iOS) || os(tvOS) || os(visionOS)
        // Use dynamic provider via UIColor when available
        if let uiColorType = UIColor.self as Any? {
            // Provide light/dark variants
            return Color(UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.35, green: 0.58, blue: 1.0, alpha: 1.0)
                    : UIColor(red: 0.16, green: 0.47, blue: 1.0, alpha: 1.0)
            })
        }
        #endif
        #if os(macOS)
        return Color(NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.35, green: 0.58, blue: 1.0, alpha: 1.0)
                : NSColor(calibratedRed: 0.16, green: 0.47, blue: 1.0, alpha: 1.0)
        }))
        #else
        // Fallback: return light color if dynamic not supported
        return Color(red: 0.16, green: 0.47, blue: 1.0)
        #endif
    }
}

// MARK: - Content View

struct ContentView: View {
    var store: ConversationStore
    @State private var searchText = ""
    @State private var showingSystemPromptEditor = false
    @State private var showingSettings = false

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
                            Button(role: .destructive) {
                                store.deleteConversation(id: conversation.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { offsets in
                        // Map section offsets back to store offsets
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
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .navigation) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            #else
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            #endif

            #if os(macOS)
            ToolbarItem(placement: .automatic) {
                Button {
                    _ = store.createConversation()
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
            }
            #else
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    _ = store.createConversation()
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
            }
            #endif
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store)
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
        .toolbar {
            ToolbarItem(placement: .automatic) {
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
                            message: Text("Chat export from ChatBot")
                        ) {
                            Label("Export Chat", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }
        }
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
            contextBar
            inputBar
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

                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                                .contextMenu {
                                    Button {
                                        #if os(iOS) || os(tvOS) || os(visionOS)
                                        UIPasteboard.general.string = message.content
                                        #elseif os(macOS)
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(message.content, forType: .string)
                                        #endif
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }

                                    if message.role != .system {
                                        ShareLink(item: message.content) {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                    }
                                }
                        }

                        // Typing indicator
                        if viewModel.isWaitingForFirstToken {
                            TypingIndicator()
                                .id("typing")
                        }

                        // Streaming partial response
                        if !viewModel.streamingText.isEmpty {
                            MessageBubble(message: Message(role: .assistant, content: viewModel.streamingText))
                                .id("streaming")
                        }
                    }
                    .padding()
                }
            }
            .onChange(of: viewModel.messages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.streamingText) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.isWaitingForFirstToken) {
                if viewModel.isWaitingForFirstToken {
                    scrollToBottom(proxy: proxy)
                }
            }
        }
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: viewModel.isResponding ? "ellipsis.circle" : "arrow.up.circle.fill")
                        .font(.title2)
                        .symbolEffect(.pulse, isActive: viewModel.isResponding)
                }
                .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isResponding)
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
        Task {
            await viewModel.send(text)
        }
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
        // Attempt Markdown rendering; fall back to plain text
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
        Text(message.content)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
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
                    Text("Defines the assistant's personality and behavior. Changing this resets the model's memory of this conversation.")
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
    @State private var showingMemories = false
    @State private var showingKnowledgeBases = false
    @State private var showingDeleteAllConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingMemories = true
                    } label: {
                        Label {
                            HStack {
                                Text("Memories")
                                Spacer()
                                Text("\(store.memoryStore.memories.count)")
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "brain")
                        }
                    }

                    Button {
                        showingKnowledgeBases = true
                    } label: {
                        Label {
                            HStack {
                                Text("Knowledge Bases")
                                Spacer()
                                Text("\(store.knowledgeBaseStore.knowledgeBases.count)")
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "books.vertical")
                        }
                    }
                } header: {
                    Text("Data")
                }

                Section {
                    Button(role: .destructive) {
                        showingDeleteAllConfirmation = true
                    } label: {
                        Label("Delete All Chats", systemImage: "trash")
                    }
                    .disabled(store.conversations.isEmpty)
                }

                Section {
                    HStack {
                        Text("App")
                        Spacer()
                        Text("ChatBot")
                            .foregroundStyle(.secondary)
                    }
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
                } header: {
                    Text("About")
                } footer: {
                    Text("All conversations are processed entirely on-device using Apple Intelligence. No data leaves your device.")
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete All Chats?", isPresented: $showingDeleteAllConfirmation) {
                Button("Delete All", role: .destructive) {
                    store.deleteAllConversations()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all conversations. Memories will be kept.")
            }
            .sheet(isPresented: $showingMemories) {
                MemoryListView(memoryStore: store.memoryStore)
            }
            .sheet(isPresented: $showingKnowledgeBases) {
                KnowledgeBaseListView(knowledgeBaseStore: store.knowledgeBaseStore)
            }
        }
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
            VStack(spacing: 0) {
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
            }
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
            Group {
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
            .navigationTitle("Memories")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                #if os(macOS)
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 12) {
                        if !memoryStore.memories.isEmpty {
                            Button("Clear All", role: .destructive) {
                                showingDeleteAllConfirmation = true
                            }
                            .foregroundStyle(.red)
                        }
                        Button {
                            showingAddMemory = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
                #else
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if !memoryStore.memories.isEmpty {
                            Button("Clear All", role: .destructive) {
                                showingDeleteAllConfirmation = true
                            }
                            .foregroundStyle(.red)
                        }
                        Button {
                            showingAddMemory = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
                #endif
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
    }
}

// MARK: - Knowledge Base List View

struct KnowledgeBaseListView: View {
    var knowledgeBaseStore: KnowledgeBaseStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingImporter = false
    @State private var showingDeleteAllConfirmation = false
    @State private var selectedKB: KnowledgeBase?

    var body: some View {
        NavigationStack {
            Group {
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
                                    Text("Processing document...")
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
                            Button {
                                selectedKB = kb
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: kb.documentType.icon)
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 32)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(kb.name)
                                            .font(.body)
                                            .foregroundStyle(.primary)
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
            .navigationTitle("Knowledge Bases")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if !knowledgeBaseStore.knowledgeBases.isEmpty {
                            Button("Clear All", role: .destructive) {
                                showingDeleteAllConfirmation = true
                            }
                            .foregroundStyle(.red)
                        }
                        Button {
                            showingImporter = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(knowledgeBaseStore.isProcessing)
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
            .sheet(item: $selectedKB) { kb in
                KnowledgeBaseDetailView(kb: kb, store: knowledgeBaseStore)
            }
        }
    }
}

// MARK: - Knowledge Base Detail View

struct KnowledgeBaseDetailView: View {
    let kb: KnowledgeBase
    var store: KnowledgeBaseStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Preview

#Preview {
    ContentView(store: ConversationStore())
}
