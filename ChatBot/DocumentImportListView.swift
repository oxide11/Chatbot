//
//  DocumentImportListView.swift
//  ChatBot
//
//  Settings → Import Documents surface. Pick PDFs / ePubs / text / Markdown
//  and run them through the wiki-extraction pipeline. Each completed import
//  is recorded so it can be re-run later (e.g. against a higher-quality
//  remote provider) or removed along with the wiki pages it produced.
//

import SwiftUI
import UniformTypeIdentifiers

struct DocumentImportListView: View {
    var importer: DocumentImporter
    @Environment(\.dismiss) private var dismiss

    @State private var showingPicker = false
    @State private var pendingDelete: DocumentImport?

    var body: some View {
        NavigationStack {
            content
                .scrollEdgeEffectStyle(.soft, for: .top)
                .navigationTitle("Imported Documents")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingPicker = true
                        } label: {
                            Label("Import", systemImage: "plus")
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        if importer.queue.contains(where: { $0.isFinished }) {
                            Menu {
                                Button {
                                    importer.clearFinishedJobs()
                                } label: {
                                    Label("Clear Finished Jobs", systemImage: "checkmark.circle")
                                }
                                if importer.isProcessing {
                                    Button(role: .destructive) {
                                        importer.cancelAll()
                                    } label: {
                                        Label("Cancel All", systemImage: "stop.circle")
                                    }
                                }
                            } label: {
                                Label("More", systemImage: "ellipsis.circle")
                            }
                        }
                    }
                }
                .fileImporter(
                    isPresented: $showingPicker,
                    allowedContentTypes: [
                        .pdf,
                        .epub,
                        .plainText,
                        UTType(filenameExtension: "md") ?? .plainText
                    ],
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result, !urls.isEmpty {
                        importer.enqueue(urls: urls)
                    }
                }
                .confirmationDialog(
                    "Delete \(pendingDelete?.fileName ?? "")?",
                    isPresented: deleteBinding,
                    titleVisibility: .visible,
                    presenting: pendingDelete
                ) { record in
                    if !record.sourceWikiPageIDs.isEmpty {
                        Button("Delete & Remove \(record.sourceWikiPageIDs.count) Wiki Page\(record.sourceWikiPageIDs.count == 1 ? "" : "s")",
                               role: .destructive) {
                            Task { await importer.delete(record, alsoDeleteWikiPages: true) }
                        }
                    }
                    Button("Forget Import", role: .destructive) {
                        Task { await importer.delete(record, alsoDeleteWikiPages: false) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { record in
                    if record.sourceWikiPageIDs.isEmpty {
                        Text("Removes the import record and source file. No wiki pages came from this document.")
                    } else {
                        Text("Forget keeps the wiki pages it produced. Delete & Remove also removes those \(record.sourceWikiPageIDs.count) page\(record.sourceWikiPageIDs.count == 1 ? "" : "s").")
                    }
                }
        }
        .presentationDragIndicator(.visible)
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    @ViewBuilder
    private var content: some View {
        if importer.imports.isEmpty && importer.queue.isEmpty {
            ContentUnavailableView {
                Label("No Imports Yet", systemImage: "doc.badge.plus")
            } description: {
                Text("Import a PDF, ePub, or text document to populate your wiki. The model reads the full text and creates structured pages — re-import later to refresh with a better model.")
            } actions: {
                Button {
                    showingPicker = true
                } label: {
                    Label("Import Documents", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
            }
        } else {
            List {
                if !importer.queue.isEmpty {
                    Section("In Progress") {
                        ForEach(importer.queue) { job in
                            ImportJobRow(job: job)
                        }
                    }
                }
                if !importer.imports.isEmpty {
                    Section("Imported") {
                        ForEach(importer.imports) { record in
                            DocumentImportRow(
                                record: record,
                                onReimport: { importer.reimport(record) },
                                onDelete: { pendingDelete = record }
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - In-flight Job Row

private struct ImportJobRow: View {
    let job: DocumentImportJob

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.documentType.icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.fileName)
                    .font(.body)
                    .lineLimit(1)
                statusRow
            }

            Spacer(minLength: 8)

            statusGlyph
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch job.status {
        case .importing(let p) where p != nil:
            ProgressView(value: p!.fractionComplete)
                .progressViewStyle(.linear)
                .tint(.accentColor)
            Text(job.label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .completed(let s):
            Text("\(s.pagesCreated) created, \(s.pagesMerged) merged")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
        default:
            Text(job.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch job.status {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .extractingText, .importing:
            ProgressView().controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}

// MARK: - Imported Row

private struct DocumentImportRow: View {
    let record: DocumentImport
    let onReimport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.documentType.icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.fileName)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(record.documentType.label)
                    Text("\u{00B7}")
                    Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                    Text("\u{00B7}")
                    Text("\(record.sourceWikiPageIDs.count) page\(record.sourceWikiPageIDs.count == 1 ? "" : "s")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Text("Imported \(record.importedAt, style: .relative) ago")
                    if record.lastImportedAt > record.importedAt.addingTimeInterval(60) {
                        Text("\u{00B7}")
                        Text("Re-run \(record.lastImportedAt, style: .relative) ago")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                if let err = record.lastErrorMessage {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            Button(action: onReimport) {
                Label("Re-import", systemImage: "arrow.clockwise")
            }
            .tint(.indigo)
        }
        .contextMenu {
            Button(action: onReimport) {
                Label("Re-import", systemImage: "arrow.clockwise")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete\u{2026}", systemImage: "trash")
            }
        }
    }
}
