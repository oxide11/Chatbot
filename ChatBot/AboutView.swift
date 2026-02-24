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
                VStack(spacing: 12) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)

                    Text(AppInfo.name)
                        .font(.title.bold())

                    Text("v\(AppInfo.version) (\(AppInfo.build))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section {
                Text("\(AppInfo.name) is an on-device AI assistant powered by Apple Intelligence. All conversations are processed entirely on your device — nothing is sent to external servers.")
                    .font(.subheadline)
            } header: {
                Text("What is \(AppInfo.name)?")
            }

            Section {
                FeatureRow(icon: "lock.shield", title: "Fully Private", detail: "All AI processing happens on-device using Apple Foundation Models")
                FeatureRow(icon: "brain", title: "Persistent Memory", detail: "Remembers key facts across conversations using RAG")
                FeatureRow(icon: "magnifyingglass.circle", title: "Semantic Search", detail: "On-device BERT embeddings for intelligent document and memory retrieval")
                FeatureRow(icon: "books.vertical", title: "Knowledge Bases", detail: "Import PDF and ePUB documents as reference material")
                FeatureRow(icon: "square.and.arrow.down.on.square", title: "Batch Import", detail: "Queue multiple documents for processing at once")
                FeatureRow(icon: "person.2.badge.gearshape", title: "Agentic Workers", detail: "Delegate specialized tasks to AI worker personas")
                FeatureRow(icon: "bubble.left.and.bubble.right", title: "Multi-Conversation", detail: "Manage multiple independent chat threads")
                FeatureRow(icon: "arrow.triangle.2.circlepath", title: "Smart Context", detail: "Automatic context rotation with summarization when nearing limits")
                FeatureRow(icon: "person.text.rectangle", title: "Custom Personas", detail: "Set per-conversation or default system prompts")
                FeatureRow(icon: "square.and.arrow.up", title: "Share Extension", detail: "Send text from any app directly into a chat or memory")
                FeatureRow(icon: "wand.and.stars", title: "Siri Integration", detail: "Ask questions or save memories via Siri Shortcuts")
            } header: {
                Text("Key Features")
            }

            Section {
                ChangelogEntry(version: "1.1.0", date: "February 2026", changes: [
                    "Semantic embeddings with NLContextualEmbedding (BERT) for intelligent retrieval",
                    "Batch document ingestion — queue multiple files at once",
                    "Storage statistics in Settings",
                    "Agentic Manager-Worker system with built-in presets",
                    "Optimized prompts and context management (~225 tokens saved per turn)",
                    "Session prewarming for faster first responses",
                    "Smaller document chunks (600 chars) for better retrieval accuracy",
                    "Cross-device embedding portability with automatic re-embedding"
                ])
                ChangelogEntry(version: "1.0.0", date: "February 2026", changes: [
                    "Initial release",
                    "On-device AI chat with Apple Foundation Models",
                    "Multi-conversation management with sidebar",
                    "RAG memory system with keyword-based retrieval",
                    "PDF and ePUB document ingestion for knowledge bases",
                    "iOS 26 Liquid Glass design",
                    "Share Extension and Siri Shortcuts",
                    "Cross-platform support (iOS, iPadOS, macOS)"
                ])
            } header: {
                Text("Changelog")
            }

            Section {
                HStack {
                    Text("AI Processing")
                    Spacer()
                    Text("On-Device Only")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Framework")
                    Spacer()
                    Text("Apple Foundation Models")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Embeddings")
                    Spacer()
                    Text("NLContextualEmbedding (BERT)")
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
                    Text("iOS 26 / macOS 26")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Technical")
            } footer: {
                Text("No data ever leaves your device. \(AppInfo.name) requires Apple Intelligence to be enabled.")
            }
        }
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
