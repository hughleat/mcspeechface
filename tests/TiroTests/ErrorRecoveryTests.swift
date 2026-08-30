import AppKit
import Foundation
import Testing
@testable import Tiro

struct ErrorRecoveryTests {
    @Test @MainActor
    func failedClipboardCopyRestoresPreviousContents() {
        let pasteboard = makePasteboard(containing: "previous clipboard")
        pasteboard.refusesNextString = true
        let coordinator = PasteCoordinator(pasteboard: pasteboard)

        #expect(throws: PasteCoordinator.PasteError.self) {
            try coordinator.copy("dictated text")
        }
        #expect(pasteboard.string == "previous clipboard")
    }

    @Test @MainActor
    func acceptedPasteWithoutAccessibilityConfirmationIsStillDispatched() async throws {
        let pasteboard = makePasteboard(containing: "previous clipboard")
        let coordinator = PasteCoordinator(
            pasteboard: pasteboard,
            eventDispatcher: { _ in .accepted },
            confirmationDelays: [0]
        )

        let result = try await coordinator.paste(
            "dictated text",
            to: PasteDestinationStub(consumptionConfirmed: false)
        )

        #expect(result == .dispatched)
        #expect(pasteboard.string == "dictated text")
    }

    @Test @MainActor
    func confirmedPasteRestoresPreviousClipboard() async throws {
        let pasteboard = makePasteboard(containing: "previous clipboard")
        let coordinator = PasteCoordinator(
            pasteboard: pasteboard,
            eventDispatcher: { _ in .accepted },
            confirmationDelays: [0]
        )

        let result = try await coordinator.paste(
            "dictated text",
            to: PasteDestinationStub(consumptionConfirmed: true)
        )

        #expect(result == .confirmed)
        #expect(pasteboard.string == "previous clipboard")
    }

    @Test @MainActor
    func backgroundConfirmationDoesNotDelayPasteCompletion() async throws {
        let pasteboard = makePasteboard(containing: "previous clipboard")
        let coordinator = PasteCoordinator(
            pasteboard: pasteboard,
            eventDispatcher: { _ in .accepted },
            confirmationDelays: [0]
        )
        let destination = SuspendedPasteDestination()

        let result = try await coordinator.paste(
            "dictated text",
            to: destination,
            waitForConfirmation: false
        )

        #expect(result == .dispatched)
        #expect(pasteboard.string == "dictated text")
        try await waitForProbe(in: destination)
        destination.resumeProbe(with: true)
        try await waitForBackgroundConfirmations(in: coordinator)
        #expect(pasteboard.string == "previous clipboard")
    }

    @Test @MainActor
    func consecutiveBackgroundPastesRestoreTheOriginalClipboard() async throws {
        let pasteboard = makePasteboard(containing: "previous clipboard")
        let coordinator = PasteCoordinator(
            pasteboard: pasteboard,
            eventDispatcher: { _ in .accepted },
            confirmationDelays: [20_000_000]
        )
        let destination = PasteDestinationStub(consumptionConfirmed: true)

        let firstResult = try await coordinator.paste(
            "first dictation",
            to: destination,
            waitForConfirmation: false
        )
        let secondResult = try await coordinator.paste("second dictation", to: destination)

        #expect(firstResult == .dispatched)
        #expect(secondResult == .confirmed)
        #expect(pasteboard.string == "previous clipboard")
    }

    @Test @MainActor
    func cancellingBackgroundConfirmationRestoresTheClipboard() async throws {
        let pasteboard = makePasteboard(containing: "previous clipboard")
        let coordinator = PasteCoordinator(
            pasteboard: pasteboard,
            eventDispatcher: { _ in .accepted },
            confirmationDelays: [1_000_000_000]
        )

        _ = try await coordinator.paste(
            "dictated text",
            to: PasteDestinationStub(consumptionConfirmed: true),
            waitForConfirmation: false
        )
        coordinator.cancelPendingConfirmation()

        #expect(pasteboard.string == "previous clipboard")
    }

    @Test @MainActor
    func backgroundConfirmationPreservesAUserClipboardChange() async throws {
        let pasteboard = makePasteboard(containing: "previous clipboard")
        let coordinator = PasteCoordinator(
            pasteboard: pasteboard,
            eventDispatcher: { _ in .accepted },
            confirmationDelays: [20_000_000]
        )

        _ = try await coordinator.paste(
            "dictated text",
            to: PasteDestinationStub(consumptionConfirmed: true),
            waitForConfirmation: false
        )
        pasteboard.clearContents()
        _ = pasteboard.setString("user clipboard", forType: .string)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(pasteboard.string == "user clipboard")
    }

    @Test @MainActor
    func staleInFlightConfirmationCannotChangeANewerClipboard() async throws {
        let pasteboard = makePasteboard(containing: "previous clipboard")
        let coordinator = PasteCoordinator(
            pasteboard: pasteboard,
            eventDispatcher: { _ in .accepted },
            confirmationDelays: [0]
        )
        let suspendedDestination = SuspendedPasteDestination()

        _ = try await coordinator.paste(
            "first dictation",
            to: suspendedDestination,
            waitForConfirmation: false
        )
        try await waitForProbe(in: suspendedDestination)
        #expect(suspendedDestination.pendingProbeCount == 1)

        let secondResult = try await coordinator.paste(
            "second dictation",
            to: PasteDestinationStub(consumptionConfirmed: true)
        )
        #expect(secondResult == .confirmed)

        pasteboard.clearContents()
        _ = pasteboard.setString("newer clipboard", forType: .string)
        suspendedDestination.resumeProbe(with: true)
        try await waitForBackgroundConfirmations(in: coordinator)

        #expect(coordinator.activeBackgroundConfirmationCount == 0)
        #expect(pasteboard.string == "newer clipboard")
    }

    @MainActor
    private func waitForProbe(in destination: SuspendedPasteDestination) async throws {
        for _ in 0..<100 {
            if destination.pendingProbeCount > 0 { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor
    private func waitForBackgroundConfirmations(
        in coordinator: PasteCoordinator
    ) async throws {
        for _ in 0..<100 {
            if coordinator.activeBackgroundConfirmationCount == 0 { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @Test @MainActor
    func rejectedPasteEventStillThrows() async {
        let pasteboard = makePasteboard(containing: "previous clipboard")
        let coordinator = PasteCoordinator(
            pasteboard: pasteboard,
            eventDispatcher: { _ in .rejected }
        )

        await #expect(throws: PasteCoordinator.PasteError.self) {
            try await coordinator.paste(
                "dictated text",
                to: PasteDestinationStub(consumptionConfirmed: false)
            )
        }
    }

    @MainActor
    private func makePasteboard(containing text: String) -> PasteboardStub {
        let pasteboard = PasteboardStub()
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        return pasteboard
    }

    @Test(arguments: [
        (RecoveryCategory.microphonePermission, RecoveryAction.openMicrophoneSettings),
        (.speechRecognitionPermission, .openSpeechRecognitionSettings),
        (.microphoneUnavailable, .retryTranscription),
        (.accessibility, .openAccessibilitySettings),
        (.missingModel, .openModels),
        (.appleSpeechUnavailable, .openModels),
        (.modelServiceUnavailable, .retryModels),
        (.transcription, .retryTranscription),
    ])
    func categoryHasExpectedAction(category: RecoveryCategory, action: RecoveryAction) {
        #expect(ErrorRecovery.presentation(for: category).action == action)
    }

    @Test
    func knownErrorsMapToRecoveryActions() {
        #expect(ErrorRecovery.presentation(for: HotkeyError.accessibilityRequired).action == .openAccessibilitySettings)
        #expect(ErrorRecovery.presentation(for: RecorderError.noInput).action == .openMicrophoneSettings)
        #expect(ErrorRecovery.presentation(for: RecorderError.noInput, microphoneAuthorized: true).action == .retryTranscription)
        #expect(ErrorRecovery.presentation(for: RecorderError.emptyRecording).action == .retryTranscription)
        #expect(
            ErrorRecovery.presentation(
                for: TiroError.message("Speech Recognition permission is required.")
            ).action == .openSpeechRecognitionSettings
        )
        #expect(
            ErrorRecovery.presentation(
                for: TiroError.message("On-device Apple Speech is unavailable.")
            ).action == .openModels
        )
        #expect(ErrorRecovery.presentation(for: TiroError.message("Model is not installed.")).action == .openModels)
        #expect(ErrorRecovery.presentation(for: TiroError.message("Could not decode audio.")).action == .retryTranscription)
        #expect(TiroError.noSpeechDetected.errorDescription == "No speech was detected.")
        #expect(ErrorRecovery.presentation(for: PasteCoordinator.PasteError.keyboardEventRejected).action == .openAccessibilitySettings)
        #expect(ErrorRecovery.presentation(for: PasteCoordinator.PasteError.secureDestination).action == .retryTranscription)
    }

    @Test
    func everyOverlayStateHasAConciseAnnouncement() {
        let states: [OverlayState] = [
            .recording, .startingUp, .transcribing, .correcting, .pasted, .pasteSent, .copied,
            .noSpeech, .modelBusy, .pasteFailed, .error,
        ]
        for state in states {
            #expect(!state.announcement.isEmpty)
            #expect(state.announcement.count < 60)
        }
    }

    @Test
    func processingStagesHaveDistinctStatusText() {
        #expect(OverlayState.transcribing.label == "Transcribing")
        #expect(OverlayState.correcting.label == "Correcting")
        #expect(OverlayState.transcribing.announcement != OverlayState.correcting.announcement)
    }

    @Test
    func emptyFinalTranscriptIsRejectedAsNoSpeech() {
        do {
            try TiroService.requireDetectedSpeech(in: " \n\t ")
            Issue.record("Expected a no-speech error")
        } catch TiroError.noSpeechDetected {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try TiroService.requireDetectedSpeech(in: "spoken words")
            try TiroService.requireDetectedSpeech(in: "new line")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@MainActor
private final class PasteboardStub: PasteboardAccess {
    private(set) var changeCount = 0
    private(set) var pasteboardItems: [NSPasteboardItem]? = []
    var refusesNextString = false

    var string: String? {
        pasteboardItems?.first?.string(forType: .string)
    }

    @discardableResult
    func clearContents() -> Int {
        changeCount += 1
        pasteboardItems = []
        return changeCount
    }

    func setString(
        _ string: String,
        forType dataType: NSPasteboard.PasteboardType
    ) -> Bool {
        if refusesNextString {
            refusesNextString = false
            return false
        }
        let item = NSPasteboardItem()
        item.setString(string, forType: dataType)
        pasteboardItems = [item]
        changeCount += 1
        return true
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        pasteboardItems = objects.compactMap { $0 as? NSPasteboardItem }
        changeCount += 1
        return pasteboardItems?.count == objects.count
    }
}

@MainActor
private struct PasteDestinationStub: PasteDestination {
    let consumptionConfirmed: Bool

    var isAvailable: Bool { true }
    var isSecure: Bool { false }
    var isFrontmost: Bool { true }
    var isFocused: Bool { true }
    var isCurrentPasteTargetAtDispatch: Bool { true }

    func restore() async -> Bool { true }

    func observePasteTarget(afterInserting text: String) -> PasteObservation {
        PasteObservation(expectedValue: text, expectedCharacterCount: nil)
    }

    func hasConsumedPaste(since observation: PasteObservation) async -> Bool {
        consumptionConfirmed
    }
}

@MainActor
private final class SuspendedPasteDestination: PasteDestination {
    private var probeContinuations: [CheckedContinuation<Bool, Never>] = []

    var pendingProbeCount: Int { probeContinuations.count }
    var isAvailable: Bool { true }
    var isSecure: Bool { false }
    var isFrontmost: Bool { true }
    var isFocused: Bool { true }
    var isCurrentPasteTargetAtDispatch: Bool { true }

    func restore() async -> Bool { true }

    func observePasteTarget(afterInserting text: String) -> PasteObservation {
        PasteObservation(expectedValue: text, expectedCharacterCount: nil)
    }

    func hasConsumedPaste(since observation: PasteObservation) async -> Bool {
        await withCheckedContinuation { continuation in
            probeContinuations.append(continuation)
        }
    }

    func resumeProbe(with result: Bool) {
        guard !probeContinuations.isEmpty else { return }
        probeContinuations.removeFirst().resume(returning: result)
    }
}
