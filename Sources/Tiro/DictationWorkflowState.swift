enum DictationShortcutTapAction: Equatable {
    case startRecording
    case cancelStarting
    case stopRecording
    case acceptReview
    case toggleDeferredRecording
    case ignore
}

enum DictationWorkflowState: Equatable {
    case idle
    case starting
    case recording
    case transcribing
    case correcting
    case reviewing
    case committing

    var commandName: String {
        switch self {
        case .idle: "idle"
        case .starting: "starting"
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .correcting: "correcting"
        case .reviewing: "reviewing"
        case .committing: "committing"
        }
    }

    var handlesEscape: Bool {
        switch self {
        case .starting, .recording, .transcribing, .correcting, .reviewing: true
        case .idle, .committing: false
        }
    }

    func shortcutTapAction(reviewIsActive: Bool) -> DictationShortcutTapAction {
        switch self {
        case .idle: .startRecording
        case .starting: .cancelStarting
        case .recording: .stopRecording
        case .transcribing, .correcting: .ignore
        case .reviewing: reviewIsActive ? .acceptReview : .toggleDeferredRecording
        case .committing: .toggleDeferredRecording
        }
    }
}
