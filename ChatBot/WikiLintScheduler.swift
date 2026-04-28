//
//  WikiLintScheduler.swift
//  ChatBot
//
//  Schedules a daily structural lint pass via BGTaskScheduler so the wiki
//  inbox stays current even if the user doesn't open Settings → Lint Wiki.
//
//  IMPORTANT: For this to actually run in the background, the identifier
//  below must be added to the app's Info.plist under
//  `BGTaskSchedulerPermittedIdentifiers`. The current project uses
//  GENERATE_INFOPLIST_FILE = YES; in Xcode add the array via
//  Project → Target → Info → Custom iOS Target Properties.
//
//  Until that's added, calls to `BGTaskScheduler.submit(_:)` will throw
//  `BGTaskScheduler.Error.unavailable`; we catch and log silently so this
//  isn't fatal.
//

import Foundation

#if canImport(BackgroundTasks) && !os(macOS)
import BackgroundTasks
import os
#endif

@MainActor
final class WikiLintScheduler {
    static let shared = WikiLintScheduler()

    /// Reverse-DNS identifier that must match the Info.plist entry.
    static let taskIdentifier = "com.polygoncyber.Engram.wiki.lint"

    private weak var store: ConversationStore?
    private var registered = false

    /// Wire up the handler. Call once from `ChatBotApp.init` before the
    /// scene appears — BGTaskScheduler requires registration during launch.
    func register(with store: ConversationStore) {
        self.store = store

        #if canImport(BackgroundTasks) && !os(macOS)
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor [weak self] in
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                await self.runScheduledLint(task: task)
            }
        }
        if !registered {
            AppLogger.wiki.warning("Wiki lint BG task registration returned false — Info.plist may be missing the identifier.")
        }
        #endif
    }

    /// Submit the next nightly run, or cancel pending submissions if the
    /// user disabled the toggle. Safe to call repeatedly.
    func reschedule(enabled: Bool) {
        #if canImport(BackgroundTasks) && !os(macOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        guard enabled else { return }

        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        // Earliest: ~24h from now. iOS picks the actual time within its
        // discretionary window; nothing is guaranteed.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.wiki.info("Scheduled next wiki lint pass.")
        } catch {
            AppLogger.wiki.warning("Could not schedule wiki lint task: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Handler

    #if canImport(BackgroundTasks) && !os(macOS)
    private func runScheduledLint(task: BGTask) async {
        // Always queue the next run — even if this one is cancelled.
        defer { reschedule(enabled: store?.ragSettings.dailyBackgroundLintEnabled ?? false) }

        guard let store else {
            task.setTaskCompleted(success: false)
            return
        }

        let cancellableTask = Task { @MainActor in
            store.runStructuralLint()
        }
        task.expirationHandler = {
            cancellableTask.cancel()
        }
        await cancellableTask.value
        task.setTaskCompleted(success: true)
    }
    #endif
}
