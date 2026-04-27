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
    @State private var showingWikiPages = false
    @State private var showingKnowledgeBases = false
    @State private var showingWorkers = false
    @State private var defaultPromptDraft = ""
    @State private var openingProvider: ChatProviderID?

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
                        showingWikiPages = true
                    } label: {
                        HStack {
                            Label("Wiki Pages", systemImage: "book.pages")
                            Spacer()
                            Text("\(store.wikiPageCount)")
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
                    Text("Wiki pages are extracted from conversations. Knowledge bases are imported documents. Workers are specialized AI personas for task delegation.")
                }

                // MARK: Providers
                Section {
                    ForEach(ChatProviderID.allCases) { id in
                        Button {
                            openingProvider = id
                        } label: {
                            ProviderRow(
                                id: id,
                                isConfigured: store.providers.isConfigured(id),
                                isDefault: store.providers.defaultProviderID == id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Providers")
                } footer: {
                    Text("Apple Intelligence runs on-device with no key required. Connect Anthropic, OpenAI, or Gemini to route chats through their cloud APIs. Keys are stored in the Keychain.")
                }

                // MARK: Retrieval
                Section {
                    Toggle("Wiki Retrieval", isOn: Binding(
                        get: { store.ragSettings.wikiRetrievalEnabled },
                        set: { newValue in
                            store.ragSettings.wikiRetrievalEnabled = newValue
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

                    Toggle("Auto-Extract from Conversations", isOn: Binding(
                        get: { store.ragSettings.autoExtractKnowledge },
                        set: { newValue in
                            store.ragSettings.autoExtractKnowledge = newValue
                            store.applyRAGSettings()
                        }
                    ))

                    Toggle("Auto-Extract from Documents", isOn: Binding(
                        get: { store.ragSettings.autoExtractWikiFromDocuments },
                        set: { newValue in
                            store.ragSettings.autoExtractWikiFromDocuments = newValue
                            store.applyRAGSettings()
                        }
                    ))

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
                    Text("Auto-Extract from Documents runs each newly imported PDF / ePub / text file through the LLM to populate wiki pages — long documents can take several minutes on-device.")
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
                        Label("Wiki Pages", systemImage: "book.pages")
                        Spacer()
                        Text("\(store.wikiPageCount) pages")
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
            .scrollEdgeEffectStyle(.soft, for: .top)
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
                Text("This will permanently delete all conversations. Wiki pages and knowledge bases will be kept.")
            }
            .sheet(isPresented: $showingWikiPages) {
                WikiPageListView(wikiStore: store.wikiStore, domains: store.knowledgeBaseStore.domains)
            }
            .sheet(isPresented: $showingKnowledgeBases) {
                KnowledgeBaseListView(
                    knowledgeBaseStore: store.knowledgeBaseStore,
                    wikiEngine: store.wikiEngine
                )
            }
            .sheet(isPresented: $showingWorkers) {
                WorkerLibraryView(orchestrator: store.orchestrator)
            }
            .sheet(item: $openingProvider) { id in
                ProviderDetailView(id: id, registry: store.providers)
            }
        }
        .presentationDragIndicator(.visible)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 540, idealHeight: 600)
        #endif
    }
}
