//
//  ProviderSettingsView.swift
//  ChatBot
//
//  Settings UI surface for managing AI provider credentials.
//  The on-device provider is always available; remote providers gain a
//  "Connected" state once an API key is stored in the Keychain.
//

import SwiftUI

// MARK: - Provider List Row

struct ProviderRow: View {
    let id: ChatProviderID
    let isConfigured: Bool
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: id.iconSystemName)
                .font(.title3)
                .foregroundStyle(id.iconTint)
                .frame(width: 32, height: 32)
                .background(id.iconTint.opacity(0.15), in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(id.displayName)
                        .font(.body)
                    if isDefault {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.18), in: .capsule)
                            .foregroundStyle(.tint)
                    }
                }
                Text(id.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Image(systemName: isConfigured ? "checkmark.circle.fill" : "chevron.right")
                .font(.body.weight(.medium))
                .foregroundStyle(isConfigured ? Color.green : Color.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Provider Detail Sheet

struct ProviderDetailView: View {
    let id: ChatProviderID
    var registry: ProviderRegistry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var keyDraft: String = ""
    @State private var showKey = false
    @State private var saveError: String?
    @State private var confirmDelete = false

    @State private var modelDraft: String = ""

    /// nil = idle, .running, .success(echo), .failure(message)
    @State private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    private var isConfigured: Bool { registry.isConfigured(id) }
    private var isDefault: Bool { registry.defaultProviderID == id }

    var body: some View {
        NavigationStack {
            Form {
                // Header
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: id.iconSystemName)
                            .font(.system(size: 28))
                            .foregroundStyle(id.iconTint)
                            .frame(width: 56, height: 56)
                            .background(id.iconTint.opacity(0.15), in: .rect(cornerRadius: 14))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(id.displayName).font(.title3.weight(.semibold))
                            Text(id.blurb)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }

                if id.requiresAPIKey {
                    keySection
                    modelSection
                    testSection
                    if isConfigured {
                        defaultSection
                        deleteSection
                    }
                } else {
                    Section {
                        Label("Always available — no setup required.", systemImage: "checkmark.seal")
                            .foregroundStyle(.secondary)
                    }
                    if isConfigured && !isDefault {
                        defaultSection
                    }
                }
            }
            .formStyle(.grouped)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle(id.shortName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Forget API Key?", isPresented: $confirmDelete) {
                Button("Forget Key", role: .destructive) {
                    do {
                        try registry.deleteAPIKey(for: id)
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Engram will no longer be able to use \(id.displayName) until you re-enter the key.")
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: Sections

    @ViewBuilder
    private var keySection: some View {
        Section {
            HStack {
                Group {
                    if showKey {
                        TextField(id.keyPlaceholder, text: $keyDraft)
                    } else {
                        SecureField(id.keyPlaceholder, text: $keyDraft)
                    }
                }
                .font(.system(.body, design: .monospaced))
                #if os(iOS) || os(tvOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showKey ? "Hide key" : "Show key")
            }

            HStack {
                Button(isConfigured ? "Update Key" : "Save Key") {
                    save()
                }
                .buttonStyle(.glassProminent)
                .disabled(!id.validate(keyDraft))

                Spacer()

                if let url = id.keyConsoleURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Get a key", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .buttonStyle(.glass)
                }
            }
        } header: {
            Text("API Key")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if isConfigured {
                    Label("Stored securely in the iOS Keychain.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let err = saveError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onAppear {
            // Don't surface the actual key; show a masked placeholder so the user
            // can tell something is stored without us revealing it.
            if isConfigured && keyDraft.isEmpty {
                keyDraft = ""
            }
            if modelDraft.isEmpty {
                modelDraft = registry.modelID(for: id)
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        Section {
            Picker("Suggested", selection: Binding(
                get: { modelDraft },
                set: { newValue in
                    modelDraft = newValue
                    registry.setModelID(newValue, for: id)
                    testStatus = .idle
                }
            )) {
                ForEach(id.modelSuggestions, id: \.self) { suggestion in
                    Text(suggestion).tag(suggestion)
                }
                if !id.modelSuggestions.contains(modelDraft) && !modelDraft.isEmpty {
                    Text(modelDraft).tag(modelDraft)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text("Custom")
                    .foregroundStyle(.secondary)
                #if os(iOS) || os(tvOS) || os(visionOS)
                TextField(id.defaultModelID, text: Binding(
                    get: { modelDraft },
                    set: { newValue in
                        modelDraft = newValue
                        registry.setModelID(newValue, for: id)
                        testStatus = .idle
                    }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                #else
                TextField(id.defaultModelID, text: Binding(
                    get: { modelDraft },
                    set: { newValue in
                        modelDraft = newValue
                        registry.setModelID(newValue, for: id)
                        testStatus = .idle
                    }
                ))
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                #endif
            }
        } header: {
            Text("Model")
        } footer: {
            Text("If your key works but the model returns an error, the alias may have changed. Try another from the picker or paste the exact id from the provider's docs.")
        }
    }

    @ViewBuilder
    private var testSection: some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack {
                    Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    switch testStatus {
                    case .idle:
                        EmptyView()
                    case .running:
                        ProgressView().controlSize(.small)
                    case .success:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure:
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            }
            .buttonStyle(.glass)
            .disabled(testStatus == .running || effectiveKey.isEmpty)

            switch testStatus {
            case .success(let echo):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected").font(.callout.weight(.medium))
                        Text("Reply: \u{201C}\(echo)\u{201D}")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
            case .failure(let detail):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Test failed").font(.callout.weight(.medium))
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            default:
                EmptyView()
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Tests with a 16-token request to confirm the key, model, and network path all work end-to-end. Errors are shown verbatim from the provider so you can copy them when filing a bug.")
        }
    }

    @ViewBuilder
    private var defaultSection: some View {
        Section {
            Button {
                registry.setDefault(id)
            } label: {
                HStack {
                    Label(isDefault ? "Default for New Chats" : "Make Default", systemImage: "star")
                    Spacer()
                    if isDefault {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .disabled(isDefault)
        } footer: {
            Text("New conversations use the default provider. You can override per-chat from the chat menu.")
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Forget API Key", systemImage: "trash")
            }
        }
    }

    private func save() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.validate(trimmed) else { return }
        do {
            try registry.setAPIKey(trimmed, for: id)
            saveError = nil
            keyDraft = ""
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - Test connection

    /// The key the test should use: prefer the in-flight draft if the user
    /// is editing, otherwise fall back to the stored key so already-saved
    /// providers can be tested without re-entering anything.
    private var effectiveKey: String {
        let draft = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty { return draft }
        return KeychainManager.getAPIKey(for: id.keychainAccount) ?? ""
    }

    private func runTest() {
        let key = effectiveKey
        guard !key.isEmpty else {
            testStatus = .failure("Enter an API key first.")
            return
        }
        let modelID = registry.modelID(for: id)
        testStatus = .running

        Task {
            do {
                let provider = try makeProvider(for: id, key: key, model: modelID)
                let echo = try await provider.validate()
                await MainActor.run { testStatus = .success(echo) }
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run { testStatus = .failure(detail) }
            }
        }
    }

    private func makeProvider(
        for id: ChatProviderID,
        key: String,
        model: String
    ) throws -> ChatProvider {
        switch id {
        case .anthropic:
            return AnthropicProvider(apiKey: key, model: model)
        case .openAI:
            return OpenAIProvider(apiKey: key, model: model)
        case .gemini:
            throw ChatProviderError.providerUnavailable(id)
        case .foundationModels:
            throw ChatProviderError.providerUnavailable(id)
        }
    }
}

// MARK: - Task Routing Row

/// One row in Settings → Routing. Lets the user pick which provider runs
/// a given task (chat, extraction, lint), or fall back to the default.
struct TaskRoutingRow: View {
    let task: ProviderTask
    var registry: ProviderRegistry

    var body: some View {
        let configured = ChatProviderID.allCases.filter { registry.configuredIDs.contains($0) }
        let activeID = registry.providerID(for: task)
        let hasOverride = registry.hasOverride(for: task)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: task.iconSystemName)
                    .font(.body)
                    .foregroundStyle(activeID.iconTint)
                    .frame(width: 28, height: 28)
                    .background(activeID.iconTint.opacity(0.15), in: .rect(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 1) {
                    Text(task.displayName).font(.body)
                    Text(task.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Picker("", selection: Binding(
                    get: { activeID },
                    set: { registry.setProvider($0, for: task) }
                )) {
                    ForEach(configured) { id in
                        Label(id.shortName, systemImage: id.iconSystemName).tag(id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if hasOverride {
                Button {
                    registry.setProvider(nil, for: task)
                } label: {
                    Label("Use Default (\(registry.defaultProviderID.shortName))",
                          systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.leading, 40)
            } else {
                Label("Inheriting default (\(registry.defaultProviderID.shortName))",
                      systemImage: "arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 40)
            }
        }
        .padding(.vertical, 4)
    }
}
