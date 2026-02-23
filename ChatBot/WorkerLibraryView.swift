//
//  WorkerLibraryView.swift
//  ChatBot
//
//  Manager-Worker Agentic Pattern: UI for managing worker profiles (CRUD + toggle).
//

import SwiftUI
import SwiftData

// MARK: - Worker Library View

struct WorkerLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkerProfile.createdAt, order: .reverse) private var workers: [WorkerProfile]
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddWorker = false
    @State private var editingWorker: WorkerProfile?
    @State private var showingDeleteAllConfirmation = false
    var orchestrator: AgentOrchestrator

    var body: some View {
        NavigationStack {
            workerContent
                .navigationTitle("Workers")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAddWorker = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("Add Worker")
                    }
                    ToolbarItem(placement: .automatic) {
                        if !workers.isEmpty {
                            Button(role: .destructive) {
                                showingDeleteAllConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("Delete All Workers")
                        }
                    }
                }
                .alert("Delete All Workers?", isPresented: $showingDeleteAllConfirmation) {
                    Button("Delete All", role: .destructive) {
                        for worker in workers {
                            modelContext.delete(worker)
                        }
                        orchestrator.refreshTools()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently delete all worker profiles.")
                }
                .sheet(isPresented: $showingAddWorker) {
                    WorkerEditorView(orchestrator: orchestrator)
                }
                .sheet(item: $editingWorker) { worker in
                    WorkerEditorView(existing: worker, orchestrator: orchestrator)
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 400, idealHeight: 560)
        #endif
    }

    @ViewBuilder
    private var workerContent: some View {
        if workers.isEmpty {
            ContentUnavailableView {
                Label("No Workers", systemImage: "person.2.badge.gearshape")
            } description: {
                Text("Workers are specialized AI personas that the assistant can delegate tasks to. Create workers for code review, writing, summarization, and more.")
            } actions: {
                Button("Add Worker") {
                    showingAddWorker = true
                }
            }
        } else {
            List {
                Section {
                    ForEach(workers) { worker in
                        Button {
                            editingWorker = worker
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: worker.icon)
                                    .font(.title2)
                                    .foregroundStyle(worker.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(worker.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(worker.triggerDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                Spacer()

                                Toggle("", isOn: Binding(
                                    get: { worker.isEnabled },
                                    set: { newValue in
                                        worker.isEnabled = newValue
                                        orchestrator.refreshTools()
                                    }
                                ))
                                .labelsHidden()
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                editingWorker = worker
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                modelContext.delete(worker)
                                orchestrator.refreshTools()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            modelContext.delete(workers[index])
                        }
                        orchestrator.refreshTools()
                    }
                } footer: {
                    Text("Each enabled worker slightly reduces the available context window. Changes apply to new conversations or after a context refresh.")
                }
            }
        }
    }
}

// MARK: - Worker Editor View

struct WorkerEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var existing: WorkerProfile?
    var orchestrator: AgentOrchestrator

    @State private var name = ""
    @State private var icon = "person.crop.circle"
    @State private var triggerDescription = ""
    @State private var systemInstructions = ""
    @State private var isEnabled = true

    private var isEditing: Bool { existing != nil }

    // Curated SF Symbols relevant to AI worker personas
    private let iconOptions = [
        "person.crop.circle", "brain.head.profile", "hammer", "book",
        "terminal", "paintbrush", "chart.bar", "globe",
        "doc.text", "graduationcap", "wrench.and.screwdriver",
        "lightbulb", "magnifyingglass", "pencil.and.ruler"
    ]

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !triggerDescription.trimmingCharacters(in: .whitespaces).isEmpty
            && !systemInstructions.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Identity
                Section {
                    TextField("e.g. Code Reviewer", text: $name)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(iconOptions, id: \.self) { symbolName in
                                Image(systemName: symbolName)
                                    .font(.title2)
                                    .foregroundStyle(icon == symbolName ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    .frame(width: 40, height: 40)
                                    .background(
                                        icon == symbolName
                                            ? Color.accentColor.opacity(0.15)
                                            : Color.clear,
                                        in: .circle
                                    )
                                    .onTapGesture { icon = symbolName }
                                    .accessibilityLabel(symbolName)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Identity")
                }

                // MARK: When to Use
                Section {
                    TextField(
                        "e.g. Use this worker when the user asks for a code review or wants feedback on code quality",
                        text: $triggerDescription,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                } header: {
                    Text("When to Use")
                } footer: {
                    Text("Describe when the assistant should delegate to this worker. This is what the AI reads to decide whether to invoke it.")
                }

                // MARK: System Instructions
                Section {
                    TextField(
                        "e.g. You are an expert code reviewer. Analyze code for bugs, style issues, and suggest improvements. Be constructive and specific.",
                        text: $systemInstructions,
                        axis: .vertical
                    )
                    .lineLimit(4...12)
                } header: {
                    Text("System Instructions")
                } footer: {
                    Text("The persona and behavior rules for this worker. Workers have their own context window and cannot see the conversation history.")
                }

                // MARK: Toggle
                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                } footer: {
                    Text("Disabled workers are not available to the assistant.")
                }

                // MARK: Info (edit mode only)
                if isEditing, let worker = existing {
                    Section {
                        LabeledContent("Created", value: worker.createdAt.formatted(date: .abbreviated, time: .shortened))
                    } header: {
                        Text("Info")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Worker" : "New Worker")
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
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if let worker = existing {
                    name = worker.name
                    icon = worker.icon
                    triggerDescription = worker.triggerDescription
                    systemInstructions = worker.systemInstructions
                    isEnabled = worker.isEnabled
                }
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedTrigger = triggerDescription.trimmingCharacters(in: .whitespaces)
        let trimmedInstructions = systemInstructions.trimmingCharacters(in: .whitespaces)

        if let worker = existing {
            worker.name = trimmedName
            worker.icon = icon
            worker.triggerDescription = trimmedTrigger
            worker.systemInstructions = trimmedInstructions
            worker.isEnabled = isEnabled
        } else {
            let worker = WorkerProfile(
                name: trimmedName,
                icon: icon,
                triggerDescription: trimmedTrigger,
                systemInstructions: trimmedInstructions,
                isEnabled: isEnabled
            )
            modelContext.insert(worker)
        }

        orchestrator.refreshTools()
        dismiss()
    }
}
