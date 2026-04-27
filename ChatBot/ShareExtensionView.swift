//
//  ShareExtensionView.swift
//  ChatBot
//
//  Created by Moussa Noun on 2026-04-27.
//


import SwiftUI

/// SwiftUI view presented inside the Share Extension.
/// Lets the user choose to save shared text as a wiki page or start a new conversation.
struct ShareExtensionView: View {
    let sharedText: String
    let onDone: () -> Void
    let onOpenApp: () -> Void

    @State private var selectedAction: SharedDataManager.SharedAction = .saveAsMemory
    @State private var tagsText = ""
    @State private var autoTags: [String] = []
    @State private var isSaved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(sharedText)
                        .font(.body)
                        .lineLimit(6)
                        .foregroundStyle(.primary)
                } header: {
                    Text("Shared Content")
                }

                Section {
                    Picker("Action", selection: $selectedAction) {
                        Label("Save to Wiki", systemImage: "book.pages")
                            .tag(SharedDataManager.SharedAction.saveAsMemory)
                        Label("Start Conversation", systemImage: "bubble.left.and.text.bubble.right")
                            .tag(SharedDataManager.SharedAction.startConversation)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("What would you like to do?")
                }

                if selectedAction == .saveAsMemory {
                    Section {
                        #if os(iOS) || os(tvOS) || os(visionOS)
                        TextField("e.g. article, research, topic", text: $tagsText)
                            .textInputAutocapitalization(.never)
                        #else
                        TextField("e.g. article, research, topic", text: $tagsText)
                        #endif

                        if !autoTags.isEmpty && tagsText.trimmingCharacters(in: .whitespaces).isEmpty {
                            HStack(spacing: 4) {
                                Text("Suggested:")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                ForEach(autoTags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.fill.tertiary, in: .capsule)
                                }
                            }
                        }
                    } header: {
                        Text("Tags (optional)")
                    } footer: {
                        Text("Comma-separated tags help the assistant find this wiki page later.")
                    }
                }

                if isSaved {
                    Section {
                        Label(
                            selectedAction == .saveAsMemory
                                ? "Wiki page saved successfully!"
                                : "Content queued \u{2014} open Engram to continue.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Share to Engram")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selectedAction == .saveAsMemory ? "Save" : "Send") {
                        performAction()
                    }
                    .disabled(isSaved)
                }
            }
            .onAppear {
                autoTags = SharedDataManager.extractKeywords(from: sharedText, limit: 5)
            }
        }
    }

    private func performAction() {
        switch selectedAction {
        case .saveAsMemory:
            let tags: [String]
            let trimmed = tagsText.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                tags = SharedDataManager.extractKeywords(from: sharedText, limit: 5)
            } else {
                tags = trimmed.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
            }

            let title = String(sharedText.prefix(60))
            SharedDataManager.savePendingWikiPage(title: title, body: sharedText, tags: tags)
            SharedDataManager.setPendingSharedText(sharedText, action: .saveAsMemory)

            isSaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onOpenApp() }

        case .startConversation:
            SharedDataManager.setPendingSharedText(sharedText, action: .startConversation)
            isSaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onOpenApp() }
        }
    }
}
