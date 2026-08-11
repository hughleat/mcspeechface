import Foundation
import TiroEditing

enum TranscriptEditingModel: String, CaseIterable, Sendable {
    case off
    case appleFoundation
    case qwenLocal

    static let defaultsKey = "transcriptEditingModel"

    var title: String {
        switch self {
        case .off: "Off"
        case .appleFoundation: "Apple Intelligence"
        case .qwenLocal: "Qwen 3 Local"
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
    private var qwenEditor: (any TranscriptEditor)?
    private let localModelStore: LocalTranscriptEditingModelStore
    private let llamaExecutableURL: URL

    init(
        modelsRoot: URL = AppPaths.editingModelsDirectory,
        llamaExecutableURL: URL = AppPaths.llamaHelperExecutable,
        downloader: any TranscriptEditingModelDownloading =
            URLSessionTranscriptEditingModelDownloader()
    ) {
        localModelStore = LocalTranscriptEditingModelStore(
            spec: .qwen3Local,
            root: modelsRoot,
            downloader: downloader
        )
        self.llamaExecutableURL = llamaExecutableURL
    }

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

    func localModelStatus() async -> LocalTranscriptEditingModelStatus {
        await localModelStore.status()
    }

    func installLocalModel() async throws {
        try await localModelStore.install()
    }

    func deleteLocalModel() async throws {
        qwenEditor = nil
        try await localModelStore.delete()
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
        case .qwenLocal:
            if let qwenEditor { return qwenEditor }
            let editor = GGUFTranscriptEditor(
                spec: .qwen3Local,
                executableURL: llamaExecutableURL,
                modelURL: localModelStore.modelURL
            )
            qwenEditor = editor
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
