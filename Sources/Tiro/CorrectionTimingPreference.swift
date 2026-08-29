import Foundation

enum CorrectionTimingPreference: String, CaseIterable {
    static let defaultsKey = "correctionTimingPreference"

    case automatic
    case onRequest
    case off

    var title: String {
        switch self {
        case .automatic: "Automatically"
        case .onRequest: "On request"
        case .off: "Off"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let value = defaults.string(forKey: defaultsKey),
              let preference = Self(rawValue: value) else {
            return .automatic
        }
        return preference
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
