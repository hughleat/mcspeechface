import Foundation
import TiroEditing

enum TranscriptEditingModel: String, CaseIterable, Sendable {
    case off
    case appleFoundation

    static let defaultsKey = "transcriptEditingModel"

    var title: String {
        switch self {
        case .off: "Off"
        case .appleFoundation: "Apple Intelligence"
        }
    }

    static var selected: TranscriptEditingModel {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(TranscriptEditingModel.init(rawValue:)) ?? .off
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

actor TranscriptEditingService {
    private var appleEditor: (any TranscriptEditor)?

    func availability(for model: TranscriptEditingModel) async -> TranscriptEditorAvailability {
        guard model != .off else {
            return .unavailable(reason: "Spoken corrections are off.")
        }
        do {
            return try await editor(for: model).availability()
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    func proposeEdits(
        to text: String,
        language: String?
    ) async throws -> TranscriptEditDecision {
        let selection = TranscriptEditingModel.selected
        guard selection != .off else { return .unchanged }
        return try await editor(for: selection).proposeEdits(
            for: TranscriptEditRequest(text: text, language: language)
        )
    }

    private func editor(for model: TranscriptEditingModel) throws -> any TranscriptEditor {
        switch model {
        case .off:
            throw TranscriptEditingServiceError.disabled
        case .appleFoundation:
            guard #available(macOS 26.0, *) else {
                throw TranscriptEditingServiceError.requiresMacOS26
            }
            if let appleEditor { return appleEditor }
            let editor = try AppleFoundationTranscriptEditor()
            appleEditor = editor
            return editor
        }
    }
}

enum TranscriptEditingServiceError: LocalizedError {
    case disabled
    case requiresMacOS26

    var errorDescription: String? {
        switch self {
        case .disabled: "Spoken corrections are off."
        case .requiresMacOS26: "Apple Intelligence requires macOS 26 or later."
        }
    }
}
