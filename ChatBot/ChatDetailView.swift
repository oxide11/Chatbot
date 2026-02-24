//
//  ChatDetailView.swift
//  ChatBot
//
//  Main chat interface view with message list, input bar, and message actions.
//  Includes typing indicator, message bubble, RAG/worker indicators, and system prompt editor.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Chat Detail View

struct ChatDetailView: View {
    var viewModel: ChatViewModel
    @State private var inputText = ""
    @State private var showingSystemPrompt = false
    @State private var systemPromptDraft = ""
    @State private var showScrollToBottom = false
    @State private var copiedMessageID: UUID?
    @State private var editingMessageID: UUID?
    @State private var editDraft = ""
    @State private var searchText = ""
    @State private var isSearching = false
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
                DomainPickerMenu(
                    domains: viewModel.knowledgeBaseStore?.domains ?? [],
                    selectedDomainID: Binding(
                        get: { viewModel.domainID },
                        set: { newID in
                            viewModel.domainID = newID
                            viewModel.notifyChanged()
                        }
                    )
                )
            }
            ToolbarItem(placement: .automatic) {
                chatMenu
            }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                DomainPickerMenu(
                    domains: viewModel.knowledgeBaseStore?.domains ?? [],
                    selectedDomainID: Binding(
                        get: { viewModel.domainID },
                        set: { newID in
                            viewModel.domainID = newID
                            viewModel.notifyChanged()
                        }
                    )
                )
            }
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

            Button {
                withAnimation { isSearching.toggle() }
                if !isSearching { searchText = "" }
            } label: {
                Label(isSearching ? "Close Search" : "Search Messages", systemImage: "magnifyingglass")
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
            if isSearching {
                searchBar
            }
            messageList
            workerIndicator
            contextBar
            inputBar
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search messages…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button("Done") {
                withAnimation {
                    isSearching = false
                    searchText = ""
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Messages filtered by search text.
    private var filteredMessages: [Message] {
        if searchText.isEmpty { return viewModel.messages }
        return viewModel.messages.filter {
            $0.content.localizedCaseInsensitiveContains(searchText)
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

                        ForEach(Array(filteredMessages.enumerated()), id: \.element.id) { index, message in
                            let isLastAssistant = message.role == .assistant
                                && message.id == viewModel.messages.last(where: { $0.role == .assistant })?.id

                            VStack(spacing: 0) {
                                // Date separator between messages on different days
                                if searchText.isEmpty, shouldShowDateSeparator(at: index, in: filteredMessages) {
                                    Text(message.timestamp, format: .dateTime.month(.wide).day().year())
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .padding(.vertical, 8)
                                }

                                // Inline edit mode
                                if editingMessageID == message.id {
                                    editBubble(for: message)
                                } else {
                                    VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                                        MessageBubble(message: message, highlightText: searchText)

                                        // Timestamp
                                        Text(message.timestamp, format: .dateTime.hour().minute())
                                            .font(.system(size: 10))
                                            .foregroundStyle(.quaternary)
                                            .padding(.horizontal, 4)

                                        // Action row for last assistant message
                                        if isLastAssistant, !viewModel.isResponding {
                                            HStack(spacing: 12) {
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

                                        // Worker invocation indicator
                                        if isLastAssistant, !viewModel.lastWorkerInvocations.isEmpty {
                                            WorkerInvocationView(workerNames: viewModel.lastWorkerInvocations)
                                        }
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

                                if message.role == .user {
                                    Button {
                                        editDraft = message.content
                                        editingMessageID = message.id
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
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

                                Divider()
                                Button(role: .destructive) {
                                    viewModel.deleteMessage(message)
                                } label: {
                                    Label("Delete", systemImage: "trash")
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
                let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                return distanceFromBottom > 100
            } action: { _, isScrolledUp in
                withAnimation(.easeInOut(duration: 0.2)) {
                    showScrollToBottom = isScrolledUp
                }
            }
        }
    }

    // MARK: - Inline Message Editing

    private func editBubble(for message: Message) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Edit message", text: $editDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.userBubbleColor.opacity(0.2), in: .rect(cornerRadius: 18))

            HStack(spacing: 12) {
                Button("Cancel") {
                    editingMessageID = nil
                    editDraft = ""
                }
                .font(.caption)

                Button("Save & Resend") {
                    let newText = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !newText.isEmpty else { return }
                    editingMessageID = nil
                    editDraft = ""
                    viewModel.editAndResend(message, newContent: newText)
                }
                .font(.caption.bold())
                .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.leading, 48)
    }

    private func shouldShowDateSeparator(at index: Int, in messages: [Message]) -> Bool {
        guard index > 0 else { return true }
        let current = messages[index].timestamp
        let previous = messages[index - 1].timestamp
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
    var highlightText: String = ""

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

// MARK: - Worker Invocation Indicator

struct WorkerInvocationView: View {
    let workerNames: [String]

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.system(size: 9))
            Text(summary)
                .font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.fill.quaternary, in: .capsule)
    }

    private var summary: String {
        let unique = Array(Set(workerNames))
        if unique.count == 1 {
            let count = workerNames.count
            if count == 1 {
                return "Used \(unique[0])"
            }
            return "Used \(unique[0]) (\(count)x)"
        }
        return "Used \(unique.joined(separator: ", "))"
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
