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
}
