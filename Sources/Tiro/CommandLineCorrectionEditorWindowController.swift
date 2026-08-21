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
    NSTextFieldDelegate {
    var onSave: ((CommandLineCorrectionConfiguration) -> Void)?
    var onDismiss: (() -> Void)?

    private let defaults: UserDefaults
    private let preset: CommandLineCorrectionPreset
    private let executableField = NSTextField()
    private let modelField = NSTextField()
    private let argumentsEditor = CommandArgumentsEditorView()
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private var savedConfiguration = CommandLineCorrectionConfiguration.default
    private var allowsClose = false
    private var discardAlertVisible = false

    init(
        preset: CommandLineCorrectionPreset,
        defaults: UserDefaults = .standard
    ) {
        self.preset = preset
        self.defaults = defaults
        let panel = CommandLineCorrectionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 590),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(preset.title) Correction Command"
        panel.minSize = NSSize(width: 560, height: 480)
        panel.center()
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = makeContentView()
        savedConfiguration = CommandLineCorrectionConfiguration.load(
            preset: preset,
            from: defaults
        )
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

    func controlTextDidChange(_ obj: Notification) {
        updateDocumentEditedState()
    }

    private func makeContentView() -> NSView {
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

        modelField.placeholderString = preset == .custom
            ? "Optional value for {model}"
            : "Model name"
        modelField.setAccessibilityLabel("Command-line correction model")
        modelField.delegate = self

        argumentsEditor.onChange = { [weak self] in
            self?.updateDocumentEditedState()
        }

        let argumentHelp = NSTextField(wrappingLabelWithString:
            "Add one command argument per row. Available placeholders: {model}, {schemaFile}, "
                + "{schemaJSON}, and {outputFile}. A blank row passes an empty argument. "
                + "Schema and output placeholders must occupy a whole row. "
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
            labeledRow("Executable", executableRow),
            labeledRow("Model", modelField),
            sectionLabel("Command Arguments"),
            argumentsEditor,
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
            argumentsEditor.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
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
        executableField.stringValue = configuration.executablePath
        modelField.stringValue = configuration.model
        argumentsEditor.setArguments(configuration.arguments)
        updateDocumentEditedState()
        validationLabel.isHidden = true
    }

    @objc private func restorePreset() {
        load(preset.configuration)
    }

    @objc private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        executableField.stringValue = url.path
        updateDocumentEditedState()
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
        CommandLineCorrectionConfiguration(
            preset: preset,
            executablePath: executableField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines),
            model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: argumentsEditor.arguments
        )
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

@MainActor
private final class CommandArgumentsEditorView: NSView, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate {
    var onChange: (() -> Void)?
    private(set) var arguments: [String] = []

    private let table = NSTableView()
    private let removeButton = NSButton()
    private let moveUpButton = NSButton()
    private let moveDownButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func setArguments(_ arguments: [String]) {
        self.arguments = arguments
        table.reloadData()
        updateButtons()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { arguments.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard arguments.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("CommandArgument")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView) ?? makeCell(identifier: identifier)
        guard let field = cell.textField else { return cell }
        field.stringValue = arguments[row]
        field.tag = row
        field.setAccessibilityLabel("Command argument \(row + 1) of \(arguments.count)")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              arguments.indices.contains(field.tag) else { return }
        arguments[field.tag] = field.stringValue
        onChange?()
    }

    private func buildContent() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("argument"))
        column.title = "Argument"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.rowHeight = 25
        table.setAccessibilityLabel("Command arguments")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table

        let addButton = iconButton(
            symbol: "plus",
            label: "Add command argument",
            action: #selector(addArgument)
        )
        configure(
            removeButton,
            symbol: "minus",
            label: "Remove selected command argument",
            action: #selector(removeArgument)
        )
        configure(
            moveUpButton,
            symbol: "arrow.up",
            label: "Move selected argument up",
            action: #selector(moveArgumentUp)
        )
        configure(
            moveDownButton,
            symbol: "arrow.down",
            label: "Move selected argument down",
            action: #selector(moveArgumentDown)
        )
        let buttons = NSStackView(views: [
            addButton, removeButton, NSView(), moveUpButton, moveDownButton,
        ])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 4

        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        updateButtons()
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func iconButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton()
        configure(button, symbol: symbol, label: label, action: action)
        return button
    }

    private func configure(
        _ button: NSButton,
        symbol: String,
        label: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @objc private func addArgument() {
        arguments.append("")
        let row = arguments.count - 1
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        table.editColumn(0, row: row, with: nil, select: true)
        onChange?()
    }

    @objc private func removeArgument() {
        let row = table.selectedRow
        guard arguments.indices.contains(row) else { return }
        arguments.remove(at: row)
        table.reloadData()
        if !arguments.isEmpty {
            table.selectRowIndexes(
                IndexSet(integer: min(row, arguments.count - 1)),
                byExtendingSelection: false
            )
        }
        updateButtons()
        onChange?()
    }

    @objc private func moveArgumentUp() {
        moveSelectedArgument(by: -1)
    }

    @objc private func moveArgumentDown() {
        moveSelectedArgument(by: 1)
    }

    private func moveSelectedArgument(by offset: Int) {
        let source = table.selectedRow
        let destination = source + offset
        guard arguments.indices.contains(source), arguments.indices.contains(destination) else {
            return
        }
        arguments.swapAt(source, destination)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        updateButtons()
        onChange?()
    }

    private func updateButtons() {
        let row = table.selectedRow
        removeButton.isEnabled = arguments.indices.contains(row)
        moveUpButton.isEnabled = arguments.indices.contains(row) && row > 0
        moveDownButton.isEnabled = arguments.indices.contains(row) && row < arguments.count - 1
    }
}
