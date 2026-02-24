//
//  AppLogger.swift
//  ChatBot
//
//  Centralized structured logging using os.log.
//  Zero overhead in release builds for debug-level messages.
//

import os

nonisolated enum AppLogger {
    /// Knowledge Base store operations (ingestion, retrieval, persistence).
    nonisolated static let kbStore = Logger(subsystem: "com.polygoncyber.Engram", category: "KBStore")

    /// Knowledge Base SwiftData actor operations.
    nonisolated static let kbActor = Logger(subsystem: "com.polygoncyber.Engram", category: "KBActor")

    /// SharedDataManager (file-based storage, App Group).
    nonisolated static let sharedData = Logger(subsystem: "com.polygoncyber.Engram", category: "SharedData")

    /// Embedding service operations.
    nonisolated static let embedding = Logger(subsystem: "com.polygoncyber.Engram", category: "Embedding")

    /// Chat view model (conversation, context, RAG).
    nonisolated static let chat = Logger(subsystem: "com.polygoncyber.Engram", category: "Chat")

    /// General app lifecycle events.
    nonisolated static let app = Logger(subsystem: "com.polygoncyber.Engram", category: "App")
}
