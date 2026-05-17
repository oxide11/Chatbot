//
//  WikiPageDetailView.swift
//  ChatBot
//
//  Read-mode wiki page with markdown + math + wikilink rendering.
//

import SwiftUI

struct WikiPageDetailView: View {
    let page: WikiPage
    var wikiStore: WikiStore
    /// Pushes another page onto the parent NavigationStack when a wikilink is tapped.
    var pushPage: (WikiPage) -> Void
    /// Pushes a `DocumentImport` onto the parent NavigationStack when a
    /// source-document row is tapped. Nil in contexts that can't host a
    /// document detail view (e.g. the wiki sheet presented over a chat
    /// without an importer ref) — source rows render as plain text then.
    var pushDocument: ((DocumentImport) -> Void)? = nil

    @State private var editing: WikiPage?
    @State private var pendingCreation: PendingCreation?
    @State private var showMissingAlert = false
    @State private var missingTitle = ""

    private struct PendingCreation: Identifiable {
        let id = UUID()
        let title: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !page.tags.isEmpty { tagFlow }
                Divider()
                RichContentView(page.body, wikilinkAction: handleWikilink)
                if !sources.isEmpty {
                    Divider().padding(.top, 4)
                    sourcesSection
                }
                Divider().padding(.top, 4)
                metadata
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(page.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = page
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
            }
        }
        .sheet(item: $editing) { p in
            WikiPageEditorView(wikiStore: wikiStore, existing: p)
        }
        .sheet(item: $pendingCreation) { creation in
            WikiPageEditorView(
                wikiStore: wikiStore,
                seedTitle: creation.title
            )
        }
        .alert("No page titled \u{201C}\(missingTitle)\u{201D}",
               isPresented: $showMissingAlert) {
            Button("Create") {
                pendingCreation = PendingCreation(title: missingTitle)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("That wiki page doesn't exist yet. Create it now?")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(page.title)
                .font(.largeTitle.weight(.semibold))
                .textSelection(.enabled)
        }
    }

    private var tagFlow: some View {
        FlowLayout(spacing: 6) {
            ForEach(page.tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.fill.tertiary, in: .capsule)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            metadataRow(icon: "calendar",
                        label: "Created",
                        value: page.createdAt.formatted(date: .abbreviated, time: .shortened))
            metadataRow(icon: "clock.arrow.circlepath",
                        label: "Updated",
                        value: page.updatedAt.formatted(date: .abbreviated, time: .shortened))
            metadataRow(icon: "eye",
                        label: "Accessed",
                        value: "\(page.accessCount) time\(page.accessCount == 1 ? "" : "s")")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metadataRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(.primary)
        }
    }

    private func handleWikilink(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let target = wikiStore.findPageByTitle(trimmed) {
            pushPage(target)
        } else {
            missingTitle = trimmed
            showMissingAlert = true
        }
    }

    // MARK: - Sources

    /// The imports and conversations that contributed to this page.
    /// Resolved via closures on `WikiStore` so the view doesn't need to
    /// know about `DocumentImporter` / `ConversationStore` directly. An
    /// entry whose source has been deleted is dropped silently (the
    /// resolver returns nil) rather than rendering a stale ghost row.
    private var sources: [SourceItem] {
        var items: [SourceItem] = []
        for id in page.sourceDocumentIDs {
            if let record = wikiStore.documentResolver?(id) {
                items.append(SourceItem(kind: .document(record), label: record.fileName))
            }
        }
        for id in page.sourceConversationIDs {
            if let title = wikiStore.conversationTitleResolver?(id) {
                items.append(SourceItem(kind: .conversation, label: title))
            }
        }
        return items
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sources) { item in
                    sourceRow(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func sourceRow(for item: SourceItem) -> some View {
        // Tappable only when (a) we know how to push a document onto the
        // parent nav stack and (b) the source is a document. Conversation
        // sources stay non-tappable here — cross-sheet nav to a chat is
        // a separate problem.
        if case let .document(record) = item.kind, let pushDocument {
            Button {
                pushDocument(record)
            } label: {
                sourceRowContent(item: item, tappable: true)
            }
            .buttonStyle(.plain)
        } else {
            sourceRowContent(item: item, tappable: false)
        }
    }

    private func sourceRowContent(item: SourceItem, tappable: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.iconName)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(item.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(tappable ? Color.accentColor : .primary)
            Spacer(minLength: 0)
            if tappable {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .contentShape(Rectangle())
    }

    private struct SourceItem: Identifiable {
        enum Kind {
            case document(DocumentImport)
            case conversation
        }
        let id = UUID()
        let kind: Kind
        let label: String

        var iconName: String {
            switch kind {
            case .document:     return "doc.text"
            case .conversation: return "bubble.left.and.bubble.right"
            }
        }
    }
}
