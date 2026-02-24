//
//  MemoryViews.swift
//  ChatBot
//
//  Memory list, editor, and flow layout for keyword pills.
//

import SwiftUI

// MARK: - Memory Editor View (Add & Edit)

struct MemoryEditorView: View {
    var memoryStore: MemoryStore
    var existing: MemoryEntry?
    /// Domain to assign new memories to (ignored when editing).
    var domainID: UUID = KnowledgeDomain.generalID
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
            memoryStore.addMemory(trimmedContent, keywords: keywords, source: "Manual Entry", domainID: domainID)
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
    var domains: [KnowledgeDomain] = []
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
                ForEach(domains.isEmpty ? [KnowledgeDomain.general()] : domains) { domain in
                    let domainMemories = memoryStore.memories(for: domain.id)
                    if !domainMemories.isEmpty {
                        Section {
                            ForEach(domainMemories) { memory in
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
                                            Text("\u{00B7}")
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

                                    if domains.count > 1 {
                                        Menu {
                                            ForEach(domains.filter { $0.id != (memory.domainID ?? KnowledgeDomain.generalID) }) { targetDomain in
                                                Button(targetDomain.name) {
                                                    memoryStore.moveMemory(memory, toDomain: targetDomain.id)
                                                }
                                            }
                                        } label: {
                                            Label("Move to Domain", systemImage: "arrow.right.square")
                                        }
                                    }

                                    Button(role: .destructive) {
                                        memoryStore.deleteMemory(memory)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .onDelete { offsets in
                                let toDelete = offsets.map { domainMemories[$0] }
                                for entry in toDelete {
                                    memoryStore.deleteMemory(entry)
                                }
                            }
                        } header: {
                            Text(domain.name)
                        }
                    }
                }
            }
        }
    }
}
