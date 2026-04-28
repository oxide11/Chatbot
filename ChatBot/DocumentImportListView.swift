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
    var wikiStore: WikiStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingPicker = false
    @State private var pendingDelete: DocumentImport?
    @State private var path: [DocumentImport] = []

    var body: some View {
        NavigationStack(path: $path) {
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
                        if importer.queue.contains(where: { $0.isFinished }) || importer.isProcessing {
                            Menu {
                                if importer.queue.contains(where: { $0.isFinished }) {
                                    Button {
                                        importer.clearFinishedJobs()
                                    } label: {
                                        Label("Clear Finished Jobs", systemImage: "checkmark.circle")
                                    }
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
                .navigationDestination(for: DocumentImport.self) { record in
                    DocumentImportDetailView(
                        record: record,
                        wikiStore: wikiStore,
                        onReimport: { importer.reimport(record) },
                        onDelete: {
                            pendingDelete = record
                        }
                    )
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
                            Task {
                                await importer.delete(record, alsoDeleteWikiPages: true)
                                if path.last == record { path.removeLast() }
                            }
                        }
                    }
                    Button("Forget Import", role: .destructive) {
                        Task {
                            await importer.delete(record, alsoDeleteWikiPages: false)
                            if path.last == record { path.removeLast() }
                        }
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
                if importer.isProcessing
                    || !importer.queue.isEmpty
                    || !importer.imports.isEmpty {
                    Section {
                        StatusBanner(importer: importer)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                }

                if !importer.queue.isEmpty {
                    Section {
                        ForEach(importer.queue) { job in
                            ImportJobRow(job: job)
                        }
                    } header: {
                        sectionHeader("In Progress",
                                      count: importer.queue.count,
                                      systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                if !importer.imports.isEmpty {
                    Section {
                        ForEach(importer.imports) { record in
                            NavigationLink(value: record) {
                                DocumentImportRow(record: record)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDelete = record
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    importer.reimport(record)
                                } label: {
                                    Label("Re-import", systemImage: "arrow.clockwise")
                                }
                                .tint(.indigo)
                            }
                        }
                    } header: {
                        sectionHeader("Imported",
                                      count: importer.imports.count,
                                      systemImage: "checkmark.seal")
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Status Banner

private struct StatusBanner: View {
    var importer: DocumentImporter

    private var inProgressCount: Int {
        importer.queue.filter {
            switch $0.status {
            case .completed, .failed: return false
            default:                  return true
            }
        }.count
    }

    private var importedCount: Int { importer.imports.count }
    private var totalPages: Int {
        importer.imports.reduce(0) { $0 + $1.sourceWikiPageIDs.count }
    }

    var body: some View {
        HStack(spacing: 14) {
            statusIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.callout.weight(.medium))
                Text(subhead)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if inProgressCount > 0 {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private var headline: String {
        if inProgressCount > 0 {
            return "Importing \(inProgressCount) document\(inProgressCount == 1 ? "" : "s")"
        }
        if importedCount == 0 { return "No imports yet" }
        return "\(importedCount) imported"
    }

    private var subhead: String {
        if inProgressCount > 0 {
            if importedCount > 0 {
                return "\(importedCount) already imported · \(totalPages) wiki page\(totalPages == 1 ? "" : "s")"
            }
            return "Reading and extracting…"
        }
        if importedCount == 0 { return "Tap + to add a document" }
        return "\(totalPages) wiki page\(totalPages == 1 ? "" : "s") created from your documents"
    }

    @ViewBuilder
    private var statusIcon: some View {
        Image(systemName: inProgressCount > 0 ? "arrow.triangle.2.circlepath" : "checkmark.seal.fill")
            .font(.title3)
            .foregroundStyle(inProgressCount > 0 ? Color.accentColor : Color.green)
            .frame(width: 32, height: 32)
            .background(
                (inProgressCount > 0 ? Color.accentColor : Color.green).opacity(0.15),
                in: .circle
            )
            .symbolEffect(.rotate, options: .repeating, isActive: inProgressCount > 0)
    }
}

// MARK: - In-flight Job Row

private struct ImportJobRow: View {
    let job: DocumentImportJob

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            typeBadge

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(job.fileName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    statusGlyph
                }

                progressBlock
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.2), value: descriptionForAnimation)
    }

    /// A stable string that captures whatever bit of state should drive
    /// SwiftUI's transition animation (label + percent).
    private var descriptionForAnimation: String {
        switch job.status {
        case .queued:               return "queued"
        case .extractingText:       return "extracting"
        case .importing(let p):
            if let p { return "import:\(p.chunkIndex)/\(p.chunkCount)" }
            return "import:start"
        case .completed:            return "completed"
        case .failed(let m):        return "failed:\(m)"
        }
    }

    private var typeBadge: some View {
        Image(systemName: job.documentType.icon)
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(.fill.tertiary, in: .rect(cornerRadius: 7))
    }

    @ViewBuilder
    private var progressBlock: some View {
        switch job.status {
        case .queued:
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.caption2)
                Text("Queued")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .extractingText:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                Text("Reading document…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .importing(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p?.fractionComplete ?? 0)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                HStack(spacing: 6) {
                    if let p {
                        Text("Chunk \(p.chunkIndex) of \(p.chunkCount)")
                            .monospacedDigit()
                        if p.pagesCreated > 0 || p.pagesMerged > 0 {
                            Text("\u{00B7}")
                            Text("\(p.pagesCreated) created, \(p.pagesMerged) merged")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Sending to model…")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let p {
                        Text("\(Int(p.fractionComplete * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .font(.caption)
            }

        case .completed(let s):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("\(s.pagesCreated) created, \(s.pagesMerged) merged")
                if s.failedChunks > 0 {
                    Text("\u{00B7}")
                    Text("\(s.failedChunks) failed")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)

        case .failed(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(msg)
                    .lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(.red)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.documentType.icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.fill.tertiary, in: .rect(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                Text(record.fileName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(record.documentType.label)
                    Text("\u{00B7}")
                    Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                    Text("\u{00B7}")
                    Text("\(record.sourceWikiPageIDs.count) page\(record.sourceWikiPageIDs.count == 1 ? "" : "s")")
                        .foregroundStyle(record.sourceWikiPageIDs.isEmpty ? .tertiary : .secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("Imported \(record.importedAt, style: .relative) ago")
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
    }
}

// MARK: - Detail View

struct DocumentImportDetailView: View {
    let record: DocumentImport
    var wikiStore: WikiStore
    var onReimport: () -> Void
    var onDelete: () -> Void

    private var producedPages: [WikiPage] {
        let ids = Set(record.sourceWikiPageIDs)
        return wikiStore.pages.filter { ids.contains($0.id) }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: record.documentType.icon)
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                        .frame(width: 56, height: 56)
                        .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.fileName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        HStack(spacing: 4) {
                            Text(record.documentType.label)
                            Text("\u{00B7}")
                            Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Imported") {
                    Text(record.importedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if record.lastImportedAt > record.importedAt.addingTimeInterval(60) {
                    LabeledContent("Last re-imported") {
                        Text(record.lastImportedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                LabeledContent("Wiki pages produced") {
                    Text("\(record.sourceWikiPageIDs.count)")
                        .monospacedDigit()
                }
                if let err = record.lastErrorMessage {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            } header: {
                Text("Details")
            }

            if !producedPages.isEmpty {
                Section {
                    ForEach(producedPages) { page in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(page.title).font(.body.weight(.medium))
                            Text(page.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HStack {
                        Text("Wiki Pages")
                        Spacer()
                        Text("\(producedPages.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } footer: {
                    let missing = record.sourceWikiPageIDs.count - producedPages.count
                    if missing > 0 {
                        Text("\(missing) page\(missing == 1 ? " was" : "s were") deleted from the wiki since this import.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else if !record.sourceWikiPageIDs.isEmpty {
                Section {
                    Text("All \(record.sourceWikiPageIDs.count) page\(record.sourceWikiPageIDs.count == 1 ? "" : "s") this import created have been deleted from the wiki.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("No wiki pages were produced from this import. Re-import after configuring a more capable provider — the same file will be re-extracted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    onReimport()
                } label: {
                    Label("Re-import", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete\u{2026}", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(record.fileName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
