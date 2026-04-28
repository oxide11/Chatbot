//
//  AppLogger.swift
//  ChatBot
//
//  Centralized structured logging using os.log.
//  Zero overhead in release builds for debug-level messages.
//

import os

nonisolated enum AppLogger {
    /// Document importer operations (file copy, text extraction, queueing).
    nonisolated static let importer = Logger(subsystem: "com.polygoncyber.Engram", category: "Importer")

    /// SharedDataManager (file-based storage, App Group).
    nonisolated static let sharedData = Logger(subsystem: "com.polygoncyber.Engram", category: "SharedData")

    /// Embedding service operations.
    nonisolated static let embedding = Logger(subsystem: "com.polygoncyber.Engram", category: "Embedding")

    /// Chat view model (conversation, context, RAG).
    nonisolated static let chat = Logger(subsystem: "com.polygoncyber.Engram", category: "Chat")

    /// Wiki engine operations (extraction, injection, page management).
    nonisolated static let wiki = Logger(subsystem: "com.polygoncyber.Engram", category: "Wiki")

    /// General app lifecycle events.
    nonisolated static let app = Logger(subsystem: "com.polygoncyber.Engram", category: "App")
}
