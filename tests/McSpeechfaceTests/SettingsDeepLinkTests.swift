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
}
