//
//  WikiExtractionProgressView.swift
//  ChatBot
//
//  Modal progress sheet for "Extract to Wiki" runs over a knowledge base
//  document. Owns the launching Task so it can cancel cleanly, and holds
//  a background-task assertion (via BackgroundTask.run) so the work can
//  continue briefly if the user backgrounds the app on iPad.
//

import SwiftUI

struct WikiExtractionProgressView: View {
    let sourceName: String
    let document: KnowledgeBase?
    let domainID: UUID?
    var wikiEngine: WikiEngine
    var knowledgeBaseStore: KnowledgeBaseStore

    @Environment(\.dismiss) private var dismiss
    @State private var progress = WikiDocumentExtractionProgress(
        chunkIndex: 0, chunkCount: 0, pagesCreated: 0, pagesMerged: 0
    )
    @State private var summary: WikiDocumentExtractionSummary?
    @State private var task: Task<Void, Never>?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 0)

                Image(systemName: summary == nil ? "wand.and.stars" : (summary?.cancelled == true ? "stop.circle" : "checkmark.seal.fill"))
                    .font(.system(size: 48))
                    .foregroundStyle(summary?.cancelled == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .symbolEffect(.bounce, value: progress.chunkIndex)

                Text(headline)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(sourceName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if summary == nil {
                    progressBlock
                } else if let s = summary {
                    summaryBlock(s)
                }

                if let err = loadError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer(minLength: 0)

                actionButtons
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Extract to Wiki")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .interactiveDismissDisabled(summary == nil)
            .task { await launch() }
            .onDisappear { task?.cancel() }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var progressBlock: some View {
        VStack(spacing: 10) {
            if progress.chunkCount > 0 {
                ProgressView(value: progress.fractionComplete)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                Text("Chunk \(progress.chunkIndex) of \(progress.chunkCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("\(progress.pagesCreated) page\(progress.pagesCreated == 1 ? "" : "s") created \u{00B7} \(progress.pagesMerged) merged")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            } else {
                ProgressView()
                Text("Loading document…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private func summaryBlock(_ s: WikiDocumentExtractionSummary) -> some View {
        VStack(spacing: 6) {
            Text("\(s.pagesCreated) page\(s.pagesCreated == 1 ? "" : "s") created")
                .font(.callout.weight(.medium))
            Text("\(s.pagesMerged) merged into existing")
                .font(.callout)
                .foregroundStyle(.secondary)
            if s.failedChunks > 0 {
                Text("\(s.failedChunks) chunk\(s.failedChunks == 1 ? "" : "s") failed")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("\(s.chunksProcessed) of \(s.chunkCount) chunks processed")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var actionButtons: some View {
        HStack {
            if summary == nil {
                Button(role: .destructive) {
                    task?.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            } else {
                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(.horizontal)
    }

    private var headline: String {
        if let s = summary {
            if s.cancelled { return "Extraction stopped" }
            if s.failedChunks > 0 { return "Extraction finished with errors" }
            return "Extraction complete"
        }
        return progress.chunkCount > 0 ? "Reading the document…" : "Preparing…"
    }

    // MARK: - Launch

    private func launch() async {
        guard let document else {
            loadError = "Missing document reference."
            return
        }
        let ref = document
        task = Task { @MainActor in
            await BackgroundTask.run("Wiki Extraction") {
                let documentText = await Self.assembleText(for: ref, store: knowledgeBaseStore)
                guard !documentText.isEmpty else {
                    loadError = "No text available for this document."
                    return
                }
                let result = await wikiEngine.extractKnowledgeFromDocument(
                    text: documentText,
                    sourceName: ref.name,
                    sourceDocumentID: ref.id,
                    domainID: domainID
                ) { p in
                    progress = p
                }
                summary = result
            }
        }
    }

    /// Reconstruct the full document text from the stored chunks. We don't keep
    /// the raw extracted text on disk after ingestion, but we do keep ordered
    /// chunks — joining them gives a faithful enough representation for a
    /// second-pass extraction.
    private static func assembleText(
        for kb: KnowledgeBase,
        store: KnowledgeBaseStore
    ) async -> String {
        let chunks = store.allChunks(for: kb.id).sorted { $0.index < $1.index }
        return chunks.map(\.content).joined(separator: "\n\n")
    }
}
