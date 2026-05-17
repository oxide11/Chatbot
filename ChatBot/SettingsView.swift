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
    @State private var showingImports = false
    @State private var showingWorkers = false
    @State private var showingWikiLint = false
    @State private var defaultPromptDraft = ""
    @State private var openingProvider: ChatProviderID?

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Intelligence
                Section {

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
                        showingImports = true
                    } label: {
                        HStack {
                            Label("Import Documents", systemImage: "doc.badge.plus")
                            Spacer()
                            Text("\(store.documentImporter.imports.count)")
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
                    Text("Wiki pages are extracted from conversations and imported documents. Workers are specialized AI personas for task delegation.")
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

                // MARK: Routing
                Section {
                    ForEach(ProviderTask.allCases, id: \.self) { task in
                        TaskRoutingRow(task: task, registry: store.providers)
                    }
                } header: {
                    Text("Routing")
                } footer: {
                    Text("Bind each task to a specific provider. Useful for keeping chat on-device while sending wiki extraction and lint review to a higher-quality remote model. \u{201C}Use Default\u{201D} falls back to the default above.")
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

                    Toggle("Auto-Extract from Conversations", isOn: Binding(
                        get: { store.ragSettings.autoExtractKnowledge },
                        set: { newValue in
                            store.ragSettings.autoExtractKnowledge = newValue
                            store.applyRAGSettings()
                        }
                    ))
                } header: {
                    Text("Retrieval")
                } footer: {
                    Text("Wiki retrieval pulls relevant pages into chat context. Auto-Extract from Conversations creates new wiki pages from each conversation as it grows.")
                }

                // MARK: Wiki Maintenance
                Section {
                    Button {
                        showingWikiLint = true
                    } label: {
                        HStack {
                            Label("Lint Wiki", systemImage: "wand.and.stars.inverse")
                            Spacer()
                            if store.wikiLinter.report.activeCount > 0 {
                                Text("\(store.wikiLinter.report.activeCount)")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.18), in: .capsule)
                                    .foregroundStyle(.orange)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    SummaryBackfillRow(engine: store.wikiEngine)

                    Toggle("Lint After Extractions", isOn: Binding(
                        get: { store.ragSettings.lintAfterExtractions },
                        set: { newValue in
                            store.ragSettings.lintAfterExtractions = newValue
                            store.applyRAGSettings()
                        }
                    ))

                    Toggle("Daily Background Lint", isOn: Binding(
                        get: { store.ragSettings.dailyBackgroundLintEnabled },
                        set: { newValue in
                            store.ragSettings.dailyBackgroundLintEnabled = newValue
                            store.applyRAGSettings()
                            WikiLintScheduler.shared.reschedule(enabled: newValue)
                        }
                    ))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Duplicate Sensitivity")
                            Spacer()
                            Text(String(format: "%.0f%%", store.ragSettings.lintSimilarityThreshold * 100))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { store.ragSettings.lintSimilarityThreshold },
                                set: { newValue in
                                    store.ragSettings.lintSimilarityThreshold = newValue
                                    store.applyRAGSettings()
                                }
                            ),
                            in: 0.7...0.95,
                            step: 0.01
                        )
                        Text(store.ragSettings.lintSimilarityThreshold > 0.9
                             ? "Conservative — only near-identical pairs flagged"
                             : (store.ragSettings.lintSimilarityThreshold < 0.78
                                ? "Aggressive — more candidates, more noise"
                                : "Balanced"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Wiki Maintenance")
                } footer: {
                    Text("Lint surfaces broken links, orphans, duplicates, stale and missing pages. Summarise Pages writes a one-line LLM summary for each page so the model can browse the wiki by table of contents. Nothing is changed without your confirmation.")
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
                        Label("Imported Documents", systemImage: "doc.badge.plus")
                        Spacer()
                        if store.documentImporter.imports.isEmpty {
                            Text("None")
                                .foregroundStyle(.secondary)
                        } else {
                            let totalBytes = store.documentImporter.imports.reduce(Int64(0)) { $0 + $1.fileSize }
                            Text("\(store.documentImporter.imports.count) \u{00B7} \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
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
                WikiPageListView(
                    wikiStore: store.wikiStore,
                    documentImporter: store.documentImporter
                )
            }
            .sheet(isPresented: $showingImports) {
                DocumentImportListView(importer: store.documentImporter, wikiStore: store.wikiStore)
            }
            .sheet(isPresented: $showingWorkers) {
                WorkerLibraryView(orchestrator: store.orchestrator)
            }
            .sheet(item: $openingProvider) { id in
                ProviderDetailView(id: id, registry: store.providers)
            }
            .sheet(isPresented: $showingWikiLint) {
                WikiLintView(linter: store.wikiLinter, wikiStore: store.wikiStore)
            }
        }
        .presentationDragIndicator(.visible)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 540, idealHeight: 600)
        #endif
    }
}

// MARK: - Summary Backfill Row

/// Settings row that drives `WikiEngine.runSummaryBackfill`. Shows the
/// pending count when idle, a progress bar + cancel button while
/// running, and hides itself when nothing is pending. Routes through
/// whichever provider the user has bound to the `.extraction` task —
/// remote callers will incur per-page cost, surfaced in the footer.
private struct SummaryBackfillRow: View {
    let engine: WikiEngine

    var body: some View {
        Group {
            if engine.isBackfillingSummaries, let progress = engine.summaryBackfillProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Summarising Pages", systemImage: "text.book.closed")
                        Spacer()
                        Button("Stop") {
                            engine.cancelSummaryBackfill()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    }
                    ProgressView(
                        value: Double(progress.processed),
                        total: Double(max(progress.total, 1))
                    )
                    Text("\(progress.processed) of \(progress.total)\(progress.failed > 0 ? " · \(progress.failed) failed" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if engine.pagesMissingSummary > 0 {
                Button {
                    engine.runSummaryBackfill()
                } label: {
                    HStack {
                        Label("Summarise Pages", systemImage: "text.book.closed")
                        Spacer()
                        Text("\(engine.pagesMissingSummary)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.18), in: .capsule)
                            .foregroundStyle(.blue)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
