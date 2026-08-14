import Foundation

enum TranscriptReviewPreference: String, CaseIterable {
    static let defaultsKey = "transcriptReviewPreference"

    case never
    case whenChanged
    case always

    var title: String {
        switch self {
        case .never: "Never"
        case .whenChanged: "When corrections change text"
        case .always: "Always"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let value = defaults.string(forKey: defaultsKey),
              let preference = Self(rawValue: value) else {
            return .whenChanged
        }
        return preference
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    func shouldReview(textChanged: Bool, usesCustomPrompt: Bool = false) -> Bool {
        if usesCustomPrompt { return true }
        return switch self {
        case .never: false
        case .whenChanged: textChanged
        case .always: true
        }
    }
}
