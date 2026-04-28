//
//  QuickActions.swift
//  ChatBot
//
//  Home-screen long-press Quick Actions:
//    - New Chat
//    - Settings
//
//  Quick Actions are registered dynamically at launch (no Info.plist
//  array required), and the user's pick is delivered through
//  `ChatBotAppDelegate.application(_:performActionFor:completionHandler:)`.
//  We funnel it into a small @Observable router that ContentView watches.
//

import SwiftUI

#if canImport(UIKit) && !os(macOS) && !os(visionOS)
import UIKit

enum QuickActionType: String, Sendable {
    case newChat = "com.polygoncyber.Engram.shortcut.newChat"
    case openSettings = "com.polygoncyber.Engram.shortcut.openSettings"
}

@MainActor
@Observable
final class QuickActionRouter {
    static let shared = QuickActionRouter()
    /// The most recent Quick Action that hasn't been consumed yet.
    /// ContentView clears this after handling.
    var pending: QuickActionType?
    private init() {}
}

final class ChatBotAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.shortcutItems = Self.makeShortcutItems()

        // Cold-launch via a Quick Action — capture it so the router fires
        // once SwiftUI's scene comes up.
        if let cold = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem,
           let action = QuickActionType(rawValue: cold.type) {
            Task { @MainActor in
                QuickActionRouter.shared.pending = action
            }
        }
        return true
    }

    /// Foreground tap on a Quick Action — the OS calls this directly.
    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let action = QuickActionType(rawValue: shortcutItem.type) else {
            completionHandler(false)
            return
        }
        Task { @MainActor in
            QuickActionRouter.shared.pending = action
            completionHandler(true)
        }
    }

    private static func makeShortcutItems() -> [UIApplicationShortcutItem] {
        [
            UIApplicationShortcutItem(
                type: QuickActionType.newChat.rawValue,
                localizedTitle: "New Chat",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "square.and.pencil"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: QuickActionType.openSettings.rawValue,
                localizedTitle: "Settings",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "gearshape"),
                userInfo: nil
            )
        ]
    }
}

#endif
