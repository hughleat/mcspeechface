import Foundation
import TiroEditing

enum TranscriptEditingModel: String, CaseIterable, Hashable, Sendable {
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

    var detail: String {
        switch self {
        case .off: "Do not repair spoken self-corrections"
        case .appleFoundation: "Provided by macOS · On-device"
        case .qwenLocal: "Multilingual · On-device · \(downloadSizeDescription)"
        }
    }

    var downloadSizeDescription: String {
        guard self == .qwenLocal else { return "" }
        return ByteCountFormatter.string(
            fromByteCount: LocalTranscriptEditingModelSpec.qwen3Local.expectedBytes,
            countStyle: .file
        )
    }

    static var selected: TranscriptEditingModel {
        get { load(from: .standard) }
        set { save(newValue, to: .standard) }
    }

    static func load(from defaults: UserDefaults) -> TranscriptEditingModel {
        defaults.string(forKey: defaultsKey)
            .flatMap(TranscriptEditingModel.init(rawValue:)) ?? .off
    }

    static func save(_ model: TranscriptEditingModel, to defaults: UserDefaults) {
        defaults.set(model.rawValue, forKey: defaultsKey)
    }
}

struct TranscriptEditingPromptPreferences {
    static let storageKey = "transcriptEditingPromptConfiguration"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> TranscriptEditingPromptConfiguration {
        if let data = defaults.data(forKey: Self.storageKey),
           let configuration = try? JSONDecoder().decode(
               TranscriptEditingPromptConfiguration.self,
               from: data
           ),
           (try? configuration.validateForSharedModels()) != nil {
            return configuration
        }
        return .default
    }

    func save(_ configuration: TranscriptEditingPromptConfiguration) throws {
        try configuration.validateForSharedModels()
        guard configuration != .default else {
            reset()
            return
        }
        defaults.set(try JSONEncoder().encode(configuration), forKey: Self.storageKey)
    }

    func reset() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}

struct TranscriptEditingModelSnapshot: Equatable, Sendable {
    let appleAvailability: TranscriptEditorAvailability
    let localStatus: LocalTranscriptEditingModelStatus

    func canSelect(_ model: TranscriptEditingModel) -> Bool {
        switch model {
        case .off:
            true
        case .appleFoundation:
            appleAvailability == .available
        case .qwenLocal:
            if case .installed = localStatus { true } else { false }
        }
    }
}

actor TranscriptEditingService {
    private var appleEditor: (any TranscriptEditor)?
    private var qwenEditor: (any TranscriptEditor)?
    private var activeQwenRepairs = 0
    private var localModelMutationInProgress = false
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
        to response: TranscriptionResponse
    ) async throws -> TranscriptEditDecision {
        let selection = TranscriptEditingModel.selected
        guard selection != .off else { return .unchanged }
        if selection == .qwenLocal, localModelMutationInProgress {
            throw TranscriptEditingServiceError.modelOperationInProgress
        }
        let selectedEditor = try editor(for: selection)
        if selection == .qwenLocal { activeQwenRepairs += 1 }
        defer {
            if selection == .qwenLocal { activeQwenRepairs -= 1 }
        }
        return try await selectedEditor.proposeEdits(
            for: Self.request(
                for: response,
                promptConfiguration: TranscriptEditingPromptPreferences().load()
            )
        )
    }

    static func request(
        for response: TranscriptionResponse,
        promptConfiguration: TranscriptEditingPromptConfiguration
    ) -> TranscriptEditRequest {
        TranscriptEditRequest(
            text: response.text,
            language: response.language,
            promptConfiguration: promptConfiguration
        )
    }

    func localModelStatus() async -> LocalTranscriptEditingModelStatus {
        await localModelStore.status()
    }

    func modelSnapshot() async -> TranscriptEditingModelSnapshot {
        async let appleAvailability = availability(for: .appleFoundation)
        async let localStatus = localModelStore.status()
        return await TranscriptEditingModelSnapshot(
            appleAvailability: appleAvailability,
            localStatus: localStatus
        )
    }

    func localModelDownloadSpace() async -> LocalTranscriptEditingModelDownloadSpace {
        await localModelStore.downloadSpace()
    }

    func installLocalModel() async throws {
        try await localModelStore.install()
    }

    func deleteLocalModel() async throws {
        guard activeQwenRepairs == 0 else {
            throw TranscriptEditingServiceError.modelInUse
        }
        guard !localModelMutationInProgress else {
            throw TranscriptEditingServiceError.modelOperationInProgress
        }
        localModelMutationInProgress = true
        defer { localModelMutationInProgress = false }
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
    case modelInUse
    case modelOperationInProgress

    var errorDescription: String? {
        switch self {
        case .disabled: "Spoken corrections are off."
        case .requiresMacOS26: "Apple Intelligence requires macOS 26 or later."
        case .modelInUse: "Wait for the current transcript repair to finish before deleting this model."
        case .modelOperationInProgress: "Wait for the correction model operation to finish."
        }
    }
}
