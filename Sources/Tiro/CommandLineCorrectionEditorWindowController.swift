import AppKit

private final class CommandLineCorrectionPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        let selector: Selector? = switch (key, shift) {
        case ("a", _): #selector(NSText.selectAll(_:))
        case ("c", _): #selector(NSText.copy(_:))
        case ("x", _): #selector(NSText.cut(_:))
        case ("v", _): #selector(NSText.paste(_:))
        case ("z", false): Selector(("undo:"))
        case ("z", true): Selector(("redo:"))
        default: nil
        }
        guard let selector else { return super.performKeyEquivalent(with: event) }
        return NSApp.sendAction(selector, to: nil, from: self)
    }
}

@MainActor
final class CommandLineCorrectionEditorWindowController: NSWindowController, NSWindowDelegate,
    NSTextViewDelegate, NSTextFieldDelegate {
    var onSave: ((CommandLineCorrectionConfiguration) -> Void)?
    var onDismiss: (() -> Void)?

    private let defaults: UserDefaults
    private let presetButton = NSPopUpButton()
    private let executableField = NSTextField()
    private let modelField = NSTextField()
    private let argumentsView = NSTextView()
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private var savedConfiguration = CommandLineCorrectionConfiguration.default
    private var displayedConfiguration = CommandLineCorrectionConfiguration.default
    private var displayedPreset = CommandLineCorrectionPreset.codex
    private var allowsClose = false
    private var discardAlertVisible = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let panel = CommandLineCorrectionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 590),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Command-Line Correction"
        panel.minSize = NSSize(width: 560, height: 480)
        panel.center()
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = makeContentView()
        savedConfiguration = CommandLineCorrectionConfiguration.load(from: defaults)
        load(savedConfiguration)
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        onDismiss?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !allowsClose, currentConfiguration != savedConfiguration else { return true }
        presentDiscardAlert(on: sender)
        return false
    }

    func textDidChange(_ notification: Notification) {
        updateDocumentEditedState()
    }

    func controlTextDidChange(_ obj: Notification) {
        updateDocumentEditedState()
    }

    private func makeContentView() -> NSView {
        presetButton.addItems(withTitles: CommandLineCorrectionPreset.allCases.map(\.title))
        presetButton.target = self
        presetButton.action = #selector(presetChanged)
        presetButton.setAccessibilityLabel("Command-line correction provider")

        executableField.placeholderString = "/absolute/path/to/executable"
        executableField.setAccessibilityLabel("Correction executable path")
        executableField.delegate = self
        let chooseButton = NSButton(
            image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Choose executable")!,
            target: self,
            action: #selector(chooseExecutable)
        )
        chooseButton.bezelStyle = .rounded
        chooseButton.toolTip = "Choose executable"
        let executableRow = NSStackView(views: [executableField, chooseButton])
        executableRow.orientation = .horizontal
        executableRow.alignment = .centerY
        executableRow.spacing = 8

        modelField.placeholderString = "Optional model name"
        modelField.setAccessibilityLabel("Command-line correction model")
        modelField.delegate = self

        argumentsView.isRichText = false
        argumentsView.isAutomaticQuoteSubstitutionEnabled = false
        argumentsView.isAutomaticDashSubstitutionEnabled = false
        argumentsView.allowsUndo = true
        argumentsView.delegate = self
        argumentsView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        argumentsView.textContainerInset = NSSize(width: 8, height: 8)
        argumentsView.setAccessibilityLabel("Command arguments, one per line")
        let argumentsScroll = NSScrollView()
        argumentsScroll.hasVerticalScroller = true
        argumentsScroll.borderType = .bezelBorder
        argumentsScroll.documentView = argumentsView

        let argumentHelp = NSTextField(wrappingLabelWithString:
            "One argument per line. Available placeholders: {model}, {schemaFile}, "
                + "{schemaJSON}, and {outputFile}. Use \"\" for an empty argument. "
                + "Schema and output placeholders must occupy a whole line. "
                + "The complete prompt is sent through standard input."
        )
        argumentHelp.textColor = .secondaryLabelColor
        argumentHelp.font = .systemFont(ofSize: 11)

        let privacy = NSTextField(wrappingLabelWithString:
            "This executable runs with your user privileges and can access your files, credentials, "
                + "and network. It may send transcripts to an external service. Corrections are "
                + "always shown for review before pasting."
        )
        privacy.textColor = .secondaryLabelColor

        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true

        let resetButton = NSButton(title: "Restore Preset", target: self, action: #selector(restorePreset))
        resetButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [resetButton, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [
            labeledRow("Provider", presetButton),
            labeledRow("Executable", executableRow),
            labeledRow("Model", modelField),
            sectionLabel("Arguments"),
            argumentsScroll,
            argumentHelp,
            privacy,
            validationLabel,
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            argumentsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
        ])
        return root
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 82).isActive = true
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        return label
    }

    private func load(_ configuration: CommandLineCorrectionConfiguration) {
        if let index = CommandLineCorrectionPreset.allCases.firstIndex(of: configuration.preset) {
            presetButton.selectItem(at: index)
        }
        executableField.stringValue = configuration.executablePath
        modelField.stringValue = configuration.model
        argumentsView.string = configuration.argumentsText
        displayedPreset = configuration.preset
        displayedConfiguration = configuration
        updateDocumentEditedState()
        validationLabel.isHidden = true
    }

    private var selectedPreset: CommandLineCorrectionPreset {
        let index = presetButton.indexOfSelectedItem
        return CommandLineCorrectionPreset.allCases.indices.contains(index)
            ? CommandLineCorrectionPreset.allCases[index]
            : .custom
    }

    @objc private func presetChanged() {
        let newPreset = selectedPreset
        guard currentConfiguration(for: displayedPreset) != displayedConfiguration else {
            load(newPreset.configuration)
            return
        }
        selectPreset(displayedPreset)
        let alert = NSAlert()
        alert.messageText = "Replace Unsaved Command Changes?"
        alert.informativeText = "Choosing another provider restores that provider's preset command."
        alert.addButton(withTitle: "Replace Changes")
        alert.addButton(withTitle: "Keep Editing")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.load(newPreset.configuration)
        }
    }

    @objc private func restorePreset() {
        load(selectedPreset.configuration)
    }

    @objc private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        executableField.stringValue = url.path
    }

    @objc private func save() {
        let configuration = currentConfiguration
        do {
            try configuration.save(to: defaults)
            savedConfiguration = configuration
            window?.isDocumentEdited = false
            onSave?(configuration)
            allowsClose = true
            dismiss()
        } catch {
            validationLabel.stringValue = error.localizedDescription
            validationLabel.isHidden = false
            AccessibilityAnnouncements.post(validationLabel.stringValue, from: validationLabel)
        }
    }

    @objc private func cancel() {
        requestDismissal()
    }

    private func dismiss() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.close()
    }

    private var currentConfiguration: CommandLineCorrectionConfiguration {
        currentConfiguration(for: selectedPreset)
    }

    private func currentConfiguration(
        for preset: CommandLineCorrectionPreset
    ) -> CommandLineCorrectionConfiguration {
        CommandLineCorrectionConfiguration(
            preset: preset,
            executablePath: executableField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines),
            model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            argumentsText: argumentsView.string
        )
    }

    private func selectPreset(_ preset: CommandLineCorrectionPreset) {
        guard let index = CommandLineCorrectionPreset.allCases.firstIndex(of: preset) else { return }
        presetButton.selectItem(at: index)
    }

    private func updateDocumentEditedState() {
        window?.isDocumentEdited = currentConfiguration != savedConfiguration
    }

    private func requestDismissal() {
        guard let window, windowShouldClose(window) else { return }
        allowsClose = true
        dismiss()
    }

    private func presentDiscardAlert(on window: NSWindow) {
        guard !discardAlertVisible else { return }
        discardAlertVisible = true
        let alert = NSAlert()
        alert.messageText = "Discard Command Changes?"
        alert.informativeText = "Your unsaved command-line correction settings will be lost."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.discardAlertVisible = false
            guard response == .alertFirstButtonReturn else { return }
            self.allowsClose = true
            self.dismiss()
        }
    }
}
