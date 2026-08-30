import AppKit

@MainActor
final class SettingsInfoButton: NSButton, NSPopoverDelegate {
    let topic: String
    let helpText: String

    private(set) var helpPopover: NSPopover?
    private var outsideClickMonitor: Any?
    private weak var observedWindow: NSWindow?

    init(topic: String, helpText: String) {
        self.topic = topic
        self.helpText = helpText
        super.init(frame: .zero)

        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        imagePosition = .imageOnly
        bezelStyle = .inline
        isBordered = false
        controlSize = .small
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(toggleHelp)
        toolTip = "About \(topic)"
        setAccessibilityLabel("About \(topic)")
        setAccessibilityHelp(helpText)
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func toggleHelp() {
        if helpPopover?.isShown == true {
            closeHelp()
            return
        }

        let title = NSTextField(labelWithString: topic)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let message = NSTextField(wrappingLabelWithString: helpText)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 0

        let content = NSStackView(views: [title, message])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        message.widthAnchor.constraint(equalToConstant: 272).isActive = true

        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 300, height: content.fittingSize.height)
        helpPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        monitorOutsideClicks()
    }

    func popoverDidClose(_ notification: Notification) {
        stopMonitoringDismissal()
    }

    private func closeHelp() {
        helpPopover?.close()
        stopMonitoringDismissal()
    }

    private func monitorOutsideClicks() {
        stopMonitoringDismissal()
        observedWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closeHelpAfterDeactivation),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        if let observedWindow {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(closeHelpAfterDeactivation),
                name: NSWindow.willCloseNotification,
                object: observedWindow
            )
        }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, helpPopover?.isShown == true else { return event }
            if event.window === window,
               bounds.contains(convert(event.locationInWindow, from: nil)) {
                return event
            }
            if event.window === helpPopover?.contentViewController?.view.window {
                return event
            }
            closeHelp()
            return event
        }
    }

    @objc private func closeHelpAfterDeactivation() {
        closeHelp()
    }

    private func stopMonitoringDismissal() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: observedWindow
            )
        }
        observedWindow = nil
    }
}

@MainActor
final class SettingsInfoLabel: NSStackView {
    init(
        _ title: String,
        helpText: String,
        font: NSFont? = nil,
        textColor: NSColor? = nil
    ) {
        let label = NSTextField(labelWithString: title)
        label.font = font
        label.textColor = textColor
        let info = SettingsInfoButton(topic: title, helpText: helpText)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        addArrangedSubview(label)
        addArrangedSubview(info)
    }

    required init?(coder: NSCoder) { nil }
}
