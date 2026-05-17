import SwiftUI
import SwiftData

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
    /// Semantic version (MAJOR.MINOR.PATCH).
    /// MAJOR: breaking schema or API changes.
    /// MINOR: new user-visible features.
    /// PATCH: bug fixes and tuning.
    static let version = "2.0.0"
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
    /// When set, presents `WikiPageListView` with this page already
    /// pushed — used by the in-sidebar wiki search results.
    @State private var openedWikiPage: WikiPage?

    /// Semantic + keyword search hits across the wiki for the current
    /// `searchText`. Empty when search is inactive. Top 5 by relevance.
    /// Uses the same `findRelevantPages` path that powers the
    /// on-device wiki tool, so ranking matches what the model sees.
    private var searchedWikiPages: [WikiPage] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return store.wikiStore.findRelevantPages(for: trimmed, limit: 5)
    }

    /// Flattened, in-display order. Used by the keyboard shortcuts so
    /// `⌘1`-`⌘9` jump to the visible position, and `⌘[` / `⌘]` walk in the
    /// same direction the user sees on screen.
    private var flatConversations: [ChatViewModel] {
        groupedConversations.flatMap { $0.1 }
    }

    private func selectPreviousChat() {
        let flat = flatConversations
        guard let id = store.selectedConversationID,
              let i = flat.firstIndex(where: { $0.id == id }),
              i > 0 else { return }
        store.selectedConversationID = flat[i - 1].id
    }

    private func selectNextChat() {
        let flat = flatConversations
        guard let id = store.selectedConversationID,
              let i = flat.firstIndex(where: { $0.id == id }),
              i + 1 < flat.count else { return }
        store.selectedConversationID = flat[i + 1].id
    }

    private func selectChat(atFlatIndex index: Int) {
        let flat = flatConversations
        guard index < flat.count else { return }
        store.selectedConversationID = flat[index].id
    }

    /// Invisible button group that registers app-wide keyboard shortcuts.
    /// Sits in `.background { ... }` of the sidebar so the responder chain
    /// picks them up regardless of which column has focus.
    private var keyboardShortcutSink: some View {
        Group {
            Button("Previous Chat", action: selectPreviousChat)
                .keyboardShortcut("[", modifiers: .command)
            Button("Next Chat", action: selectNextChat)
                .keyboardShortcut("]", modifiers: .command)
            ForEach(0..<9, id: \.self) { i in
                Button("Chat \(i + 1)") { selectChat(atFlatIndex: i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

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
            store.configureWikiStore(with: modelContext)
            store.configureDocumentImporter(with: modelContext)
            EmbeddingService.shared.requestAssetsIfNeeded()
            handlePendingQuickAction()
        }
        #if canImport(UIKit) && !os(macOS) && !os(visionOS)
        .onChange(of: QuickActionRouter.shared.pending) { _, _ in
            handlePendingQuickAction()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { handlePendingQuickAction() }
        }
        #endif
    }

    @Environment(\.scenePhase) private var scenePhase

    private func handlePendingQuickAction() {
        #if canImport(UIKit) && !os(macOS) && !os(visionOS)
        guard let action = QuickActionRouter.shared.pending else { return }
        switch action {
        case .newChat:
            _ = store.createConversation()
        case .openSettings:
            showingSettings = true
        }
        QuickActionRouter.shared.pending = nil
        #endif
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(
            get: { store.selectedConversationID },
            set: { store.selectedConversationID = $0 }
        )) {
            if !searchedWikiPages.isEmpty {
                Section("Wiki Pages") {
                    ForEach(searchedWikiPages) { page in
                        Button {
                            openedWikiPage = page
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Image(systemName: "book.pages")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(page.title)
                                        .lineLimit(1)
                                        .font(.body)
                                }
                                let summary = page.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !summary.isEmpty {
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

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
                                        Text("\u{00B7}")
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
        .background { keyboardShortcutSink }
        .searchable(text: $searchText, prompt: "Search chats and wiki")
        #if os(iOS) || os(tvOS) || os(visionOS)
        .searchToolbarBehavior(.minimize)
        #endif
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle("Chats")
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .automatic) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Settings")
                .keyboardShortcut(",", modifiers: .command)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    _ = store.createConversation()
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Chat (\u{2318}N)")
            }
            #else
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (\u{2318},)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    _ = store.createConversation()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Chat (\u{2318}N)")
            }
            #endif
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store)
        }
        .sheet(item: $openedWikiPage) { page in
            WikiPageListView(
                wikiStore: store.wikiStore,
                initialPage: page,
                documentImporter: store.documentImporter
            )
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

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let conversation = store.selectedConversation() {
            ChatDetailView(viewModel: conversation) {
                _ = store.createConversation()
            }
        } else {
            ContentUnavailableView {
                Label("No Chat Selected", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Select a conversation or create a new one.")
            } actions: {
                Button {
                    _ = store.createConversation()
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView(store: ConversationStore())
}
