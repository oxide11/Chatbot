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
    static let version = "1.1.0"
    static let build = "2"
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
            store.configureKnowledgeBaseStore(with: modelContext)
            // Ensure embedding model assets are downloaded for semantic RAG
            EmbeddingService.shared.requestAssetsIfNeeded()
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
                                        Text("\u{00B7}")
                                        Text("\(conversation.messages.count) messages")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                if let domainName = store.knowledgeBaseStore.domains.first(where: { $0.id == conversation.domainID })?.name,
                                   domainName != "General" {
                                    Text(domainName)
                                        .font(.caption2)
                                        .foregroundStyle(.tint)
                                }
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
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .automatic) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
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
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")

                    Spacer()

                    Button {
                        _ = store.createConversation()
                    } label: {
                        Label("New Chat", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New Chat (\u{2318}N)")
                }
            }
            #endif
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

// MARK: - Preview

#Preview {
    ContentView(store: ConversationStore())
}
