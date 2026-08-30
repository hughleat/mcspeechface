import Foundation

func isCurrentDictationTask(
    isCancelled: Bool,
    operationID: UUID?,
    currentOperationID: UUID?,
    generationID: UUID? = nil,
    currentGenerationID: UUID? = nil
) -> Bool {
    guard !isCancelled, let operationID, operationID == currentOperationID else { return false }
    return generationID.map { $0 == currentGenerationID } ?? true
}

enum DictationShortcutTapAction: Equatable {
    case startRecording
    case cancelStarting
    case stopRecording
    case acceptReview
    case requestDeferredRecording
    case ignore
}

struct DeferredRecordingStart {
    private var isPending = false

    mutating func request() {
        isPending = true
    }

    mutating func consume() -> Bool {
        guard isPending else { return false }
        isPending = false
        return true
    }
}

enum DictationWorkflowState: Equatable {
    case idle
    case starting
    case recording
    case transcribing
    case addingReviewDictation
    case transcribingReviewDictation
    case correcting
    case reviewing
    case committing

    var commandName: String {
        switch self {
        case .idle: "idle"
        case .starting: "starting"
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .addingReviewDictation: "adding review dictation"
        case .transcribingReviewDictation: "transcribing review dictation"
        case .correcting: "correcting"
        case .reviewing: "reviewing"
        case .committing: "committing"
        }
    }

    var handlesEscape: Bool {
        switch self {
        case .starting, .recording, .transcribing, .addingReviewDictation,
             .transcribingReviewDictation, .correcting, .reviewing: true
        case .idle, .committing: false
        }
    }

    func shortcutTapAction(reviewIsActive: Bool) -> DictationShortcutTapAction {
        switch self {
        case .idle: .startRecording
        case .starting: .cancelStarting
        case .recording: .stopRecording
        case .transcribing, .addingReviewDictation,
             .transcribingReviewDictation, .correcting: .ignore
        case .reviewing: reviewIsActive ? .acceptReview : .requestDeferredRecording
        case .committing: .requestDeferredRecording
        }
    }
}
