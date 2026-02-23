//
//  WorkerProfile.swift
//  ChatBot
//
//  Manager-Worker Agentic Pattern: SwiftData persistence for user-defined worker profiles.
//

import Foundation
import SwiftData

@Model
final class WorkerProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var icon: String
    var triggerDescription: String
    var systemInstructions: String
    var isEnabled: Bool
    var createdAt: Date

    init(
        name: String,
        icon: String = "person.crop.circle",
        triggerDescription: String,
        systemInstructions: String,
        isEnabled: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.triggerDescription = triggerDescription
        self.systemInstructions = systemInstructions
        self.isEnabled = isEnabled
        self.createdAt = Date()
    }
}
