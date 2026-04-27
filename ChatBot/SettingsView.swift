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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Keyword Boost")
                            Spacer()
                            Text(String(format: "%.0f%%", store.ragSettings.lexicalWeight * 100))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { Float(store.ragSettings.lexicalWeight) },
                                set: { newValue in
                                    store.ragSettings.lexicalWeight = Float(newValue)
                                    store.applyRAGSettings()
                                }
                            ),
                            in: 0...0.5,
                            step: 0.05
                        )
                        Text(store.ragSettings.lexicalWeight < 0.1 ? "Semantic only" : store.ragSettings.lexicalWeight > 0.4 ? "Strong keyword matching" : "Balanced hybrid")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Memory Recency")
                            Spacer()
                            Text(String(format: "%.0f%%", store.ragSettings.recencyWeight * 100))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { Float(store.ragSettings.recencyWeight) },
                                set: { newValue in
                                    store.ragSettings.recencyWeight = Float(newValue)
                                    store.applyRAGSettings()
                                }
                            ),
                            in: 0...0.4,
                            step: 0.05
                        )
                        Text(store.ragSettings.recencyWeight < 0.05 ? "Age ignored" : store.ragSettings.recencyWeight > 0.3 ? "Strongly prefer recent" : "Balanced")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Retrieval")
                } footer: {
                    Text("More results use more of the limited context window. Keyword Boost blends exact term matching with semantic search. Memory Recency favors recently stored memories over older ones (45-day half-life).")
                }

                // MARK: Generation
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text(String(format: "%.1f", store.ragSettings.temperature))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { store.ragSettings.temperature },
                                set: { newValue in
                                    store.ragSettings.temperature = newValue
                                    store.applyRAGSettings()
                                }
                            ),
                            in: 0...2,
                            step: 0.1
                        )
                        Text(store.ragSettings.temperature < 0.5 ? "Focused and precise" : store.ragSettings.temperature > 1.5 ? "Highly creative" : "Balanced")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Sampling", selection: Binding(
                        get: { store.ragSettings.samplingMode },
                        set: { newValue in
                            store.ragSettings.samplingMode = newValue
                            store.applyRAGSettings()
                        }
                    )) {
                        ForEach(SamplingModeSetting.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    if store.ragSettings.samplingMode == .topK {
                        Stepper(
                            "Top-K: \(store.ragSettings.topKValue)",
                            value: Binding(
                                get: { store.ragSettings.topKValue },
                                set: { newValue in
                                    store.ragSettings.topKValue = newValue
                                    store.applyRAGSettings()
                                }
                            ),
                            in: 1...100
                        )
                    }

                    if store.ragSettings.samplingMode == .topP {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Top-P")
                                Spacer()
                                Text(String(format: "%.2f", store.ragSettings.topPValue))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(
                                value: Binding(
                                    get: { store.ragSettings.topPValue },
                                    set: { newValue in
                                        store.ragSettings.topPValue = newValue
                                        store.applyRAGSettings()
                                    }
                                ),
                                in: 0.1...1.0,
                                step: 0.05
                            )
                        }
                    }
                } header: {
                    Text("Generation")
                } footer: {
                    Text(store.ragSettings.samplingMode.description)
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
