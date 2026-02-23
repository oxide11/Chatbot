//
//  ChatBotApp.swift
//  ChatBot
//
//  Created by Moussa Noun on 2026-02-16.
//

import SwiftUI
import SwiftData

@main
struct ChatBotApp: App {
    @State private var store = ConversationStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .modelContainer(for: WorkerProfile.self)
                .onOpenURL { url in
                    // Handle engram://shared or chatbot://shared URL from Share Extension
                    if (url.scheme == "engram" || url.scheme == "chatbot") && url.host == "shared" {
                        store.processPendingSharedContent()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        store.processPendingSharedContent()
                    }
                }
        }
    }
}
