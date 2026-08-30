import Foundation
import TiroEditing
import TiroIPC

struct CommandCorrectionRequest: Sendable {
    let snapshot: TranscriptEditingExecutionSnapshot
    let instructions: String?
    let useToken: TranscriptEditingExecutionUseToken?

    var model: TranscriptEditingModel { snapshot.model }
}

enum CommandTranscriptCompletionError: LocalizedError {
    case correctionFailed(String)
    case clipboardFailed(String)

    var code: String {
        switch self {
        case .correctionFailed: "correction_failed"
        case .clipboardFailed: "clipboard_failed"
        }
    }

    var errorDescription: String? {
        switch self {
        case .correctionFailed(let message): "Correction failed: \(message)"
        case .clipboardFailed(let message): message
        }
    }
}

@MainActor
struct CommandTranscriptCompletion {
    typealias Correct = @MainActor (
        TranscriptionResponse,
        TranscriptEditingExecutionSnapshot,
        String?
    ) async throws -> TranscriptEditingResult
    typealias UpdateHistory = @MainActor (String, String) async throws -> Void
    typealias Copy = @MainActor (String) throws -> Void
    typealias ReportCorrecting = @MainActor (String) async throws -> Void
    typealias RequireActive = @MainActor () throws -> Void

    let correct: Correct
    let updateHistory: UpdateHistory
    let copy: Copy
    let reportCorrecting: ReportCorrecting
    let requireActive: RequireActive
    var now: @MainActor () -> Date = Date.init

    func complete(
        _ response: TranscriptionResponse,
        correction: CommandCorrectionRequest?,
        copyRequested: Bool
    ) async throws -> TiroCommandResult {
        try Task.checkCancellation()
        try requireActive()
        let originalText = response.text
        var finalText = originalText
        var correctionResult: TiroCommandCorrectionResult?

        if let correction {
            try await reportCorrecting(correction.model.title)
            try Task.checkCancellation()
            try requireActive()
            let startedAt = now()
            let result: TranscriptEditingResult
            do {
                result = try await correct(
                    response,
                    correction.snapshot,
                    correction.instructions
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CommandTranscriptCompletionError.correctionFailed(
                    error.localizedDescription
                )
            }
            try Task.checkCancellation()
            try requireActive()

            var explanation = ""
            if case .proposal(let proposal) = result.decision {
                finalText = proposal.revisedText
                explanation = proposal.explanation
            }
            let changed = finalText != originalText
            correctionResult = TiroCommandCorrectionResult(
                model: correction.model.cliKey,
                changed: changed,
                seconds: max(0, now().timeIntervalSince(startedAt)),
                explanation: explanation,
                reviewRecommended: result.requiresReview || correction.instructions != nil
            )
            if changed, response.saved_to_history {
                try Task.checkCancellation()
                try await updateHistory(response.id, finalText)
            }
        }

        try Task.checkCancellation()
        try requireActive()
        if copyRequested {
            do {
                try copy(finalText)
            } catch {
                throw CommandTranscriptCompletionError.clipboardFailed(
                    error.localizedDescription
                )
            }
        }
        let changed = correctionResult?.changed == true
        return TiroCommandResult(
            kind: "transcript",
            text: finalText,
            originalText: correction == nil ? nil : originalText,
            model: response.model,
            correction: correctionResult,
            historyID: response.saved_to_history ? response.id : nil,
            transcriptionSeconds: response.transcription_seconds,
            segments: changed ? nil : response.segments.map {
                TiroCommandSegment(
                    text: $0.text,
                    startTime: $0.startSeconds,
                    endTime: $0.endSeconds,
                    speakerID: $0.speakerID
                )
            }
        )
    }
}
