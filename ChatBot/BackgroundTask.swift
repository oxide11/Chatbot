//
//  BackgroundTask.swift
//  ChatBot
//
//  Lets long-running user-initiated work (wiki extraction over a multi-hundred-page
//  PDF) keep going briefly when the user backgrounds the app on iPad.
//
//  This uses `UIApplication.beginBackgroundTask`, which gives us roughly 30 seconds
//  of additional execution time after the app moves to the background. For genuine
//  long-running work (minutes), the right tool on iOS 26 is BGContinuedProcessingTask
//  registered in Info.plist — this helper is the conservative interim path.
//

import Foundation

#if canImport(UIKit) && !os(macOS) && !os(visionOS)
import UIKit
#endif

enum BackgroundTask {
    /// Run an async operation with a background task assertion held for its
    /// duration so the system gives us extra time if the user leaves the app.
    /// On macOS / visionOS the assertion is a no-op.
    @MainActor
    static func run<T>(
        _ name: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        #if canImport(UIKit) && !os(macOS) && !os(visionOS)
        let app = UIApplication.shared
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = app.beginBackgroundTask(withName: name) {
            if taskID != .invalid {
                app.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        defer {
            if taskID != .invalid {
                app.endBackgroundTask(taskID)
            }
        }
        return try await operation()
        #else
        return try await operation()
        #endif
    }
}
