import Foundation
import TiroEditing

enum TranscriptEditingModel: String, CaseIterable, Hashable, Sendable {
    case off
    case appleFoundation
    case commandLine
    case qwenLocal
    case ministralLocal

    static let defaultsKey = "transcriptEditingModel"

    var title: String {
        switch self {
        case .off: "Off"
        case .appleFoundation: "Apple Intelligence"
        case .commandLine: "Command Line"
        case .qwenLocal: "Qwen 3 1.7B"
        case .ministralLocal: "Ministral 3 3B"
        }
    }

    var detail: String {
        switch self {
        case .off: return "Do not repair spoken self-corrections"
        case .appleFoundation: return "Provided by macOS · On-device"
        case .commandLine:
            let configuration = CommandLineCorrectionConfiguration.load()
            return "\(configuration.preset.title) · May send text off-device"
        case .qwenLocal:
            return "Balanced local model · On-device · \(downloadSizeDescription)"
        case .ministralLocal:
            return "Higher-quality local model · On-device · \(downloadSizeDescription)"
        }
    }

    var downloadSizeDescription: String {
        guard let localSpec else { return "" }
        return ByteCountFormatter.string(
            fromByteCount: localSpec.expectedBytes,
            countStyle: .file
        )
    }

    var localSpec: LocalTranscriptEditingModelSpec? {
        switch self {
        case .qwenLocal: .qwen3Local
        case .ministralLocal: .ministral3Local
        case .off, .appleFoundation, .commandLine: nil
        }
    }

    static var localModels: [TranscriptEditingModel] {
        allCases.filter { $0.localSpec != nil }
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
    let commandLineAvailability: TranscriptEditorAvailability
    let localStatuses: [TranscriptEditingModel: LocalTranscriptEditingModelStatus]

    func canSelect(_ model: TranscriptEditingModel) -> Bool {
        switch model {
        case .off:
            true
        case .appleFoundation:
            appleAvailability == .available
        case .commandLine:
            commandLineAvailability == .available
        case .qwenLocal, .ministralLocal:
            if case .installed = localStatuses[model] { true } else { false }
        }
    }
}

struct TranscriptEditingResult: Sendable {
    let decision: TranscriptEditDecision
    let requiresReview: Bool
}

actor TranscriptEditingService {
    private var appleEditor: (any TranscriptEditor)?
    private var commandLineEditor: (
        configuration: CommandLineCorrectionConfiguration,
        editor: any TranscriptEditor
    )?
    private var localEditors: [TranscriptEditingModel: any TranscriptEditor] = [:]
    private var activeLocalRepairs: [TranscriptEditingModel: Int] = [:]
    private var localModelMutations: Set<TranscriptEditingModel> = []
    private let localModelStores: [TranscriptEditingModel: LocalTranscriptEditingModelStore]
    private let llamaExecutableURL: URL

    init(
        modelsRoot: URL = AppPaths.editingModelsDirectory,
        llamaExecutableURL: URL = AppPaths.llamaHelperExecutable,
        downloader: any TranscriptEditingModelDownloading =
            URLSessionTranscriptEditingModelDownloader()
    ) {
        localModelStores = Dictionary(uniqueKeysWithValues: TranscriptEditingModel.localModels.compactMap {
            guard let spec = $0.localSpec else { return nil }
            return ($0, LocalTranscriptEditingModelStore(
                spec: spec,
                root: modelsRoot,
                downloader: downloader
            ))
        })
        self.llamaExecutableURL = llamaExecutableURL
    }

    func availability(for model: TranscriptEditingModel) async -> TranscriptEditorAvailability {
        guard model != .off else {
            return .unavailable(reason: "Spoken corrections are off.")
        }
        if model == .commandLine {
            let configuration = CommandLineCorrectionConfiguration.load()
            return configuration.isExecutableAvailable
                ? .available
                : .unavailable(reason: "Choose an installed executable.")
        }
        do {
            return try await editor(for: model).availability()
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    func proposeEdits(
        to response: TranscriptionResponse
    ) async throws -> TranscriptEditingResult {
        let selection = TranscriptEditingModel.selected
        guard selection != .off else {
            return TranscriptEditingResult(decision: .unchanged, requiresReview: false)
        }
        if localModelMutations.contains(selection) {
            throw TranscriptEditingServiceError.modelOperationInProgress
        }
        let selectedEditor = try editor(for: selection)
        if selection.localSpec != nil {
            activeLocalRepairs[selection, default: 0] += 1
        }
        defer {
            if selection.localSpec != nil {
                activeLocalRepairs[selection, default: 1] -= 1
            }
        }
        let promptConfiguration = TranscriptEditingPromptPreferences().load()
        let decision = try await selectedEditor.proposeEdits(
            for: Self.request(for: response, promptConfiguration: promptConfiguration)
        )
        return TranscriptEditingResult(
            decision: decision,
            requiresReview: promptConfiguration.isCustom || selection == .commandLine
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

    func compareCorrections(
        text: String,
        language: String?,
        models: [TranscriptEditingModel]
    ) async throws -> TranscriptCorrectionComparison {
        let selectedModels = models.reduce(into: [TranscriptEditingModel]()) { result, model in
            guard model != .off, !result.contains(model) else { return }
            result.append(model)
        }
        guard !selectedModels.contains(where: localModelMutations.contains) else {
            throw TranscriptEditingServiceError.modelOperationInProgress
        }
        let localModels = selectedModels.filter { $0.localSpec != nil }
        for model in localModels { activeLocalRepairs[model, default: 0] += 1 }
        defer {
            for model in localModels { activeLocalRepairs[model, default: 1] -= 1 }
        }
        let request = TranscriptEditRequest(
            text: text,
            language: language,
            promptConfiguration: TranscriptEditingPromptPreferences().load()
        )
        let providers = try selectedModels.map {
            TranscriptCorrectionProvider(editor: try editor(for: $0))
        }
        return try await TranscriptCorrectionComparator().compare(
            request: request,
            providers: providers
        )
    }

    func localModelStatus(
        for model: TranscriptEditingModel
    ) async -> LocalTranscriptEditingModelStatus {
        guard let store = localModelStores[model] else { return .notInstalled }
        return await store.status()
    }

    func modelSnapshot() async -> TranscriptEditingModelSnapshot {
        let appleAvailability = await availability(for: .appleFoundation)
        let commandLineAvailability = await availability(for: .commandLine)
        var localStatuses: [TranscriptEditingModel: LocalTranscriptEditingModelStatus] = [:]
        for (model, store) in localModelStores {
            localStatuses[model] = await store.status()
        }
        return TranscriptEditingModelSnapshot(
            appleAvailability: appleAvailability,
            commandLineAvailability: commandLineAvailability,
            localStatuses: localStatuses
        )
    }

    func localModelDownloadSpaces() async -> [
        TranscriptEditingModel: LocalTranscriptEditingModelDownloadSpace
    ] {
        var spaces: [TranscriptEditingModel: LocalTranscriptEditingModelDownloadSpace] = [:]
        for (model, store) in localModelStores {
            spaces[model] = await store.downloadSpace()
        }
        return spaces
    }

    func installLocalModel(_ model: TranscriptEditingModel) async throws {
        guard let store = localModelStores[model] else {
            throw TranscriptEditingServiceError.notLocalModel
        }
        guard localModelMutations.isEmpty else {
            throw TranscriptEditingServiceError.modelOperationInProgress
        }
        localModelMutations.insert(model)
        defer { localModelMutations.remove(model) }
        try await store.install()
    }

    func deleteLocalModel(_ model: TranscriptEditingModel) async throws {
        guard let store = localModelStores[model] else {
            throw TranscriptEditingServiceError.notLocalModel
        }
        guard TranscriptEditingModel.selected != model else {
            throw TranscriptEditingServiceError.selectedModel
        }
        guard activeLocalRepairs[model, default: 0] == 0 else {
            throw TranscriptEditingServiceError.modelInUse
        }
        guard localModelMutations.isEmpty else {
            throw TranscriptEditingServiceError.modelOperationInProgress
        }
        localModelMutations.insert(model)
        defer { localModelMutations.remove(model) }
        localEditors[model] = nil
        try await store.delete()
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
        case .commandLine:
            let saved = CommandLineCorrectionConfiguration.load()
            if let commandLineEditor, commandLineEditor.configuration == saved {
                return commandLineEditor.editor
            }
            try saved.validate()
            let arguments = saved.arguments.map {
                $0.replacingOccurrences(of: "{model}", with: saved.model)
            }
            let configuration = try TiroEditing.CommandLineCorrectionConfiguration(
                id: "command-line-\(saved.preset.rawValue)",
                name: saved.preset.title,
                executablePath: saved.executablePath,
                arguments: arguments,
                timeout: 120
            )
            let editor = CommandLineTranscriptEditor(
                configuration: configuration,
                requiresGrounding: false
            )
            commandLineEditor = (saved, editor)
            return editor
        case .qwenLocal, .ministralLocal:
            if let editor = localEditors[model] { return editor }
            guard let spec = model.localSpec,
                  let store = localModelStores[model] else {
                throw TranscriptEditingServiceError.notLocalModel
            }
            let editor = GGUFTranscriptEditor(
                spec: spec,
                executableURL: llamaExecutableURL,
                modelURL: store.modelURL
            )
            localEditors[model] = editor
            return editor
        }
    }
}

enum TranscriptEditingServiceError: LocalizedError {
    case disabled
    case requiresMacOS26
    case modelInUse
    case modelOperationInProgress
    case notLocalModel
    case selectedModel
    case commandLineNotConfigured

    var errorDescription: String? {
        switch self {
        case .disabled: "Spoken corrections are off."
        case .requiresMacOS26: "Apple Intelligence requires macOS 26 or later."
        case .modelInUse: "Wait for the current transcript repair to finish before deleting this model."
        case .modelOperationInProgress: "Wait for the correction model operation to finish."
        case .notLocalModel: "This correction model is not downloadable."
        case .selectedModel: "Select another correction model before deleting this one."
        case .commandLineNotConfigured: "Configure an available command-line correction executable."
        }
    }
}
