//
//  WikiViews.swift
//  ChatBot
//
//  Wiki page browser, editor, and flow layout for tag pills.
//

import SwiftUI

// MARK: - Wiki Page Editor View (Add & Edit)

struct WikiPageEditorView: View {
    var wikiStore: WikiStore
    var existing: WikiPage?
    var seedTitle: String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var pageBody = ""
    @State private var tagsText = ""

    private var isEditing: Bool { existing != nil }
    private var viewTitle: String { isEditing ? "Edit Wiki Page" : "New Wiki Page" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Page title", text: $title)
                } header: {
                    Text("Title")
                }

                Section {
                    TextField("Page content", text: $pageBody, axis: .vertical)
                        .lineLimit(3...10)
                } header: {
                    Text("Body")
                } footer: {
                    Text("Supports markdown, `$inline$` math, `$$display$$` math, code fences, and `[[wikilinks]]`.")
                }

                Section {
                    #if os(iOS) || os(tvOS) || os(visionOS)
                    TextField("swift, coding, preference", text: $tagsText)
                        .textInputAutocapitalization(.never)
                    #else
                    TextField("swift, coding, preference", text: $tagsText)
                    #endif
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Comma-separated. Leave blank to auto-detect from content.")
                }

                if isEditing, let page = existing {
                    Section {
                        LabeledContent("Created", value: page.createdAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Updated", value: page.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Accessed", value: "\(page.accessCount) times")
                    } header: {
                        Text("Info")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(viewTitle)
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
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || pageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let page = existing {
                    title = page.title
                    pageBody = page.body
                    tagsText = page.tags.joined(separator: ", ")
                } else if let seed = seedTitle, title.isEmpty {
                    title = seed
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = pageBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedBody.isEmpty else { return }

        let tags: [String]
        let trimmedTags = tagsText.trimmingCharacters(in: .whitespaces)
        if trimmedTags.isEmpty {
            tags = SharedDataManager.extractKeywords(from: "\(trimmedTitle) \(trimmedBody)", limit: 5)
        } else {
            tags = trimmedTags.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        }

        if let page = existing {
            Task {
                await wikiStore.updatePage(id: page.id, body: trimmedBody, tags: tags)
            }
        } else {
            Task {
                await wikiStore.createPage(
                    title: trimmedTitle,
                    body: trimmedBody,
                    tags: tags,
                    sourceConversationID: nil
                )
            }
        }
        dismiss()
    }
}

// MARK: - Flow Layout (for tag pills)

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

// MARK: - Wiki Page List View

struct WikiPageListView: View {
    var wikiStore: WikiStore
    /// When non-nil, the navigation stack opens with this page already
    /// pushed — used for the "tap an inline citation in chat" flow.
    var initialPage: WikiPage? = nil
    /// Optional `DocumentImporter` reference. When set, source-document
    /// rows in `WikiPageDetailView` become tappable and push
    /// `DocumentImportDetailView` onto this view's nav stack.
    /// Contexts that can't host that detail (e.g. the wiki sheet
    /// presented from inline chat citations) leave it nil and source
    /// rows render as plain text.
    var documentImporter: DocumentImporter? = nil

    @Environment(\.dismiss) private var dismiss
    /// `NavigationPath` instead of `[WikiPage]` so the stack can hold
    /// both `WikiPage` and `DocumentImport` destinations.
    @State private var path = NavigationPath()
    @State private var showingDeleteAllConfirmation = false
    @State private var showingAddPage = false
    @State private var pendingDelete: DocumentImport?
    /// Drives the `.fileExporter` for "Export Wiki…". The actual
    /// document is constructed lazily from the current `wikiStore.pages`
    /// each time the sheet is presented so an export reflects the
    /// latest state, not whatever was loaded when the view first
    /// appeared.
    @State private var isExporting = false

    /// Default folder name suggested by the file exporter. Date-stamped
    /// so successive exports don't collide in the picker.
    private var exportDefaultFilename: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "Engram Wiki \(f.string(from: Date()))"
    }

    var body: some View {
        NavigationStack(path: $path) {
            pageContent
                .scrollEdgeEffectStyle(.soft, for: .top)
                .navigationTitle("Wiki Pages")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAddPage = true
                        } label: {
                            Label("Add Wiki Page", systemImage: "plus")
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        if !wikiStore.pages.isEmpty {
                            Menu {
                                Button {
                                    isExporting = true
                                } label: {
                                    Label("Export Wiki\u{2026}", systemImage: "square.and.arrow.up")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    showingDeleteAllConfirmation = true
                                } label: {
                                    Label("Clear All Pages", systemImage: "trash")
                                }
                            } label: {
                                Label("More", systemImage: "ellipsis.circle")
                            }
                        }
                    }
                }
                .navigationDestination(for: WikiPage.self) { destination in
                    WikiPageDetailView(
                        page: destination,
                        wikiStore: wikiStore,
                        pushPage: { path.append($0) },
                        pushDocument: documentImporter == nil ? nil : { path.append($0) }
                    )
                }
                .navigationDestination(for: DocumentImport.self) { record in
                    if let importer = documentImporter {
                        DocumentImportDetailView(
                            record: record,
                            wikiStore: wikiStore,
                            onReimport: { importer.reimport(record) },
                            onDelete: { pendingDelete = record }
                        )
                    }
                }
                .alert("Clear All Wiki Pages?", isPresented: $showingDeleteAllConfirmation) {
                    Button("Clear All", role: .destructive) {
                        Task { await wikiStore.deleteAllPages() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently delete all wiki pages.")
                }
                .confirmationDialog(
                    "Delete \(pendingDelete?.fileName ?? "")?",
                    isPresented: Binding(
                        get: { pendingDelete != nil },
                        set: { if !$0 { pendingDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete Import Only", role: .destructive) {
                        if let record = pendingDelete, let importer = documentImporter {
                            Task { await importer.delete(record, alsoDeleteWikiPages: false) }
                        }
                        pendingDelete = nil
                    }
                    Button("Delete Import + Wiki Pages", role: .destructive) {
                        if let record = pendingDelete, let importer = documentImporter {
                            Task { await importer.delete(record, alsoDeleteWikiPages: true) }
                        }
                        pendingDelete = nil
                    }
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                }
                .sheet(isPresented: $showingAddPage) {
                    WikiPageEditorView(wikiStore: wikiStore)
                }
                .fileExporter(
                    isPresented: $isExporting,
                    document: WikiExportDocument(
                        pages: wikiStore.pages,
                        conversationTitle: { wikiStore.conversationTitleResolver?($0) },
                        documentName: { wikiStore.documentResolver?($0)?.fileName }
                    ),
                    contentType: .folder,
                    defaultFilename: exportDefaultFilename
                ) { result in
                    if case .failure(let error) = result {
                        AppLogger.wiki.error("Wiki export failed: \(error.localizedDescription)")
                    }
                }
                .onAppear {
                    if let initialPage, path.isEmpty {
                        path.append(initialPage)
                    }
                }
        }
        .presentationDragIndicator(.visible)
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 400, idealHeight: 560)
        #endif
    }

    @ViewBuilder
    private var pageContent: some View {
        if wikiStore.pages.isEmpty {
            ContentUnavailableView {
                Label("No Wiki Pages", systemImage: "book.pages")
            } description: {
                Text("Wiki pages are automatically created from conversations, or you can add them manually.")
            } actions: {
                Button {
                    showingAddPage = true
                } label: {
                    Label("Add Wiki Page", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
            }
        } else {
            List {
                ForEach(wikiStore.pages) { page in
                    NavigationLink(value: page) {
                        WikiPageRow(page: page)
                    }
                    .contextMenu {
                        Button {
                            path.append(page)
                        } label: {
                            Label("Open", systemImage: "doc.text")
                        }

                        Button(role: .destructive) {
                            Task { await wikiStore.deletePage(id: page.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Wiki Page Row

private struct WikiPageRow: View {
    let page: WikiPage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(page.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(page.body)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(2)

            if !page.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(page.tags.prefix(4), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.fill.tertiary, in: .capsule)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 4) {
                Text("Updated \(page.updatedAt, style: .relative) ago")
                Text("\u{00B7}")
                Text("\(page.accessCount) access\(page.accessCount == 1 ? "" : "es")")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
