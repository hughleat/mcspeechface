import AppKit
import TiroEditing

@MainActor
final class TranscriptEditingSettingsView: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    var onModelChanged: ((TranscriptEditingModel) -> Void)?
    var onCompareModels: (() -> Void)?

    private enum ModelState: Equatable {
        case checking
        case available
        case unavailable(String)
        case local(LocalTranscriptEditingModelStatus)
        case localError(String, LocalTranscriptEditingModelStatus)
        case cancelling
        case deleting
    }

    private let service: TranscriptEditingService
    private let promptPreferences: TranscriptEditingPromptPreferences
    private let defaults: UserDefaults
    private let table = NSTableView()
    private let storageLabel = NSTextField(labelWithString: "")
    private let compareButton = NSButton()
    private let idleTimeoutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var localDownloadSpaces: [
        TranscriptEditingModel: LocalTranscriptEditingModelDownloadSpace
    ] = [:]
    private var states: [TranscriptEditingModel: ModelState] = {
        var states: [TranscriptEditingModel: ModelState] = [
            .off: .available,
            .appleFoundation: .checking,
        ]
        for model in TranscriptEditingModel.commandLineModels { states[model] = .checking }
        for model in TranscriptEditingModel.localModels { states[model] = .checking }
        return states
    }()
    private var refreshTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var runtimeRefreshTask: Task<Void, Never>?
    private var runtimeActionTask: Task<Void, Never>?
    private var operationModel: TranscriptEditingModel?
    private var runtimeStates: [TranscriptEditingModel: LocalCorrectionRuntimeState] = [:]
    private var providerRuntimeStates: [
        TranscriptEditingModel: PersistentCorrectionRuntimeState
    ] = [:]
    private var promptEditorController: TranscriptEditingPromptEditorWindowController?
    private var commandLineEditorController: CommandLineCorrectionEditorWindowController?
    private var refreshGeneration = 0
    private var isApplyingSelection = false

    init(
        service: TranscriptEditingService,
        promptPreferences: TranscriptEditingPromptPreferences = .init(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.promptPreferences = promptPreferences
        self.defaults = defaults
        super.init(frame: .zero)
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        refreshTask?.cancel()
        operationTask?.cancel()
        runtimeRefreshTask?.cancel()
        runtimeActionTask?.cancel()
    }

    func refresh() {
        startRuntimeRefreshIfNeeded()
        invalidateRefresh()
        let generation = refreshGeneration
        states[.appleFoundation] = .checking
        for model in TranscriptEditingModel.commandLineModels { states[model] = .checking }
        if operationTask == nil {
            for model in TranscriptEditingModel.localModels { states[model] = .checking }
        }
        reloadTable()
        refreshTask = Task { [weak self, service] in
            async let snapshot = service.modelSnapshot()
            async let downloadSpaces = service.localModelDownloadSpaces()
            let results = await (snapshot, downloadSpaces)
            guard !Task.isCancelled, self?.refreshGeneration == generation else { return }
            self?.apply(
                snapshot: results.0,
                downloadSpaces: results.1
            )
        }
    }

    func cancelWork() {
        invalidateRefresh()
        runtimeRefreshTask?.cancel()
        runtimeRefreshTask = nil
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 7

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(selectClickedModel)
        table.rowHeight = 68
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Correction models")

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = table
        addArrangedSubview(scrollView)
        scrollView.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 206).isActive = true

        let idleTimeoutLabel = NSTextField(labelWithString: "Unload local model after")
        idleTimeoutLabel.font = .systemFont(ofSize: 13, weight: .medium)
        for timeout in LocalCorrectionIdleTimeout.allCases {
            idleTimeoutPopup.addItem(withTitle: timeout.title)
            idleTimeoutPopup.lastItem?.tag = timeout.rawValue
        }
        idleTimeoutPopup.selectItem(
            withTag: LocalCorrectionIdleTimeout.load(from: defaults).rawValue
        )
        idleTimeoutPopup.target = self
        idleTimeoutPopup.action = #selector(idleTimeoutChanged)
        idleTimeoutPopup.toolTip = "How long an idle local correction model remains in memory"
        idleTimeoutPopup.setAccessibilityLabel("Unload local correction model after")
        let idleTimeoutRow = NSStackView(views: [
            idleTimeoutLabel,
            NSView(),
            idleTimeoutPopup,
        ])
        idleTimeoutRow.orientation = .horizontal
        idleTimeoutRow.alignment = .centerY
        idleTimeoutRow.spacing = 8
        addArrangedSubview(idleTimeoutRow)
        idleTimeoutRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        storageLabel.font = .systemFont(ofSize: 11)
        storageLabel.textColor = .secondaryLabelColor
        storageLabel.alignment = .right
        storageLabel.isHidden = true
        let instructionsLabel = NSTextField(labelWithString: "Correction Prompts")
        instructionsLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let promptsButton = NSButton(
            title: "Edit…",
            target: self,
            action: #selector(editPrompts)
        )
        promptsButton.image = NSImage(
            systemSymbolName: "pencil",
            accessibilityDescription: nil
        )
        promptsButton.imagePosition = .imageLeading
        promptsButton.bezelStyle = .rounded
        promptsButton.toolTip = "Edit the complete prompts used by every correction model"
        promptsButton.setAccessibilityLabel("Edit correction prompts")
        promptsButton.setAccessibilityHelp(promptsButton.toolTip)
        let instructionsRow = NSStackView(views: [instructionsLabel, NSView(), promptsButton])
        instructionsRow.orientation = .horizontal
        instructionsRow.alignment = .centerY
        instructionsRow.spacing = 8
        addArrangedSubview(instructionsRow)
        instructionsRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        compareButton.title = "Compare Corrections…"
        compareButton.image = NSImage(
            systemSymbolName: "rectangle.split.3x1",
            accessibilityDescription: nil
        )
        compareButton.imagePosition = .imageLeading
        compareButton.bezelStyle = .rounded
        compareButton.target = self
        compareButton.action = #selector(compareCorrections)
        compareButton.toolTip = "Compare correction models on a saved transcript"
        let footer = NSStackView(views: [compareButton, NSView(), storageLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        TranscriptEditingModel.allCases.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard TranscriptEditingModel.allCases.indices.contains(row) else { return nil }
        let model = TranscriptEditingModel.allCases[row]
        let identifier = NSUserInterfaceItemIdentifier("CorrectionModelRow")
        let cell = (tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ModelLibraryRowView) ?? ModelLibraryRowView(identifier: identifier)
        cell.configure(with: rowContent(for: model, row: row))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        applySelectedModel()
    }

    @objc private func selectClickedModel() {
        applySelectedModel()
    }

    private func applySelectedModel() {
        guard !isApplyingSelection,
              TranscriptEditingModel.allCases.indices.contains(table.selectedRow) else { return }
        let model = TranscriptEditingModel.allCases[table.selectedRow]
        guard isSelectable(model) else {
            restoreSelection()
            return
        }
        guard selectedModel != model else { return }
        selectedModel = model
        onModelChanged?(model)
        reloadTable(selecting: model)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard TranscriptEditingModel.allCases.indices.contains(row) else { return false }
        return isSelectable(TranscriptEditingModel.allCases[row])
    }

    func apply(
        snapshot: TranscriptEditingModelSnapshot,
        downloadSpaces: [TranscriptEditingModel: LocalTranscriptEditingModelDownloadSpace]
    ) {
        states[.appleFoundation] = switch snapshot.appleAvailability {
        case .available: .available
        case .unavailable(let reason): .unavailable(reason)
        }
        for model in TranscriptEditingModel.commandLineModels {
            states[model] = switch snapshot.commandLineAvailability[model] {
            case .available: .available
            case .unavailable(let reason): .unavailable(reason)
            case nil: .unavailable("Configure an installed executable.")
            }
        }
        for model in TranscriptEditingModel.localModels {
            states[model] = .local(snapshot.localStatuses[model] ?? .notInstalled)
        }
        apply(downloadSpaces: downloadSpaces)
        if !canRemainSelected(selectedModel) {
            selectedModel = .off
            onModelChanged?(.off)
            AccessibilityAnnouncements.post("Correction model set to Off.", from: table)
        }
        reloadTable()
    }

    private func isSelectable(_ model: TranscriptEditingModel) -> Bool {
        switch states[model] {
        case .checking:
            return operationTask == nil && model == selectedModel
        default:
            let appleAvailable = states[.appleFoundation] == .available
            let commandLineAvailable = model.commandLinePreset.map {
                CommandLineCorrectionConfiguration.load(
                    preset: $0,
                    from: defaults
                ).isExecutableAvailable
            } ?? false
            let localStatus = localModelStatus(for: model)
            return Self.allowsSelection(
                of: model,
                appleAvailable: appleAvailable,
                commandLineAvailable: commandLineAvailable,
                localStatus: localStatus,
                operationInProgress: operationTask != nil
            )
        }
    }

    static func allowsSelection(
        of model: TranscriptEditingModel,
        appleAvailable: Bool,
        commandLineAvailable: Bool = false,
        localStatus: LocalTranscriptEditingModelStatus,
        operationInProgress: Bool
    ) -> Bool {
        guard !operationInProgress else { return false }
        switch model {
        case .off: return true
        case .appleFoundation: return appleAvailable
        case .codexCommandLine, .claudeCommandLine, .customCommandLine:
            return commandLineAvailable
        case .qwenLocal, .ministralLocal:
            if case .installed = localStatus { return true }
            return false
        }
    }

    private func canRemainSelected(_ model: TranscriptEditingModel) -> Bool {
        switch states[model] {
        case .available, .checking, .local(.installed): true
        case .localError(_, .installed): true
        case .unavailable, .local, .localError, .cancelling, .deleting, nil: false
        }
    }

    private func localModelStatus(
        for model: TranscriptEditingModel
    ) -> LocalTranscriptEditingModelStatus {
        switch states[model] {
        case .local(let status), .localError(_, let status): status
        case .checking, .available, .unavailable, .cancelling, .deleting, nil: .notInstalled
        }
    }

    private func restoreSelection() {
        let selected = selectedModel
        selectRow(for: canRemainSelected(selected) ? selected : .off)
    }

    private func selectRow(for model: TranscriptEditingModel) {
        guard let row = TranscriptEditingModel.allCases.firstIndex(of: model),
              table.selectedRow != row else { return }
        let wasApplyingSelection = isApplyingSelection
        isApplyingSelection = true
        defer { isApplyingSelection = wasApplyingSelection }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func reloadTable(selecting model: TranscriptEditingModel? = nil) {
        let selection = model ?? (canRemainSelected(selectedModel) ? selectedModel : .off)
        let wasApplyingSelection = isApplyingSelection
        isApplyingSelection = true
        defer { isApplyingSelection = wasApplyingSelection }
        table.reloadData()
        selectRow(for: selection)
    }

    private func rowContent(
        for model: TranscriptEditingModel,
        row: Int
    ) -> ModelLibraryRowView.Content {
        let selected = model == selectedModel
        let state = states[model] ?? .checking
        let runtimeState = runtimeStates[model] ?? .stopped
        let presentation = presentation(
            for: model,
            state: state,
            runtimeState: runtimeState,
            selected: selected
        )
        return ModelLibraryRowView.Content(
            name: model.title,
            detail: presentation.detail,
            detailColor: presentation.detailColor,
            detailToolTip: presentation.detailToolTip,
            status: presentation.status,
            statusColor: presentation.statusColor,
            progress: presentation.progress,
            action: action(
                for: model,
                state: state,
                runtimeState: runtimeState,
                selected: selected,
                row: row
            ),
            isSelected: selected,
            accessibilityValue: "\(selected ? "Selected model" : presentation.status), "
                + presentation.detail
        )
    }

    private func presentation(
        for model: TranscriptEditingModel,
        state: ModelState,
        runtimeState: LocalCorrectionRuntimeState,
        selected: Bool
    ) -> (
        detail: String,
        detailColor: NSColor,
        detailToolTip: String?,
        status: String,
        statusColor: NSColor,
        progress: ModelLibraryRowView.ProgressState?
    ) {
        let normalDetail = model.detail(from: defaults)
        switch state {
        case .checking:
            return (
                normalDetail, .secondaryLabelColor, nil,
                "Checking...", .tertiaryLabelColor,
                .indeterminate(accessibilityValue: "Checking availability")
            )
        case .available:
            if model.isCommandLine,
               CommandLineCorrectionConfiguration.load(
                    preset: model.commandLinePreset ?? .custom,
                    from: defaults
               ).connectionMode == .enhanced {
                let provider = Self.providerRuntimePresentation(
                    providerRuntimeStates[model] ?? .stopped,
                    selected: selected
                )
                return (
                    normalDetail, .secondaryLabelColor, nil,
                    provider.status, provider.color, provider.progress
                )
            }
            let status = selected ? "Selected" : (model == .off ? "" : "Ready")
            return (
                normalDetail, .secondaryLabelColor, nil,
                status, .secondaryLabelColor, nil
            )
        case .unavailable(let reason):
            return (
                reason, .secondaryLabelColor, reason,
                "Unavailable", .tertiaryLabelColor, nil
            )
        case .local(.notInstalled):
            if let space = localDownloadSpaces[model], !space.hasEnoughSpace,
               let available = space.availableBytes {
                let detail = "Needs \(Self.fileSize(space.requiredBytes)) free · "
                    + "\(Self.fileSize(available)) available"
                return (
                    detail, .secondaryLabelColor, detail,
                    "Not enough space", .tertiaryLabelColor, nil
                )
            }
            return (
                normalDetail, .secondaryLabelColor, nil,
                "Not installed", .tertiaryLabelColor, nil
            )
        case .local(.installing):
            return (
                normalDetail, .secondaryLabelColor, nil,
                "Downloading...", .secondaryLabelColor,
                .indeterminate(accessibilityValue: "Downloading and verifying")
            )
        case .local(.installed(let bytes)):
            let detail = normalDetail.replacingOccurrences(
                of: model.downloadSizeDescription,
                with: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            )
            if case .failed(let reason) = runtimeState {
                return (reason, .systemRed, reason, "Load failed", .systemRed, nil)
            }
            let runtimePresentation = Self.runtimePresentation(
                runtimeState,
                selected: selected
            )
            return (
                detail, .secondaryLabelColor, nil,
                runtimePresentation.status,
                runtimePresentation.color,
                runtimePresentation.progress
            )
        case .localError(let message, _):
            return (
                message, .systemRed, message,
                "Operation failed", .systemRed, nil
            )
        case .cancelling:
            return (
                normalDetail, .secondaryLabelColor, nil,
                "Cancelling...", .secondaryLabelColor,
                .indeterminate(accessibilityValue: "Cancelling")
            )
        case .deleting:
            return (
                normalDetail, .secondaryLabelColor, nil,
                "Deleting...", .secondaryLabelColor,
                .indeterminate(accessibilityValue: "Deleting")
            )
        }
    }

    private func action(
        for model: TranscriptEditingModel,
        state: ModelState,
        runtimeState: LocalCorrectionRuntimeState,
        selected: Bool,
        row: Int
    ) -> ModelLibraryRowView.Action? {
        if model.isCommandLine {
            let actionLabel = model == .customCommandLine
                ? "Edit Custom Command"
                : "Configure \(model.title)"
            return ModelLibraryRowView.Action(
                label: actionLabel,
                symbol: "slider.horizontal.3",
                isEnabled: operationTask == nil,
                toolTip: model == .customCommandLine
                    ? "Edit the executable, model, and arguments"
                    : "Choose the model, connection, effort, and access used by \(model.title)",
                tag: row,
                target: self,
                selector: #selector(configureCommandLineCorrection)
            )
        }
        guard model.localSpec != nil else { return nil }
        let label: String
        let symbol: String
        let selector: Selector
        let enabled: Bool
        let toolTip: String
        switch state {
        case .local(.notInstalled):
            label = "Download \(model.title)"
            symbol = "arrow.down.circle"
            selector = #selector(downloadLocalModel(_:))
            enabled = operationTask == nil && localDownloadSpaces[model]?.hasEnoughSpace != false
            toolTip = enabled ? label : "Not enough space to download \(model.title)"
        case .local(.installing):
            label = "Cancel \(model.title) download"
            symbol = "xmark.circle"
            selector = #selector(cancelLocalModelDownload(_:))
            enabled = true
            toolTip = label
        case .local(.installed):
            if runtimeState.isRunning {
                label = "Stop \(model.title)"
                symbol = "stop.circle"
                selector = #selector(stopLocalModel(_:))
                enabled = operationTask == nil
                    && runtimeActionTask == nil
                    && runtimeState != .correcting
                toolTip = runtimeState == .correcting
                    ? "Wait for the current correction to finish"
                    : "Unload \(model.title) from memory"
            } else {
                label = "Delete \(model.title)"
                symbol = "trash"
                selector = #selector(deleteLocalModel(_:))
                enabled = operationTask == nil && !selected
                toolTip = selected
                    ? "Select another correction model before deleting"
                    : label
            }
        case .localError(_, let status):
            if case .installed = status {
                label = "Retry deleting \(model.title)"
                symbol = "trash"
                selector = #selector(deleteLocalModel(_:))
                enabled = operationTask == nil && !selected
                toolTip = selected
                    ? "Select another correction model before deleting"
                    : label
            } else {
                label = "Retry \(model.title) download"
                symbol = "arrow.clockwise"
                selector = #selector(downloadLocalModel(_:))
                enabled = operationTask == nil && localDownloadSpaces[model]?.hasEnoughSpace != false
                toolTip = enabled ? label : "Not enough space to download \(model.title)"
            }
        case .checking, .available, .unavailable, .cancelling, .deleting:
            return nil
        }
        return ModelLibraryRowView.Action(
            label: label,
            symbol: symbol,
            isEnabled: enabled,
            toolTip: toolTip,
            tag: row,
            target: self,
            selector: selector
        )
    }

    @objc private func downloadLocalModel(_ sender: NSButton) {
        guard operationTask == nil,
              let model = model(for: sender),
              model.localSpec != nil else { return }
        invalidateRefresh()
        operationModel = model
        states[model] = .local(.installing)
        reloadTable()
        AccessibilityAnnouncements.post("Downloading \(model.title).", from: table)
        operationTask = Task { [weak self, service] in
            let finalState: ModelState
            let announcement: String
            do {
                try await service.installLocalModel(model)
                finalState = .local(await service.localModelStatus(for: model))
                announcement = "\(model.title) installed."
            } catch {
                let status = await service.localModelStatus(for: model)
                if Self.isCancellation(error) {
                    finalState = .local(status)
                    announcement = "\(model.title) download cancelled."
                } else {
                    finalState = .localError(error.localizedDescription, status)
                    announcement = "\(model.title) download failed."
                }
            }
            let spaces = await service.localModelDownloadSpaces()
            self?.finishLocalOperation(
                model: model,
                state: finalState,
                downloadSpaces: spaces,
                announcement: announcement
            )
        }
    }

    @objc private func editPrompts() {
        guard promptEditorController == nil else {
            promptEditorController?.showWindow(nil)
            return
        }
        let controller = TranscriptEditingPromptEditorWindowController(
            preferences: promptPreferences
        )
        controller.onDismiss = { [weak self] in
            self?.promptEditorController = nil
        }
        promptEditorController = controller
        if let parent = window, let editorWindow = controller.window {
            parent.beginSheet(editorWindow)
        } else {
            controller.showWindow(nil)
        }
    }

    @objc private func configureCommandLineCorrection(_ sender: NSButton) {
        guard let model = model(for: sender),
              let preset = model.commandLinePreset else { return }
        guard commandLineEditorController == nil else {
            commandLineEditorController?.showWindow(nil)
            return
        }
        let controller = CommandLineCorrectionEditorWindowController(
            preset: preset,
            defaults: defaults,
            service: service
        )
        controller.onSave = { [weak self, service] _ in
            Task {
                await service.stopPersistentProvider(model)
                guard let self else { return }
                self.refresh()
                self.onModelChanged?(self.selectedModel)
            }
        }
        controller.onDismiss = { [weak self] in
            self?.commandLineEditorController = nil
        }
        commandLineEditorController = controller
        if let parent = window, let editorWindow = controller.window {
            parent.beginSheet(editorWindow)
        } else {
            controller.showWindow(nil)
        }
    }

    @objc private func compareCorrections() {
        onCompareModels?()
    }

    @objc private func idleTimeoutChanged() {
        guard let timeout = LocalCorrectionIdleTimeout(
            rawValue: idleTimeoutPopup.selectedTag()
        ) else { return }
        timeout.save(to: defaults)
        Task { [service] in
            await service.updateLocalModelIdleTimeout(timeout)
        }
    }

    @objc private func stopLocalModel(_ sender: NSButton) {
        guard runtimeActionTask == nil, let model = model(for: sender) else { return }
        sender.isEnabled = false
        runtimeActionTask = Task { [weak self, service] in
            do {
                try await service.stopLocalModel(model)
                self?.runtimeStates = await service.localRuntimeStates()
                self?.reloadTable()
                self?.announce("\(model.title) unloaded from memory.")
            } catch {
                self?.announce(error.localizedDescription)
            }
            self?.runtimeActionTask = nil
            self?.reloadTable()
        }
    }

    @objc private func cancelLocalModelDownload(_ sender: NSButton) {
        guard let model = operationModel else { return }
        states[model] = .cancelling
        reloadTable()
        announce("Cancelling \(model.title) download.")
        operationTask?.cancel()
    }

    @objc private func deleteLocalModel(_ sender: NSButton) {
        guard let model = model(for: sender),
              selectedModel != model,
              operationTask == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(model.title)?"
        alert.informativeText =
            "The downloaded model file will be removed. You can download it again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performLocalModelDeletion(model)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func performLocalModelDeletion(_ model: TranscriptEditingModel) {
        guard selectedModel != model, operationTask == nil else {
            reloadTable(selecting: selectedModel)
            return
        }
        invalidateRefresh()
        operationModel = model
        states[model] = .deleting
        reloadTable()
        AccessibilityAnnouncements.post("Deleting \(model.title).", from: table)
        operationTask = Task { [weak self, service] in
            let finalState: ModelState
            let announcement: String
            do {
                try await service.deleteLocalModel(model)
                finalState = .local(.notInstalled)
                announcement = "\(model.title) deleted."
            } catch {
                let status = await service.localModelStatus(for: model)
                finalState = .localError(error.localizedDescription, status)
                announcement = "\(model.title) could not be deleted."
            }
            let spaces = await service.localModelDownloadSpaces()
            self?.finishLocalOperation(
                model: model,
                state: finalState,
                downloadSpaces: spaces,
                announcement: announcement
            )
        }
    }

    private func finishLocalOperation(
        model: TranscriptEditingModel,
        state: ModelState,
        downloadSpaces: [TranscriptEditingModel: LocalTranscriptEditingModelDownloadSpace],
        announcement: String
    ) {
        invalidateRefresh()
        states[model] = state
        apply(downloadSpaces: downloadSpaces)
        operationTask = nil
        operationModel = nil
        reloadTable()
        announce(announcement)
        resumeAppleAvailabilityCheckIfNeeded()
    }

    private static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || Task.isCancelled
    }

    private func apply(
        downloadSpaces: [TranscriptEditingModel: LocalTranscriptEditingModelDownloadSpace]
    ) {
        localDownloadSpaces = downloadSpaces
        if let available = downloadSpaces.values.compactMap(\.availableBytes).first {
            storageLabel.stringValue = "\(Self.fileSize(available)) available for models"
            storageLabel.isHidden = false
        } else {
            storageLabel.isHidden = true
        }
    }

    private func announce(_ message: String) {
        AccessibilityAnnouncements.post(message, from: table)
    }

    private func invalidateRefresh() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func startRuntimeRefreshIfNeeded() {
        guard runtimeRefreshTask == nil else { return }
        runtimeRefreshTask = Task { [weak self, service] in
            while !Task.isCancelled {
                async let localStates = service.localRuntimeStates()
                async let providerStates = service.persistentProviderStates()
                let states = await (localStates, providerStates)
                guard !Task.isCancelled else { return }
                if self?.runtimeStates != states.0
                    || self?.providerRuntimeStates != states.1 {
                    self?.runtimeStates = states.0
                    self?.providerRuntimeStates = states.1
                    self?.reloadTable()
                }
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
            }
        }
    }

    private static func runtimePresentation(
        _ state: LocalCorrectionRuntimeState,
        selected: Bool
    ) -> (
        status: String,
        color: NSColor,
        progress: ModelLibraryRowView.ProgressState?
    ) {
        switch state {
        case .stopped:
            return (selected ? "Selected · Stopped" : "Installed", .secondaryLabelColor, nil)
        case .loading:
            return (
                "Loading...",
                .secondaryLabelColor,
                .indeterminate(accessibilityValue: "Loading model into memory")
            )
        case .ready:
            return (selected ? "Selected · Loaded" : "Loaded", .systemGreen, nil)
        case .correcting:
            return (
                "Correcting...",
                .secondaryLabelColor,
                .indeterminate(accessibilityValue: "Correcting transcript")
            )
        case .failed:
            return ("Load failed", .systemRed, nil)
        }
    }

    private static func providerRuntimePresentation(
        _ state: PersistentCorrectionRuntimeState,
        selected: Bool
    ) -> (
        status: String,
        color: NSColor,
        progress: ModelLibraryRowView.ProgressState?
    ) {
        switch state {
        case .stopped:
            return (selected ? "Selected · Stopped" : "Ready", .secondaryLabelColor, nil)
        case .starting:
            return (
                "Connecting...",
                .secondaryLabelColor,
                .indeterminate(accessibilityValue: "Starting provider connection")
            )
        case .ready:
            return (selected ? "Selected · Connected" : "Connected", .systemGreen, nil)
        case .correcting:
            return (
                "Correcting...",
                .secondaryLabelColor,
                .indeterminate(accessibilityValue: "Correcting transcript")
            )
        case .failed:
            return ("Connection failed", .systemRed, nil)
        }
    }

    private func model(for sender: NSButton) -> TranscriptEditingModel? {
        guard TranscriptEditingModel.allCases.indices.contains(sender.tag) else { return nil }
        return TranscriptEditingModel.allCases[sender.tag]
    }

    private var selectedModel: TranscriptEditingModel {
        get { TranscriptEditingModel.load(from: defaults) }
        set { TranscriptEditingModel.save(newValue, to: defaults) }
    }

    private func resumeAppleAvailabilityCheckIfNeeded() {
        guard states[.appleFoundation] == .checking else { return }
        let generation = refreshGeneration
        refreshTask = Task { [weak self, service] in
            let availability = await service.availability(for: .appleFoundation)
            guard !Task.isCancelled, self?.refreshGeneration == generation else { return }
            self?.states[.appleFoundation] = switch availability {
            case .available: .available
            case .unavailable(let reason): .unavailable(reason)
            }
            self?.reloadTable()
        }
    }
}
