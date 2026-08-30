import Foundation

enum PermissionSettingsReturn: String {
    case settings
    case setup

    static let defaultsKey = "permissionSettingsReturn"
    static let timestampDefaultsKey = "permissionSettingsReturnTimestamp"
    static let maximumAge: TimeInterval = 10 * 60

    func recordOpen(
        _ opened: Bool,
        in defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        Self.clear(from: defaults)
        guard opened else { return }
        defaults.set(rawValue, forKey: Self.defaultsKey)
        defaults.set(now.timeIntervalSince1970, forKey: Self.timestampDefaultsKey)
    }

    static func consume(
        from defaults: UserDefaults = .standard,
        now: Date = Date(),
        setupCompleted: Bool
    ) -> Self? {
        defer { clear(from: defaults) }
        guard let rawValue = defaults.string(forKey: defaultsKey),
              Self(rawValue: rawValue) != nil else { return nil }
        let age = now.timeIntervalSince1970
            - defaults.double(forKey: timestampDefaultsKey)
        guard age >= 0, age <= maximumAge else { return nil }
        return setupCompleted ? .settings : .setup
    }

    private static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: timestampDefaultsKey)
    }
}
