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
            if let name = wikiStore.documentTitleResolver?(id) {
                items.append(SourceItem(kind: .document, label: name))
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
                    HStack(spacing: 8) {
                        Image(systemName: item.kind.icon)
                            .foregroundStyle(.tertiary)
                            .frame(width: 14)
                        Text(item.label)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private struct SourceItem: Identifiable {
        enum Kind {
            case document, conversation

            var icon: String {
                switch self {
                case .document:     return "doc.text"
                case .conversation: return "bubble.left.and.bubble.right"
                }
            }
        }
        let id = UUID()
        let kind: Kind
        let label: String
    }
}
