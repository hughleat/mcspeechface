import Testing
@testable import McSpeechface

struct BuildFeaturesTests {
    @Test
    func sponsorshipMatchesCompilerConfiguration() {
#if MCSPEECHFACE_SPONSORSHIP_ENABLED
        #expect(BuildFeatures.sponsorshipEnabled)
        #expect(BuildFeatures.sponsorshipMenuTitle != nil)
        #expect(BuildFeatures.sponsorshipButtonTitle != nil)
#else
        #expect(!BuildFeatures.sponsorshipEnabled)
        #expect(BuildFeatures.sponsorshipMenuTitle == nil)
        #expect(BuildFeatures.sponsorshipButtonTitle == nil)
#endif
    }
}
