import AppKit
import TiroEditing

@MainActor
final class TranscriptEditingSettingsView: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
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
    private let table = NSTableView()
    private let storageLabel = NSTextField(labelWithString: "")
    private var localDownloadSpace: LocalTranscriptEditingModelDownloadSpace?
    private var states: [TranscriptEditingModel: ModelState] = [
        .off: .available,
        .appleFoundation: .checking,
        .qwenLocal: .checking,
    ]
    private var refreshTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var isApplyingSelection = false

    init(service: TranscriptEditingService) {
        self.service = service
        super.init(frame: .zero)
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        refreshTask?.cancel()
        operationTask?.cancel()
    }

    func refresh() {
        invalidateRefresh()
        let generation = refreshGeneration
        states[.appleFoundation] = .checking
        if operationTask == nil { states[.qwenLocal] = .checking }
        table.reloadData()
        restoreSelection()
        refreshTask = Task { [weak self, service] in
            async let appleAvailability = service.availability(for: .appleFoundation)
            async let localStatus = service.localModelStatus()
            async let downloadSpace = service.localModelDownloadSpace()
            let results = await (appleAvailability, localStatus, downloadSpace)
            guard !Task.isCancelled, self?.refreshGeneration == generation else { return }
            self?.apply(
                appleAvailability: results.0,
                localStatus: results.1,
                downloadSpace: results.2
            )
        }
    }

    func cancelWork() {
        invalidateRefresh()
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

        storageLabel.font = .systemFont(ofSize: 11)
        storageLabel.textColor = .secondaryLabelColor
        storageLabel.alignment = .right
        storageLabel.isHidden = true
        addArrangedSubview(storageLabel)
        storageLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
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
        guard !isApplyingSelection,
              TranscriptEditingModel.allCases.indices.contains(table.selectedRow) else {
            return
        }
        let model = TranscriptEditingModel.allCases[table.selectedRow]
        guard isSelectable(model) else {
            restoreSelection()
            return
        }
        TranscriptEditingModel.selected = model
        table.reloadData()
        selectRow(for: model)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard TranscriptEditingModel.allCases.indices.contains(row) else { return false }
        return isSelectable(TranscriptEditingModel.allCases[row])
    }

    private func apply(
        appleAvailability: TranscriptEditorAvailability,
        localStatus: LocalTranscriptEditingModelStatus,
        downloadSpace: LocalTranscriptEditingModelDownloadSpace
    ) {
        states[.appleFoundation] = switch appleAvailability {
        case .available: .available
        case .unavailable(let reason): .unavailable(reason)
        }
        states[.qwenLocal] = .local(localStatus)
        apply(downloadSpace: downloadSpace)
        if !canRemainSelected(TranscriptEditingModel.selected) {
            TranscriptEditingModel.selected = .off
            AccessibilityAnnouncements.post("Correction model set to Off.", from: table)
        }
        table.reloadData()
        restoreSelection()
    }

    private func isSelectable(_ model: TranscriptEditingModel) -> Bool {
        switch states[model] {
        case .checking:
            return operationTask == nil && model == TranscriptEditingModel.selected
        default:
            let appleAvailable = states[.appleFoundation] == .available
            let localStatus = localModelStatus
            return Self.allowsSelection(
                of: model,
                appleAvailable: appleAvailable,
                localStatus: localStatus,
                operationInProgress: operationTask != nil
            )
        }
    }

    static func allowsSelection(
        of model: TranscriptEditingModel,
        appleAvailable: Bool,
        localStatus: LocalTranscriptEditingModelStatus,
        operationInProgress: Bool
    ) -> Bool {
        guard !operationInProgress else { return false }
        switch model {
        case .off: return true
        case .appleFoundation: return appleAvailable
        case .qwenLocal:
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

    private var localModelStatus: LocalTranscriptEditingModelStatus {
        switch states[.qwenLocal] {
        case .local(let status), .localError(_, let status): status
        case .checking, .available, .unavailable, .cancelling, .deleting, nil: .notInstalled
        }
    }

    private func restoreSelection() {
        let selected = TranscriptEditingModel.selected
        selectRow(for: canRemainSelected(selected) ? selected : .off)
    }

    private func selectRow(for model: TranscriptEditingModel) {
        guard let row = TranscriptEditingModel.allCases.firstIndex(of: model),
              table.selectedRow != row else { return }
        isApplyingSelection = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isApplyingSelection = false
    }

    private func rowContent(
        for model: TranscriptEditingModel,
        row: Int
    ) -> ModelLibraryRowView.Content {
        let selected = model == TranscriptEditingModel.selected
        let state = states[model] ?? .checking
        let presentation = presentation(for: model, state: state, selected: selected)
        return ModelLibraryRowView.Content(
            name: model.title,
            detail: presentation.detail,
            detailColor: presentation.detailColor,
            detailToolTip: presentation.detailToolTip,
            status: presentation.status,
            statusColor: presentation.statusColor,
            progress: presentation.progress,
            action: action(for: model, state: state, selected: selected, row: row),
            isSelected: selected,
            accessibilityValue: "\(selected ? "Selected model" : presentation.status), "
                + presentation.detail
        )
    }

    private func presentation(
        for model: TranscriptEditingModel,
        state: ModelState,
        selected: Bool
    ) -> (
        detail: String,
        detailColor: NSColor,
        detailToolTip: String?,
        status: String,
        statusColor: NSColor,
        progress: ModelLibraryRowView.ProgressState?
    ) {
        let normalDetail = model.detail
        switch state {
        case .checking:
            return (
                normalDetail, .secondaryLabelColor, nil,
                "Checking...", .tertiaryLabelColor,
                .indeterminate(accessibilityValue: "Checking availability")
            )
        case .available:
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
            if let space = localDownloadSpace, !space.hasEnoughSpace,
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
            let detail = model.detail.replacingOccurrences(
                of: model.downloadSizeDescription,
                with: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            )
            return (
                detail, .secondaryLabelColor, nil,
                selected ? "Selected" : "Installed", .secondaryLabelColor, nil
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
        selected: Bool,
        row: Int
    ) -> ModelLibraryRowView.Action? {
        guard model == .qwenLocal else { return nil }
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
            enabled = operationTask == nil && localDownloadSpace?.hasEnoughSpace != false
            toolTip = enabled ? label : "Not enough space to download \(model.title)"
        case .local(.installing):
            label = "Cancel \(model.title) download"
            symbol = "xmark.circle"
            selector = #selector(cancelLocalModelDownload(_:))
            enabled = true
            toolTip = label
        case .local(.installed):
            label = "Delete \(model.title)"
            symbol = "trash"
            selector = #selector(deleteLocalModel(_:))
            enabled = operationTask == nil && !selected
            toolTip = selected
                ? "Select another correction model before deleting"
                : label
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
                enabled = operationTask == nil && localDownloadSpace?.hasEnoughSpace != false
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
        guard operationTask == nil else { return }
        invalidateRefresh()
        states[.qwenLocal] = .local(.installing)
        table.reloadData()
        AccessibilityAnnouncements.post("Downloading Qwen 3 Local.", from: table)
        operationTask = Task { [weak self, service] in
            let finalState: ModelState
            let announcement: String
            do {
                try await service.installLocalModel()
                finalState = .local(await service.localModelStatus())
                announcement = "Qwen 3 Local installed."
            } catch {
                let status = await service.localModelStatus()
                if Self.isCancellation(error) {
                    finalState = .local(status)
                    announcement = "Qwen 3 Local download cancelled."
                } else {
                    finalState = .localError(error.localizedDescription, status)
                    announcement = "Qwen 3 Local download failed."
                }
            }
            let space = await service.localModelDownloadSpace()
            self?.finishLocalOperation(
                state: finalState,
                downloadSpace: space,
                announcement: announcement
            )
        }
    }

    @objc private func cancelLocalModelDownload(_ sender: NSButton) {
        states[.qwenLocal] = .cancelling
        table.reloadData()
        announce("Cancelling Qwen 3 Local download.")
        operationTask?.cancel()
    }

    @objc private func deleteLocalModel(_ sender: NSButton) {
        guard TranscriptEditingModel.selected != .qwenLocal, operationTask == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Qwen 3 Local?"
        alert.informativeText =
            "The downloaded model file will be removed. You can download it again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performLocalModelDeletion()
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func performLocalModelDeletion() {
        invalidateRefresh()
        states[.qwenLocal] = .deleting
        table.reloadData()
        AccessibilityAnnouncements.post("Deleting Qwen 3 Local.", from: table)
        operationTask = Task { [weak self, service] in
            let finalState: ModelState
            let announcement: String
            do {
                try await service.deleteLocalModel()
                finalState = .local(.notInstalled)
                announcement = "Qwen 3 Local deleted."
            } catch {
                let status = await service.localModelStatus()
                finalState = .localError(error.localizedDescription, status)
                announcement = "Qwen 3 Local could not be deleted."
            }
            let space = await service.localModelDownloadSpace()
            self?.finishLocalOperation(
                state: finalState,
                downloadSpace: space,
                announcement: announcement
            )
        }
    }

    private func finishLocalOperation(
        state: ModelState,
        downloadSpace: LocalTranscriptEditingModelDownloadSpace,
        announcement: String
    ) {
        invalidateRefresh()
        states[.qwenLocal] = state
        apply(downloadSpace: downloadSpace)
        operationTask = nil
        table.reloadData()
        restoreSelection()
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

    private func apply(downloadSpace: LocalTranscriptEditingModelDownloadSpace) {
        localDownloadSpace = downloadSpace
        if let available = downloadSpace.availableBytes {
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
            self?.table.reloadData()
            self?.restoreSelection()
        }
    }
}
