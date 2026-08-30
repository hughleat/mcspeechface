import Foundation
import Testing
import McSpeechfaceEditing
import McSpeechfaceRecognition
@testable import McSpeechface

struct CommandTranscriptCompletionTests {
    @Test @MainActor
    func correctionUpdatesHistoryBeforeCopyAndBuildsStructuredResult() async throws {
        var operations: [String] = []
        let completion = CommandTranscriptCompletion(
            correct: { response, _, instructions in
                operations.append("correct:\(instructions ?? "")")
                return TranscriptEditingResult(
                    decision: .proposal(TranscriptEditProposal(
                        originalText: response.text,
                        revisedText: "Send it today.",
                        explanation: "Removed a filler."
                    )),
                    requiresReview: false
                )
            },
            updateHistory: { id, text in
                operations.append("history:\(id):\(text)")
            },
            copy: { text in operations.append("copy:\(text)") },
            reportCorrecting: { title in operations.append("report:\(title)") },
            requireActive: { operations.append("active") }
        )

        let result = try await completion.complete(
            response(savedToHistory: true),
            correction: correction(instructions: "Remove fillers."),
            copyRequested: true
        )

        #expect(result.text == "Send it today.")
        #expect(result.originalText == "Um, send it today.")
        #expect(result.historyID == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        #expect(result.correction?.changed == true)
        #expect(result.correction?.reviewRecommended == true)
        #expect(result.segments == nil)
        #expect(operations == [
            "active",
            "report:Apple Intelligence",
            "active",
            "correct:Remove fillers.",
            "active",
            "history:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee:Send it today.",
            "active",
            "copy:Send it today.",
        ])
    }

    @Test @MainActor
    func cancellationAfterCorrectionPreventsHistoryAndClipboardSideEffects() async {
        var activeChecks = 0
        var wroteHistory = false
        var copied = false
        let completion = CommandTranscriptCompletion(
            correct: { response, _, _ in
                TranscriptEditingResult(
                    decision: .proposal(TranscriptEditProposal(
                        originalText: response.text,
                        revisedText: "Changed",
                        explanation: "Changed it."
                    )),
                    requiresReview: false
                )
            },
            updateHistory: { _, _ in wroteHistory = true },
            copy: { _ in copied = true },
            reportCorrecting: { _ in },
            requireActive: {
                activeChecks += 1
                if activeChecks == 2 { throw CancellationError() }
            }
        )

        await #expect(throws: CancellationError.self) {
            try await completion.complete(
                response(savedToHistory: true),
                correction: correction(instructions: nil),
                copyRequested: true
            )
        }
        #expect(!wroteHistory)
        #expect(!copied)
    }

    @Test @MainActor
    func taskCancellationStopsANonCooperativeCorrectionBeforeSideEffects() async {
        let gate = NonCooperativeCorrectionGate()
        var wroteHistory = false
        var copied = false
        let completion = CommandTranscriptCompletion(
            correct: { response, _, _ in
                await gate.wait()
                return TranscriptEditingResult(
                    decision: .proposal(TranscriptEditProposal(
                        originalText: response.text,
                        revisedText: "Changed",
                        explanation: "Changed it."
                    )),
                    requiresReview: false
                )
            },
            updateHistory: { _, _ in wroteHistory = true },
            copy: { _ in copied = true },
            reportCorrecting: { _ in },
            requireActive: {}
        )
        let task = Task { @MainActor in
            try await completion.complete(
                response(savedToHistory: true),
                correction: correction(instructions: nil),
                copyRequested: true
            )
        }
        while !gate.isWaiting { await Task.yield() }
        task.cancel()
        gate.resume()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!wroteHistory)
        #expect(!copied)
    }

    @Test @MainActor
    func cancellationDuringStatusEventDoesNotLaunchCorrection() async {
        let gate = NonCooperativeCorrectionGate()
        var corrected = false
        let completion = CommandTranscriptCompletion(
            correct: { _, _, _ in
                corrected = true
                return TranscriptEditingResult(decision: .unchanged, requiresReview: false)
            },
            updateHistory: { _, _ in },
            copy: { _ in },
            reportCorrecting: { _ in await gate.wait() },
            requireActive: {}
        )
        let task = Task { @MainActor in
            try await completion.complete(
                response(savedToHistory: false),
                correction: correction(instructions: nil),
                copyRequested: false
            )
        }
        while !gate.isWaiting { await Task.yield() }
        task.cancel()
        gate.resume()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!corrected)
    }

    @Test @MainActor
    func clipboardFailureIsReportedAfterPreservingTheHistoryResult() async {
        struct CopyFailure: LocalizedError {
            var errorDescription: String? { "Clipboard unavailable." }
        }
        var wroteHistory = false
        let completion = CommandTranscriptCompletion(
            correct: { response, _, _ in
                TranscriptEditingResult(
                    decision: .proposal(TranscriptEditProposal(
                        originalText: response.text,
                        revisedText: "Changed",
                        explanation: "Changed it."
                    )),
                    requiresReview: false
                )
            },
            updateHistory: { _, _ in wroteHistory = true },
            copy: { _ in throw CopyFailure() },
            reportCorrecting: { _ in },
            requireActive: {}
        )

        do {
            _ = try await completion.complete(
                response(savedToHistory: true),
                correction: correction(instructions: nil),
                copyRequested: true
            )
            Issue.record("Expected clipboard failure")
        } catch let error as CommandTranscriptCompletionError {
            #expect(error.code == "clipboard_failed")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(wroteHistory)
    }

    private func correction(instructions: String?) -> CommandCorrectionRequest {
        CommandCorrectionRequest(
            snapshot: TranscriptEditingExecutionSnapshot(
                model: .appleFoundation,
                promptConfiguration: .default,
                commandLineConfiguration: nil
            ),
            instructions: instructions,
            useToken: nil
        )
    }

    private func response(savedToHistory: Bool) -> TranscriptionResponse {
        TranscriptionResponse(
            id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            timestamp: "2026-08-30T00:00:00Z",
            model: "test-model",
            audio_file: nil,
            transcription_seconds: 0.5,
            text: "Um, send it today.",
            language: "English",
            origin_bundle_id: nil,
            origin_app_name: nil,
            source_filename: nil,
            segments: [TranscriptSegment(
                text: "Um, send it today.",
                startSeconds: 0,
                endSeconds: 1
            )],
            saved_to_history: savedToHistory
        )
    }
}

@MainActor
private final class NonCooperativeCorrectionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
