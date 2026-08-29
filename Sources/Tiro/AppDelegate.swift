import AppKit
import AVFoundation
import ApplicationServices
import TiroEditing
import TiroIPC
import TiroRecognition
import UniformTypeIdentifiers

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct CommandRecording {
        let session: UUID
        let model: DictationModel
        let saveToHistory: Bool
    }

    private struct CorrectionOutcome {
        let revisedText: String
        let explanation: String
        let requiresReview: Bool
        let failed: Bool
    }

    private let recorder = AudioRecorder()
    private let service = TiroService()
    private let overlay = OverlayPanel()
    private let recordingSounds = RecordingSoundPlayer()
    private let hotkeys = HotkeyManager()
    private let destinationTracker = DestinationTracker()
    private let pasteCoordinator = PasteCoordinator()
    private let transcriptEditingService = TranscriptEditingService()
    private let commandServer = TiroCommandSocketServer()
#if TIRO_SPONSORSHIP_ENABLED
    private let supportPromptPolicy = SupportPromptPolicy()
    private lazy var supportPromptWindow = makeSupportPromptWindow()
#endif
    private lazy var settingsWindow = makeSettingsWindow()
    private lazy var fileTranscriptionWindow = makeFileTranscriptionWindow()
    private var transcriptReviewWindow: TranscriptReviewWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private var statusItem: NSStatusItem!
    private var state: DictationWorkflowState = .idle
    private var menuToggleItem: NSMenuItem!
    private var shortcutStatusItem: NSMenuItem!
    private var pasteRecoveryItem: NSMenuItem!
    private var privacyNoticeItem: NSMenuItem!
    private var modelStatusItem: NSMenuItem!
    private var updateAvailableItem: NSMenuItem!
    private var transcriptionModelItem: NSMenuItem!
    private var transcriptionModelMenu: NSMenu!
    private var correctionModelItem: NSMenuItem!
    private var correctionModelMenu: NSMenu!
    private var setupMenuItem: NSMenuItem!
    private var availableCorrectionModels: Set<TranscriptEditingModel> = [.off]
    private var installedModelKeys: Set<String> = []
    private var renderedInstalledModelKeys: Set<String>?
    private var renderedCorrectionModels: Set<TranscriptEditingModel>?
    private var statusMenuIsOpen = false
    private var transcriptionMenuNeedsRebuild = false
    private var correctionMenuNeedsRebuild = false
    private var modelInventoryStatus = ModelInventoryStatus.loading
    private var modelStartupTask: Task<Void, Never>?
    private var modelSelectionTask: Task<Void, Never>?
    private var correctionModelRefreshTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var correctionInstructionTask: Task<Void, Never>?
    private var transcriptionID: UUID?
    private var recordingModelUseReserved = false
    private var recordingModel: DictationModel?
    private var commandRecording: CommandRecording?
    private var commandTranscriptionTask: Task<TranscriptionResponse, Error>?
    private var externalOperationID: UUID?
    private var permissionTimer: Timer?
    private var updateCheckTimer: Timer?
    private var updateCheckTask: Task<Void, Never>?
#if TIRO_SPONSORSHIP_ENABLED
    private var supportPromptTimer: Timer?
#endif
    private var hotkeysStarted = false
    private var isCapturingShortcut = false
    private var destinationSession: DestinationSession?
    private var originApplication: ApplicationIdentity?
    private var shouldAutoPaste = false
    private var lastFailedPasteText: String?
    private var pasteRecoveryGeneration = 0
    private var pasteRetryTask: Task<Void, Never>?
    private var correctionPreloadTask: Task<Void, Never>?
    private var localCorrectionUseToken: LocalCorrectionUseToken?
    private var awaitingPrivacyReview = false
    private var isPresentingRecovery = false
    private var localCorrectionShutdownPrepared = false
    private var deferredRecordingStart = DeferredRecordingStart()
#if TIRO_SPONSORSHIP_ENABLED
    private var supportPromptSuppressedUntil: Date?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "autoPaste": true,
            "soundFeedback": true,
            CorrectionTimingPreference.defaultsKey: CorrectionTimingPreference.automatic.rawValue,
            TranscriptReviewPreference.defaultsKey: TranscriptReviewPreference.whenChanged.rawValue,
            AutomaticUpdateCheckPolicy.enabledDefaultsKey: true,
        ])
#if TIRO_SPONSORSHIP_ENABLED
        supportPromptPolicy.registerLaunch()
#endif
        AudioRecorder.removeStaleRecordings()
        _ = try? VocabularyFile.load()
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        startCommandServer()
        configurePermissionsAndStart()
        prepareInstalledModel()
        if !UserDefaults.standard.bool(forKey: "setupCompleted") {
            showSetup()
        } else {
            scheduleAutomaticUpdateCheck()
        }
#if TIRO_SPONSORSHIP_ENABLED
        if UserDefaults.standard.bool(forKey: "setupCompleted") {
            scheduleNextSupportPromptCheck(minimumDelay: 1)
        }
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        updateCheckTimer?.invalidate()
        updateCheckTask?.cancel()
#if TIRO_SPONSORSHIP_ENABLED
        supportPromptTimer?.invalidate()
#endif
        modelStartupTask?.cancel()
        modelSelectionTask?.cancel()
        correctionModelRefreshTask?.cancel()
        transcriptionTask?.cancel()
        correctionInstructionTask?.cancel()
        pasteRetryTask?.cancel()
        pasteCoordinator.cancelPendingConfirmation()
        commandTranscriptionTask?.cancel()
        transcriptReviewWindow?.cancel()
        hotkeys.stop()
        PasteEventGate.shared.stop()
        commandServer.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !localCorrectionShutdownPrepared else { return .terminateNow }
        localCorrectionShutdownPrepared = true
        let preloadTask = correctionPreloadTask
        correctionPreloadTask?.cancel()
        Task { [transcriptEditingService] in
            await transcriptEditingService.prepareForShutdown()
            _ = await preloadTask?.result
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tiro")

        let menu = NSMenu()
        menu.delegate = self
        menuToggleItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        menuToggleItem.target = self
        menu.addItem(menuToggleItem)

        let transcribeFile = NSMenuItem(
            title: "Transcribe Audio File…",
            action: #selector(showFileTranscription),
            keyEquivalent: "o"
        )
        transcribeFile.target = self
        menu.addItem(transcribeFile)

        transcriptionModelMenu = NSMenu()
        transcriptionModelItem = NSMenuItem(title: "Transcription Models", action: nil, keyEquivalent: "")
        transcriptionModelItem.submenu = transcriptionModelMenu
        menu.addItem(transcriptionModelItem)
        updateModelChecks()

        correctionModelMenu = NSMenu()
        correctionModelItem = NSMenuItem(title: "Corrections", action: nil, keyEquivalent: "")
        correctionModelItem.submenu = correctionModelMenu
        menu.addItem(correctionModelItem)
        updateCorrectionModelChecks()
        refreshCorrectionModelMenu()

        modelStatusItem = NSMenuItem(title: "Transcription: Loading…", action: nil, keyEquivalent: "")
        modelStatusItem.isEnabled = false
        modelStatusItem.isHidden = true
        menu.addItem(modelStatusItem)

        menu.addItem(.separator())
        shortcutStatusItem = NSMenuItem(
            title: "Right Command Shortcut: Checking…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        shortcutStatusItem.target = self
        menu.addItem(shortcutStatusItem)
        pasteRecoveryItem = NSMenuItem(
            title: "Auto-paste needs Accessibility permission…",
            action: #selector(showPermissionsSettings),
            keyEquivalent: ""
        )
        pasteRecoveryItem.target = self
        pasteRecoveryItem.isHidden = true
        menu.addItem(pasteRecoveryItem)
        privacyNoticeItem = NSMenuItem(
            title: "Review Updated Privacy Settings…",
            action: #selector(reviewPrivacySettings),
            keyEquivalent: ""
        )
        privacyNoticeItem.target = self
        let hasLegacyStorage = FileManager.default.fileExists(atPath: AppPaths.historyFile.path)
            || FileManager.default.fileExists(atPath: AppPaths.legacyRetentionFile.path)
        privacyNoticeItem.isHidden = !hasLegacyStorage
            || UserDefaults.standard.bool(forKey: "privacyMigrationNoticeReviewed")
        menu.addItem(privacyNoticeItem)
        updateAvailableItem = NSMenuItem(
            title: "Update Available…",
            action: #selector(openAvailableUpdate),
            keyEquivalent: ""
        )
        updateAvailableItem.target = self
        updateAvailableItem.isHidden = true
        menu.addItem(updateAvailableItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        setupMenuItem = NSMenuItem(title: "Setup…", action: #selector(showSetup), keyEquivalent: "")
        setupMenuItem.target = self
        setupMenuItem.isHidden = UserDefaults.standard.bool(forKey: "setupCompleted")
        menu.addItem(setupMenuItem)
#if TIRO_SPONSORSHIP_ENABLED
        let support = NSMenuItem(
            title: BuildFeatures.sponsorshipMenuTitle!,
            action: #selector(supportTiro),
            keyEquivalent: ""
        )
        support.target = self
        menu.addItem(support)
#endif
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tiro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func startCommandServer() {
        do {
            try commandServer.start { [weak self] request, responder in
                guard let self else {
                    try await responder.sendFailure(
                        code: "app_unavailable",
                        message: "Tiro is shutting down."
                    )
                    return
                }
                await self.handleCommand(request, responder: responder)
            }
        } catch {
            NSLog("Could not start Tiro command server: %@", error.localizedDescription)
        }
    }

    private func handleCommand(
        _ request: TiroCommandRequest,
        responder: TiroCommandResponder
    ) async {
        do {
            if request.command != .status,
               request.command != .models,
               !UserDefaults.standard.bool(forKey: "setupCompleted") {
                try await responder.sendFailure(
                    code: "setup_required",
                    message: "Finish Tiro setup before using command-line transcription."
                )
                return
            }
            switch request.command {
            case .status:
                try await responder.sendSuccess(TiroCommandResult(
                    kind: "status",
                    state: commandState,
                    selectedModel: DictationModel.selected.key
                ))
            case .models:
                let models = await service.models()
                try await responder.sendSuccess(TiroCommandResult(
                    kind: "models",
                    models: models.map {
                        TiroCommandModel(
                            key: $0.key,
                            name: $0.name,
                            installed: $0.installed,
                            transcription: $0.dictationModel != nil
                        )
                    }
                ))
            case .transcribe:
                try await handleTranscribeCommand(request, responder: responder)
            case .recordStart:
                try await handleRecordStartCommand(request, responder: responder)
            case .recordStop:
                try await handleRecordStopCommand(request, responder: responder)
            case .recordCancel:
                try await handleRecordCancelCommand(request, responder: responder)
            }
        } catch {
            try? await responder.sendFailure(
                code: "transcription_failed",
                message: error.localizedDescription
            )
        }
    }

    private func handleTranscribeCommand(
        _ request: TiroCommandRequest,
        responder: TiroCommandResponder
    ) async throws {
        guard state == .idle, commandRecording == nil, externalOperationID == nil else {
            try await responder.sendFailure(
                code: "busy",
                message: "Tiro is already recording or transcribing."
            )
            return
        }
        let operationID = UUID()
        externalOperationID = operationID
        state = .transcribing
        menuToggleItem.title = "Transcribing..."
        defer {
            if externalOperationID == operationID {
                externalOperationID = nil
                state = .idle
                menuToggleItem.title = "Start Recording"
            }
        }
        guard let arguments = request.arguments, let path = arguments.path else {
            throw TiroError.message("The command did not include an audio file.")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: url.path),
              UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true else {
            throw TiroError.message("The requested audio file is unavailable or unsupported.")
        }
        let model: DictationModel
        if let key = arguments.model {
            guard let requested = DictationModel.all.first(where: { $0.key == key }) else {
                throw TiroError.message("No Tiro model has the key \(key).")
            }
            model = requested
        } else {
            model = DictationModel.selected
        }

        try await responder.sendEvent(name: "transcribing", detail: url.lastPathComponent)
        let response = try await service.transcribe(
            audioURL: url,
            model: model,
            sourceFilename: url.lastPathComponent,
            archiveAudio: false,
            identifySpeakers: arguments.diarize ?? false,
            saveToHistory: arguments.saveHistory ?? true
        )
        if arguments.copy == true {
            copyToClipboard(response.text)
        }
        settingsWindow.refreshHistory()
        try await responder.sendSuccess(TiroCommandResult(
            kind: "transcript",
            text: response.text,
            model: response.model,
            historyID: (arguments.saveHistory ?? true) ? response.id : nil,
            transcriptionSeconds: response.transcription_seconds,
            segments: commandSegments(response.segments)
        ))
    }

    private func handleRecordStartCommand(
        _ request: TiroCommandRequest,
        responder: TiroCommandResponder
    ) async throws {
        guard state == .idle, commandRecording == nil else {
            try await responder.sendFailure(
                code: "busy",
                message: "Tiro is already recording or transcribing."
            )
            return
        }
        let arguments = request.arguments
        let model: DictationModel
        if let key = arguments?.model {
            guard let requested = DictationModel.all.first(where: { $0.key == key }) else {
                throw TiroError.message("No Tiro model has the key \(key).")
            }
            model = requested
        } else {
            model = DictationModel.selected
        }
        let recording = CommandRecording(
            session: UUID(),
            model: model,
            saveToHistory: arguments?.saveHistory ?? true
        )
        try reserveRecordingModelUse()
        commandRecording = recording
        destinationSession = nil
        originApplication = nil
        shouldAutoPaste = false
        state = .starting
        menuToggleItem.title = "Recording from Command Line"
        do {
            try await withTaskCancellationHandler {
                try await service.preload(model: model, usingRecordingReservation: true)
            } onCancel: { [weak self] in
                Task { @MainActor in
                    await self?.cancelCommandRecording(session: recording.session)
                }
            }
            try Task.checkCancellation()
            guard commandRecording?.session == recording.session, state == .starting else {
                throw CancellationError()
            }
            beginRecording(reportErrors: false)
            guard state == .recording else {
                throw TiroError.message("Tiro could not start recording.")
            }

            let session = recording.session.uuidString.lowercased()
            if arguments?.lease == true {
                try await responder.sendEvent(name: "recording", detail: session)
                while commandRecording?.session == recording.session {
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                try await responder.sendSuccess(TiroCommandResult(
                    kind: "lease_released",
                    state: "idle",
                    session: session
                ))
            } else {
                try await responder.sendSuccess(TiroCommandResult(
                    kind: "recording",
                    model: model.key,
                    state: "recording",
                    session: session
                ))
            }
        } catch {
            await cancelCommandRecording(session: recording.session)
            throw error
        }
    }

    private func handleRecordStopCommand(
        _ request: TiroCommandRequest,
        responder: TiroCommandResponder
    ) async throws {
        guard let recording = matchingCommandRecording(request) else {
            try await responder.sendFailure(
                code: "recording_not_found",
                message: "That command-line recording session is not active."
            )
            return
        }
        guard state == .recording else {
            try await responder.sendFailure(
                code: "busy",
                message: "The recording is not ready to stop."
            )
            return
        }

        let audioURL = try recorder.stop()
        state = .transcribing
        menuToggleItem.title = "Transcribing..."
        overlay.show(.transcribing)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let task = Task { @MainActor [service] in
            try await service.transcribe(
                audioURL: audioURL,
                model: recording.model,
                archiveAudio: recording.saveToHistory,
                saveToHistory: recording.saveToHistory,
                usingRecordingReservation: true
            )
        }
        commandTranscriptionTask = task
        do {
            try await responder.sendEvent(name: "transcribing")
            let response = try await task.value
            guard commandRecording?.session == recording.session else {
                throw CancellationError()
            }
            if request.arguments?.copy == true {
                copyToClipboard(response.text)
            }
            commandRecording = nil
            commandTranscriptionTask = nil
            finishCancelledTranscription()
            settingsWindow.refreshHistory()
            try await responder.sendSuccess(TiroCommandResult(
                kind: "transcript",
                text: response.text,
                model: response.model,
                historyID: recording.saveToHistory ? response.id : nil,
                transcriptionSeconds: response.transcription_seconds,
                segments: commandSegments(response.segments)
            ))
        } catch {
            task.cancel()
            _ = await task.result
            if commandRecording?.session == recording.session {
                commandRecording = nil
                commandTranscriptionTask = nil
                finishCancelledTranscription()
            }
            throw error
        }
    }

    private func handleRecordCancelCommand(
        _ request: TiroCommandRequest,
        responder: TiroCommandResponder
    ) async throws {
        guard matchingCommandRecording(request) != nil else {
            try await responder.sendFailure(
                code: "recording_not_found",
                message: "That command-line recording session is not active."
            )
            return
        }
        let session = commandRecording?.session
        if let session {
            await cancelCommandRecording(session: session)
        }
        try await responder.sendSuccess(TiroCommandResult(
            kind: "cancelled",
            state: "idle"
        ))
    }

    private func cancelCommandRecording(session: UUID) async {
        guard commandRecording?.session == session else { return }
        if state == .transcribing {
            let task = commandTranscriptionTask
            task?.cancel()
            commandTranscriptionTask = nil
            commandRecording = nil
            if let task { _ = await task.result }
        } else {
            if recorder.isRecording {
                recorder.cancel()
            }
            commandRecording = nil
        }
        finishCancelledTranscription()
    }

    private func matchingCommandRecording(_ request: TiroCommandRequest) -> CommandRecording? {
        guard let recording = commandRecording,
              let session = request.arguments?.session,
              UUID(uuidString: session) == recording.session else {
            return nil
        }
        return recording
    }

    private var commandState: String {
        state.commandName
    }

    private func commandSegments(_ segments: [TranscriptSegment]) -> [TiroCommandSegment] {
        segments.map {
            TiroCommandSegment(
                text: $0.text,
                startTime: $0.startSeconds,
                endTime: $0.endSeconds,
                speakerID: $0.speakerID
            )
        }
    }

    private func makeSettingsWindow() -> SettingsWindowController {
        let controller = SettingsWindowController(
            service: service,
            transcriptEditingService: transcriptEditingService
        )
        controller.onModelChanged = { [weak self] model in
            self?.updateModelChecks()
            if self?.installedModelKeys.contains(model.key) == true {
                self?.setTranscriptionStatus(nil)
            }
        }
        controller.onModelsChanged = { [weak self] models in
            self?.applyModelInventory(models)
        }
        controller.onCorrectionModelChanged = { [weak self] model in
            self?.updateCorrectionModelChecks()
            self?.refreshCorrectionModelMenu()
            guard let self else { return }
            Task { [transcriptEditingService] in
                await transcriptEditingService.correctionModelDidChange(to: model)
            }
        }
        controller.onShortcutChanged = { [weak self] shortcut in
            guard let self else { return }
            do {
                try shortcut.save()
                try self.hotkeys.updateShortcut(shortcut)
                self.updateShortcutStatus(trusted: AXIsProcessTrusted())
            } catch {
                self.presentError(error)
            }
        }
        controller.onShortcutCaptureChanged = { [weak self] isCapturing, suppressedKeys in
            guard let self else { return }
            self.isCapturingShortcut = isCapturing
            if isCapturing {
                self.hotkeys.stop()
                self.hotkeysStarted = false
            } else {
                self.hotkeys.suppressUntilRelease(suppressedKeys)
                self.installHotkeysWhenPermitted()
            }
        }
        controller.onPrivacySettingsLoaded = { [weak self] in
            guard self?.awaitingPrivacyReview == true else { return }
            self?.awaitingPrivacyReview = false
            UserDefaults.standard.set(true, forKey: "privacyMigrationNoticeReviewed")
            self?.privacyNoticeItem.isHidden = true
        }
        controller.onAutomaticUpdateChecksChanged = { [weak self] enabled in
            if enabled {
                self?.scheduleAutomaticUpdateCheck()
            } else {
                self?.updateCheckTimer?.invalidate()
                self?.updateCheckTimer = nil
                self?.updateCheckTask?.cancel()
                self?.updateCheckTask = nil
            }
        }
        return controller
    }

    private func makeFileTranscriptionWindow() -> FileTranscriptionWindowController {
        let controller = FileTranscriptionWindowController(service: service)
        controller.requestOperation = { [weak self] in
            guard let self,
                  self.state == .idle,
                  self.commandRecording == nil,
                  self.externalOperationID == nil else { return false }
            self.externalOperationID = UUID()
            self.state = .transcribing
            self.menuToggleItem.title = "Transcribing File..."
            return true
        }
        controller.onOperationEnded = { [weak self] in
            guard let self, self.externalOperationID != nil else { return }
            self.externalOperationID = nil
            self.state = .idle
            self.menuToggleItem.title = "Start Recording"
        }
        controller.onTranscriptionCompleted = { [weak self] in
            self?.settingsWindow.refreshHistory()
        }
        return controller
    }

#if TIRO_SPONSORSHIP_ENABLED
    private func makeSupportPromptWindow() -> SupportPromptWindowController {
        let controller = SupportPromptWindowController()
        controller.onSupport = {
            NSWorkspace.shared.open(BuildFeatures.sponsorsURL)
        }
        controller.onAlreadySupporting = { [weak self] in
            self?.supportPromptPolicy.markAlreadySupporting()
            self?.supportPromptTimer?.invalidate()
        }
        return controller
    }
#endif

    private func configurePermissionsAndStart() {
        hotkeys.onTap = { [weak self] in self?.toggleRecording() }
        hotkeys.onHoldStart = { [weak self] in
            guard let self, self.transcriptReviewWindow?.isReviewing != true else { return false }
            return self.startRecording(playStartSound: false)
        }
        hotkeys.onHoldEnd = { [weak self] in self?.stopRecording() }
        hotkeys.onHoldCancel = { [weak self] in self?.cancelRecording() }
        hotkeys.allowsCorrectionGesture = { [weak self] in
            guard let self else { return false }
            return self.state == .reviewing
                && CorrectionTimingPreference.load() == .onRequest
                && self.transcriptReviewWindow?.canRequestCorrection == true
        }
        hotkeys.onCorrectionTap = { [weak self] in
            self?.transcriptReviewWindow?.requestCorrection()
        }
        hotkeys.onCorrectionHoldStart = { [weak self] in
            self?.startCorrectionInstructionRecording() ?? false
        }
        hotkeys.onCorrectionHoldEnd = { [weak self] in
            self?.stopCorrectionInstructionRecording()
        }
        hotkeys.onCorrectionHoldCancel = { [weak self] in
            self?.cancelCorrectionInstructionRecording()
        }
        hotkeys.onEscape = { [weak self] in self?.cancelRecording() }
        hotkeys.shouldHandleEscape = { [weak self] in
            guard let self,
                  self.commandRecording == nil,
                  self.externalOperationID == nil else { return false }
            return self.state.handlesEscape
        }

        installHotkeysWhenPermitted()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.installHotkeysWhenPermitted()
                self?.refreshSetupPermissions()
            }
        }
    }

    private func installHotkeysWhenPermitted() {
        let trusted = AXIsProcessTrusted()
        updateShortcutStatus(trusted: trusted)
        if !trusted {
            if hotkeysStarted {
                hotkeys.stop()
                PasteEventGate.shared.stop()
                hotkeysStarted = false
            }
            return
        }

        guard !isCapturingShortcut else { return }
        do {
            if hotkeysStarted {
                try hotkeys.maintain()
                try PasteEventGate.shared.maintain()
            } else {
                try PasteEventGate.shared.start()
                try hotkeys.start()
                hotkeysStarted = true
                NSLog("Installed the global dictation shortcut.")
            }
        } catch {
            hotkeys.stop()
            PasteEventGate.shared.stop()
            hotkeysStarted = false
            shortcutStatusItem.title = "\(hotkeys.shortcut.displayName) Shortcut Unavailable"
            shortcutStatusItem.state = .off
            NSLog("Could not install global dictation keys: %@", error.localizedDescription)
        }
    }

    private func updateShortcutStatus(trusted: Bool) {
        let name = hotkeys.shortcut.displayName
        shortcutStatusItem.title = trusted ? "\(name) Shortcut Enabled" : "Enable \(name) Shortcut…"
        shortcutStatusItem.state = trusted ? .on : .off
    }

    @objc private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestMicrophoneAccess() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refreshSetupPermissions() }
            }
            return
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleRecording() {
        guard commandRecording == nil else { return }
        let tapAction = state.shortcutTapAction(
            reviewIsActive: transcriptReviewWindow?.isReviewing == true
        )
        switch tapAction {
        case .startRecording: startRecording()
        case .cancelStarting: cancelRecording()
        case .stopRecording: stopRecording()
        case .acceptReview: transcriptReviewWindow?.accept()
        case .requestDeferredRecording: deferredRecordingStart.request()
        case .ignore: break
        }
    }

    @discardableResult
    private func startRecording(playStartSound: Bool = true) -> Bool {
        guard state == .idle else { return false }
        do {
            try reserveRecordingModelUse()
        } catch {
            overlay.show(.modelBusy)
            overlay.dismiss(after: 1.5)
            return false
        }
        recordingModel = DictationModel.selected
#if TIRO_SPONSORSHIP_ENABLED
        supportPromptWindow.close()
#endif
        switch modelInventoryStatus {
        case .loading:
            setTranscriptionStatus("Checking installed transcription models…")
            overlay.show(.startingUp)
            overlay.dismiss(after: 1.2)
            releaseRecordingModelUse()
            return false
        case .unavailable:
            releaseRecordingModelUse()
            presentRecovery(ErrorRecovery.presentation(for: .modelServiceUnavailable))
            return false
        case .missing:
            setTranscriptionStatus("No transcription model installed")
            releaseRecordingModelUse()
            presentRecovery(ErrorRecovery.presentation(for: .missingModel))
            return false
        case .available:
            break
        }
        let isSetupPractice = onboardingWindow?.isPracticeFieldFocused == true
        shouldAutoPaste = isSetupPractice || UserDefaults.standard.bool(forKey: "autoPaste")
        originApplication = isSetupPractice ? nil : destinationTracker.captureApplicationIdentity()
        destinationSession = destinationTracker.capture(allowTiro: isSetupPractice)
        if shouldAutoPaste, destinationSession == nil {
            NSLog("Could not capture the focused destination; transcription will be copied.")
        }
        state = .starting
        menuToggleItem.title = "Cancel Starting"
        correctionPreloadTask?.cancel()
        correctionPreloadTask = nil
        if CorrectionTimingPreference.load() != .off,
           TranscriptEditingModel.selected != .off {
            correctionPreloadTask = Task { [weak self, transcriptEditingService] in
                var token: LocalCorrectionUseToken?
                do {
                    token = try await transcriptEditingService.prepareSelectedLocalModel()
                } catch {
                    if !Task.isCancelled {
                        NSLog(
                            "Could not preload local correction model: %@",
                            error.localizedDescription
                        )
                    }
                }
                guard !Task.isCancelled, let self, self.recordingModelUseReserved else {
                    if let token { await transcriptEditingService.releaseLocalModelUse(token) }
                    return
                }
                self.localCorrectionUseToken = token
                self.correctionPreloadTask = nil
            }
        }
        if playStartSound, UserDefaults.standard.bool(forKey: "soundFeedback") {
            recordingSounds.playStart { [weak self] in self?.beginRecording() }
        } else {
            beginRecording()
            if UserDefaults.standard.bool(forKey: "soundFeedback") {
                recordingSounds.playHoldStart()
            }
        }
        return true
    }

    private func beginRecording(reportErrors: Bool = true) {
        guard state == .starting else { return }
        do {
            try recorder.start()
            state = .recording
            menuToggleItem.title = "Stop Recording"
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            statusItem.button?.contentTintColor = .systemRed
            overlay.showRecording(levelProvider: { [weak self] in
                self?.recorder.normalizedMicrophoneLevel ?? 0
            })
        } catch {
            if reportErrors {
                presentError(error)
            } else {
                commandRecording = nil
                state = .idle
                menuToggleItem.title = "Start Recording"
                releaseRecordingModelUse()
                NSLog("Could not start command-line recording: %@", error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        guard commandRecording == nil else { return }
        if state == .starting {
            cancelRecording()
            return
        }
        guard state == .recording else { return }
        do {
            let wavURL = try recorder.stop()
            if UserDefaults.standard.bool(forKey: "soundFeedback") { recordingSounds.playStop() }
            state = .transcribing
            menuToggleItem.title = "Transcribing…"
            overlay.show(.transcribing)
            let model = recordingModel ?? DictationModel.selected
            let originBundleID = originApplication?.bundleIdentifier
            let originName = originApplication?.applicationName

            let transcriptionID = UUID()
            self.transcriptionID = transcriptionID
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                defer { try? FileManager.default.removeItem(at: wavURL) }
                defer {
                    if self.transcriptionID == transcriptionID {
                        self.transcriptionTask = nil
                        self.transcriptionID = nil
                    }
                }
                do {
                    let response = try await service.transcribe(
                        audioURL: wavURL,
                        model: model,
                        originBundleID: originBundleID,
                        originName: originName,
                        usingRecordingReservation: true
                    )
                    try Task.checkCancellation()
                    guard self.transcriptionID == transcriptionID else { return }
                    await complete(
                        response,
                        model: model,
                        audioURL: wavURL,
                        operationID: transcriptionID
                    )
                } catch is CancellationError {
                    if self.transcriptionID == transcriptionID {
                        finishCancelledTranscription()
                    }
                } catch TiroError.noSpeechDetected {
                    if self.transcriptionID == transcriptionID {
                        finishNoSpeechTranscription()
                    }
                } catch {
                    if self.transcriptionID == transcriptionID {
                        await MainActor.run { self.presentError(error) }
                    }
                }
            }
        } catch {
            presentError(error)
        }
    }

    private func startCorrectionInstructionRecording() -> Bool {
        guard state == .reviewing,
              transcriptReviewWindow?.beginAdditionalInstruction() == true else {
            return false
        }
        do {
            try recorder.start()
            state = .addingCorrectionInstruction
            menuToggleItem.title = "Adding Correction Instruction…"
            if UserDefaults.standard.bool(forKey: "soundFeedback") {
                recordingSounds.playHoldStart()
            }
            return true
        } catch {
            state = .reviewing
            menuToggleItem.title = shouldAutoPaste ? "Paste Transcription" : "Copy Transcription"
            transcriptReviewWindow?.showInstructionFailure(error.localizedDescription)
            return false
        }
    }

    private func stopCorrectionInstructionRecording() {
        guard state == .addingCorrectionInstruction else { return }
        do {
            let audioURL = try recorder.stop()
            if UserDefaults.standard.bool(forKey: "soundFeedback") { recordingSounds.playStop() }
            state = .transcribingCorrectionInstruction
            menuToggleItem.title = "Transcribing Correction Instruction…"
            transcriptReviewWindow?.showInstructionTranscriptionProgress()
            let model = recordingModel ?? DictationModel.selected
            let operationID = transcriptionID
            correctionInstructionTask = Task { [weak self] in
                guard let self else { return }
                defer { try? FileManager.default.removeItem(at: audioURL) }
                defer { self.correctionInstructionTask = nil }
                do {
                    let response = try await service.transcribe(
                        audioURL: audioURL,
                        model: model,
                        archiveAudio: false,
                        saveToHistory: false,
                        usingRecordingReservation: true
                    )
                    try Task.checkCancellation()
                    guard self.transcriptionID == operationID else { return }
                    self.state = .reviewing
                    self.menuToggleItem.title = self.shouldAutoPaste
                        ? "Paste Transcription"
                        : "Copy Transcription"
                    self.transcriptReviewWindow?.appendInstructionAndRequestCorrection(response.text)
                } catch is CancellationError {
                    return
                } catch TiroError.noSpeechDetected {
                    guard self.transcriptionID == operationID else { return }
                    self.state = .reviewing
                    self.menuToggleItem.title = self.shouldAutoPaste
                        ? "Paste Transcription"
                        : "Copy Transcription"
                    self.transcriptReviewWindow?.showInstructionFailure(
                        "No correction instruction was detected."
                    )
                } catch {
                    guard self.transcriptionID == operationID else { return }
                    self.state = .reviewing
                    self.menuToggleItem.title = self.shouldAutoPaste
                        ? "Paste Transcription"
                        : "Copy Transcription"
                    self.transcriptReviewWindow?.showInstructionFailure(
                        "Could not transcribe the instruction: \(error.localizedDescription)"
                    )
                }
            }
        } catch {
            state = .reviewing
            menuToggleItem.title = shouldAutoPaste ? "Paste Transcription" : "Copy Transcription"
            transcriptReviewWindow?.showInstructionFailure(error.localizedDescription)
        }
    }

    private func cancelCorrectionInstructionRecording() {
        guard state == .addingCorrectionInstruction else { return }
        recorder.cancel()
        if UserDefaults.standard.bool(forKey: "soundFeedback") { recordingSounds.playStop() }
        state = .reviewing
        menuToggleItem.title = shouldAutoPaste ? "Paste Transcription" : "Copy Transcription"
        transcriptReviewWindow?.showInstructionFailure("Correction instruction cancelled.")
    }

    private func cancelRecording() {
        guard commandRecording == nil, externalOperationID == nil else { return }
        if state == .addingCorrectionInstruction || state == .transcribingCorrectionInstruction {
            if recorder.isRecording { recorder.cancel() }
            correctionInstructionTask?.cancel()
            correctionInstructionTask = nil
            transcriptReviewWindow?.cancel()
            return
        }
        if state == .reviewing {
            transcriptReviewWindow?.cancel()
            return
        }
        if state == .correcting {
            transcriptReviewWindow?.cancel()
            transcriptionTask?.cancel()
            return
        }
        if state == .transcribing {
            transcriptionTask?.cancel()
            transcriptionID = nil
            finishCancelledTranscription()
            return
        }
        if state == .starting {
            recordingSounds.cancelStart()
            destinationSession = nil
            originApplication = nil
            state = .idle
            menuToggleItem.title = "Start Recording"
            releaseRecordingModelUse()
            return
        }
        guard state == .recording else { return }
        recorder.cancel()
        commandRecording = nil
        destinationSession = nil
        originApplication = nil
        if UserDefaults.standard.bool(forKey: "soundFeedback") { recordingSounds.playStop() }
        state = .idle
        menuToggleItem.title = "Start Recording"
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tiro")
        statusItem.button?.contentTintColor = nil
        releaseRecordingModelUse()
        overlay.dismiss()
    }

    private func finishCancelledTranscription() {
        resetAfterTranscription()
        overlay.dismiss()
        startDeferredRecordingIfNeeded()
    }

    private func finishNoSpeechTranscription() {
        resetAfterTranscription()
        overlay.show(.noSpeech)
        overlay.dismiss(after: 1.2)
    }

    private func resetAfterTranscription() {
        transcriptionTask = nil
        transcriptionID = nil
        destinationSession = nil
        originApplication = nil
        state = .idle
        menuToggleItem.title = "Start Recording"
        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Tiro"
        )
        statusItem.button?.contentTintColor = nil
        releaseRecordingModelUse()
    }

    private func reserveRecordingModelUse() throws {
        guard !recordingModelUseReserved else { return }
        try service.beginRecordingModelUse()
        recordingModelUseReserved = true
        updateModelChecks()
    }

    private func releaseRecordingModelUse() {
        guard recordingModelUseReserved else { return }
        recordingModelUseReserved = false
        correctionPreloadTask?.cancel()
        correctionPreloadTask = nil
        if let token = localCorrectionUseToken {
            localCorrectionUseToken = nil
            Task { [transcriptEditingService] in
                await transcriptEditingService.releaseLocalModelUse(token)
            }
        }
        recordingModel = nil
        service.endRecordingModelUse()
        updateModelChecks()
    }

    private func complete(
        _ response: TranscriptionResponse,
        model: DictationModel,
        audioURL: URL,
        operationID: UUID
    ) async {
        guard transcriptionID == operationID else { return }
        let destination = destinationSession
        destinationSession = nil
        originApplication = nil
        var completionOverlay = OverlayState.copied
        guard let completedText = await reviewedText(
            response,
            audioURL: audioURL,
            willPaste: shouldAutoPaste && destination != nil,
            operationID: operationID
        ) else {
            guard transcriptionID == operationID else { return }
            _ = await destination?.restore()
            guard transcriptionID == operationID else { return }
            finishCancelledTranscription()
            settingsWindow.refreshHistory()
            return
        }
        guard !Task.isCancelled, transcriptionID == operationID else { return }
        state = .committing
        menuToggleItem.title = "Finishing…"
        if completedText != response.text {
            do {
                try await service.correctHistoryEntry(id: response.id, correctedText: completedText)
            } catch is CancellationError {
                return
            } catch {
                NSLog(
                    "Could not save the accepted spoken correction: %@",
                    error.localizedDescription
                )
            }
        }
        guard !Task.isCancelled, transcriptionID == operationID else { return }
#if TIRO_SPONSORSHIP_ENABLED
        supportPromptPolicy.recordSuccessfulTranscription()
        scheduleNextSupportPromptCheck(minimumDelay: 1)
#endif
        if shouldAutoPaste, let destination {
            do {
                let result = try await pasteCoordinator.paste(
                    completedText,
                    to: destination,
                    waitForConfirmation: false
                )
                completionOverlay = result == .confirmed ? .pasted : .pasteSent
                clearPasteRecovery()
            } catch {
                copyToClipboard(completedText)
                _ = await destination.restore()
                completionOverlay = .pasteFailed
                rememberPasteFailure(completedText, error: error)
                NSLog("Could not auto-paste transcription: %@", error.localizedDescription)
            }
        } else {
            copyToClipboard(completedText)
            clearPasteRecovery()
            _ = await destination?.restore()
        }
        guard transcriptionID == operationID else { return }
        state = .idle
        menuToggleItem.title = "Start Recording"
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tiro")
        statusItem.button?.contentTintColor = nil
        releaseRecordingModelUse()
        settingsWindow.refreshHistory()
        overlay.show(completionOverlay)
        overlay.dismiss(after: 0.8)
        if DictationModel.selected == model {
            setTranscriptionStatus(nil)
        }
        startDeferredRecordingIfNeeded()
    }

    private func startDeferredRecordingIfNeeded() {
        guard deferredRecordingStart.consume() else { return }
        startRecording()
    }

    private func reviewedText(
        _ response: TranscriptionResponse,
        audioURL: URL,
        willPaste: Bool,
        operationID: UUID
    ) async -> String? {
        let timing = CorrectionTimingPreference.load()
        let correctionIsAvailable = TranscriptEditingModel.selected != .off
            && !response.text.isEmpty
        var outcome = CorrectionOutcome(
            revisedText: response.text,
            explanation: "",
            requiresReview: false,
            failed: false
        )
        if timing == .automatic, correctionIsAvailable {
            guard let automaticOutcome = await correctionOutcome(
                for: response.text,
                fallbackText: response.text,
                instructionText: nil,
                response: response,
                operationID: operationID,
                inReviewWindow: false
            ) else { return nil }
            outcome = automaticOutcome
        }
        guard !Task.isCancelled, transcriptionID == operationID else { return nil }

        let previewExplanation = timing == .onRequest && !correctionIsAvailable
            ? "Choose a correction model in Settings > Models to use Repair."
            : outcome.explanation
        var draft = TranscriptReviewDraft(
            originalText: response.text,
            revisedText: outcome.revisedText,
            explanation: previewExplanation,
            audioURL: audioURL,
            duration: response.transcription_seconds,
            action: willPaste ? .paste : .copy,
            allowsCorrection: timing == .onRequest,
            correctionIsAvailable: correctionIsAvailable,
            allowsCorrectionInstruction: hotkeys.supportsCorrectionGesture
        )
        let shouldReview = timing == .onRequest || TranscriptReviewPreference.load().shouldReview(
            textChanged: draft.textChanged,
            requiresReview: outcome.requiresReview
        )
        guard shouldReview else {
            return nonEmpty(outcome.revisedText)
        }

        overlay.dismiss()
        let reviewWindow = transcriptReviewWindow ?? TranscriptReviewWindowController()
        transcriptReviewWindow = reviewWindow
        reviewWindow.onCancelBusy = { [weak self] in self?.cancelRecording() }
        while !Task.isCancelled, transcriptionID == operationID {
            state = .reviewing
            menuToggleItem.title = willPaste ? "Paste Transcription" : "Copy Transcription"
            switch await reviewWindow.review(draft) {
            case .accepted(let text):
                guard !Task.isCancelled, transcriptionID == operationID else { return nil }
                return nonEmpty(text)
            case .correctionRequested(let text, let fallbackText, let instructionText):
                guard timing == .onRequest, TranscriptEditingModel.selected != .off else {
                    return nonEmpty(text)
                }
                guard let requestedOutcome = await correctionOutcome(
                    for: text,
                    fallbackText: fallbackText,
                    instructionText: instructionText,
                    response: response,
                    operationID: operationID,
                    inReviewWindow: true
                ) else { return nil }
                draft = TranscriptReviewDraft(
                    originalText: fallbackText,
                    revisedText: requestedOutcome.revisedText,
                    explanation: requestedOutcome.explanation,
                    audioURL: audioURL,
                    duration: response.transcription_seconds,
                    action: willPaste ? .paste : .copy,
                    allowsCorrection: requestedOutcome.failed,
                    correctionIsAvailable: true,
                    allowsCorrectionInstruction: hotkeys.supportsCorrectionGesture
                )
            case .cancelled: return nil
            }
        }
        return nil
    }

    private func correctionOutcome(
        for text: String,
        fallbackText: String,
        instructionText: String?,
        response: TranscriptionResponse,
        operationID: UUID,
        inReviewWindow: Bool
    ) async -> CorrectionOutcome? {
        state = .correcting
        menuToggleItem.title = "Correcting…"
        if inReviewWindow {
            transcriptReviewWindow?.showCorrectionProgress(
                providerName: TranscriptEditingModel.selected.title,
                phase: "Starting"
            )
        } else {
            overlay.show(.correcting)
        }
        do {
            let result = try await transcriptEditingService.proposeEdits(
                to: Self.response(response, replacingText: text),
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.transcriptionID == operationID else { return }
                        if inReviewWindow {
                            self.transcriptReviewWindow?.showCorrectionProgress(
                                providerName: progress.providerName,
                                phase: Self.correctionProgressTitle(progress.phase)
                            )
                        } else {
                            self.overlay.show(Self.overlayState(for: progress))
                        }
                    }
                }
            )
            var revisedText = fallbackText
            var explanation = ""
            var instructionWasNotApplied = text != fallbackText
            if case .proposal(let proposal) = result.decision {
                if Self.containsDictatedInstruction(
                    proposal.revisedText,
                    instructionText: instructionText
                ) {
                    explanation = "The correction model returned the added instruction instead of applying it."
                } else {
                    revisedText = proposal.revisedText
                    explanation = proposal.explanation
                    instructionWasNotApplied = false
                }
            } else if instructionWasNotApplied {
                explanation = "The correction model did not apply the added instruction."
            }
            return CorrectionOutcome(
                revisedText: revisedText,
                explanation: explanation,
                requiresReview: result.requiresReview || instructionWasNotApplied,
                failed: instructionWasNotApplied
            )
        } catch is CancellationError {
            return nil
        } catch {
            NSLog("Could not analyse spoken corrections: %@", error.localizedDescription)
            return CorrectionOutcome(
                revisedText: fallbackText,
                explanation: "Correction failed: \(error.localizedDescription) The original transcription is shown.",
                requiresReview: true,
                failed: true
            )
        }
    }

    private func nonEmpty(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static func response(
        _ response: TranscriptionResponse,
        replacingText text: String
    ) -> TranscriptionResponse {
        TranscriptionResponse(
            id: response.id,
            timestamp: response.timestamp,
            model: response.model,
            audio_file: response.audio_file,
            transcription_seconds: response.transcription_seconds,
            text: text,
            language: response.language,
            origin_bundle_id: response.origin_bundle_id,
            origin_app_name: response.origin_app_name,
            source_filename: response.source_filename,
            segments: response.segments
        )
    }

    private static func containsDictatedInstruction(
        _ revisedText: String,
        instructionText: String?
    ) -> Bool {
        guard let instructionText else { return false }
        let instructionWords = normalizedWords(instructionText)
        guard instructionWords.count >= 3 else { return false }
        let revisedWords = normalizedWords(revisedText)
        guard revisedWords.count >= instructionWords.count else { return false }
        for start in 0...(revisedWords.count - instructionWords.count) {
            if Array(revisedWords[start..<(start + instructionWords.count)]) == instructionWords {
                return true
            }
        }
        return false
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func correctionProgressTitle(
        _ phase: TranscriptEditingProgressPhase
    ) -> String {
        switch phase {
        case .starting: "Starting"
        case .working: "Correcting"
        case .receiving: "Receiving correction"
        }
    }

    private static func overlayState(
        for progress: TranscriptEditingProgress
    ) -> OverlayState {
        switch progress.phase {
        case .starting: .correctionStarting(progress.providerName)
        case .working: .correctionWorking(progress.providerName)
        case .receiving: .correctionReceiving(progress.providerName)
        }
    }

    private func presentError(_ error: Error) {
        if recorder.isRecording { recorder.cancel() }
        commandRecording = nil
        destinationSession = nil
        originApplication = nil
        state = .idle
        menuToggleItem.title = "Start Recording"
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tiro")
        statusItem.button?.contentTintColor = nil
        releaseRecordingModelUse()
        overlay.show(.error)
        overlay.dismiss(after: 2.0)
        NSLog("Tiro error: %@", error.localizedDescription)
        presentRecovery(ErrorRecovery.presentation(
            for: error,
            microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        ))
    }

    private func presentRecovery(_ presentation: RecoveryPresentation) {
        guard presentation.action != .retryTranscription else { return }
        guard !isPresentingRecovery else { return }
        isPresentingRecovery = true
        defer {
            isPresentingRecovery = false
#if TIRO_SPONSORSHIP_ENABLED
            supportPromptSuppressedUntil = Date().addingTimeInterval(60)
#endif
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.title
        alert.informativeText = presentation.detail
        alert.addButton(withTitle: recoveryButtonTitle(for: presentation.action))
        alert.addButton(withTitle: "Dismiss")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performRecovery(presentation.action)
    }

    private func recoveryButtonTitle(for action: RecoveryAction) -> String {
        switch action {
        case .openMicrophoneSettings, .openSpeechRecognitionSettings,
             .openAccessibilitySettings:
            return "Open Permissions"
        case .openModels: return "Open Models"
        case .retryModels: return "Retry"
        case .retryTranscription: return "OK"
        }
    }

    private func performRecovery(_ action: RecoveryAction) {
        switch action {
        case .openMicrophoneSettings, .openSpeechRecognitionSettings,
             .openAccessibilitySettings:
            settingsWindow.showPermissionsSettings()
        case .openModels:
            settingsWindow.showModelsSettings()
        case .retryModels:
            prepareInstalledModel()
        case .retryTranscription:
            break
        }
    }

    @objc private func showSettings() {
        settingsWindow.showWindow(nil)
    }

    @objc private func showTranscriptionModelsSettings() {
        settingsWindow.showTranscriptionModelsSettings()
    }

    @objc private func showCorrectionModelsSettings() {
        settingsWindow.showCorrectionModelsSettings()
    }

    @objc private func showFileTranscription() {
        guard UserDefaults.standard.bool(forKey: "setupCompleted") else {
            showSetup()
            return
        }
        fileTranscriptionWindow.showWindow(nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.count == 1, let url = urls.first, url.scheme == "tiro" {
            guard let section = SettingsSection(deepLink: url) else {
                presentError(TiroError.message("Tiro could not open that link."))
                return
            }
            settingsWindow.showSettings(section)
            return
        }
        guard UserDefaults.standard.bool(forKey: "setupCompleted") else {
            showSetup()
            presentError(TiroError.message(
                "Finish Tiro setup, then open the audio file again."
            ))
            return
        }
        guard urls.count == 1, let url = urls.first else {
            presentError(TiroError.message("Open one audio file at a time."))
            return
        }
        fileTranscriptionWindow.transcribe(url)
    }

#if TIRO_SPONSORSHIP_ENABLED
    @objc private func supportTiro() {
        NSWorkspace.shared.open(BuildFeatures.sponsorsURL)
    }
#endif

    @objc private func showPermissionsSettings() {
        settingsWindow.showPermissionsSettings()
    }

    @objc private func reviewPrivacySettings() {
        awaitingPrivacyReview = true
        settingsWindow.showPrivacySettings()
    }

    @objc private func showSetup() {
        let controller = onboardingWindow ?? makeOnboardingWindow()
        onboardingWindow = controller
        controller.updatePermissions(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            accessibilityAllowed: AXIsProcessTrusted()
        )
        controller.showWindow(nil)
    }

    private func makeOnboardingWindow() -> OnboardingWindowController {
        let controller = OnboardingWindowController(
            service: service,
            shortcutName: hotkeys.shortcut.displayName
        )
        controller.onRequestMicrophone = { [weak self] in self?.requestMicrophoneAccess() }
        controller.onOpenAccessibility = { [weak self] in self?.openAccessibilitySettings() }
        controller.onModelsChanged = { [weak self] models in
            self?.applyModelInventory(models)
        }
        controller.onDownloadCompleted = { [weak self] in self?.prepareInstalledModel() }
        controller.onComplete = { [weak self] in
            UserDefaults.standard.set(true, forKey: "setupCompleted")
            self?.setupMenuItem.isHidden = true
            self?.scheduleAutomaticUpdateCheck()
#if TIRO_SPONSORSHIP_ENABLED
            self?.scheduleNextSupportPromptCheck()
#endif
        }
        return controller
    }

    func menuDidClose(_ menu: NSMenu) {
        statusMenuIsOpen = false
        if transcriptionMenuNeedsRebuild { updateModelChecks() }
        if correctionMenuNeedsRebuild { updateCorrectionModelChecks() }
#if TIRO_SPONSORSHIP_ENABLED
        handleSupportPromptCheck()
#endif
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateModelChecks()
        updateCorrectionModelChecks()
        statusMenuIsOpen = true
        refreshCorrectionModelMenu()
    }

    private func scheduleAutomaticUpdateCheck(
        minimumDelay: TimeInterval = 15
    ) {
        updateCheckTimer?.invalidate()
        guard UserDefaults.standard.bool(
            forKey: AutomaticUpdateCheckPolicy.enabledDefaultsKey
        ), currentReleaseTag != nil else { return }
        let lastCheck = UserDefaults.standard.object(
            forKey: AutomaticUpdateCheckPolicy.lastSuccessfulCheckDefaultsKey
        ) as? Date
        let delay = AutomaticUpdateCheckPolicy.nextDelay(
            lastSuccessfulCheck: lastCheck,
            minimumDelay: minimumDelay
        )
        updateCheckTimer = Timer.scheduledTimer(
            withTimeInterval: delay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.performAutomaticUpdateCheck() }
        }
    }

    private func performAutomaticUpdateCheck() {
        guard updateCheckTask == nil, let currentTag = currentReleaseTag else { return }
        updateCheckTask = Task { [weak self] in
            defer { self?.updateCheckTask = nil }
            do {
                let result = try await UpdateChecker.check(currentTag: currentTag)
                try Task.checkCancellation()
                UserDefaults.standard.set(
                    Date(),
                    forKey: AutomaticUpdateCheckPolicy.lastSuccessfulCheckDefaultsKey
                )
                self?.handleAutomaticUpdateResult(result)
                self?.scheduleAutomaticUpdateCheck()
            } catch is CancellationError {
                return
            } catch {
                self?.scheduleAutomaticUpdateCheck(
                    minimumDelay: AutomaticUpdateCheckPolicy.retryInterval
                )
            }
        }
    }

    private func handleAutomaticUpdateResult(_ result: UpdateCheckResult) {
        guard case .updateAvailable(let release) = result else {
            updateAvailableItem.isHidden = true
            return
        }
        updateAvailableItem.title = "Update Available: \(release.tagName)…"
        updateAvailableItem.representedObject = release.pageURL
        updateAvailableItem.isHidden = false

        let defaults = UserDefaults.standard
        guard state == .idle,
              defaults.bool(forKey: "setupCompleted"),
              defaults.string(
                forKey: AutomaticUpdateCheckPolicy.lastNotifiedTagDefaultsKey
              ) != release.tagName else { return }
        defaults.set(
            release.tagName,
            forKey: AutomaticUpdateCheckPolicy.lastNotifiedTagDefaultsKey
        )
        let alert = NSAlert()
        alert.messageText = "Tiro \(release.tagName) is available"
        alert.informativeText = "Download the latest version from GitHub Releases."
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    private var currentReleaseTag: String? {
        Bundle.main.object(forInfoDictionaryKey: "TiroReleaseTag") as? String
    }

    @objc private func openAvailableUpdate(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

#if TIRO_SPONSORSHIP_ENABLED
    private func scheduleNextSupportPromptCheck(minimumDelay: TimeInterval = 0) {
        supportPromptTimer?.invalidate()
        guard let due = supportPromptPolicy.nextPromptDate() else { return }
        let delay = max(minimumDelay, due.timeIntervalSinceNow)
        supportPromptTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.handleSupportPromptCheck() }
        }
    }

    private func handleSupportPromptCheck() {
        guard supportPromptPolicy.shouldPrompt() else {
            scheduleNextSupportPromptCheck()
            return
        }
        let presentation = SupportPromptPresentationState(
            isIdle: state == .idle,
            setupCompleted: UserDefaults.standard.bool(forKey: "setupCompleted"),
            onboardingVisible: onboardingWindow?.window?.isVisible == true,
            presentingRecovery: isPresentingRecovery,
            overlayVisible: overlay.isVisible,
            promptVisible: supportPromptWindow.window?.isVisible == true,
            suppressedUntil: supportPromptSuppressedUntil
        )
        guard presentation.canPresent() else {
            supportPromptTimer?.invalidate()
            supportPromptTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.handleSupportPromptCheck() }
            }
            return
        }
        supportPromptPolicy.markShown()
        supportPromptWindow.showWindow(nil)
        scheduleNextSupportPromptCheck()
    }
#endif

    private func refreshSetupPermissions() {
        guard let onboardingWindow, onboardingWindow.window?.isVisible == true else { return }
        onboardingWindow.updatePermissions(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            accessibilityAllowed: AXIsProcessTrusted()
        )
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let model = DictationModel.all.first(where: { $0.key == key }) else { return }
        guard installedModelKeys.contains(key) else {
            settingsWindow.showTranscriptionModelsSettings()
            return
        }
        do {
            try service.select(model: model)
        } catch {
            presentError(error)
            return
        }
        updateModelChecks()
        settingsWindow.refreshModel()
        setTranscriptionStatus("Switching to \(model.name)…")
        modelSelectionTask?.cancel()
        modelSelectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.activate(model: model)
                guard !Task.isCancelled else { return }
                let models = await service.models()
                guard !Task.isCancelled else { return }
                applyModelInventory(models)
            } catch {
                guard !Task.isCancelled else { return }
                setTranscriptionStatus("Could not switch transcription model")
                presentError(error)
            }
        }
    }

    @objc private func selectCorrectionModel(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let model = TranscriptEditingModel(rawValue: rawValue) else { return }
        guard availableCorrectionModels.contains(model) else {
            settingsWindow.showCorrectionModelsSettings()
            return
        }
        TranscriptEditingModel.selected = model
        updateCorrectionModelChecks()
        settingsWindow.refreshCorrectionModel()
        Task { [transcriptEditingService] in
            await transcriptEditingService.correctionModelDidChange(to: model)
        }
    }

    private func updateModelChecks() {
        let selected = DictationModel.selected
        if renderedInstalledModelKeys != installedModelKeys {
            if statusMenuIsOpen {
                transcriptionMenuNeedsRebuild = true
            } else {
                rebuildTranscriptionModelMenu()
            }
        }
        for item in transcriptionModelMenu.items {
            guard let key = item.representedObject as? String else { continue }
            item.isEnabled = !service.modelUseInProgress
            item.state = key == selected.key ? .on : .off
        }
        transcriptionModelItem.title = installedModelKeys.contains(selected.key)
            ? "Transcription: \(selected.name)"
            : "Transcription Models"
        menuToggleItem.isEnabled = installedModelKeys.contains(selected.key)
    }

    private func rebuildTranscriptionModelMenu() {
        transcriptionModelMenu.removeAllItems()
        let installedModels = DictationModel.all.filter { installedModelKeys.contains($0.key) }
        if installedModels.isEmpty {
            let emptyItem = NSMenuItem(title: "No Models Installed", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            transcriptionModelMenu.addItem(emptyItem)
        } else {
            for model in installedModels {
                let item = NSMenuItem(
                    title: model.name,
                    action: #selector(selectModel(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = model.key
                item.isEnabled = !service.modelUseInProgress
                transcriptionModelMenu.addItem(item)
            }
        }
        transcriptionModelMenu.addItem(.separator())
        let manageItem = NSMenuItem(
            title: "Manage Transcription Models…",
            action: #selector(showTranscriptionModelsSettings),
            keyEquivalent: ""
        )
        manageItem.target = self
        transcriptionModelMenu.addItem(manageItem)
        renderedInstalledModelKeys = installedModelKeys
        transcriptionMenuNeedsRebuild = false
    }

    private func updateCorrectionModelChecks() {
        let selected = TranscriptEditingModel.selected
        if renderedCorrectionModels != availableCorrectionModels {
            if statusMenuIsOpen {
                correctionMenuNeedsRebuild = true
            } else {
                rebuildCorrectionModelMenu()
            }
        }
        correctionModelItem.title = "Corrections: \(selected.title)"
        for item in correctionModelMenu.items {
            guard let rawValue = item.representedObject as? String,
                  let model = TranscriptEditingModel(rawValue: rawValue) else { continue }
            item.isEnabled = true
            item.state = model == selected ? .on : .off
        }
    }

    private func rebuildCorrectionModelMenu() {
        correctionModelMenu.removeAllItems()
        for model in TranscriptEditingModel.allCases where availableCorrectionModels.contains(model) {
            let item = NSMenuItem(
                title: model.title,
                action: #selector(selectCorrectionModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = model.rawValue
            correctionModelMenu.addItem(item)
        }
        correctionModelMenu.addItem(.separator())
        let manageItem = NSMenuItem(
            title: "Manage Correction Models…",
            action: #selector(showCorrectionModelsSettings),
            keyEquivalent: ""
        )
        manageItem.target = self
        correctionModelMenu.addItem(manageItem)
        renderedCorrectionModels = availableCorrectionModels
        correctionMenuNeedsRebuild = false
    }

    private func refreshCorrectionModelMenu() {
        correctionModelRefreshTask?.cancel()
        correctionModelRefreshTask = Task { [weak self, transcriptEditingService] in
            let snapshot = await transcriptEditingService.modelSnapshot()
            guard !Task.isCancelled, let self else { return }
            let available = Set(TranscriptEditingModel.allCases.filter(snapshot.canSelect))
            availableCorrectionModels = available
            if !available.contains(TranscriptEditingModel.selected) {
                TranscriptEditingModel.selected = .off
                settingsWindow.refreshCorrectionModel()
                await transcriptEditingService.correctionModelDidChange(to: .off)
            }
            updateCorrectionModelChecks()
        }
    }

    private func prepareInstalledModel() {
        modelInventoryStatus = .loading
        setTranscriptionStatus("Checking installed transcription models…")
        modelStartupTask?.cancel()
        modelStartupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let models = await service.models()
                guard !Task.isCancelled else { return }
                guard let model = applyModelInventory(models) else {
                    return
                }
                setTranscriptionStatus("Loading \(model.name)…")
                try await service.preload(model: model)
                guard !Task.isCancelled else { return }
                if DictationModel.selected == model {
                    setTranscriptionStatus(nil)
                }
            } catch {
                guard !Task.isCancelled else { return }
                modelInventoryStatus = modelInventoryStatus.afterPreparationFailure
                setTranscriptionStatus("Installed transcription models unavailable")
                updateModelChecks()
                NSLog("Could not prepare an installed model: %@", error.localizedDescription)
            }
        }
    }

    @discardableResult
    private func applyModelInventory(_ models: [ManagedModel]) -> DictationModel? {
        installedModelKeys = Set(models.lazy.filter { $0.usable && !$0.deleting }.map(\.key))
        var selected = DictationModel.selected
        if !installedModelKeys.contains(selected.key),
           let fallback = DictationModel.all.first(where: { installedModelKeys.contains($0.key) }) {
            DictationModel.select(fallback)
            selected = fallback
        }
        updateModelChecks()
        guard installedModelKeys.contains(selected.key) else {
            modelInventoryStatus = .missing
            setTranscriptionStatus("No transcription model installed")
            return nil
        }
        modelInventoryStatus = .available
        setTranscriptionStatus(nil)
        return selected
    }

    private func setTranscriptionStatus(_ status: String?) {
        modelStatusItem.title = status ?? ""
        modelStatusItem.isHidden = status == nil
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func clearPasteRecovery() {
        pasteRecoveryGeneration += 1
        pasteRetryTask?.cancel()
        pasteRetryTask = nil
        lastFailedPasteText = nil
        pasteRecoveryItem.isHidden = true
        pasteRecoveryItem.isEnabled = true
        pasteRecoveryItem.target = self
        pasteRecoveryItem.action = #selector(showPermissionsSettings)
        pasteRecoveryItem.title = "Auto-paste needs Accessibility permission…"
    }

    private func rememberPasteFailure(_ text: String, error: Error) {
        pasteRecoveryGeneration += 1
        pasteRetryTask?.cancel()
        pasteRetryTask = nil
        lastFailedPasteText = text
        pasteRecoveryItem.target = self
        pasteRecoveryItem.isHidden = false
        pasteRecoveryItem.isEnabled = true
        if ErrorRecovery.presentation(for: error).action == .openAccessibilitySettings {
            pasteRecoveryItem.title = "Fix Auto-paste Permission…"
            pasteRecoveryItem.action = #selector(showPermissionsSettings)
        } else {
            pasteRecoveryItem.title = "Paste Last Dictation Again"
            pasteRecoveryItem.action = #selector(retryLastPaste)
        }
    }

    @objc private func retryLastPaste() {
        guard pasteRetryTask == nil else { return }
        guard let text = lastFailedPasteText else {
            clearPasteRecovery()
            return
        }
        guard let destination = destinationTracker.capture() else {
            copyToClipboard(text)
            overlay.show(.pasteFailed)
            overlay.dismiss(after: 2)
            return
        }
        let generation = pasteRecoveryGeneration
        pasteRecoveryItem.isEnabled = false
        pasteRecoveryItem.title = "Pasting Last Dictation…"
        pasteRetryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await pasteCoordinator.paste(text, to: destination)
                guard !Task.isCancelled, generation == pasteRecoveryGeneration else { return }
                pasteRetryTask = nil
                clearPasteRecovery()
                overlay.show(result == .confirmed ? .pasted : .pasteSent)
                overlay.dismiss(after: 1.2)
            } catch {
                guard !Task.isCancelled, generation == pasteRecoveryGeneration else { return }
                pasteRetryTask = nil
                copyToClipboard(text)
                rememberPasteFailure(text, error: error)
                overlay.show(.pasteFailed)
                overlay.dismiss(after: 2)
            }
        }
    }
}
