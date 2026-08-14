import AppKit

@MainActor
final class SettingsPageViewController: NSViewController {
    private let pageTitle: String
    private let contentView: NSView

    init(title: String, contentView: NSView) {
        pageTitle = title
        self.contentView = contentView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let titleLabel = NSTextField(labelWithString: pageTitle)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleLabel)
        root.addSubview(contentView)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            contentView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        ])
        view = root
    }
}

@MainActor
final class SettingsTabbedContentView: NSView {
    struct Tab {
        let title: String
        let view: NSView
    }

    private let tabs: [Tab]
    private let segmentedControl: NSSegmentedControl
    private let container = NSView()
    private weak var visibleView: NSView?

    private(set) var selectedTabIndex = 0
    var selectedTabTitle: String? {
        tabs.indices.contains(selectedTabIndex) ? tabs[selectedTabIndex].title : nil
    }

    init(tabs: [Tab], accessibilityLabel: String = "Page view") {
        self.tabs = tabs
        segmentedControl = NSSegmentedControl(
            labels: tabs.map(\.title),
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        segmentedControl.setAccessibilityLabel(accessibilityLabel)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        segmentedControl.segmentStyle = .rounded
        segmentedControl.selectedSegment = 0
        segmentedControl.target = self
        segmentedControl.action = #selector(selectionChanged)
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(segmentedControl)
        addSubview(container)
        NSLayoutConstraint.activate([
            segmentedControl.leadingAnchor.constraint(equalTo: leadingAnchor),
            segmentedControl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            segmentedControl.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 16),
            container.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        selectTab(at: 0)
    }

    @objc private func selectionChanged() {
        showTab(at: segmentedControl.selectedSegment, announce: false)
    }

    func selectTab(at index: Int) {
        showTab(at: index, announce: true)
    }

    private func showTab(at index: Int, announce: Bool) {
        guard tabs.indices.contains(index) else { return }
        let changed = selectedTabIndex != index
        selectedTabIndex = index
        segmentedControl.selectedSegment = index
        visibleView?.removeFromSuperview()
        let next = tabs[index].view
        next.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(next)
        NSLayoutConstraint.activate([
            next.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            next.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            next.topAnchor.constraint(equalTo: container.topAnchor),
            next.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        visibleView = next
        if changed && announce {
            NSAccessibility.post(element: segmentedControl, notification: .valueChanged)
        }
    }
}

@MainActor
final class SettingsScrollView: NSScrollView {
    init(document: NSView) {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        document.translatesAutoresizingMaskIntoConstraints = false
        documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: contentView.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}
