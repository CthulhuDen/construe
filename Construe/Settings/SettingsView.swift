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
            KeyboardShortcuts.Recorder(for: .togglePanel) {
                Text("Show Construe")
                Text("Opens the popup from any app, including fullscreen ones.")
            }

            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login")
                Text("Starts Construe in the menu bar when you log in.")
            }
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
                LabeledContent {
                    SecureField("API key", text: $apiKey, prompt: Text("sk-ant-…"))
                        .labelsHidden()
                        .onChange(of: apiKey) { _, newValue in
                            saveAPIKey(newValue)
                        }
                } label: {
                    Text("API key")
                    Text("Stored in your Keychain. Usage is billed to your Claude Console account.")
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
            }

            Section("Model") {
                LabeledContent {
                    HStack {
                        TextField("Model", text: $settings.model)
                            .labelsHidden()
                        Menu("Presets") {
                            ForEach(AppSettings.modelPresets, id: \.id) { preset in
                                Button(preset.name) { settings.model = preset.id }
                            }
                        }
                        .fixedSize()
                    }
                } label: {
                    Text("Model")
                    Text("Any Messages API model ID; Presets lists the current models.")
                }
                Picker(selection: $settings.effort) {
                    ForEach(Effort.allCases) { effort in
                        Text(effort.label).tag(effort)
                    }
                } label: {
                    Text("Effort")
                    Text("How much the model reasons before answering. Lower is faster and cheaper. "
                        + "Haiku 4.5 needs Model default.")
                }
                Toggle(isOn: $settings.fastMode) {
                    Text("Fast mode")
                    Text(AnthropicClient.fastModeModels.contains(settings.model)
                        ? "Up to 2.5× faster output at twice the price. Research preview."
                        : "Not available for this model; only Opus 5.5, Opus 5 and Opus 4.8 support it.")
                }
                .disabled(!AnthropicClient.fastModeModels.contains(settings.model))
            }

            Section("Screenshots") {
                Toggle(isOn: $settings.sendImage) {
                    Text("Attach screenshot image to the request")
                    Text("Lets Claude correct text-recognition mistakes, at a small extra cost per request. "
                        + "When off, only the recognized text is sent.")
                }
                Picker(selection: $settings.ocrLanguage) {
                    Text("Automatic").tag(String?.none)
                    Divider()
                    ForEach(Self.ocrLanguages, id: \.id) { language in
                        Text(language.name).tag(String?.some(language.id))
                    }
                } label: {
                    Text("Text recognition language")
                    Text("Recognition runs on your Mac. Choose a language if Automatic misreads text.")
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

struct PromptSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                TextEditor(text: $settings.systemPrompt)
                    .font(.body)
                    .frame(height: 320)
                Button("Reset to default") {
                    settings.systemPrompt = AppSettings.defaultSystemPrompt
                }
                .disabled(settings.systemPrompt == AppSettings.defaultSystemPrompt)
            } header: {
                Text("System prompt")
            } footer: {
                Text("The instructions Claude follows for every request. To reuse a claude.ai Project, "
                    + "paste its instructions here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPane()
    }
}

struct HandoffSettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    TextField("Project ID", text: $settings.projectID, prompt: Text("Optional"))
                        .labelsHidden()
                } label: {
                    Text("Project ID")
                    Text("Handoffs open in this claude.ai Project (claude.ai/project/<ID>). Empty: plain new chat.")
                }
            }

            Section {
                TextEditor(text: $settings.handoffTemplate)
                    .font(.body.monospaced())
                    .frame(height: 200)
                Button("Reset to default") {
                    settings.handoffTemplate = AppSettings.defaultHandoffTemplate
                }
                .disabled(settings.handoffTemplate == AppSettings.defaultHandoffTemplate)
            } header: {
                Text("Template")
            } footer: {
                Text("\(ClaudeHandoff.phrasePlaceholder) is replaced by the text you sent, \(ClaudeHandoff.replyPlaceholder) by Claude's answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Test link") {
                    let text = ClaudeHandoff.text(
                        template: settings.handoffTemplate,
                        phrase: "¿Qué tal? Me he liado un poco.",
                        reply: "Translation: How are you? I got a bit muddled."
                    )
                    if let url = ClaudeHandoff.url(projectID: settings.projectID, text: text) {
                        openURL(url)
                    }
                }
            } footer: {
                Text("Opens a new claude.ai chat with a sample prefill, so you can check the project and template.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPane()
    }
}

#Preview("Claude") {
    ClaudeSettingsView(settings: AppSettings(defaults: UserDefaults(suiteName: "preview") ?? .standard))
}

#Preview("Prompt") {
    PromptSettingsView(settings: AppSettings(defaults: UserDefaults(suiteName: "preview") ?? .standard))
}

#Preview("Handoff") {
    HandoffSettingsView(settings: AppSettings(defaults: UserDefaults(suiteName: "preview") ?? .standard))
}
