import Foundation
import TiroEditing

enum TranscriptEditingModel: String, CaseIterable, Hashable, Sendable {
    case off
    case appleFoundation
    case codexCommandLine
    case claudeCommandLine
    case customCommandLine
    case qwen35SmallLocal
    case qwen3SmallLocal
    case qwenLocal
    case granite4Local
    case smolLM3Local
    case ministralLocal

    static let defaultsKey = "transcriptEditingModel"

    var title: String {
        switch self {
        case .off: "Off"
        case .appleFoundation: "Apple Intelligence"
        case .codexCommandLine: "Codex"
        case .claudeCommandLine: "Claude"
        case .customCommandLine: "Custom Command"
        case .qwen35SmallLocal: "Qwen 3.5 0.8B"
        case .qwen3SmallLocal: "Qwen 3 0.6B"
        case .qwenLocal: "Qwen 3 1.7B"
        case .granite4Local: "Granite 4.0 1B"
        case .smolLM3Local: "SmolLM3 3B"
        case .ministralLocal: "Ministral 3 3B"
        }
    }

    var detail: String { detail(from: .standard) }

    func detail(from defaults: UserDefaults) -> String {
        switch self {
        case .off: return "Do not repair spoken self-corrections"
        case .appleFoundation: return "Provided by macOS · On-device"
        case .codexCommandLine:
            return providerDetail(for: .codex, defaults: defaults)
        case .claudeCommandLine:
            return providerDetail(for: .claude, defaults: defaults)
        case .customCommandLine:
            return "Run an executable with editable arguments · May send text off-device"
        case .qwen35SmallLocal:
            return "Newest lightweight Qwen · On-device · \(downloadSizeDescription)"
        case .qwen3SmallLocal:
            return "Fastest local model · On-device · \(downloadSizeDescription)"
        case .qwenLocal:
            return "Balanced local model · On-device · \(downloadSizeDescription)"
        case .granite4Local:
            return "Compact general-purpose model · On-device · \(downloadSizeDescription)"
        case .smolLM3Local:
            return "Stronger local model · On-device · \(downloadSizeDescription)"
        case .ministralLocal:
            return "Higher-quality local model · On-device · \(downloadSizeDescription)"
        }
    }

    private func providerDetail(
        for preset: CommandLineCorrectionPreset,
        defaults: UserDefaults
    ) -> String {
        let configuration = CommandLineCorrectionConfiguration.load(
            preset: preset,
            from: defaults
        )
        let connection = configuration.connectionMode.title
        let access = configuration.usesExplicitArguments
            ? "Custom command permissions"
            : configuration.accessProfile.title
        return "\(connection) · \(configuration.model) · \(access)"
            + " · May send text off-device"
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
        case .qwen35SmallLocal: .qwen35SmallLocal
        case .qwen3SmallLocal: .qwen3SmallLocal
        case .qwenLocal: .qwen3Local
        case .granite4Local: .granite4Local
        case .smolLM3Local: .smolLM3Local
        case .ministralLocal: .ministral3Local
        case .off, .appleFoundation, .codexCommandLine, .claudeCommandLine,
             .customCommandLine: nil
        }
    }

    var commandLinePreset: CommandLineCorrectionPreset? {
        switch self {
        case .codexCommandLine: .codex
        case .claudeCommandLine: .claude
        case .customCommandLine: .custom
        case .off, .appleFoundation, .qwen35SmallLocal, .qwen3SmallLocal,
             .qwenLocal, .granite4Local, .smolLM3Local, .ministralLocal: nil
        }
    }

    var isCommandLine: Bool { commandLinePreset != nil }

    var cliKey: String {
        switch self {
        case .off: "off"
        case .appleFoundation: "apple-foundation"
        case .codexCommandLine: "codex"
        case .claudeCommandLine: "claude"
        case .customCommandLine: "custom-command"
        case .qwen35SmallLocal: "qwen-3.5-0.8b"
        case .qwen3SmallLocal: "qwen-3-0.6b"
        case .qwenLocal: "qwen-3-1.7b"
        case .granite4Local: "granite-4-1b"
        case .smolLM3Local: "smollm3-3b"
        case .ministralLocal: "ministral-3-3b"
        }
    }

    static func model(cliKey: String) -> TranscriptEditingModel? {
        allCases.first { $0.cliKey == cliKey }
    }

    static var commandLineModels: [TranscriptEditingModel] {
        allCases.filter(\.isCommandLine)
    }

    static var localModels: [TranscriptEditingModel] {
        allCases.filter { $0.localSpec != nil }
    }

    static var selected: TranscriptEditingModel {
        get { load(from: .standard) }
        set { save(newValue, to: .standard) }
    }

    static func load(from defaults: UserDefaults) -> TranscriptEditingModel {
        guard let rawValue = defaults.string(forKey: defaultsKey) else { return .off }
        if rawValue == "commandLine" {
            return model(for: CommandLineCorrectionConfiguration.loadLegacy(from: defaults).preset)
        }
        return TranscriptEditingModel(rawValue: rawValue) ?? .off
    }

    static func save(_ model: TranscriptEditingModel, to defaults: UserDefaults) {
        defaults.set(model.rawValue, forKey: defaultsKey)
    }

    static func model(for preset: CommandLineCorrectionPreset) -> TranscriptEditingModel {
        switch preset {
        case .codex: .codexCommandLine
        case .claude: .claudeCommandLine
        case .custom: .customCommandLine
        }
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
    let commandLineAvailability: [TranscriptEditingModel: TranscriptEditorAvailability]
    let localStatuses: [TranscriptEditingModel: LocalTranscriptEditingModelStatus]

    func canSelect(_ model: TranscriptEditingModel) -> Bool {
        if model == .off { return true }
        return if case .available = availability(for: model) { true } else { false }
    }

    func availability(for model: TranscriptEditingModel) -> TranscriptEditorAvailability {
        switch model {
        case .off:
            .unavailable(reason: "Correction is off.")
        case .appleFoundation:
            appleAvailability
        case .codexCommandLine, .claudeCommandLine, .customCommandLine:
            commandLineAvailability[model]
                ?? .unavailable(reason: "The command-line provider is unavailable.")
        case .qwen35SmallLocal, .qwen3SmallLocal, .qwenLocal,
             .granite4Local, .smolLM3Local, .ministralLocal:
            switch localStatuses[model] ?? .notInstalled {
            case .installed: .available
            case .installing: .unavailable(reason: "The model is still downloading.")
            case .notInstalled: .unavailable(reason: "The model is not installed.")
            }
        }
    }

    func installed(for model: TranscriptEditingModel) -> Bool? {
        guard model.localSpec != nil else { return nil }
        if case .installed = localStatuses[model] { return true }
        return false
    }
}

extension TranscriptEditorAvailability {
    var unavailableReason: String? {
        if case .unavailable(let reason) = self { reason } else { nil }
    }
}

struct TranscriptEditingResult: Sendable {
    let decision: TranscriptEditDecision
    let requiresReview: Bool
}

struct TranscriptEditingExecutionSnapshot: Sendable {
    let model: TranscriptEditingModel
    let promptConfiguration: TranscriptEditingPromptConfiguration
    let commandLineConfiguration: CommandLineCorrectionConfiguration?
}

struct TranscriptEditingExecutionUseToken: Sendable {
    let id: UUID
    let model: TranscriptEditingModel
}

struct LocalCorrectionUseToken: Sendable {
    let model: TranscriptEditingModel
}

enum LocalCorrectionIdleTimeout: Int, CaseIterable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case never = 0

    static let defaultsKey = "localCorrectionIdleTimeoutSeconds"
    static let `default` = LocalCorrectionIdleTimeout.tenMinutes

    var title: String {
        switch self {
        case .oneMinute: "1 minute"
        case .fiveMinutes: "5 minutes"
        case .tenMinutes: "10 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .never: "Never"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard defaults.object(forKey: defaultsKey) != nil else { return .default }
        return Self(rawValue: defaults.integer(forKey: defaultsKey)) ?? .default
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

actor TranscriptEditingService {
    private var appleEditor: (any TranscriptEditor)?
    private var commandLineEditors: [TranscriptEditingModel: (
        configuration: CommandLineCorrectionConfiguration,
        promptConfiguration: TranscriptEditingPromptConfiguration,
        editor: any TranscriptEditor
    )] = [:]
    private var localEditors: [TranscriptEditingModel: GGUFTranscriptEditor] = [:]
    private var activeCorrections: [TranscriptEditingModel: Int] = [:]
    private var executionUseTokens: [UUID: TranscriptEditingModel] = [:]
    private var localModelMutations: Set<TranscriptEditingModel> = []
    private var isShuttingDown = false
    private let localModelStores: [TranscriptEditingModel: LocalTranscriptEditingModelStore]
    private let llamaServerExecutableURL: URL
    private let defaults: UserDefaults

    init(
        modelsRoot: URL = AppPaths.editingModelsDirectory,
        llamaServerExecutableURL: URL = AppPaths.llamaServerHelperExecutable,
        defaults: UserDefaults = .standard,
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
        self.llamaServerExecutableURL = llamaServerExecutableURL
        self.defaults = defaults
    }

    func availability(for model: TranscriptEditingModel) async -> TranscriptEditorAvailability {
        await availability(for: executionSnapshot(for: model))
    }

    func executionSnapshot(for model: TranscriptEditingModel) -> TranscriptEditingExecutionSnapshot {
        let commandLineConfiguration = model.commandLinePreset.map {
            CommandLineCorrectionConfiguration.load(preset: $0, from: defaults)
        }
        return TranscriptEditingExecutionSnapshot(
            model: model,
            promptConfiguration: TranscriptEditingPromptPreferences(defaults: defaults).load(),
            commandLineConfiguration: commandLineConfiguration
        )
    }

    func availability(
        for snapshot: TranscriptEditingExecutionSnapshot
    ) async -> TranscriptEditorAvailability {
        let model = snapshot.model
        guard model != .off else {
            return .unavailable(reason: "Spoken corrections are off.")
        }
        if let configuration = snapshot.commandLineConfiguration {
            return configuration.isExecutableAvailable
                ? .available
                : .unavailable(reason: "Choose an installed executable.")
        }
        do {
            return try await editor(for: snapshot).availability()
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    func proposeEdits(
        to response: TranscriptionResponse,
        model: TranscriptEditingModel? = nil,
        additionalInstructions: String? = nil,
        progressHandler: (@Sendable (TranscriptEditingProgress) -> Void)? = nil
    ) async throws -> TranscriptEditingResult {
        let selection = model ?? TranscriptEditingModel.load(from: defaults)
        return try await proposeEdits(
            to: response,
            snapshot: executionSnapshot(for: selection),
            additionalInstructions: additionalInstructions,
            progressHandler: progressHandler
        )
    }

    func proposeEdits(
        to response: TranscriptionResponse,
        snapshot: TranscriptEditingExecutionSnapshot,
        additionalInstructions: String? = nil,
        progressHandler: (@Sendable (TranscriptEditingProgress) -> Void)? = nil
    ) async throws -> TranscriptEditingResult {
        guard !isShuttingDown else { throw TranscriptEditingServiceError.shuttingDown }
        let selection = snapshot.model
        guard selection != .off else {
            return TranscriptEditingResult(decision: .unchanged, requiresReview: false)
        }
        if localModelMutations.contains(selection) {
            throw TranscriptEditingServiceError.modelOperationInProgress
        }
        let selectedEditor = try await editor(for: snapshot)
        activeCorrections[selection, default: 0] += 1
        defer {
            releaseActiveCorrection(for: selection)
        }
        let promptConfiguration = snapshot.promptConfiguration
        let request = Self.request(
            for: response,
            promptConfiguration: promptConfiguration,
            additionalInstructions: additionalInstructions
        )
        let decision: TranscriptEditDecision
        if let progressEditor = selectedEditor as? any ProgressReportingTranscriptEditor {
            decision = try await progressEditor.proposeEdits(
                for: request,
                progressHandler: progressHandler
            )
        } else {
            decision = try await selectedEditor.proposeEdits(for: request)
        }
        return TranscriptEditingResult(
            decision: decision,
            requiresReview: promptConfiguration.isCustom || selection.isCommandLine
        )
    }

    func prepareSelectedLocalModel() async throws -> LocalCorrectionUseToken? {
        try Task.checkCancellation()
        guard !isShuttingDown else { throw TranscriptEditingServiceError.shuttingDown }
        let selection = TranscriptEditingModel.load(from: defaults)
        if let preset = selection.commandLinePreset, preset != .custom {
            let configuration = CommandLineCorrectionConfiguration.load(
                preset: preset,
                from: defaults
            )
            if configuration.connectionMode == .enhanced {
                let selectedEditor = try await editor(for: selection)
                if let editor = selectedEditor as? any PersistentTranscriptEditor {
                    try await editor.prepare()
                }
            }
            return nil
        }
        guard selection.localSpec != nil else { return nil }
        guard !localModelMutations.contains(selection) else {
            throw TranscriptEditingServiceError.modelOperationInProgress
        }
        let editor = try localEditor(for: selection)
        await editor.beginUse()
        do {
            try Task.checkCancellation()
            await editor.updateIdleTimeout(idleTimeout)
            try await editor.prepare()
            return LocalCorrectionUseToken(model: selection)
        } catch {
            await editor.endUse()
            throw error
        }
    }

    func releaseLocalModelUse(_ token: LocalCorrectionUseToken) async {
        await localEditors[token.model]?.endUse()
    }

    func reserveExecution(
        for snapshot: TranscriptEditingExecutionSnapshot
    ) async throws -> TranscriptEditingExecutionUseToken {
        guard !isShuttingDown else { throw TranscriptEditingServiceError.shuttingDown }
        guard snapshot.model != .off else { throw TranscriptEditingServiceError.disabled }
        guard !localModelMutations.contains(snapshot.model) else {
            throw TranscriptEditingServiceError.modelOperationInProgress
        }
        if snapshot.model.localSpec != nil {
            activeCorrections[snapshot.model, default: 0] += 1
            do {
                _ = try await editor(for: snapshot)
            } catch {
                releaseActiveCorrection(for: snapshot.model)
                throw error
            }
        } else {
            _ = try await editor(for: snapshot)
            activeCorrections[snapshot.model, default: 0] += 1
        }
        let token = TranscriptEditingExecutionUseToken(id: UUID(), model: snapshot.model)
        executionUseTokens[token.id] = token.model
        return token
    }

    func releaseExecution(_ token: TranscriptEditingExecutionUseToken) {
        guard let model = executionUseTokens.removeValue(forKey: token.id) else { return }
        releaseActiveCorrection(for: model)
    }

    func prepareForShutdown() async {
        isShuttingDown = true
        await stopAllLocalModels()
        await stopAllPersistentProviders()
    }

    func correctionModelDidChange(to selectedModel: TranscriptEditingModel) async {
        for (model, editor) in localEditors
        where model != selectedModel && activeCorrections[model, default: 0] == 0 {
            await editor.stop()
        }
        if let editor = localEditors[selectedModel] {
            await editor.updateIdleTimeout(idleTimeout)
        }
        for (model, cached) in commandLineEditors
        where model != selectedModel && activeCorrections[model, default: 0] == 0 {
            await (cached.editor as? any PersistentTranscriptEditor)?.stop()
        }
    }

    func updateLocalModelIdleTimeout(_ timeout: LocalCorrectionIdleTimeout) async {
        timeout.save(to: defaults)
        for editor in localEditors.values {
            await editor.updateIdleTimeout(TimeInterval(timeout.rawValue))
        }
    }

    func localRuntimeStates() async -> [TranscriptEditingModel: LocalCorrectionRuntimeState] {
        var result: [TranscriptEditingModel: LocalCorrectionRuntimeState] = [:]
        for model in TranscriptEditingModel.localModels {
            if let editor = localEditors[model] {
                result[model] = await editor.runtimeState()
            } else {
                result[model] = .stopped
            }
        }
        return result
    }

    func stopLocalModel(_ model: TranscriptEditingModel) async throws {
        guard model.localSpec != nil else { throw TranscriptEditingServiceError.notLocalModel }
        guard activeCorrections[model, default: 0] == 0 else {
            throw TranscriptEditingServiceError.modelInUse
        }
        await localEditors[model]?.stop()
    }

    func stopAllLocalModels() async {
        for editor in localEditors.values {
            await editor.stop()
        }
    }

    func persistentProviderStates() async -> [
        TranscriptEditingModel: PersistentCorrectionRuntimeState
    ] {
        var states: [TranscriptEditingModel: PersistentCorrectionRuntimeState] = [:]
        for model in TranscriptEditingModel.commandLineModels {
            if let editor = commandLineEditors[model]?.editor as? any PersistentTranscriptEditor {
                states[model] = await editor.runtimeState()
            } else {
                states[model] = .stopped
            }
        }
        return states
    }

    @discardableResult
    func stopPersistentProvider(_ model: TranscriptEditingModel) async -> Bool {
        guard activeCorrections[model, default: 0] == 0 else { return false }
        await (commandLineEditors[model]?.editor as? any PersistentTranscriptEditor)?.stop()
        return true
    }

    func preparePersistentProvider(_ model: TranscriptEditingModel) async throws {
        let selectedEditor = try await editor(for: model)
        try await prepare(selectedEditor)
    }

    func preparePersistentProvider(
        _ model: TranscriptEditingModel,
        configuration: CommandLineCorrectionConfiguration
    ) async throws {
        let promptConfiguration = TranscriptEditingPromptPreferences(defaults: defaults).load()
        if let cached = commandLineEditors[model],
           cached.configuration == configuration,
           cached.promptConfiguration == promptConfiguration {
            try await prepare(cached.editor)
            return
        }
        guard activeCorrections[model, default: 0] == 0 else {
            throw TranscriptEditingServiceError.modelInUse
        }
        if let cached = commandLineEditors[model] {
            await (cached.editor as? any PersistentTranscriptEditor)?.stop()
        }
        let selectedEditor = try providerEditor(
            for: model,
            configuration: configuration,
            promptConfiguration: promptConfiguration
        )
        commandLineEditors[model] = (configuration, promptConfiguration, selectedEditor)
        try await prepare(selectedEditor)
    }

    private func prepare(_ editor: any TranscriptEditor) async throws {
        if let editor = editor as? any PersistentTranscriptEditor {
            try await editor.prepare()
        } else {
            throw TranscriptEditingServiceError.commandLineNotConfigured
        }
    }

    func discoverCodexModels() async throws -> [CodexModelOption] {
        let saved = CommandLineCorrectionConfiguration.load(
            preset: .codex,
            from: defaults
        )
        try saved.validate()
        let editor = CodexAppServerTranscriptEditor(
            configuration: codexConfiguration(from: saved)
        )
        do {
            let models = try await editor.supportedModels()
            await editor.stop()
            return models
        } catch {
            await editor.stop()
            throw error
        }
    }

    private func stopAllPersistentProviders() async {
        for cached in commandLineEditors.values {
            await (cached.editor as? any PersistentTranscriptEditor)?.stop()
        }
    }

    static func request(
        for response: TranscriptionResponse,
        promptConfiguration: TranscriptEditingPromptConfiguration,
        additionalInstructions: String? = nil
    ) -> TranscriptEditRequest {
        TranscriptEditRequest(
            text: response.text,
            language: response.language,
            additionalInstructions: additionalInstructions,
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
        for model in selectedModels { activeCorrections[model, default: 0] += 1 }
        defer {
            for model in selectedModels { activeCorrections[model, default: 1] -= 1 }
        }
        let request = TranscriptEditRequest(
            text: text,
            language: language,
            promptConfiguration: TranscriptEditingPromptPreferences(defaults: defaults).load()
        )
        var providers: [TranscriptCorrectionProvider] = []
        for model in selectedModels {
            providers.append(TranscriptCorrectionProvider(editor: try await editor(for: model)))
        }
        do {
            let comparison = try await TranscriptCorrectionComparator().compare(
                request: request,
                providers: providers
            )
            await stopUnselectedComparisonModels(localModels)
            return comparison
        } catch {
            await stopUnselectedComparisonModels(localModels)
            throw error
        }
    }

    func localModelStatus(
        for model: TranscriptEditingModel
    ) async -> LocalTranscriptEditingModelStatus {
        guard let store = localModelStores[model] else { return .notInstalled }
        return await store.status()
    }

    func modelSnapshot() async -> TranscriptEditingModelSnapshot {
        let appleAvailability = await availability(for: .appleFoundation)
        var commandLineAvailability: [
            TranscriptEditingModel: TranscriptEditorAvailability
        ] = [:]
        for model in TranscriptEditingModel.commandLineModels {
            commandLineAvailability[model] = await availability(for: model)
        }
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
        guard TranscriptEditingModel.load(from: defaults) != model else {
            throw TranscriptEditingServiceError.selectedModel
        }
        guard activeCorrections[model, default: 0] == 0 else {
            throw TranscriptEditingServiceError.modelInUse
        }
        guard localModelMutations.isEmpty else {
            throw TranscriptEditingServiceError.modelOperationInProgress
        }
        localModelMutations.insert(model)
        defer { localModelMutations.remove(model) }
        await localEditors[model]?.stop()
        localEditors[model] = nil
        try await store.delete()
    }

    private func editor(for model: TranscriptEditingModel) async throws -> any TranscriptEditor {
        try await editor(for: executionSnapshot(for: model))
    }

    private func editor(
        for snapshot: TranscriptEditingExecutionSnapshot
    ) async throws -> any TranscriptEditor {
        let model = snapshot.model
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
        case .codexCommandLine, .claudeCommandLine, .customCommandLine:
            guard let saved = snapshot.commandLineConfiguration else {
                throw TranscriptEditingServiceError.commandLineNotConfigured
            }
            if let commandLineEditor = commandLineEditors[model],
               commandLineEditor.configuration == saved,
               commandLineEditor.promptConfiguration == snapshot.promptConfiguration {
                return commandLineEditor.editor
            }
            guard activeCorrections[model, default: 0] == 0 else {
                throw TranscriptEditingServiceError.modelInUse
            }
            if let commandLineEditor = commandLineEditors[model] {
                await stopPersistentEditor(commandLineEditor.editor)
            }
            let editor = try providerEditor(
                for: model,
                configuration: saved,
                promptConfiguration: snapshot.promptConfiguration
            )
            commandLineEditors[model] = (saved, snapshot.promptConfiguration, editor)
            return editor
        case .qwen35SmallLocal, .qwen3SmallLocal, .qwenLocal,
             .granite4Local, .smolLM3Local, .ministralLocal:
            return try localEditor(for: model)
        }
    }

    private func providerEditor(
        for model: TranscriptEditingModel,
        configuration saved: CommandLineCorrectionConfiguration,
        promptConfiguration: TranscriptEditingPromptConfiguration
    ) throws -> any TranscriptEditor {
        try saved.validate()
        if saved.preset == .codex, saved.connectionMode == .enhanced {
            return CodexAppServerTranscriptEditor(configuration: codexConfiguration(from: saved))
        }
        if saved.preset == .claude, saved.connectionMode == .enhanced {
            let arguments = saved.effectiveArguments.map {
                if $0 == "{schemaJSON}" { return TranscriptCorrectionOutputSchema.json }
                return $0.replacingOccurrences(of: "{model}", with: saved.model)
            }
            let configuration = ClaudeStreamingConfiguration(
                executablePath: saved.executablePath,
                arguments: arguments,
                systemPrompt: promptConfiguration.renderedSystemPrompt(language: nil),
                idleTimeout: TimeInterval(saved.idleTimeoutSeconds)
            )
            return ClaudeStreamingTranscriptEditor(configuration: configuration)
        }
        let arguments = saved.effectiveArguments.map {
            $0.replacingOccurrences(of: "{model}", with: saved.model)
        }
        let configuration = try TiroEditing.CommandLineCorrectionConfiguration(
            id: "command-line-\(saved.preset.rawValue)",
            name: saved.preset.title,
            executablePath: saved.executablePath,
            arguments: arguments,
            timeout: 120
        )
        return CommandLineTranscriptEditor(
            configuration: configuration,
            requiresGrounding: false
        )
    }

    private func releaseActiveCorrection(for model: TranscriptEditingModel) {
        let remaining = activeCorrections[model, default: 1] - 1
        if remaining > 0 {
            activeCorrections[model] = remaining
        } else {
            activeCorrections.removeValue(forKey: model)
        }
    }

    private func codexConfiguration(
        from saved: CommandLineCorrectionConfiguration
    ) -> CodexAppServerConfiguration {
        CodexAppServerConfiguration(
            executablePath: saved.executablePath,
            model: saved.model,
            reasoningEffort: saved.reasoningEffort.commandLineValue,
            access: saved.codexAccess,
            idleTimeout: TimeInterval(saved.idleTimeoutSeconds)
        )
    }

    private func stopPersistentEditor(_ editor: any TranscriptEditor) async {
        await (editor as? any PersistentTranscriptEditor)?.stop()
    }

    private func localEditor(
        for model: TranscriptEditingModel
    ) throws -> GGUFTranscriptEditor {
        if let editor = localEditors[model] { return editor }
        guard let spec = model.localSpec,
              let store = localModelStores[model] else {
            throw TranscriptEditingServiceError.notLocalModel
        }
        let editor = GGUFTranscriptEditor(
            spec: spec,
            executableURL: llamaServerExecutableURL,
            modelURL: store.modelURL,
            idleTimeout: idleTimeout
        )
        localEditors[model] = editor
        return editor
    }

    private func stopUnselectedComparisonModels(
        _ models: [TranscriptEditingModel]
    ) async {
        let selected = TranscriptEditingModel.load(from: defaults)
        for model in models where model != selected {
            await localEditors[model]?.stop()
        }
    }

    private var idleTimeout: TimeInterval {
        TimeInterval(LocalCorrectionIdleTimeout.load(from: defaults).rawValue)
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
    case shuttingDown

    var errorDescription: String? {
        switch self {
        case .disabled: "Spoken corrections are off."
        case .requiresMacOS26: "Apple Intelligence requires macOS 26 or later."
        case .modelInUse: "Wait for the current transcript repair to finish before deleting this model."
        case .modelOperationInProgress: "Wait for the correction model operation to finish."
        case .notLocalModel: "This correction model is not downloadable."
        case .selectedModel: "Select another correction model before deleting this one."
        case .commandLineNotConfigured: "Configure an available command-line correction executable."
        case .shuttingDown: "The app is shutting down."
        }
    }
}
