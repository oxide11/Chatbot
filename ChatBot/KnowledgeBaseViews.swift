//
//  KnowledgeBaseViews.swift
//  ChatBot
//
//  Knowledge base list, detail, text input, and export views.
//

import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Knowledge Base List View

struct KnowledgeBaseListView: View {
    var knowledgeBaseStore: KnowledgeBaseStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingImporter = false
    @State private var showingDeleteAllConfirmation = false
    @State private var showingTextInput = false
    @State private var renamingKB: KnowledgeBase?
    @State private var renameDraft = ""

    var body: some View {
        NavigationStack {
            kbContent
                .navigationTitle("Knowledge Bases")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
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
                        .help("Add Knowledge Base")
                    }
                    ToolbarItem(placement: .automatic) {
                        if !knowledgeBaseStore.knowledgeBases.isEmpty {
                            Button(role: .destructive) {
                                showingDeleteAllConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("Delete All Knowledge Bases")
                        }
                    }
                }
                .fileImporter(
                    isPresented: $showingImporter,
                    allowedContentTypes: [.pdf, .epub, .plainText],
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result, !urls.isEmpty {
                        knowledgeBaseStore.queueDocuments(from: urls)
                    }
                }
                .alert("Delete All Knowledge Bases?", isPresented: $showingDeleteAllConfirmation) {
                    Button("Delete All", role: .destructive) {
                        knowledgeBaseStore.deleteAllKnowledgeBases()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently delete all imported documents and their chunks.")
                }
                .alert("Rename Knowledge Base", isPresented: Binding(
                    get: { renamingKB != nil },
                    set: { if !$0 { renamingKB = nil } }
                )) {
                    TextField("Name", text: $renameDraft)
                    Button("Rename") {
                        if let kb = renamingKB {
                            knowledgeBaseStore.renameKnowledgeBase(kb, to: renameDraft)
                        }
                        renamingKB = nil
                    }
                    Button("Cancel", role: .cancel) {
                        renamingKB = nil
                    }
                } message: {
                    Text("Enter a new name for this knowledge base.")
                }
                .sheet(isPresented: $showingTextInput) {
                    TextInputSheet(knowledgeBaseStore: knowledgeBaseStore)
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 400, idealHeight: 560)
        #endif
    }

    @ViewBuilder
    private var kbContent: some View {
        if knowledgeBaseStore.knowledgeBases.isEmpty && !knowledgeBaseStore.isProcessing && knowledgeBaseStore.ingestionQueue.isEmpty {
            ContentUnavailableView {
                Label("No Knowledge Bases", systemImage: "books.vertical")
            } description: {
                Text("Import PDF, ePUB, or text documents to give the assistant knowledge about specific topics. You can also paste text directly.")
            } actions: {
                Button {
                    showingImporter = true
                } label: {
                    Text("Import Documents")
                }
            }
        } else {
            List {
                // Ingestion queue
                if !knowledgeBaseStore.ingestionQueue.isEmpty {
                    Section {
                        if knowledgeBaseStore.isProcessing {
                            VStack(spacing: 6) {
                                ProgressView(value: knowledgeBaseStore.processingProgress)
                                let done = knowledgeBaseStore.ingestionQueue.filter(\.isFinished).count
                                Text("Processing \(done + 1) of \(knowledgeBaseStore.ingestionQueue.count)\u{2026}")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }

                        ForEach(knowledgeBaseStore.ingestionQueue) { job in
                            HStack(spacing: 10) {
                                Group {
                                    switch job.status {
                                    case .processing:
                                        ProgressView()
                                            .controlSize(.small)
                                    case .completed:
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    case .failed:
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.red)
                                    case .queued:
                                        Image(systemName: "clock")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.fileName)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(job.status.label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if job.isFinished {
                                    Button {
                                        knowledgeBaseStore.removeJob(job)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        if knowledgeBaseStore.isProcessing {
                            Button("Cancel Remaining") {
                                knowledgeBaseStore.cancelQueue()
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }

                        let finishedCount = knowledgeBaseStore.ingestionQueue.filter(\.isFinished).count
                        if !knowledgeBaseStore.isProcessing && finishedCount > 0 {
                            Button("Clear Queue") {
                                knowledgeBaseStore.clearFinishedJobs()
                            }
                            .font(.caption)
                        }
                    } header: {
                        Text("Import Queue")
                    }
                }

                if let error = knowledgeBaseStore.processingError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                // Existing knowledge bases, grouped by domain
                ForEach(knowledgeBaseStore.domains) { domain in
                    let domainKBs = knowledgeBaseStore.knowledgeBases(for: domain.id)
                    if !domainKBs.isEmpty {
                        Section {
                            ForEach(domainKBs) { kb in
                                NavigationLink {
                                    KnowledgeBaseDetailView(kb: kb, store: knowledgeBaseStore)
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
                                                    fromByteCount: knowledgeBaseStore.storageSize(for: kb),
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

                                    if knowledgeBaseStore.domains.count > 1 {
                                        Menu {
                                            ForEach(knowledgeBaseStore.domains.filter { $0.id != kb.effectiveDomainID }) { targetDomain in
                                                Button(targetDomain.name) {
                                                    knowledgeBaseStore.moveKnowledgeBase(kb, toDomain: targetDomain.id)
                                                }
                                            }
                                        } label: {
                                            Label("Move to Domain", systemImage: "arrow.right.square")
                                        }
                                    }

                                    Divider()
                                    Button(role: .destructive) {
                                        knowledgeBaseStore.deleteKnowledgeBase(kb)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .onDelete { offsets in
                                let toDelete = offsets.map { domainKBs[$0] }
                                for kb in toDelete {
                                    knowledgeBaseStore.deleteKnowledgeBase(kb)
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

// MARK: - Text Input Sheet

struct TextInputSheet: View {
    var knowledgeBaseStore: KnowledgeBaseStore
    var domainID: UUID = KnowledgeDomain.generalID
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""

    private var canImport: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Knowledge base name", text: $name)
                } header: {
                    Text("Name")
                }

                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 200)
                        .font(.body)
                } header: {
                    Text("Content")
                } footer: {
                    if !text.isEmpty {
                        Text("\(text.count) characters")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Paste Text")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        knowledgeBaseStore.ingestText(name: name, text: text, domainID: domainID)
                        dismiss()
                    }
                    .bold()
                    .disabled(!canImport)
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Knowledge Base Detail View

struct KnowledgeBaseDetailView: View {
    let kb: KnowledgeBase
    var store: KnowledgeBaseStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirmation = false
    @State private var showingReimporter = false
    @State private var showingRenameAlert = false
    @State private var renameDraft = ""
    @State private var exportURL: URL?
    @State private var showingExportShare = false

    var body: some View {
        List {
            // MARK: Metadata
            Section {
                LabeledContent("Type", value: kb.documentType.label)
                LabeledContent("Chunks", value: "\(kb.chunkCount)")
                LabeledContent("Original Size", value: ByteCountFormatter.string(
                    fromByteCount: kb.fileSize, countStyle: .file
                ))
                LabeledContent("Storage Used", value: ByteCountFormatter.string(
                    fromByteCount: store.storageSize(for: kb), countStyle: .file
                ))
                LabeledContent("Imported", value: kb.createdAt.formatted(
                    date: .abbreviated, time: .shortened
                ))
                if kb.updatedAt.timeIntervalSince(kb.createdAt) > 1 {
                    LabeledContent("Updated", value: kb.updatedAt.formatted(
                        date: .abbreviated, time: .shortened
                    ))
                }

                // Embedding status
                HStack {
                    Text("Embeddings")
                    Spacer()
                    if let modelID = kb.embeddingModelID, !modelID.isEmpty {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("None", systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Details")
            }

            // MARK: All Chunks
            Section {
                let chunks = store.allChunks(for: kb.id)
                if chunks.isEmpty {
                    Text("No chunks available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(chunks) { chunk in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(chunk.locationLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("#\(chunk.index)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(chunk.content)
                                .font(.caption2)
                                .lineLimit(4)
                            if !chunk.keywords.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(chunk.keywords.prefix(4), id: \.self) { kw in
                                        Text(kw)
                                            .font(.system(size: 9))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(.fill.tertiary, in: .capsule)
                                    }
                                }
                            }
                            if chunk.embedding != nil {
                                HStack(spacing: 2) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 8))
                                    Text("Embedded")
                                        .font(.system(size: 9))
                                }
                                .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { offsets in
                        let chunks = store.allChunks(for: kb.id)
                        for index in offsets {
                            store.deleteChunk(chunkID: chunks[index].id, from: kb.id)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Chunks")
                    Spacer()
                    Text("\(store.allChunks(for: kb.id).count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(kb.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        renameDraft = kb.name
                        showingRenameAlert = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button {
                        showingReimporter = true
                    } label: {
                        Label("Re-import Document", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Button {
                        exportURL = store.exportKnowledgeBase(kb)
                        if exportURL != nil {
                            showingExportShare = true
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Knowledge Base", isPresented: $showingRenameAlert) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                store.renameKnowledgeBase(kb, to: renameDraft)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new name for this knowledge base.")
        }
        .alert("Delete Knowledge Base?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                store.deleteKnowledgeBase(kb)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete '\(kb.name)' and all its chunks.")
        }
        .fileImporter(
            isPresented: $showingReimporter,
            allowedContentTypes: [.pdf, .epub, .plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.updateDocument(for: kb, from: url)
            }
        }
        .sheet(isPresented: $showingExportShare) {
            if let url = exportURL {
                #if os(iOS) || os(tvOS) || os(visionOS)
                ShareSheetView(items: [url])
                #else
                VStack(spacing: 16) {
                    Text("Export Successful")
                        .font(.headline)
                    Text("File saved to: \(url.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ShareLink(item: url) {
                        Label("Share File", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Done") {
                        showingExportShare = false
                    }
                }
                .padding()
                #endif
            }
        }
    }
}

// MARK: - Share Sheet (iOS)

#if os(iOS) || os(tvOS) || os(visionOS)
struct ShareSheetView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
