import AppKit
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
        #expect(DictationWorkflowState.correcting.handlesEscape)
        #expect(DictationWorkflowState.correcting.commandName == "correcting")
        #expect(!DictationWorkflowState.committing.handlesEscape)
        #expect(DictationWorkflowState.committing.commandName == "committing")
    }

    @Test @MainActor
    func reviewPanelAlwaysUsesTheDarkOverlayAppearance() throws {
        _ = NSApplication.shared
        let controller = TranscriptReviewWindowController()
        let translucent = TranscriptReviewWindowController.surfaceColor(reduceTransparency: false)
        let opaque = TranscriptReviewWindowController.surfaceColor(reduceTransparency: true)
        let backgroundColor = try #require(controller.window?.contentView?.layer?.backgroundColor)
        let appliedColor = try #require(NSColor(cgColor: backgroundColor))
        let expectedColor = TranscriptReviewWindowController.surfaceColor(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        var white: CGFloat = 0
        var alpha: CGFloat = 0

        #expect(controller.window?.appearance?.name == .darkAqua)
        #expect(controller.window?.contentView?.appearance?.name == .darkAqua)
        #expect(appliedColor == expectedColor)
        translucent.getWhite(&white, alpha: &alpha)
        #expect(abs(white - 0.08) < 0.001)
        #expect(abs(alpha - 0.94) < 0.001)
        opaque.getWhite(&white, alpha: &alpha)
        #expect(abs(white - 0.08) < 0.001)
        #expect(abs(alpha - 1) < 0.001)
    }

    @Test @MainActor
    func presentedPasteButtonIsEnabledAndAcceptsTheReviewedText() async throws {
        _ = NSApplication.shared
        let controller = TranscriptReviewWindowController()
        let draft = TranscriptReviewDraft(
            originalText: "Um, send it tomorrow.",
            revisedText: "Send it tomorrow.",
            explanation: "Removed a filler.",
            audioURL: nil,
            duration: 1,
            action: .paste
        )
        let review = Task { @MainActor in await controller.review(draft) }
        await Task.yield()

        let pasteButton = try #require(allSubviews(of: NSButton.self, in: controller.window?.contentView)
            .first { $0.title == "Paste" })
        #expect(controller.isReviewing)
        #expect(pasteButton.isEnabled)
        pasteButton.performClick(nil)

        #expect(await review.value == .accepted("Send it tomorrow."))
    }

    private func words(in text: String, ranges: [NSRange]) -> [String] {
        let value = text as NSString
        return ranges.map(value.substring(with:))
    }

    @MainActor
    private func allSubviews<T: NSView>(of type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        return ((root as? T).map { [$0] } ?? [])
            + root.subviews.flatMap { allSubviews(of: type, in: $0) }
    }
}
