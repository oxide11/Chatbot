//
//  WikiLinter.swift
//  ChatBot
//
//  Wiki health analyzer (Karpathy LLM-Wiki "lint"). Two passes:
//  - Structural: pure-Swift, fast. No model calls. Surfaces broken links,
//    orphans, dead-ends, duplicate candidates, stale pages, missing pages.
//  - Semantic: LLM-driven. Proposes merges, drafts stubs for missing /
//    broken-link concepts, flags contradictions between similar pages.
//
//  All actions are surfaced to the user — nothing is auto-applied.
//

import Foundation
import os
import FoundationModels

@MainActor
@Observable
final class WikiLinter {
    let wikiStore: WikiStore

    /// Set by ConversationStore. Routes the semantic pass to whichever
    /// provider the user has bound to the `.lint` task.
    var providerRegistry: ProviderRegistry?

    /// Latest report. Replaced wholesale by each lint run.
    private(set) var report: WikiLintReport = .empty

    /// True while a structural or semantic pass is in flight.
    private(set) var isRunning: Bool = false

    /// Tunable similarity threshold (0...1) for duplicate detection.
    /// 0.85 is a reasonable starting point.
    var similarityThreshold: Double = 0.85

    /// Days an unread page must sit before being considered stale.
    var staleAfterDays: Double = 90

    /// Min number of pages mentioning a capitalized phrase before we suggest
    /// it deserves its own page.
    var missingPageMentionThreshold: Int = 3

    init(wikiStore: WikiStore) {
        self.wikiStore = wikiStore
    }

    // MARK: - Structural Pass

    /// Build a fresh report from the current wiki contents. Returns the
    /// number of findings. Always succeeds and replaces `report`.
    @discardableResult
    func runStructuralLint() -> WikiLintReport {
        isRunning = true
        defer { isRunning = false }

        let pages = wikiStore.pages
        var findings: [WikiLintFinding] = []
        let titleByLowered: [String: WikiPage] = Dictionary(
            uniqueKeysWithValues: pages.map { ($0.title.lowercased(), $0) }
        )

        // --- Outbound and inbound link maps ---
        var outboundByPage: [UUID: [String]] = [:]
        var inboundByTitle: [String: [UUID]] = [:]
        for page in pages {
            let targets = WikiExtractionPrompts.extractWikilinks(from: page.body)
            outboundByPage[page.id] = targets
            for target in targets {
                inboundByTitle[target.lowercased(), default: []].append(page.id)
            }
        }

        // --- 1. Broken links + missing-page candidates ---
        var brokenTargetCounts: [String: Int] = [:]
        for (pageID, targets) in outboundByPage {
            for target in Set(targets) {
                let lowered = target.lowercased()
                if titleByLowered[lowered] == nil {
                    brokenTargetCounts[lowered, default: 0] += 1
                    findings.append(WikiLintFinding(
                        kind: .brokenLink,
                        primaryPageID: pageID,
                        linkTarget: target,
                        confidence: 1.0,
                        summary: "Link points at \u{201C}\(target)\u{201D}, which has no wiki page."
                    ))
                }
            }
        }

        // A broken target referenced from N pages becomes a missingPage finding too.
        for (loweredTarget, count) in brokenTargetCounts where count >= 2 {
            // Pick the first page that references it as the "primary" so
            // the user has somewhere to read context.
            let referencingPageID = inboundByTitle[loweredTarget]?.first ?? UUID()
            findings.append(WikiLintFinding(
                kind: .missingPage,
                primaryPageID: referencingPageID,
                linkTarget: loweredTarget,
                confidence: min(1.0, Double(count) / 5.0),
                summary: "\u{201C}\(loweredTarget.capitalized)\u{201D} is referenced by \(count) pages but doesn't exist."
            ))
        }

        // --- 2. Orphan pages (no inbound links) ---
        for page in pages {
            let inbound = inboundByTitle[page.title.lowercased()] ?? []
            if inbound.isEmpty && page.accessCount < 2 {
                findings.append(WikiLintFinding(
                    kind: .orphan,
                    primaryPageID: page.id,
                    confidence: 0.5,
                    summary: "No other page links to \u{201C}\(page.title)\u{201D}."
                ))
            }
        }

        // --- 3. Dead-end pages (no outbound links) ---
        for page in pages {
            if (outboundByPage[page.id] ?? []).isEmpty && page.body.count > 200 {
                findings.append(WikiLintFinding(
                    kind: .deadEnd,
                    primaryPageID: page.id,
                    confidence: 0.4,
                    summary: "\u{201C}\(page.title)\u{201D} has no outbound [[wikilinks]]."
                ))
            }
        }

        // --- 4. Duplicate candidates by embedding similarity ---
        // Within the same domain only — different domains may legitimately
        // describe overlapping concepts in their own context.
        let pagesWithEmbeddings = pages.filter { $0.embedding != nil }
        for i in 0..<pagesWithEmbeddings.count {
            for j in (i + 1)..<pagesWithEmbeddings.count {
                let a = pagesWithEmbeddings[i]
                let b = pagesWithEmbeddings[j]
                guard let av = a.embedding, let bv = b.embedding else { continue }
                let similarity = EmbeddingService.cosineSimilarity(av, bv)
                if similarity >= similarityThreshold {
                    findings.append(WikiLintFinding(
                        kind: .duplicateCandidate,
                        primaryPageID: a.id,
                        secondaryPageID: b.id,
                        confidence: similarity,
                        summary: "\u{201C}\(a.title)\u{201D} and \u{201C}\(b.title)\u{201D} share \(Int(similarity * 100))% semantic similarity."
                    ))
                }
            }
        }

        // --- 5. Stale pages ---
        let now = Date()
        for page in pages {
            let ageDays = now.timeIntervalSince(page.updatedAt) / 86_400
            if ageDays > staleAfterDays && page.accessCount == 0 {
                findings.append(WikiLintFinding(
                    kind: .stalePage,
                    primaryPageID: page.id,
                    confidence: min(1.0, ageDays / (staleAfterDays * 4)),
                    summary: "Last updated \(Int(ageDays)) days ago, never read."
                ))
            }
        }

        let report = WikiLintReport(
            findings: findings.sorted { $0.confidence > $1.confidence },
            generatedAt: Date(),
            pagesAnalyzed: pages.count,
            semanticReviewComplete: false,
            semanticReviewProgress: nil
        )
        self.report = report
        AppLogger.wiki.info("Structural lint: \(findings.count) finding(s) across \(pages.count) page(s)")
        return report
    }

    // MARK: - Semantic Pass

    /// Run the LLM over each finding that benefits from semantic review,
    /// populating `suggestion` on each. Honors cancellation.
    func runSemanticReview(
        onProgress: @MainActor @Sendable (Int, Int) -> Void = { _, _ in }
    ) async {
        let candidates = report.findings.indices.filter {
            report.findings[$0].kind.requiresSemanticReview
                && !report.findings[$0].isDismissed
                && report.findings[$0].suggestion == nil
        }
        guard !candidates.isEmpty else {
            report.semanticReviewComplete = true
            return
        }

        isRunning = true
        defer {
            isRunning = false
            report.semanticReviewComplete = true
            report.semanticReviewProgress = nil
        }

        report.semanticReviewProgress = .init(processed: 0, total: candidates.count)

        for (idx, findingIndex) in candidates.enumerated() {
            if Task.isCancelled { break }
            let finding = report.findings[findingIndex]
            do {
                let suggestion = try await suggestion(for: finding)
                report.findings[findingIndex].suggestion = suggestion
            } catch {
                AppLogger.wiki.error("Semantic lint failed for \(finding.kind.rawValue): \(error.localizedDescription)")
            }
            report.semanticReviewProgress = .init(processed: idx + 1, total: candidates.count)
            onProgress(idx + 1, candidates.count)
        }
    }

    private static let semanticSystemPrompt = """
        You review a personal wiki for duplicates, missing pages, and contradictions. \
        Be conservative: when in doubt, prefer the literal sentinel words KEEP_BOTH or SKIP \
        over a low-confidence merge or stub. Output only the requested format — no preamble, no commentary.
        """

    /// Run a single LLM round-trip and decode the response into a
    /// `Generable` type. The FoundationModels path returns the typed value
    /// directly (no parser); the remote-provider path returns text and the
    /// caller-supplied `decodeText` adapter wraps it back into the typed
    /// shape via `WikiExtractionPrompts.parse*`.
    private func respondGenerable<T: Generable & Sendable>(
        prompt: String,
        maxTokens: Int,
        generating type: T.Type,
        decodeText: (String) -> T
    ) async throws -> T {
        if let provider = providerRegistry?.resolve(for: .lint) {
            let text = try await provider.respond(
                history: [ProviderMessage(role: .user, content: prompt)],
                systemPrompt: Self.semanticSystemPrompt,
                options: ProviderGenerationOptions(maxOutputTokens: maxTokens, temperature: 1.0)
            )
            return decodeText(text)
        }
        let session = LanguageModelSession { Self.semanticSystemPrompt }
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
        let response = try await session.respond(to: prompt, generating: type, options: options)
        return response.content
    }

    private func suggestion(for finding: WikiLintFinding) async throws -> WikiLintSuggestion {
        switch finding.kind {
        case .duplicateCandidate:
            return try await mergeSuggestion(for: finding)
        case .missingPage:
            return try await stubSuggestion(for: finding)
        case .contradiction:
            return .noAction(rationale: "Manual review required.")
        default:
            return .noAction(rationale: "No semantic action available for this kind.")
        }
    }

    private func mergeSuggestion(for finding: WikiLintFinding) async throws -> WikiLintSuggestion {
        guard
            let a = wikiStore.pages.first(where: { $0.id == finding.primaryPageID }),
            let secID = finding.secondaryPageID,
            let b = wikiStore.pages.first(where: { $0.id == secID })
        else {
            return .noAction(rationale: "Page no longer exists.")
        }

        let prompt = """
        Decide whether these two wiki pages describe the same concept.

        - If they are the same concept, output a merged page that keeps every distinct fact from both (deduplicate exact repeats; preserve numbers, names, and `[[wikilinks]]` from either source).
        - If they are related but distinct, respond with exactly: KEEP_BOTH

        Output one of:
          (a) KEEP_BOTH on a single line by itself, or
          (b) a single page block in this exact shape (no preamble, no commentary):

        ---PAGE---
        TITLE: <best surviving title>
        TAGS: <comma-separated, lowercase>
        BODY:
        <merged content; bullet points; ≤120 words>
        ---END---

        --- Page A: \(a.title) ---
        \(a.body)

        --- Page B: \(b.title) ---
        \(b.body)
        """

        let decision = try await respondGenerable(
            prompt: prompt,
            maxTokens: 400,
            generating: WikiMergeDecision.self,
            decodeText: WikiExtractionPrompts.parseMergeDecision
        )
        if !decision.shouldMerge {
            return .noAction(rationale: "Pages are related but distinct.")
        }
        if let merged = decision.mergedPage {
            return .mergePages(title: merged.title, body: merged.body, tags: merged.tags)
        }
        return .noAction(rationale: "Could not parse a merge proposal.")
    }

    private func stubSuggestion(for finding: WikiLintFinding) async throws -> WikiLintSuggestion {
        guard let target = finding.linkTarget,
              let referencer = wikiStore.pages.first(where: { $0.id == finding.primaryPageID }) else {
            return .noAction(rationale: "Missing context.")
        }

        let prompt = """
        The wiki references `[[\(target)]]` but no page exists for it. \
        Draft a stub page using ONLY facts you can ground in the surrounding context below. \
        Do not invent or guess. \
        If the context is too thin to write anything truthful, respond with exactly: SKIP

        Output one of:
          (a) SKIP on a single line by itself, or
          (b) a single page block in this exact shape (no preamble, no commentary):

        ---PAGE---
        TITLE: \(target.capitalized)
        TAGS: <comma-separated, lowercase>
        BODY:
        <2–4 bullet points; ≤80 words>
        ---END---

        --- Surrounding context (from \u{201C}\(referencer.title)\u{201D}) ---
        \(referencer.body)
        """

        let decision = try await respondGenerable(
            prompt: prompt,
            maxTokens: 400,
            generating: WikiStubDecision.self,
            decodeText: WikiExtractionPrompts.parseStubDecision
        )
        if !decision.canDraft {
            return .noAction(rationale: "Insufficient context to draft a stub.")
        }
        if let stub = decision.stub {
            return .createStub(title: stub.title, body: stub.body, tags: stub.tags)
        }
        return .noAction(rationale: "Could not parse a stub draft.")
    }

    // MARK: - Apply / Dismiss

    /// Apply a user-confirmed action and remove the finding from the report.
    func apply(_ action: WikiLintAction, to finding: WikiLintFinding) async {
        switch action {
        case .mergeIntoPrimary(let title, let body, let tags, let deleteID):
            await wikiStore.updatePage(
                id: finding.primaryPageID,
                body: body,
                tags: tags,
                linkedPageIDs: []
            )
            // Update the title via a separate path — the existing actor
            // updatePage doesn't change titles, so we route through a
            // delete + create when the new title differs.
            if let primary = wikiStore.pages.first(where: { $0.id == finding.primaryPageID }),
               primary.title != title {
                _ = await wikiStore.createPage(
                    title: title,
                    body: body,
                    tags: tags
                )
                await wikiStore.deletePage(id: finding.primaryPageID)
            }
            await wikiStore.deletePage(id: deleteID)

        case .keepBoth:
            break // dismiss only

        case .createPage(let title, let body, let tags):
            _ = await wikiStore.createPage(
                title: title,
                body: body,
                tags: tags
            )

        case .rewriteLink(let from, let to):
            await rewriteLink(in: finding.primaryPageID, from: from, to: to)

        case .stripBrokenLink(let target):
            await stripBrokenLink(in: finding.primaryPageID, target: target)

        case .deletePrimary:
            await wikiStore.deletePage(id: finding.primaryPageID)

        case .dismiss:
            break
        }

        dismiss(finding)
    }

    /// Mark a finding dismissed without modifying the wiki.
    func dismiss(_ finding: WikiLintFinding) {
        guard let i = report.findings.firstIndex(where: { $0.id == finding.id }) else { return }
        report.findings[i].isDismissed = true
    }

    // MARK: - Link helpers

    private func rewriteLink(in pageID: UUID, from: String, to: String) async {
        guard let page = wikiStore.pages.first(where: { $0.id == pageID }) else { return }
        let newBody = page.body.replacingOccurrences(of: "[[\(from)]]", with: "[[\(to)]]")
        guard newBody != page.body else { return }
        await wikiStore.updatePage(
            id: pageID,
            body: newBody,
            tags: page.tags,
            linkedPageIDs: page.linkedPageIDs
        )
    }

    private func stripBrokenLink(in pageID: UUID, target: String) async {
        guard let page = wikiStore.pages.first(where: { $0.id == pageID }) else { return }
        let newBody = page.body
            .replacingOccurrences(of: "[[\(target)]]", with: target)
        guard newBody != page.body else { return }
        await wikiStore.updatePage(
            id: pageID,
            body: newBody,
            tags: page.tags,
            linkedPageIDs: page.linkedPageIDs
        )
    }
}
