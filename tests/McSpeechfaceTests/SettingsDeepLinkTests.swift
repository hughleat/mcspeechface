import Foundation
import Testing
@testable import McSpeechface

struct SettingsDeepLinkTests {
    @Test
    func opensSettingsSections() throws {
        #expect(SettingsSection(deepLink: try #require(URL(string: "mcspeechface://settings"))) == .general)
        for section in SettingsSection.allCases {
            let url = try #require(URL(string: "mcspeechface://settings/\(section.rawValue)"))
            #expect(SettingsSection(deepLink: url) == section)
        }
    }

    @Test
    func rejectsUnknownLinks() throws {
        #expect(SettingsSection(deepLink: try #require(URL(string: "https://example.com/settings"))) == nil)
        #expect(SettingsSection(deepLink: try #require(URL(string: "mcspeechface://unknown/models"))) == nil)
        #expect(SettingsSection(deepLink: try #require(URL(string: "mcspeechface://settings/unknown"))) == nil)
        #expect(SettingsSection(deepLink: try #require(URL(string: "mcspeechface://settings/models/extra"))) == nil)
    }

    @Test
    func permissionReturnSurvivesRelaunchAndUsesCurrentSetupState() throws {
        let suiteName = "PermissionSettingsReturnTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_000_000)

        for requested in [PermissionSettingsReturn.settings, .setup] {
            requested.recordOpen(true, in: defaults, now: now)
            #expect(PermissionSettingsReturn.consume(
                from: defaults,
                now: now,
                setupCompleted: false
            ) == .setup)

            requested.recordOpen(true, in: defaults, now: now)
            #expect(PermissionSettingsReturn.consume(
                from: defaults,
                now: now,
                setupCompleted: true
            ) == .settings)
        }
        #expect(PermissionSettingsReturn.consume(
            from: defaults,
            now: now,
            setupCompleted: true
        ) == nil)
    }

    @Test
    func permissionReturnRejectsFailedStaleAndInvalidHandoffs() throws {
        let suiteName = "PermissionSettingsReturnFailureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_000_000)

        PermissionSettingsReturn.settings.recordOpen(false, in: defaults, now: now)
        #expect(PermissionSettingsReturn.consume(
            from: defaults,
            now: now,
            setupCompleted: true
        ) == nil)

        PermissionSettingsReturn.settings.recordOpen(
            true,
            in: defaults,
            now: now.addingTimeInterval(-PermissionSettingsReturn.maximumAge - 1)
        )
        #expect(PermissionSettingsReturn.consume(
            from: defaults,
            now: now,
            setupCompleted: true
        ) == nil)

        defaults.set("invalid", forKey: PermissionSettingsReturn.defaultsKey)
        defaults.set(now.timeIntervalSince1970, forKey: PermissionSettingsReturn.timestampDefaultsKey)
        #expect(PermissionSettingsReturn.consume(
            from: defaults,
            now: now,
            setupCompleted: true
        ) == nil)
    }
}
