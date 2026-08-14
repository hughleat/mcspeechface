import Foundation
import Testing
@testable import Tiro

@Suite(.serialized)
struct TranscriptReviewTests {
    @Test func preferencesRoundTripAndInvalidValuesFallBack() throws {
        let suiteName = "TranscriptReviewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(TranscriptReviewPreference.load(from: defaults) == .whenChanged)
        TranscriptReviewPreference.always.save(to: defaults)
        #expect(TranscriptReviewPreference.load(from: defaults) == .always)
        defaults.set("unexpected", forKey: TranscriptReviewPreference.defaultsKey)
        #expect(TranscriptReviewPreference.load(from: defaults) == .whenChanged)
    }

    @Test func preferenceDecidesWhetherReviewIsNeeded() {
        #expect(!TranscriptReviewPreference.never.shouldReview(textChanged: true))
        #expect(!TranscriptReviewPreference.whenChanged.shouldReview(textChanged: false))
        #expect(TranscriptReviewPreference.whenChanged.shouldReview(textChanged: true))
        #expect(TranscriptReviewPreference.always.shouldReview(textChanged: false))
    }

    @Test func differenceLocatesChangedWordsInBothVersions() {
        let original = "Please send the revise proposal to Yana tomorrow."
        let revised = "Please send the revised proposal to Janne tomorrow."
        let difference = TranscriptDifference(original: original, revised: revised)

        #expect(difference.changeCount == 2)
        #expect(words(in: original, ranges: difference.originalRanges) == ["revise", "Yana"])
        #expect(words(in: revised, ranges: difference.revisedRanges) == ["revised", "Janne"])
    }

    @Test func differenceHandlesInsertionsAndUnchangedText() {
        #expect(TranscriptDifference(original: "same", revised: "same").changeCount == 0)
        let insertion = TranscriptDifference(original: "send it", revised: "please send it")
        #expect(insertion.originalRanges.isEmpty)
        #expect(insertion.changeCount == 1)
    }

    @Test func selectedVersionDeterminesAcceptedText() {
        #expect(TranscriptReviewVersion.original.acceptedText(
            original: "Original",
            editedCorrection: "Edited correction"
        ) == "Original")
        #expect(TranscriptReviewVersion.corrected.acceptedText(
            original: "Original",
            editedCorrection: "Edited correction"
        ) == "Edited correction")
    }

    @Test func committingCannotBeCancelledAfterAcceptance() {
        #expect(DictationWorkflowState.reviewing.handlesEscape)
        #expect(!DictationWorkflowState.committing.handlesEscape)
        #expect(DictationWorkflowState.committing.commandName == "committing")
    }

    private func words(in text: String, ranges: [NSRange]) -> [String] {
        let value = text as NSString
        return ranges.map(value.substring(with:))
    }
}
