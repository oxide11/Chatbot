//
//  WikiLintView.swift
//  ChatBot
//
//  Wiki health "inbox" — surfaces findings from the linter, lets the user
//  drill into each one, review the LLM's proposal side-by-side with the
//  original page(s), and choose what to keep, edit, or remove.
//

import SwiftUI

// MARK: - Lint Inbox

struct WikiLintView: View {
    var linter: WikiLinter
    var wikiStore: WikiStore
    @Environment(\.dismiss) private var dismiss

    @State private var isRunningSemantic = false
    @State private var semanticTask: Task<Void, Never>?
    @State private var path: [WikiLintFinding] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .scrollEdgeEffectStyle(.soft, for: .top)
                .navigationTitle("Wiki Health")
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
                                linter.runStructuralLint()
                            } label: {
                                Label("Re-Scan", systemImage: "arrow.clockwise")
                            }
                            Button {
                                runSemantic()
                            } label: {
                                Label(linter.report.semanticReviewComplete ? "Re-Run AI Review" : "AI Review",
                                      systemImage: "wand.and.stars")
                            }
                            .disabled(linter.report.findings.isEmpty || isRunningSemantic)
                        } label: {
                            Label("Actions", systemImage: "ellipsis.circle")
                        }
                    }
                }
                .navigationDestination(for: WikiLintFinding.self) { finding in
                    WikiLintFindingDetail(
                        finding: finding,
                        linter: linter,
                        wikiStore: wikiStore,
                        onClose: { path.removeLast() }
                    )
                }
                .task {
                    if linter.report.generatedAt == .distantPast {
                        linter.runStructuralLint()
                    }
                }
                .onDisappear { semanticTask?.cancel() }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if linter.report.findings.isEmpty && !linter.isRunning {
            ContentUnavailableView {
                Label("Wiki is Healthy", systemImage: "checkmark.seal.fill")
            } description: {
                Text("No structural issues found across \(linter.report.pagesAnalyzed) page\(linter.report.pagesAnalyzed == 1 ? "" : "s").")
            } actions: {
                Button {
                    linter.runStructuralLint()
                } label: {
                    Label("Re-Scan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
            }
        } else {
            List {
                if isRunningSemantic, let progress = linter.report.semanticReviewProgress {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("AI review in progress")
                                    .font(.callout)
                                Spacer()
                                Text("\(progress.processed) / \(progress.total)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(progress.processed),
                                         total: Double(max(progress.total, 1)))
                                .tint(.accentColor)
                        }
                        .padding(.vertical, 2)
                    }
                }

                ForEach(linter.report.grouped, id: \.kind) { kind, findings in
                    Section {
                        ForEach(findings) { finding in
                            NavigationLink(value: finding) {
                                FindingRow(finding: finding, wikiStore: wikiStore)
                            }
                        }
                    } header: {
                        HStack {
                            Image(systemName: kind.iconSystemName)
                            Text(kind.displayName)
                            Spacer()
                            Text("\(findings.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                Section {
                    Text(linter.report.generatedAt == .distantPast
                         ? "Run a scan to begin."
                         : "Scanned \(linter.report.pagesAnalyzed) page\(linter.report.pagesAnalyzed == 1 ? "" : "s") on \(linter.report.generatedAt.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
        }
    }

    // MARK: - Semantic launcher

    private func runSemantic() {
        guard !isRunningSemantic else { return }
        isRunningSemantic = true
        semanticTask = Task { @MainActor in
            await BackgroundTask.run("Wiki AI Review") {
                await linter.runSemanticReview()
            }
            isRunningSemantic = false
        }
    }
}

// MARK: - Finding Row

private struct FindingRow: View {
    let finding: WikiLintFinding
    var wikiStore: WikiStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if finding.suggestion != nil {
                    Image(systemName: "wand.and.stars")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
                Text(primaryTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let secondaryTitle {
                    Text("\u{2194}")
                        .foregroundStyle(.tertiary)
                    Text(secondaryTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(Int(finding.confidence * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(finding.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var primaryTitle: String {
        if let target = finding.linkTarget, finding.kind == .missingPage {
            return target.capitalized
        }
        return wikiStore.pages.first(where: { $0.id == finding.primaryPageID })?.title
            ?? "(unknown page)"
    }

    private var secondaryTitle: String? {
        guard let id = finding.secondaryPageID else { return nil }
        return wikiStore.pages.first(where: { $0.id == id })?.title
    }
}

// MARK: - Detail View

struct WikiLintFindingDetail: View {
    let finding: WikiLintFinding
    var linter: WikiLinter
    var wikiStore: WikiStore
    var onClose: () -> Void

    var body: some View {
        Group {
            switch finding.kind {
            case .duplicateCandidate:
                DuplicateMergeView(finding: finding, linter: linter,
                                   wikiStore: wikiStore, onClose: onClose)
            case .brokenLink:
                BrokenLinkView(finding: finding, linter: linter,
                               wikiStore: wikiStore, onClose: onClose)
            case .missingPage:
                MissingPageView(finding: finding, linter: linter,
                                wikiStore: wikiStore, onClose: onClose)
            case .orphan:
                OrphanView(finding: finding, linter: linter,
                           wikiStore: wikiStore, onClose: onClose)
            case .stalePage:
                StalePageView(finding: finding, linter: linter,
                              wikiStore: wikiStore, onClose: onClose)
            case .deadEnd:
                DeadEndView(finding: finding, wikiStore: wikiStore,
                            linter: linter, onClose: onClose)
            case .contradiction:
                ContradictionView(finding: finding, linter: linter,
                                  wikiStore: wikiStore, onClose: onClose)
            }
        }
        .navigationTitle(finding.kind.displayName.dropLast())
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Duplicate Merge (the meaty one)

private struct DuplicateMergeView: View {
    let finding: WikiLintFinding
    var linter: WikiLinter
    var wikiStore: WikiStore
    var onClose: () -> Void

    @State private var mergedTitle: String = ""
    @State private var mergedBody: String = ""
    @State private var mergedTagsText: String = ""
    @State private var keepPageID: UUID?

    private var primary: WikiPage? { wikiStore.pages.first { $0.id == finding.primaryPageID } }
    private var secondary: WikiPage? {
        guard let id = finding.secondaryPageID else { return nil }
        return wikiStore.pages.first { $0.id == id }
    }

    var body: some View {
        Form {
            if let a = primary, let b = secondary {
                Section {
                    pagePreview(a, isSelected: keepPageID == a.id) {
                        keepPageID = a.id
                        mergedTitle = a.title
                        mergedBody = mergeBodies(keep: a, drop: b)
                        mergedTagsText = mergedTags(a, b).joined(separator: ", ")
                    }
                    pagePreview(b, isSelected: keepPageID == b.id) {
                        keepPageID = b.id
                        mergedTitle = b.title
                        mergedBody = mergeBodies(keep: b, drop: a)
                        mergedTagsText = mergedTags(a, b).joined(separator: ", ")
                    }
                } header: {
                    Text("Pages")
                } footer: {
                    Text("Tap a page to use it as the surviving title. The other page will be deleted after merge.")
                }

                Section {
                    TextField("Title", text: $mergedTitle)
                    TextField("Body", text: $mergedBody, axis: .vertical)
                        .font(.callout)
                        .lineLimit(6...20)
                    #if os(iOS) || os(tvOS) || os(visionOS)
                    TextField("Comma-separated tags", text: $mergedTagsText)
                        .textInputAutocapitalization(.never)
                    #else
                    TextField("Comma-separated tags", text: $mergedTagsText)
                    #endif
                } header: {
                    Text("Merged page")
                } footer: {
                    if let suggestion = finding.suggestion, case .mergePages = suggestion {
                        Label("Pre-filled from AI review. Edit before saving.",
                              systemImage: "wand.and.stars")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Run AI review from the inbox menu to pre-fill a merge proposal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        applyMerge()
                    } label: {
                        Label("Save Merge", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(keepPageID == nil
                              || mergedTitle.trimmingCharacters(in: .whitespaces).isEmpty
                              || mergedBody.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button {
                        Task {
                            await linter.apply(.keepBoth, to: finding)
                            onClose()
                        }
                    } label: {
                        Label("Keep Both", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    Button(role: .destructive) {
                        Task {
                            await linter.apply(.dismiss, to: finding)
                            onClose()
                        }
                    } label: {
                        Label("Dismiss", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            } else {
                Section {
                    Text("Pages no longer exist.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onAppear {
            if let suggestion = finding.suggestion,
               case .mergePages(let title, let body, let tags) = suggestion {
                mergedTitle = title
                mergedBody = body
                mergedTagsText = tags.joined(separator: ", ")
            } else if let a = primary {
                mergedTitle = a.title
                mergedBody = a.body
                mergedTagsText = a.tags.joined(separator: ", ")
            }
            if keepPageID == nil { keepPageID = primary?.id }
        }
    }

    @ViewBuilder
    private func pagePreview(_ page: WikiPage, isSelected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    Text(page.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("Updated \(page.updatedAt, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(page.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func mergeBodies(keep: WikiPage, drop: WikiPage) -> String {
        let keepLines = Set(keep.body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        let dropAdditions = drop.body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !keepLines.contains($0.lowercased()) }
        if dropAdditions.isEmpty { return keep.body }
        return keep.body + "\n" + dropAdditions.joined(separator: "\n")
    }

    private func mergedTags(_ a: WikiPage, _ b: WikiPage) -> [String] {
        Array(Set(a.tags + b.tags)).sorted()
    }

    private func applyMerge() {
        guard let keepID = keepPageID,
              let dropID = (keepID == finding.primaryPageID
                            ? finding.secondaryPageID
                            : finding.primaryPageID) else { return }
        let title = mergedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = mergedBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = mergedTagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let action = WikiLintAction.mergeIntoPrimary(
            title: title,
            body: body,
            tags: tags,
            deletePageID: dropID
        )
        let primaryFinding = WikiLintFinding(
            id: finding.id,
            kind: finding.kind,
            primaryPageID: keepID,
            secondaryPageID: dropID,
            confidence: finding.confidence,
            summary: finding.summary,
            suggestion: finding.suggestion
        )
        Task {
            await linter.apply(action, to: primaryFinding)
            onClose()
        }
    }
}

// MARK: - Broken Link View

private struct BrokenLinkView: View {
    let finding: WikiLintFinding
    var linter: WikiLinter
    var wikiStore: WikiStore
    var onClose: () -> Void

    @State private var rewriteTarget = ""

    private var page: WikiPage? { wikiStore.pages.first { $0.id == finding.primaryPageID } }

    var body: some View {
        Form {
            if let p = page, let target = finding.linkTarget {
                Section {
                    LabeledContent("From page", value: p.title)
                    LabeledContent("Broken link", value: "[[\(target)]]")
                }

                Section("Context") {
                    Text(snippet(around: target, in: p.body))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let suggestion = finding.suggestion,
                   case .createStub(let title, let body, let tags) = suggestion {
                    Section("AI-Drafted Stub") {
                        Text(title).font(.headline)
                        Text(body).font(.callout).foregroundStyle(.secondary)
                        if !tags.isEmpty {
                            Text(tags.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            Task {
                                await linter.apply(
                                    .createPage(title: title, body: body, tags: tags),
                                    to: finding
                                )
                                onClose()
                            }
                        } label: {
                            Label("Create This Page", systemImage: "doc.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                }

                Section("Repoint Link") {
                    Picker("Existing page", selection: $rewriteTarget) {
                        Text("(none)").tag("")
                        ForEach(candidatePages(target: target), id: \.id) { c in
                            Text(c.title).tag(c.title)
                        }
                    }
                    Button {
                        guard !rewriteTarget.isEmpty else { return }
                        Task {
                            await linter.apply(
                                .rewriteLink(from: target, to: rewriteTarget),
                                to: finding
                            )
                            onClose()
                        }
                    } label: {
                        Label("Repoint to selected", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(rewriteTarget.isEmpty)
                }

                Section {
                    Button {
                        Task {
                            await linter.apply(.stripBrokenLink(target: target), to: finding)
                            onClose()
                        }
                    } label: {
                        Label("Remove [[]] markup, keep text", systemImage: "scissors")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    Button(role: .destructive) {
                        Task {
                            await linter.apply(.dismiss, to: finding)
                            onClose()
                        }
                    } label: {
                        Label("Dismiss", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private func snippet(around target: String, in body: String) -> String {
        guard let range = body.range(of: "[[\(target)]]") else { return body }
        let lower = body.index(range.lowerBound, offsetBy: -120, limitedBy: body.startIndex) ?? body.startIndex
        let upper = body.index(range.upperBound, offsetBy: 120, limitedBy: body.endIndex) ?? body.endIndex
        return "\u{2026}\(body[lower..<upper])\u{2026}"
    }

    private func candidatePages(target: String) -> [WikiPage] {
        let lowered = target.lowercased()
        return wikiStore.pages
            .filter { $0.title.lowercased().contains(lowered) || lowered.contains($0.title.lowercased()) }
            .prefix(10)
            .map { $0 }
    }
}

// MARK: - Missing Page

private struct MissingPageView: View {
    let finding: WikiLintFinding
    var linter: WikiLinter
    var wikiStore: WikiStore
    var onClose: () -> Void

    @State private var draftBody: String = ""
    @State private var draftTags: String = ""
    @State private var draftTitle: String = ""

    private var page: WikiPage? { wikiStore.pages.first { $0.id == finding.primaryPageID } }

    var body: some View {
        Form {
            if finding.linkTarget != nil {
                Section("Concept") {
                    TextField("Title", text: $draftTitle)
                    TextField("Body", text: $draftBody, axis: .vertical)
                        .font(.callout)
                        .lineLimit(4...12)
                    #if os(iOS) || os(tvOS) || os(visionOS)
                    TextField("Tags, comma-separated", text: $draftTags)
                        .textInputAutocapitalization(.never)
                    #else
                    TextField("Tags, comma-separated", text: $draftTags)
                    #endif
                }

                if let p = page {
                    Section("Mentioned in") {
                        Text(p.title).font(.headline)
                        Text(p.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                    }
                }

                Section {
                    Button {
                        let tags = draftTags.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                            .filter { !$0.isEmpty }
                        Task {
                            await linter.apply(
                                .createPage(
                                    title: draftTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                                    body: draftBody.trimmingCharacters(in: .whitespacesAndNewlines),
                                    tags: tags
                                ),
                                to: finding
                            )
                            onClose()
                        }
                    } label: {
                        Label("Create Page", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(role: .destructive) {
                        Task {
                            await linter.apply(.dismiss, to: finding)
                            onClose()
                        }
                    } label: {
                        Label("Dismiss", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onAppear {
            if let suggestion = finding.suggestion,
               case .createStub(let title, let body, let tags) = suggestion {
                draftTitle = title
                draftBody = body
                draftTags = tags.joined(separator: ", ")
            } else if let target = finding.linkTarget {
                draftTitle = target.capitalized
            }
        }
    }
}

// MARK: - Orphan / Stale / Dead-End / Contradiction

private struct OrphanView: View {
    let finding: WikiLintFinding
    var linter: WikiLinter
    var wikiStore: WikiStore
    var onClose: () -> Void

    var body: some View {
        SimplePageActionView(
            page: wikiStore.pages.first { $0.id == finding.primaryPageID },
            primaryAction: ("Keep — Add Inbound Links Later", "checkmark.circle", false, {
                Task { await linter.apply(.dismiss, to: finding); onClose() }
            }),
            destructiveAction: ("Delete Page", "trash", {
                Task { await linter.apply(.deletePrimary, to: finding); onClose() }
            })
        )
    }
}

private struct StalePageView: View {
    let finding: WikiLintFinding
    var linter: WikiLinter
    var wikiStore: WikiStore
    var onClose: () -> Void

    var body: some View {
        SimplePageActionView(
            page: wikiStore.pages.first { $0.id == finding.primaryPageID },
            primaryAction: ("Keep — Mark Reviewed", "hand.thumbsup", false, {
                Task { await linter.apply(.dismiss, to: finding); onClose() }
            }),
            destructiveAction: ("Delete Stale Page", "trash", {
                Task { await linter.apply(.deletePrimary, to: finding); onClose() }
            })
        )
    }
}

private struct DeadEndView: View {
    let finding: WikiLintFinding
    var wikiStore: WikiStore
    var linter: WikiLinter
    var onClose: () -> Void

    var body: some View {
        SimplePageActionView(
            page: wikiStore.pages.first { $0.id == finding.primaryPageID },
            primaryAction: ("Keep — I'll Add Links", "checkmark.circle", false, {
                Task { await linter.apply(.dismiss, to: finding); onClose() }
            }),
            destructiveAction: nil
        )
    }
}

private struct ContradictionView: View {
    let finding: WikiLintFinding
    var linter: WikiLinter
    var wikiStore: WikiStore
    var onClose: () -> Void

    var body: some View {
        Form {
            Section {
                Text(finding.summary)
            }
            Section {
                Button {
                    Task { await linter.apply(.dismiss, to: finding); onClose() }
                } label: {
                    Label("Mark Reviewed", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Simple Page Action Helper

private struct SimplePageActionView: View {
    let page: WikiPage?
    let primaryAction: (label: String, icon: String, prominent: Bool, action: () -> Void)
    let destructiveAction: (label: String, icon: String, action: () -> Void)?

    var body: some View {
        Form {
            if let p = page {
                Section {
                    Text(p.title).font(.title3.weight(.semibold))
                    Text(p.body)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(20)
                    HStack {
                        Label("\(p.tags.count) tag\(p.tags.count == 1 ? "" : "s")", systemImage: "tag")
                        Spacer()
                        Label("\(p.accessCount) access\(p.accessCount == 1 ? "" : "es")", systemImage: "eye")
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }

            Section {
                if primaryAction.prominent {
                    Button(action: primaryAction.action) {
                        Label(primaryAction.label, systemImage: primaryAction.icon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    Button(action: primaryAction.action) {
                        Label(primaryAction.label, systemImage: primaryAction.icon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }

                if let destructive = destructiveAction {
                    Button(role: .destructive, action: destructive.action) {
                        Label(destructive.label, systemImage: destructive.icon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}
