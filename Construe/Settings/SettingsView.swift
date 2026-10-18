import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import Vision

extension View {
    /// Styles a settings tab: a grouped form at a fixed width that's as tall as its content.
    ///
    /// Grouped forms scroll, so they have no natural height of their own. Disabling scrolling and
    /// fixing the vertical size makes the form report its content height, which the settings window
    /// uses to size itself for each tab.
    func settingsPane() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 560)
    }
}

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Show Construe:", name: .togglePanel)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    updateLaunchAtLogin(enabled)
                }
            if SMAppService.mainApp.status == .requiresApproval {
                Text("Approve Construe in System Settings > General > Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .settingsPane()
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct ClaudeSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var apiKey = KeychainStore.apiKey.read() ?? ""
    @State private var apiKeyError: String?

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $apiKey, prompt: Text("sk-ant-…"))
                    .onChange(of: apiKey) { _, newValue in
                        saveAPIKey(newValue)
                    }
                if let apiKeyError {
                    Text(apiKeyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let consoleURL = URL(string: "https://platform.claude.com") {
                    Link("Get an API key in the Claude Console", destination: consoleURL)
                        .font(.caption)
                }
            } footer: {
                Text("Stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                HStack {
                    TextField("Model", text: $settings.model)
                    Menu("Presets") {
                        ForEach(AppSettings.modelPresets, id: \.id) { preset in
                            Button(preset.name) { settings.model = preset.id }
                        }
                    }
                    .fixedSize()
                }
                Picker("Effort", selection: $settings.effort) {
                    ForEach(Effort.allCases) { effort in
                        Text(effort.label).tag(effort)
                    }
                }
                Toggle(isOn: $settings.fastMode) {
                    Text("Fast mode")
                    Text(AnthropicClient.fastModeModels.contains(settings.model)
                        ? "Up to 2.5× faster output at twice the price. Research preview."
                        : "Not available for this model; only Opus 5.5, Opus 5 and Opus 4.8 support it.")
                }
                .disabled(!AnthropicClient.fastModeModels.contains(settings.model))
            }

            Section("System prompt") {
                TextEditor(text: $settings.systemPrompt)
                    .font(.body)
                    .frame(height: 200)
                Button("Reset to default") {
                    settings.systemPrompt = AppSettings.defaultSystemPrompt
                }
                .disabled(settings.systemPrompt == AppSettings.defaultSystemPrompt)
            }

            Section("Screenshots") {
                Toggle("Attach screenshot image to the request", isOn: $settings.sendImage)
                Picker("Text recognition language", selection: $settings.ocrLanguage) {
                    Text("Automatic").tag(String?.none)
                    Divider()
                    ForEach(Self.ocrLanguages, id: \.id) { language in
                        Text(language.name).tag(String?.some(language.id))
                    }
                }
            }
        }
        .settingsPane()
    }

    private func saveAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try KeychainStore.apiKey.delete()
            } else {
                try KeychainStore.apiKey.save(trimmed)
            }
            apiKeyError = nil
        } catch {
            apiKeyError = error.localizedDescription
        }
    }

    /// Languages Vision can recognize, sorted by their localized display name.
    private static let ocrLanguages: [(id: String, name: String)] = RecognizeTextRequest()
        .supportedRecognitionLanguages
        .map { language in
            let id = language.minimalIdentifier
            return (id, Locale.current.localizedString(forIdentifier: id) ?? id)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

struct HandoffSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                TextField("Project ID", text: $settings.projectID, prompt: Text("Optional"))
            } footer: {
                Text("The ID from a claude.ai Project URL (claude.ai/project/<ID>). Leave empty to open a plain new chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preamble") {
                TextEditor(text: $settings.handoffPreamble)
                    .font(.body)
                    .frame(height: 80)
                Button("Reset to default") {
                    settings.handoffPreamble = AppSettings.defaultHandoffPreamble
                }
                .disabled(settings.handoffPreamble == AppSettings.defaultHandoffPreamble)
            }
        }
        .settingsPane()
    }
}

#Preview("Claude") {
    ClaudeSettingsView(settings: AppSettings(defaults: UserDefaults(suiteName: "preview") ?? .standard))
}

#Preview("Handoff") {
    HandoffSettingsView(settings: AppSettings(defaults: UserDefaults(suiteName: "preview") ?? .standard))
}
