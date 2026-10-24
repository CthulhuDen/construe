import Foundation
import Observation

/// Reasoning effort sent to the API. `modelDefault` omits the parameter, which models without
/// effort support (such as Claude Haiku 4.5) require.
enum Effort: String, CaseIterable, Identifiable {
    case modelDefault = "default"
    case low
    case medium
    case high

    var id: Self { self }

    var label: String {
        switch self {
        case .modelDefault: "Model default"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

/// User preferences, persisted in `UserDefaults`. The API key is not stored here; see `KeychainStore`.
@Observable
final class AppSettings {
    static let defaultModel = "claude-opus-5-5"
    static let defaultEffort = Effort.medium
    static let defaultListeningBufferSeconds = 15
    static let defaultListeningAutoStopMinutes = 30
    static let defaultSystemPrompt = """
        Explain the text the user sends. If it's in a foreign language, translate it, \
        then break down anything non-obvious: idioms, grammar, word choice and tone. Be concise.
        """
    /// `{{phrase}}` and `{{reply}}` are replaced by the sent text and Claude's answer; the trailing
    /// separator and blank lines leave room to type the follow-up question.
    static let defaultHandoffTemplate = """
        I'd like to discuss this phrase and its breakdown further.

        {{phrase}}

        ---

        {{reply}}

        ---


        """

    /// Models offered in the Settings preset menu as (display name, model ID).
    static let modelPresets: [(name: String, id: String)] = [
        ("Claude Opus 5.5", "claude-opus-5-5"),
        ("Claude Sonnet 5.5", "claude-sonnet-5-5"),
        ("Claude Haiku 4.5", "claude-haiku-4-5"),
    ]

    private enum Key {
        static let model = "model"
        static let effort = "effort"
        static let systemPrompt = "systemPrompt"
        static let projectID = "projectID"
        static let handoffTemplate = "handoffTemplate"
        static let sendImage = "sendImage"
        static let ocrLanguage = "ocrLanguage"
        static let fastMode = "fastMode"
        static let speechLocale = "speechLocale"
        static let listeningBufferSeconds = "listeningBufferSeconds"
        static let listeningAutoStopMinutes = "listeningAutoStopMinutes"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var model: String {
        didSet { defaults.set(model, forKey: Key.model) }
    }

    var effort: Effort {
        didSet { defaults.set(effort.rawValue, forKey: Key.effort) }
    }

    var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: Key.systemPrompt) }
    }

    /// claude.ai Project to open on handoff. Empty means a plain new chat.
    var projectID: String {
        didSet { defaults.set(projectID, forKey: Key.projectID) }
    }

    /// Text prefilled into the claude.ai chat; see `defaultHandoffTemplate` for the placeholders.
    var handoffTemplate: String {
        didSet { defaults.set(handoffTemplate, forKey: Key.handoffTemplate) }
    }

    /// Whether a pasted screenshot is attached to the request alongside its OCR text.
    var sendImage: Bool {
        didSet { defaults.set(sendImage, forKey: Key.sendImage) }
    }

    /// Language identifier for OCR (e.g. "es"), or `nil` for automatic detection.
    var ocrLanguage: String? {
        didSet { defaults.set(ocrLanguage, forKey: Key.ocrLanguage) }
    }

    /// Requests faster output at premium pricing. Only applied to models that support it.
    var fastMode: Bool {
        didSet { defaults.set(fastMode, forKey: Key.fastMode) }
    }

    /// BCP-47 language for speech recognition (e.g. "es-ES"), or `nil` for the system language.
    var speechLocale: String? {
        didSet { defaults.set(speechLocale, forKey: Key.speechLocale) }
    }

    /// Seconds of sound kept while listening. Applies the next time listening starts.
    var listeningBufferSeconds: Int {
        didSet { defaults.set(listeningBufferSeconds, forKey: Key.listeningBufferSeconds) }
    }

    /// Minutes of silence after which listening stops; 0 means never.
    var listeningAutoStopMinutes: Int {
        didSet { defaults.set(listeningAutoStopMinutes, forKey: Key.listeningAutoStopMinutes) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = defaults.string(forKey: Key.model) ?? Self.defaultModel
        effort = defaults.string(forKey: Key.effort).flatMap(Effort.init(rawValue:)) ?? Self.defaultEffort
        systemPrompt = defaults.string(forKey: Key.systemPrompt) ?? Self.defaultSystemPrompt
        projectID = defaults.string(forKey: Key.projectID) ?? ""
        handoffTemplate = defaults.string(forKey: Key.handoffTemplate) ?? Self.defaultHandoffTemplate
        sendImage = defaults.object(forKey: Key.sendImage) as? Bool ?? true
        ocrLanguage = defaults.string(forKey: Key.ocrLanguage)
        fastMode = defaults.bool(forKey: Key.fastMode)
        speechLocale = defaults.string(forKey: Key.speechLocale)
        listeningBufferSeconds = defaults.object(forKey: Key.listeningBufferSeconds) as? Int
            ?? Self.defaultListeningBufferSeconds
        listeningAutoStopMinutes = defaults.object(forKey: Key.listeningAutoStopMinutes) as? Int
            ?? Self.defaultListeningAutoStopMinutes
    }
}
