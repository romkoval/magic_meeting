import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let consent = "aiConsentGiven"
        static let consentPromptShown = "aiConsentPromptShown"
        static let recognitionLanguage = "recognitionLanguage"
        static let deviceID = "deviceID"
    }

    private let defaults: UserDefaults

    /// Explicit consent to send audio and texts to the AI service (TZ §8).
    /// Without it recording works, sending does not.
    var hasAIConsent: Bool {
        didSet { defaults.set(hasAIConsent, forKey: Keys.consent) }
    }

    var consentPromptShown: Bool {
        didSet { defaults.set(consentPromptShown, forKey: Keys.consentPromptShown) }
    }

    /// ISO-639-1 code, or empty for automatic detection.
    var recognitionLanguage: String {
        didSet { defaults.set(recognitionLanguage, forKey: Keys.recognitionLanguage) }
    }

    /// Random per-install identifier for the proxy's rate limits. Not linked to the user.
    let deviceID: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasAIConsent = defaults.bool(forKey: Keys.consent)
        consentPromptShown = defaults.bool(forKey: Keys.consentPromptShown)
        recognitionLanguage = defaults.string(forKey: Keys.recognitionLanguage) ?? ""
        if let id = defaults.string(forKey: Keys.deviceID) {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Keys.deviceID)
        }
    }

    /// Language for LLM answers when the transcript language is unknown.
    var interfaceLanguage: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    var privacyPolicyURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "PrivacyPolicyURL") as? String).flatMap(URL.init(string:))
    }
}
