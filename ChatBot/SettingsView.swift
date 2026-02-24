//
//  SettingsView.swift
//  ChatBot
//
//  Settings panel for Intelligence, Retrieval, System Prompt, Storage, and Data management.
//

import SwiftUI

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
                    NavigationLink {
                        DomainSettingsContent(store: store)
                    } label: {
                        HStack {
                            Label("Knowledge Domains", systemImage: "square.stack.3d.up")
                            Spacer()
                            Text("\(store.knowledgeBaseStore.domains.count)")
                                .foregroundStyle(.secondary)
                        }
                    }

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
                            guard oldValue != newValue, !oldValue.isEmpty || !newValue.isEmpty else { return }
                            store.defaultSystemPrompt = newValue
                            store.applyDefaultSystemPrompt()
                        }
                } header: {
                    Text("Default System Prompt")
                } footer: {
                    Text("Applied to new conversations. Individual chats can override this.")
                }

                // MARK: Storage
                Section {
                    HStack {
                        Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                        Spacer()
                        Text("\(store.conversations.count) \u{00B7} \(ByteCountFormatter.string(fromByteCount: Int64(store.conversationDataSize), countStyle: .file))")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Memories", systemImage: "brain")
                        Spacer()
                        Text("\(store.memoryStore.memories.count) \u{00B7} \(ByteCountFormatter.string(fromByteCount: Int64(store.memoryDataSize), countStyle: .file))")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Knowledge Bases", systemImage: "books.vertical")
                        Spacer()
                        if store.knowledgeBaseStore.knowledgeBases.isEmpty {
                            Text("None")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(store.knowledgeBaseStore.knowledgeBases.count) docs \u{00B7} \(store.knowledgeBaseStore.totalChunkCount) chunks \u{00B7} \(ByteCountFormatter.string(fromByteCount: store.knowledgeBaseStore.totalChunkStorageSize, countStyle: .file))")
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Label("Embeddings", systemImage: "sparkles")
                        Spacer()
                        Text(EmbeddingService.shared.isAvailable ? "Active" : "Unavailable")
                            .foregroundStyle(EmbeddingService.shared.isAvailable ? .green : .secondary)
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Total: \(ByteCountFormatter.string(fromByteCount: store.totalStorageBytes, countStyle: .file))")
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
                MemoryListView(memoryStore: store.memoryStore, domains: store.knowledgeBaseStore.domains)
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
