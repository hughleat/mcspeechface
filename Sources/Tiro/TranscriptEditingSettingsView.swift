import AppKit
import TiroEditing

@MainActor
final class TranscriptEditingSettingsView: NSStackView {
    private let service: TranscriptEditingService
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton()
    private let progressIndicator = NSProgressIndicator()
    private var refreshTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var localModelStatus = LocalTranscriptEditingModelStatus.notInstalled

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
        let selection = TranscriptEditingModel.selected
        picker.selectItem(at: TranscriptEditingModel.allCases.firstIndex(of: selection) ?? 0)
        updateStatus(for: selection)
    }

    func cancelWork() {
        refreshTask?.cancel()
        refreshTask = nil
        operationTask?.cancel()
        operationTask = nil
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 6

        picker.addItems(withTitles: TranscriptEditingModel.allCases.map(\.title))
        picker.target = self
        picker.action = #selector(selectionChanged)
        picker.setAccessibilityLabel("Spoken corrections model")

        actionButton.target = self
        actionButton.action = #selector(performModelAction)
        actionButton.bezelStyle = .rounded
        actionButton.isHidden = true

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let title = NSTextField(labelWithString: "Model")
        title.textColor = .secondaryLabelColor
        title.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [title, NSView(), progressIndicator, actionButton, picker])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        addArrangedSubview(row)
        addArrangedSubview(statusLabel)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        statusLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
    }

    @objc private func selectionChanged() {
        let index = picker.indexOfSelectedItem
        guard TranscriptEditingModel.allCases.indices.contains(index) else { return }
        let selection = TranscriptEditingModel.allCases[index]
        TranscriptEditingModel.selected = selection
        updateStatus(for: selection)
    }

    private func updateStatus(for selection: TranscriptEditingModel) {
        refreshTask?.cancel()
        actionButton.isHidden = true
        if selection == .off {
            statusLabel.stringValue = "Spoken corrections are off."
            return
        }
        if selection == .qwenLocal {
            updateLocalModelStatus()
            return
        }
        statusLabel.stringValue = "Checking local model availability..."
        refreshTask = Task { [weak self, service] in
            let availability = await service.availability(for: selection)
            guard !Task.isCancelled, TranscriptEditingModel.selected == selection else { return }
            switch availability {
            case .available:
                self?.statusLabel.stringValue = "Ready. Transcript analysis stays on this Mac."
            case .unavailable(let reason):
                self?.statusLabel.stringValue = reason
            }
        }
    }

    private func updateLocalModelStatus() {
        statusLabel.stringValue = "Checking local model..."
        refreshTask = Task { [weak self, service] in
            let status = await service.localModelStatus()
            guard !Task.isCancelled, TranscriptEditingModel.selected == .qwenLocal else {
                return
            }
            self?.apply(status)
        }
    }

    private func apply(_ status: LocalTranscriptEditingModelStatus) {
        localModelStatus = status
        actionButton.isHidden = false
        switch status {
        case .notInstalled:
            progressIndicator.stopAnimation(nil)
            statusLabel.stringValue = "Download 1.28 GB. Analysis stays on this Mac."
            configureAction(title: "Download", symbol: "arrow.down.circle")
        case .installing:
            progressIndicator.startAnimation(nil)
            statusLabel.stringValue = "Downloading and verifying Qwen 3 Local..."
            configureAction(title: "Cancel", symbol: "xmark")
        case .installed(let bytes):
            progressIndicator.stopAnimation(nil)
            statusLabel.stringValue = "Ready · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
            configureAction(title: "Remove", symbol: "trash")
        }
    }

    private func configureAction(title: String, symbol: String) {
        actionButton.title = title
        actionButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        actionButton.imagePosition = .imageLeading
        actionButton.isEnabled = true
    }

    @objc private func performModelAction() {
        switch localModelStatus {
        case .notInstalled:
            installLocalModel()
        case .installing:
            operationTask?.cancel()
            actionButton.isEnabled = false
            statusLabel.stringValue = "Cancelling download..."
        case .installed:
            confirmLocalModelRemoval()
        }
    }

    private func installLocalModel() {
        operationTask?.cancel()
        apply(.installing)
        operationTask = Task { [weak self, service] in
            do {
                try await service.installLocalModel()
                guard !Task.isCancelled else { return }
                let status = await service.localModelStatus()
                if TranscriptEditingModel.selected == .qwenLocal {
                    self?.apply(status)
                }
            } catch is CancellationError {
                let status = await service.localModelStatus()
                if TranscriptEditingModel.selected == .qwenLocal {
                    self?.apply(status)
                }
            } catch {
                if TranscriptEditingModel.selected == .qwenLocal {
                    self?.progressIndicator.stopAnimation(nil)
                    self?.statusLabel.stringValue = error.localizedDescription
                    self?.configureAction(title: "Retry", symbol: "arrow.clockwise")
                    self?.localModelStatus = .notInstalled
                }
            }
            self?.operationTask = nil
        }
    }

    private func confirmLocalModelRemoval() {
        let alert = NSAlert()
        alert.messageText = "Remove Qwen 3 Local?"
        alert.informativeText = "You can download the model again later."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        operationTask = Task { [weak self, service] in
            do {
                try await service.deleteLocalModel()
                TranscriptEditingModel.selected = .off
                self?.refresh()
            } catch {
                self?.statusLabel.stringValue = error.localizedDescription
            }
            self?.operationTask = nil
        }
    }
}
