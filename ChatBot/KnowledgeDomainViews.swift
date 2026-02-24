//
//  KnowledgeDomainViews.swift
//  ChatBot
//
//  Domain list, detail, editor, and picker views for Knowledge Domains.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Domain Settings Content (inline, no NavigationStack — used inside Settings push)

struct DomainSettingsContent: View {
    var store: ConversationStore
    @State private var showingEditor = false
    @State private var renamingDomain: KnowledgeDomain?
    @State private var renameDraft = ""
    @State private var deletingDomain: KnowledgeDomain?

    var body: some View {
        List {
            if store.knowledgeBaseStore.domains.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Domains", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("Tap + to create a domain.")
                    }
                }
            } else {
                Section {
                    ForEach(store.knowledgeBaseStore.domains) { domain in
                        NavigationLink {
                            DomainDetailContent(domain: domain, store: store)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(domain.name)
                                            .font(.body)
                                        if domain.isDefault {
                                            Image(systemName: "lock.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    HStack(spacing: 4) {
                                        let kbCount = store.knowledgeBaseStore.knowledgeBases(for: domain.id).count
                                        let memCount = store.memoryStore.memories(for: domain.id).count
                                        Text("\(memCount) memor\(memCount == 1 ? "y" : "ies")")
                                        Text("\u{00B7}")
                                        Text("\(kbCount) KB\(kbCount == 1 ? "" : "s")")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .contextMenu {
                            Button {
                                renameDraft = domain.name
                                renamingDomain = domain
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .disabled(domain.isDefault)

                            Divider()

                            Button(role: .destructive) {
                                deletingDomain = domain
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(domain.isDefault)
                        }
                    }
                } header: {
                    HStack {
                        Text("Domains")
                        Spacer()
                        Button {
                            showingEditor = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
        .navigationTitle("Knowledge Domains")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showingEditor) {
            DomainEditorView { name in
                _ = store.knowledgeBaseStore.createDomain(name: name)
            }
        }
        .alert("Rename Domain", isPresented: Binding(
            get: { renamingDomain != nil },
            set: { if !$0 { renamingDomain = nil } }
        )) {
            TextField("Domain name", text: $renameDraft)
            Button("Rename") {
                if let domain = renamingDomain {
                    store.knowledgeBaseStore.renameDomain(domain, to: renameDraft)
                }
                renamingDomain = nil
            }
            Button("Cancel", role: .cancel) {
                renamingDomain = nil
            }
        } message: {
            Text("Enter a new name for this domain.")
        }
        .alert("Delete Domain?", isPresented: Binding(
            get: { deletingDomain != nil },
            set: { if !$0 { deletingDomain = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let domain = deletingDomain {
                    let generalID = store.knowledgeBaseStore.domains.first(where: { $0.isDefault })?.id ?? KnowledgeDomain.generalID
                    for memory in store.memoryStore.memories(for: domain.id) {
                        store.memoryStore.moveMemory(memory, toDomain: generalID)
                    }
                    store.knowledgeBaseStore.deleteDomain(domain)
                }
                deletingDomain = nil
            }
            Button("Cancel", role: .cancel) {
                deletingDomain = nil
            }
        } message: {
            Text("All knowledge bases and memories in this domain will be moved to General.")
        }
    }
}

// MARK: - Domain Detail Content (works inside any NavigationStack)

struct DomainDetailContent: View {
    let domain: KnowledgeDomain
    var store: ConversationStore

    @State private var showingImporter = false
    @State private var showingTextInput = false
    @State private var showingAddMemory = false
    @State private var showingKBPicker = false
    @State private var showingMemoryPicker = false
    @State private var editingMemory: MemoryEntry?
    @State private var renamingKB: KnowledgeBase?
    @State private var renameDraft = ""

    private var domainKBs: [KnowledgeBase] {
        store.knowledgeBaseStore.knowledgeBases(for: domain.id)
    }

    private var domainMemories: [MemoryEntry] {
        store.memoryStore.memories(for: domain.id)
    }

    /// KBs that live in other domains and could be moved here.
    private var otherDomainKBs: [KnowledgeBase] {
        store.knowledgeBaseStore.knowledgeBases.filter { $0.effectiveDomainID != domain.id }
    }

    /// Memories that live in other domains and could be moved here.
    private var otherDomainMemories: [MemoryEntry] {
        store.memoryStore.memories.filter { ($0.domainID ?? KnowledgeDomain.generalID) != domain.id }
    }

    var body: some View {
        List {
            // MARK: Knowledge Bases Section
            Section {
                if domainKBs.isEmpty {
                    Text("No knowledge bases in this domain.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(domainKBs) { kb in
                        NavigationLink {
                            KnowledgeBaseDetailView(kb: kb, store: store.knowledgeBaseStore)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: kb.documentType.icon)
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(kb.name)
                                        .font(.body)
                                        .lineLimit(1)

                                    HStack(spacing: 4) {
                                        Text(kb.documentType.label)
                                        Text("\u{00B7}")
                                        Text("\(kb.chunkCount) chunks")
                                        Text("\u{00B7}")
                                        Text(ByteCountFormatter.string(
                                            fromByteCount: store.knowledgeBaseStore.storageSize(for: kb),
                                            countStyle: .file
                                        ))
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .contextMenu {
                            Button {
                                renameDraft = kb.name
                                renamingKB = kb
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }

                            if store.knowledgeBaseStore.domains.count > 1 {
                                Menu {
                                    ForEach(store.knowledgeBaseStore.domains.filter { $0.id != domain.id }) { targetDomain in
                                        Button(targetDomain.name) {
                                            store.knowledgeBaseStore.moveKnowledgeBase(kb, toDomain: targetDomain.id)
                                        }
                                    }
                                } label: {
                                    Label("Move to Domain", systemImage: "arrow.right.square")
                                }
                            }

                            Divider()

                            Button(role: .destructive) {
                                store.knowledgeBaseStore.deleteKnowledgeBase(kb)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { offsets in
                        let toDelete = offsets.map { domainKBs[$0] }
                        for kb in toDelete {
                            store.knowledgeBaseStore.deleteKnowledgeBase(kb)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Knowledge Bases")
                    Spacer()
                    Menu {
                        Button {
                            showingKBPicker = true
                        } label: {
                            Label("Add Existing", systemImage: "arrow.right.doc.on.clipboard")
                        }
                        .disabled(otherDomainKBs.isEmpty)

                        Divider()

                        Button {
                            showingImporter = true
                        } label: {
                            Label("Import Document", systemImage: "doc.badge.plus")
                        }
                        Button {
                            showingTextInput = true
                        } label: {
                            Label("Paste Text", systemImage: "doc.text")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }

            // MARK: Memories Section
            Section {
                if domainMemories.isEmpty {
                    Text("No memories in this domain.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
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

                            if store.knowledgeBaseStore.domains.count > 1 {
                                Menu {
                                    ForEach(store.knowledgeBaseStore.domains.filter { $0.id != domain.id }) { targetDomain in
                                        Button(targetDomain.name) {
                                            store.memoryStore.moveMemory(memory, toDomain: targetDomain.id)
                                        }
                                    }
                                } label: {
                                    Label("Move to Domain", systemImage: "arrow.right.square")
                                }
                            }

                            Divider()

                            Button(role: .destructive) {
                                store.memoryStore.deleteMemory(memory)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { offsets in
                        let toDelete = offsets.map { domainMemories[$0] }
                        for memory in toDelete {
                            store.memoryStore.deleteMemory(memory)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Memories")
                    Spacer()
                    Menu {
                        Button {
                            showingMemoryPicker = true
                        } label: {
                            Label("Add Existing", systemImage: "arrow.right.doc.on.clipboard")
                        }
                        .disabled(otherDomainMemories.isEmpty)

                        Divider()

                        Button {
                            showingAddMemory = true
                        } label: {
                            Label("New Memory", systemImage: "plus.circle")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .navigationTitle(domain.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.pdf, .epub, .plainText],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                store.knowledgeBaseStore.queueDocuments(from: urls, domainID: domain.id)
            }
        }
        .sheet(isPresented: $showingTextInput) {
            TextInputSheet(knowledgeBaseStore: store.knowledgeBaseStore, domainID: domain.id)
        }
        .sheet(isPresented: $showingAddMemory) {
            MemoryEditorView(memoryStore: store.memoryStore, domainID: domain.id)
        }
        .sheet(item: $editingMemory) { memory in
            MemoryEditorView(memoryStore: store.memoryStore, existing: memory)
        }
        .sheet(isPresented: $showingKBPicker) {
            ExistingKBPickerView(
                store: store,
                targetDomainID: domain.id
            )
        }
        .sheet(isPresented: $showingMemoryPicker) {
            ExistingMemoryPickerView(
                store: store,
                targetDomainID: domain.id
            )
        }
        .alert("Rename Knowledge Base", isPresented: Binding(
            get: { renamingKB != nil },
            set: { if !$0 { renamingKB = nil } }
        )) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let kb = renamingKB {
                    store.knowledgeBaseStore.renameKnowledgeBase(kb, to: renameDraft)
                }
                renamingKB = nil
            }
            Button("Cancel", role: .cancel) {
                renamingKB = nil
            }
        } message: {
            Text("Enter a new name for this knowledge base.")
        }
    }
}

// MARK: - Existing KB Picker (move KBs from other domains into this one)

struct ExistingKBPickerView: View {
    var store: ConversationStore
    let targetDomainID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    /// KBs grouped by their current domain, excluding the target domain.
    private var groupedKBs: [(domain: KnowledgeDomain, kbs: [KnowledgeBase])] {
        store.knowledgeBaseStore.domains
            .filter { $0.id != targetDomainID }
            .compactMap { domain in
                let kbs = store.knowledgeBaseStore.knowledgeBases(for: domain.id)
                guard !kbs.isEmpty else { return nil }
                return (domain: domain, kbs: kbs)
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if groupedKBs.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to Add", systemImage: "tray")
                    } description: {
                        Text("All knowledge bases are already in this domain. Import a document or paste text to create new ones, or move items here from another domain.")
                    }
                } else {
                    List {
                        ForEach(groupedKBs, id: \.domain.id) { group in
                            Section {
                                ForEach(group.kbs) { kb in
                                    Button {
                                        if selected.contains(kb.id) {
                                            selected.remove(kb.id)
                                        } else {
                                            selected.insert(kb.id)
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: selected.contains(kb.id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selected.contains(kb.id) ? .blue : .secondary)
                                                .font(.title3)

                                            Image(systemName: kb.documentType.icon)
                                                .font(.title3)
                                                .foregroundStyle(.secondary)
                                                .frame(width: 24)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(kb.name)
                                                    .font(.body)
                                                    .lineLimit(1)
                                                HStack(spacing: 4) {
                                                    Text(kb.documentType.label)
                                                    Text("\u{00B7}")
                                                    Text("\(kb.chunkCount) chunks")
                                                }
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                Text(group.domain.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Knowledge Bases")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move \(selected.count)") {
                        for kbID in selected {
                            if let kb = store.knowledgeBaseStore.knowledgeBases.first(where: { $0.id == kbID }) {
                                store.knowledgeBaseStore.moveKnowledgeBase(kb, toDomain: targetDomainID)
                            }
                        }
                        dismiss()
                    }
                    .bold()
                    .disabled(selected.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Existing Memory Picker (move memories from other domains into this one)

struct ExistingMemoryPickerView: View {
    var store: ConversationStore
    let targetDomainID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    /// Memories grouped by their current domain, excluding the target domain.
    private var groupedMemories: [(domain: KnowledgeDomain, memories: [MemoryEntry])] {
        store.knowledgeBaseStore.domains
            .filter { $0.id != targetDomainID }
            .compactMap { domain in
                let memories = store.memoryStore.memories(for: domain.id)
                guard !memories.isEmpty else { return nil }
                return (domain: domain, memories: memories)
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if groupedMemories.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to Add", systemImage: "tray")
                    } description: {
                        Text("All memories are already in this domain. Create new memories manually, or move items here from another domain.")
                    }
                } else {
                    List {
                        ForEach(groupedMemories, id: \.domain.id) { group in
                            Section {
                                ForEach(group.memories) { memory in
                                    Button {
                                        if selected.contains(memory.id) {
                                            selected.remove(memory.id)
                                        } else {
                                            selected.insert(memory.id)
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: selected.contains(memory.id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selected.contains(memory.id) ? .blue : .secondary)
                                                .font(.title3)

                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(memory.content)
                                                    .font(.body)
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(2)

                                                if !memory.keywords.isEmpty {
                                                    HStack(spacing: 4) {
                                                        ForEach(memory.keywords.prefix(3), id: \.self) { keyword in
                                                            Text(keyword)
                                                                .font(.caption2)
                                                                .padding(.horizontal, 5)
                                                                .padding(.vertical, 1)
                                                                .background(.fill.tertiary, in: .capsule)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                Text(group.domain.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Memories")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move \(selected.count)") {
                        for memID in selected {
                            if let memory = store.memoryStore.memories.first(where: { $0.id == memID }) {
                                store.memoryStore.moveMemory(memory, toDomain: targetDomainID)
                            }
                        }
                        dismiss()
                    }
                    .bold()
                    .disabled(selected.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Domain Editor View (Create)

struct DomainEditorView: View {
    var onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Domain name", text: $name)
                } header: {
                    Text("Name")
                } footer: {
                    Text("e.g. Medical, Cooking, Work")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Domain")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onCreate(trimmed)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Domain Picker Menu (for chat toolbar)

struct DomainPickerMenu: View {
    let domains: [KnowledgeDomain]
    @Binding var selectedDomainID: UUID

    var body: some View {
        Menu {
            ForEach(domains) { domain in
                Button {
                    selectedDomainID = domain.id
                } label: {
                    HStack {
                        Text(domain.name)
                        if domain.id == selectedDomainID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label(selectedDomainName, systemImage: "square.stack.3d.up")
        }
    }

    private var selectedDomainName: String {
        domains.first(where: { $0.id == selectedDomainID })?.name ?? "General"
    }
}
