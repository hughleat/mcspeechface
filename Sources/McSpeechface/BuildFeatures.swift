import Foundation

enum BuildFeatures {
    static let releasesURL = URL(string: "https://github.com/hughleat/mcspeechface/releases")!
    static let releasesAPIURL = URL(string: "https://api.github.com/repos/hughleat/mcspeechface/releases?per_page=20")!
    static let newIssueURL = URL(string: "https://github.com/hughleat/mcspeechface/issues/new/choose")!
#if MCSPEECHFACE_SPONSORSHIP_ENABLED
    static let sponsorshipEnabled = true
    static let sponsorshipMenuTitle: String? = "Support McSpeechface..."
    static let sponsorshipButtonTitle: String? = "Support McSpeechface"
    static let sponsorsURL = URL(string: "https://github.com/sponsors/hughleat")!
#else
    static let sponsorshipEnabled = false
    static let sponsorshipMenuTitle: String? = nil
    static let sponsorshipButtonTitle: String? = nil
#endif
}
