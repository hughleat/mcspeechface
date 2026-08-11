import AppKit
import TiroEditing

@MainActor
final class TranscriptEditingSettingsView: NSStackView {
    private let service: TranscriptEditingService
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var refreshTask: Task<Void, Never>?

    init(service: TranscriptEditingService) {
        self.service = service
        super.init(frame: .zero)
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    deinit { refreshTask?.cancel() }

    func refresh() {
        let selection = TranscriptEditingModel.selected
        picker.selectItem(at: TranscriptEditingModel.allCases.firstIndex(of: selection) ?? 0)
        updateStatus(for: selection)
    }

    func cancelWork() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 6

        picker.addItems(withTitles: TranscriptEditingModel.allCases.map(\.title))
        picker.target = self
        picker.action = #selector(selectionChanged)
        picker.setAccessibilityLabel("Spoken corrections model")

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let title = NSTextField(labelWithString: "Model")
        title.textColor = .secondaryLabelColor
        title.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [title, NSView(), picker])
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
        if selection == .off {
            statusLabel.stringValue = "Spoken corrections are off."
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
}
