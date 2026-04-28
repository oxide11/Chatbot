//
//  AboutView.swift
//  ChatBot
//
//  About page with app info, feature list, changelog, and technical details.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - About View

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(.tint)
                        .padding(20)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.25)), in: .circle)

                    Text(AppInfo.name)
                        .font(.title.weight(.semibold))

                    Text("v\(AppInfo.version) (\(AppInfo.build))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }

            Section {
                Text("\(AppInfo.name) is a personal LLM Wiki — a structured, interlinked knowledge base that grows as you chat and import documents. Conversations and PDFs become wiki pages; relevant pages are pulled back into context the next time you ask. Inspired by Andrej Karpathy's LLM Wiki concept.")
                    .font(.subheadline)
            } header: {
                Text("What is \(AppInfo.name)?")
            }

            Section {
                FeatureRow(icon: "book.pages", title: "LLM Wiki", detail: "Structured, interlinked pages — your second brain, written by your AI")
                FeatureRow(icon: "doc.badge.plus", title: "Document → Wiki", detail: "Import PDFs, ePubs, text, and Markdown. The model reads the full text and writes structured pages")
                FeatureRow(icon: "wand.and.stars.inverse", title: "Wiki Lint", detail: "Periodic health checks find duplicates, broken links, orphans, and stale pages — every change confirmed by you")
                FeatureRow(icon: "link", title: "[[Wikilinks]]", detail: "Pages reference each other with markdown wiki links; tap to navigate or create the missing page")
                FeatureRow(icon: "function", title: "Math + Markdown", detail: "Full LaTeX rendering in chat and wiki pages via SwiftMath")
                FeatureRow(icon: "lock.shield", title: "On-Device by Default", detail: "Apple Foundation Models runs locally. Bring your own Anthropic / OpenAI / Gemini key for higher-quality work")
                FeatureRow(icon: "arrow.triangle.branch", title: "Per-Task Routing", detail: "Keep chat on-device while sending wiki extraction and lint review to a stronger remote provider")
                FeatureRow(icon: "magnifyingglass.circle", title: "Semantic Retrieval", detail: "On-device BERT embeddings rank wiki pages so relevant context is pulled back into chat")
                FeatureRow(icon: "person.2.badge.gearshape", title: "Agentic Workers", detail: "Specialised AI personas the assistant delegates to via the Manager-Worker pattern")
                FeatureRow(icon: "bubble.left.and.bubble.right", title: "Multi-Conversation", detail: "Manage independent chat threads, each with its own provider")
                FeatureRow(icon: "square.and.arrow.up", title: "Share Extension", detail: "Send text from any app into a chat or wiki page")
                FeatureRow(icon: "wand.and.stars", title: "Siri + Quick Actions", detail: "Start a chat or open Settings from the Home Screen long-press, or ask Siri")
            } header: {
                Text("Key Features")
            }

            Section {
                ChangelogEntry(version: "2.0.0", date: "April 2026", changes: [
                    "Knowledge Bases retired — the wiki is now the only long-term knowledge surface",
                    "Document Importer: PDF / ePub / text / Markdown one-shot through the LLM into structured pages",
                    "Re-import any document later against a stronger provider; source files kept in Documents/Imports/",
                    "Live import progress with status banner, percentage, and per-job rows",
                    "Drag-and-drop import from Files / Safari directly onto the imports list",
                    "Home-screen Quick Actions for New Chat and Settings",
                    "Keyboard shortcuts: \u{2318}N new chat, \u{2318}, settings, \u{2318}F search, \u{2318}[ / \u{2318}] previous/next chat, \u{2318}1\u{2013}\u{2318}9 jump to chat"
                ])
                ChangelogEntry(version: "1.0.0", date: "April 2026", changes: [
                    "Knowledge Domains removed — single global wiki and KB pool",
                    "Multi-provider scaffolding + Anthropic streaming + per-task routing (chat / extraction / lint)",
                    "Test-Connection diagnostics on every provider key",
                    "App Sandbox network entitlement for outgoing API calls",
                    "Liquid Glass UI sweep with iOS 26 scroll edge effects"
                ])
                ChangelogEntry(version: "0.x — Pre-1.0", date: "February\u{2013}March 2026", changes: [
                    "LLM Wiki replaces the legacy MemoryStore as the long-term knowledge surface",
                    "Wiki Lint with structural + semantic LLM passes; human-in-the-loop merge UI",
                    "Karpathy-style document → wiki extraction pipeline",
                    "Math rendering, [[wikilinks]], rich markdown in chat and wiki",
                    "Initial release with on-device chat, batch document ingestion, share extension, Siri shortcuts"
                ])
            } header: {
                Text("Changelog")
            }

            Section {
                HStack {
                    Text("Default AI")
                    Spacer()
                    Text("Apple Foundation Models · On-Device")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Optional Providers")
                    Spacer()
                    Text("Anthropic, OpenAI, Gemini")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Embeddings")
                    Spacer()
                    Text("NLContextualEmbedding (BERT)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Persistence")
                    Spacer()
                    Text("SwiftData")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Platform")
                    Spacer()
                    Text(platformName)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Min. OS")
                    Spacer()
                    Text("iOS 26 / iPadOS 26 / macOS 26")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Technical")
            } footer: {
                Text("Default routing keeps everything on-device. Connecting Anthropic / OpenAI / Gemini sends only the requests you route to them — keys are stored in the iOS Keychain and never leave your device otherwise.")
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var platformName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
    }
}

// MARK: - Feature Row

struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Changelog Entry

struct ChangelogEntry: View {
    let version: String
    let date: String
    let changes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("v\(version)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(changes, id: \.self) { change in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\u{2022}")
                            .foregroundStyle(.secondary)
                        Text(change)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
