import AppKit

@MainActor
final class ModelLibraryRowView: NSTableCellView {
    enum ProgressState {
        case determinate(value: Double, accessibilityValue: String)
        case indeterminate(accessibilityValue: String)
    }

    struct Action {
        let label: String
        let symbol: String
        let isEnabled: Bool
        let toolTip: String
        let tag: Int
        let target: AnyObject
        let selector: Selector
    }

    struct Content {
        let name: String
        let detail: String
        let detailColor: NSColor
        let detailToolTip: String?
        let status: String
        let statusColor: NSColor
        let progress: ProgressState?
        let action: Action?
        let isSelected: Bool
        let accessibilityValue: String
    }

    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let actionButton = NSButton()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func configure(with content: Content) {
        nameLabel.stringValue = content.name
        detailLabel.stringValue = content.detail
        detailLabel.textColor = content.detailColor
        detailLabel.toolTip = content.detailToolTip
        statusLabel.stringValue = content.status
        statusLabel.textColor = content.statusColor
        configureProgress(content.progress)
        configureAction(content.action)

        setAccessibilityLabel(content.name)
        let blockedReason = content.action.flatMap { action in
            action.isEnabled ? nil : action.toolTip
        }
        setAccessibilityValue(
            [content.accessibilityValue, blockedReason]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        setAccessibilitySelected(content.isSelected)
    }

    private func buildContent() {
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.alignment = .right

        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.setAccessibilityLabel("Model operation progress")

        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let trailing = NSStackView(views: [statusLabel, progressIndicator, actionButton])
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 8
        labels.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        addSubview(trailing)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -10),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 88),
            actionButton.widthAnchor.constraint(equalToConstant: 28),
            actionButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        nameLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        detailLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
    }

    private func configureProgress(_ state: ProgressState?) {
        switch state {
        case .determinate(let value, let accessibilityValue):
            progressIndicator.isHidden = false
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = value
            progressIndicator.startAnimation(nil)
            progressIndicator.setAccessibilityValue(accessibilityValue)
        case .indeterminate(let accessibilityValue):
            progressIndicator.isHidden = false
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
            progressIndicator.setAccessibilityValue(accessibilityValue)
        case nil:
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            progressIndicator.setAccessibilityValue(nil)
        }
    }

    private func configureAction(_ action: Action?) {
        guard let action else {
            actionButton.isHidden = true
            actionButton.target = nil
            actionButton.action = nil
            actionButton.toolTip = nil
            actionButton.setAccessibilityHelp(nil)
            return
        }
        actionButton.image = NSImage(
            systemSymbolName: action.symbol,
            accessibilityDescription: action.label
        )
        actionButton.imagePosition = .imageOnly
        actionButton.bezelStyle = .texturedRounded
        actionButton.isBordered = false
        actionButton.tag = action.tag
        actionButton.target = action.target
        actionButton.action = action.selector
        actionButton.isHidden = false
        actionButton.isEnabled = action.isEnabled
        actionButton.toolTip = action.toolTip
        actionButton.setAccessibilityLabel(action.label)
        actionButton.setAccessibilityHelp(action.toolTip)
    }
}
