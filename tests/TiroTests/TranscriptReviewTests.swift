import AppKit
import AVFoundation
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

    @Test func correctionTimingRoundTripsAndInvalidValuesFallBack() throws {
        let suiteName = "CorrectionTimingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(CorrectionTimingPreference.load(from: defaults) == .automatic)
        CorrectionTimingPreference.onRequest.save(to: defaults)
        #expect(CorrectionTimingPreference.load(from: defaults) == .onRequest)
        defaults.set("unexpected", forKey: CorrectionTimingPreference.defaultsKey)
        #expect(CorrectionTimingPreference.load(from: defaults) == .automatic)
    }

    @Test func preferenceDecidesWhetherReviewIsNeeded() {
        #expect(!TranscriptReviewPreference.never.shouldReview(textChanged: true))
        #expect(!TranscriptReviewPreference.whenChanged.shouldReview(textChanged: false))
        #expect(TranscriptReviewPreference.whenChanged.shouldReview(textChanged: true))
        #expect(TranscriptReviewPreference.always.shouldReview(textChanged: false))
        #expect(TranscriptReviewPreference.never.shouldReview(
            textChanged: false,
            requiresReview: true
        ))
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

    @Test func repairModeChangesOnlyAfterASuccessfulRepair() {
        #expect(TranscriptReviewMode.transcript.afterRepair(failed: true) == .transcript)
        #expect(TranscriptReviewMode.transcript.afterRepair(failed: false) == .repaired)
        #expect(TranscriptReviewMode.repaired.afterRepair(failed: true) == .repaired)
    }

    @Test func committingCannotBeCancelledAfterAcceptance() {
        #expect(DictationWorkflowState.reviewing.handlesEscape)
        #expect(DictationWorkflowState.correcting.handlesEscape)
        #expect(DictationWorkflowState.addingReviewDictation.handlesEscape)
        #expect(DictationWorkflowState.transcribingReviewDictation.handlesEscape)
        #expect(DictationWorkflowState.correcting.commandName == "correcting")
        #expect(!DictationWorkflowState.committing.handlesEscape)
        #expect(DictationWorkflowState.committing.commandName == "committing")
    }

    @Test func shortcutTapIsDeferredAcrossTheReviewCommitHandoff() {
        #expect(
            DictationWorkflowState.reviewing.shortcutTapAction(reviewIsActive: true)
                == .acceptReview
        )
        #expect(
            DictationWorkflowState.reviewing.shortcutTapAction(reviewIsActive: false)
                == .requestDeferredRecording
        )
        #expect(
            DictationWorkflowState.committing.shortcutTapAction(reviewIsActive: false)
                == .requestDeferredRecording
        )
        #expect(
            DictationWorkflowState.idle.shortcutTapAction(reviewIsActive: false)
                == .startRecording
        )
    }

    @Test func repeatedDeferredRecordingRequestsCoalesce() {
        var deferredStart = DeferredRecordingStart()
        deferredStart.request()
        deferredStart.request()

        let firstStart = deferredStart.consume()
        let secondStart = deferredStart.consume()
        #expect(firstStart)
        #expect(!secondStart)
    }

    @Test func staleReviewTaskFailuresCannotMutateTheCurrentReview() {
        let operationID = UUID()
        let currentAdditionID = UUID()

        #expect(!isCurrentDictationTask(
            isCancelled: false,
            operationID: operationID,
            currentOperationID: operationID,
            generationID: UUID(),
            currentGenerationID: currentAdditionID
        ))
        #expect(isCurrentDictationTask(
            isCancelled: false,
            operationID: operationID,
            currentOperationID: operationID,
            generationID: currentAdditionID,
            currentGenerationID: currentAdditionID
        ))
    }

    @Test func cancelledCorrectionErrorsCannotBecomeFailures() {
        let operationID = UUID()
        let correctionID = UUID()

        #expect(!isCurrentDictationTask(
            isCancelled: true,
            operationID: operationID,
            currentOperationID: operationID,
            generationID: correctionID,
            currentGenerationID: correctionID
        ))
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
            action: .paste,
            mode: .repaired
        )
        let review = Task { @MainActor in await controller.review(draft) }
        await Task.yield()

        let pasteButton = try #require(allSubviews(of: NSButton.self, in: controller.window?.contentView)
            .first { $0.title == "Paste" })
        let background = try #require(
            pasteButton.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?
                .usingColorSpace(.deviceRGB)
        )
        #expect(controller.isReviewing)
        #expect(pasteButton.isEnabled)
        #expect(!pasteButton.isBordered)
        #expect(background.greenComponent > background.redComponent + 0.35)
        #expect(background.alphaComponent > 0.9)
        pasteButton.performClick(nil)

        #expect(await review.value == .accepted("Send it tomorrow."))
    }

    @Test @MainActor
    func onRequestPreviewOffersRepairAndReturnsItsEditableText() async throws {
        _ = NSApplication.shared
        let controller = TranscriptReviewWindowController()
        let draft = TranscriptReviewDraft(
            originalText: "Um, send it tomorrow.",
            revisedText: "Um, send it tomorrow.",
            explanation: "",
            audioURL: nil,
            duration: 1,
            action: .paste,
            allowsCorrection: true
        )
        let review = Task { @MainActor in await controller.review(draft) }
        await Task.yield()

        let repairButton = try #require(allSubviews(of: NSButton.self, in: controller.window?.contentView)
            .first { $0.title == "Repair" })
        #expect(controller.canRequestCorrection)
        #expect(!repairButton.isHidden)
        repairButton.performClick(nil)

        #expect(await review.value == .correctionRequested(
            text: "Um, send it tomorrow.",
            originalText: "Um, send it tomorrow.",
            fallbackText: "Um, send it tomorrow.",
            reason: .repair
        ))
        controller.cancel()
    }

    @Test @MainActor
    func onRequestPreviewOffersVisibleAddMoreActionWithConfiguredShortcut() async throws {
        _ = NSApplication.shared
        let controller = TranscriptReviewWindowController()
        var requestCount = 0
        controller.onRequestAdditionalDictation = {
            requestCount += 1
            if requestCount == 1 {
                #expect(controller.beginAdditionalDictation())
            }
        }
        let draft = TranscriptReviewDraft(
            originalText: "Send the report tomorrow.",
            revisedText: "Send the report tomorrow.",
            explanation: "",
            audioURL: nil,
            duration: 1,
            action: .paste,
            allowsCorrection: true,
            correctionIsAvailable: false,
            additionalDictationShortcut: "Option + Right Command"
        )
        let review = Task { @MainActor in await controller.review(draft) }
        await Task.yield()

        let addMoreButton = try #require(
            allSubviews(of: NSButton.self, in: controller.window?.contentView)
                .first { $0.title == "Add more" }
        )
        #expect(!addMoreButton.isHidden)
        #expect(addMoreButton.isEnabled)
        #expect(addMoreButton.toolTip?.contains("Option + Right Command") == true)
        addMoreButton.performClick(nil)
        #expect(requestCount == 1)
        #expect(addMoreButton.title == "Done")
        #expect(addMoreButton.isEnabled)
        addMoreButton.performClick(nil)
        #expect(requestCount == 2)

        controller.cancel()
        #expect(await review.value == .cancelled)
    }

    @Test @MainActor
    func additionalDictationExtendsOriginalWithoutImplicitRepair() async throws {
        _ = NSApplication.shared
        let controller = TranscriptReviewWindowController()
        let draft = TranscriptReviewDraft(
            originalText: "First paragraph.",
            revisedText: "First paragraph.",
            explanation: "",
            audioURL: nil,
            duration: 1,
            action: .paste,
            allowsCorrection: true,
            mode: .transcript
        )
        let review = Task { @MainActor in await controller.review(draft) }
        await Task.yield()

        #expect(controller.beginAdditionalDictation())
        controller.appendAdditionalTranscription("Second paragraph.")
        #expect(controller.isReviewing)

        controller.requestCorrection()
        let combined = "First paragraph.\n\nSecond paragraph."
        #expect(await review.value == .correctionRequested(
            text: combined,
            originalText: combined,
            fallbackText: combined,
            reason: .repair
        ))
        controller.cancel()
    }

    @Test @MainActor
    func additionalDictationInRepairModeExtendsOriginalThenRequestsRepair() async throws {
        _ = NSApplication.shared
        let controller = TranscriptReviewWindowController()
        let draft = TranscriptReviewDraft(
            originalText: "Um, first paragraph.",
            revisedText: "First paragraph.",
            explanation: "Removed a filler.",
            audioURL: nil,
            duration: 1,
            action: .paste,
            allowsCorrection: true,
            mode: .repaired
        )
        let review = Task { @MainActor in await controller.review(draft) }
        await Task.yield()

        #expect(controller.beginAdditionalDictation())
        controller.appendAdditionalTranscription("Please change first to second.")

        #expect(await review.value == .correctionRequested(
            text: "First paragraph.\n\nPlease change first to second.",
            originalText: "Um, first paragraph.\n\nPlease change first to second.",
            fallbackText: "First paragraph.\n\nPlease change first to second.",
            reason: .additionalDictation
        ))
        controller.cancel()
    }

    @Test @MainActor
    func repeatedRepairPreservesTheAccumulatedOriginal() async throws {
        _ = NSApplication.shared
        let controller = TranscriptReviewWindowController()
        let draft = TranscriptReviewDraft(
            originalText: "Um, first paragraph.",
            revisedText: "First paragraph.",
            explanation: "Removed a filler.",
            audioURL: nil,
            duration: 1,
            action: .paste,
            allowsCorrection: true,
            mode: .repaired
        )
        let review = Task { @MainActor in await controller.review(draft) }
        await Task.yield()

        controller.requestCorrection()

        #expect(await review.value == .correctionRequested(
            text: "First paragraph.",
            originalText: "Um, first paragraph.",
            fallbackText: "First paragraph.",
            reason: .repair
        ))
        controller.cancel()
    }

    @Test
    func additionalRecordingIsAppendedToReviewAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewAudioAssemblerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingURL = root.appendingPathComponent("recording.wav")
        let additionURL = root.appendingPathComponent("addition.wav")
        try writeAudio(frameCount: 160, to: recordingURL)
        try writeAudio(frameCount: 320, to: additionURL)

        try ReviewAudioAssembler.append(additionURL, to: recordingURL)

        let combined = try AVAudioFile(forReading: recordingURL)
        #expect(combined.length == 480)
    }

    @Test @MainActor
    func onRequestPreviewRendersRawTranscriptInVisibleGrey() async throws {
        _ = NSApplication.shared
        let controller = TranscriptReviewWindowController()
        let rawTranscript = "A longer raw transcript that must wrap within the visible editor instead of extending beyond its right edge."
        let draft = TranscriptReviewDraft(
            originalText: rawTranscript,
            revisedText: rawTranscript,
            explanation: "",
            audioURL: nil,
            duration: 1,
            action: .paste,
            allowsCorrection: true
        )
        let review = Task { @MainActor in await controller.review(draft) }
        defer { controller.cancel() }
        await Task.yield()

        let contentView = try #require(controller.window?.contentView)
        let textView = try #require(allSubviews(of: NSTextView.self, in: contentView).first)
        let foreground = try #require(textView.textColor?.usingColorSpace(.deviceRGB))
        let scrollView = try #require(textView.enclosingScrollView)
        let textContainer = try #require(textView.textContainer)
        let layoutManager = try #require(textView.layoutManager)
        let storedForeground = try #require(
            (textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?
                .usingColorSpace(.deviceRGB)
        )
        let typingForeground = try #require(
            (textView.typingAttributes[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceRGB)
        )
        let background = try #require(textView.backgroundColor.usingColorSpace(.deviceRGB))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let glyphBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

        #expect(foreground == TranscriptReviewWindowController.rawTranscriptColor.usingColorSpace(.deviceRGB))
        #expect(storedForeground == foreground)
        #expect(typingForeground == foreground)
        #expect(foreground.brightnessComponent > background.brightnessComponent + 0.5)
        #expect(textView.string == rawTranscript)
        #expect(scrollView.documentView === textView)
        #expect(textContainer.widthTracksTextView)
        #expect(textView.isVerticallyResizable)
        #expect(textView.frame.width > 0)
        #expect(textView.frame.height > 0)
        #expect(abs(textView.frame.width - scrollView.contentView.bounds.width) < 1)
        #expect(glyphRange.length > 0)
        #expect(glyphBounds.width > 0)
        #expect(glyphBounds.height > 20)

        controller.cancel()
        #expect(await review.value == .cancelled)
    }

    private func words(in text: String, ranges: [NSRange]) -> [String] {
        let value = text as NSString
        return ranges.map(value.substring(with:))
    }

    private func writeAudio(frameCount: AVAudioFrameCount, to url: URL) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(frameCount) { samples[index] = 0.1 }
        }
        try file.write(from: buffer)
    }

    @MainActor
    private func allSubviews<T: NSView>(of type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        return ((root as? T).map { [$0] } ?? [])
            + root.subviews.flatMap { allSubviews(of: type, in: $0) }
    }
}
