import AppKit
import McSpeechfaceEditing

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
    private let service: TranscriptEditingService?
    private let executableField = NSTextField()
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelField = NSTextField()
    private var modelFieldRow: NSView?
    private let connectionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let connectionDetail = NSTextField(wrappingLabelWithString: "")
    private let accessPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let accessDetail = NSTextField(wrappingLabelWithString: "")
    private let effortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let idlePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let argumentsEditor = CommandArgumentsEditorView()
    private let argumentsSection = NSStackView()
    private let commandPreview = NSTextView()
    private let commandPreviewLabel = NSTextField(labelWithString: "Command Line Preview")
    private let commandPreviewScroll = NSScrollView()
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private let connectionButton = NSButton()
    private var savedConfiguration = CommandLineCorrectionConfiguration.default
    private var modelOptions: [CorrectionProviderModelOption] = []
    private var allowsClose = false
    private var discardAlertVisible = false
    private var discoveryTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var runtimeRefreshTask: Task<Void, Never>?
    private var testedConfiguration: CommandLineCorrectionConfiguration?
    private var connectionState = PersistentCorrectionRuntimeState.stopped
    private var customModelSelected = false
    private var lastUsesCommandLine: Bool?

    init(
        preset: CommandLineCorrectionPreset,
        defaults: UserDefaults = .standard,
        service: TranscriptEditingService? = nil
    ) {
        self.preset = preset
        self.defaults = defaults
        self.service = service
        let panel = CommandLineCorrectionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: preset == .custom ? 610 : 430),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = preset == .custom ? "Custom Correction Command" : "\(preset.title) Correction"
        panel.minSize = NSSize(width: 580, height: preset == .custom ? 500 : 420)
        panel.center()
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = makeContentView()
        savedConfiguration = CommandLineCorrectionConfiguration.load(preset: preset, from: defaults)
        load(savedConfiguration)
        discoverModelsIfAvailable()
        refreshConnectionButton()
        beginRuntimePolling()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        discoveryTask?.cancel()
        connectionTask?.cancel()
        runtimeRefreshTask?.cancel()
    }

    func windowWillClose(_ notification: Notification) {
        let shouldStopProvider = connectionTask != nil
            || (testedConfiguration != nil && testedConfiguration != savedConfiguration)
        connectionTask?.cancel()
        runtimeRefreshTask?.cancel()
        if shouldStopProvider, let service {
            let model = TranscriptEditingModel.model(for: preset)
            Task { await service.stopPersistentProvider(model) }
        }
        onDismiss?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !allowsClose, currentConfiguration != savedConfiguration else { return true }
        presentDiscardAlert(on: sender)
        return false
    }

    func controlTextDidChange(_ obj: Notification) { controlsChanged() }

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

        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.setAccessibilityLabel("Correction model")
        modelField.placeholderString = preset == .custom ? "Optional value for {model}" : "Model ID"
        modelField.setAccessibilityLabel("Command-line correction model")
        modelField.delegate = self

        for mode in CorrectionProviderConnectionMode.allCases {
            connectionPopup.addItem(withTitle: mode.title)
            connectionPopup.lastItem?.representedObject = mode.rawValue
        }
        connectionPopup.target = self
        connectionPopup.action = #selector(controlsChanged)
        connectionPopup.setAccessibilityLabel("Provider connection mode")
        connectionDetail.textColor = .secondaryLabelColor
        connectionDetail.font = .systemFont(ofSize: 11)

        for profile in CorrectionProviderAccessProfile.allCases {
            accessPopup.addItem(withTitle: profile.title)
            accessPopup.lastItem?.representedObject = profile.rawValue
        }
        accessPopup.target = self
        accessPopup.action = #selector(accessChanged)
        accessPopup.setAccessibilityLabel("Provider access")
        accessDetail.textColor = .secondaryLabelColor
        accessDetail.font = .systemFont(ofSize: 11)

        for effort in CorrectionProviderReasoningEffort.allCases {
            effortPopup.addItem(withTitle: effort.title)
            effortPopup.lastItem?.representedObject = effort.rawValue
        }
        effortPopup.target = self
        effortPopup.action = #selector(controlsChanged)
        effortPopup.setAccessibilityLabel("Reasoning effort")

        for (title, seconds) in [
            ("1 minute", 60), ("5 minutes", 300), ("10 minutes", 600),
            ("30 minutes", 1_800), ("1 hour", 3_600), ("Never", 0),
        ] {
            idlePopup.addItem(withTitle: title)
            idlePopup.lastItem?.tag = seconds
        }
        idlePopup.target = self
        idlePopup.action = #selector(controlsChanged)
        idlePopup.setAccessibilityLabel("Stop idle provider after")

        argumentsEditor.onChange = { [weak self] in self?.controlsChanged() }
        let argumentHelp = NSTextField(wrappingLabelWithString:
            "Add one argument per row. Available placeholders: {model}, {schemaFile}, "
                + "{schemaJSON}, and {outputFile}. The complete prompt is sent through standard input."
        )
        argumentHelp.textColor = .secondaryLabelColor
        argumentHelp.font = .systemFont(ofSize: 11)
        argumentsSection.orientation = .vertical
        argumentsSection.alignment = .leading
        argumentsSection.spacing = 8
        argumentsSection.addArrangedSubview(sectionLabel("Command Arguments"))
        argumentsSection.addArrangedSubview(argumentsEditor)
        argumentsSection.addArrangedSubview(argumentHelp)
        for view in argumentsSection.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: argumentsSection.widthAnchor).isActive = true
        }

        commandPreview.isEditable = false
        commandPreview.isSelectable = true
        commandPreview.drawsBackground = false
        commandPreview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandPreview.textColor = .secondaryLabelColor
        commandPreview.textContainerInset = NSSize(width: 6, height: 6)
        commandPreview.setAccessibilityLabel("Generated correction command")
        commandPreviewLabel.font = .systemFont(ofSize: 13, weight: .medium)
        commandPreviewScroll.borderType = .bezelBorder
        commandPreviewScroll.hasVerticalScroller = true
        commandPreviewScroll.documentView = commandPreview
        commandPreviewScroll.heightAnchor.constraint(equalToConstant: 92).isActive = true

        let privacy = NSTextField(wrappingLabelWithString:
            "Transcripts may be sent to \(preset.title). Corrections are validated and shown for "
                + "review before pasting. Access controls apply only to correction sessions."
        )
        privacy.textColor = .secondaryLabelColor
        privacy.font = .systemFont(ofSize: 11)
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true

        let resetButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restorePreset))
        resetButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        connectionButton.title = "Start Provider"
        connectionButton.image = NSImage(
            systemSymbolName: "bolt.horizontal",
            accessibilityDescription: nil
        )
        connectionButton.imagePosition = .imageLeading
        connectionButton.bezelStyle = .rounded
        connectionButton.target = self
        connectionButton.action = #selector(toggleProviderConnection)
        connectionButton.isHidden = preset == .custom
        let buttons = NSStackView(views: [
            resetButton, connectionButton, NSView(), cancelButton, saveButton,
        ])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        var views: [NSView] = [labeledRow("Executable", executableRow)]
        if preset == .custom {
            views += [labeledRow("Model", modelField), argumentsSection]
        } else {
            let customModelRow = labeledRow("Custom model", modelField)
            modelFieldRow = customModelRow
            views += [
                labeledRow("Model", modelPopup),
                customModelRow,
                labeledRow("Effort", effortPopup),
                labeledRow("Connection", connectionPopup),
                connectionDetail,
                labeledRow("Access", accessPopup),
                accessDetail,
                labeledRow("Stop after", idlePopup),
                argumentsSection,
                commandPreviewLabel,
                commandPreviewScroll,
            ]
        }
        views += [privacy, validationLabel, buttons]
        let stack = NSStackView(views: views)
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
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
            preset == .custom
                ? argumentsEditor.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
                : modelPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        return root
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 98).isActive = true
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
        modelOptions = configuration.modelOptions
        customModelSelected = !modelOptions.contains(where: { $0.id == configuration.model })
        populateModelPopup(selecting: configuration.model, preferCustom: customModelSelected)
        select(connectionPopup, rawValue: configuration.connectionMode.rawValue)
        select(accessPopup, rawValue: configuration.accessProfile.rawValue)
        select(effortPopup, rawValue: configuration.reasoningEffort.rawValue)
        idlePopup.selectItem(withTag: configuration.idleTimeoutSeconds)
        if idlePopup.selectedItem == nil {
            idlePopup.addItem(withTitle: Self.timeoutTitle(configuration.idleTimeoutSeconds))
            idlePopup.lastItem?.tag = configuration.idleTimeoutSeconds
            idlePopup.select(idlePopup.lastItem)
        }
        updateAccessDetail()
        updateModelFieldVisibility()
        updateConnectionControl()
        updateCommandPreview()
        updateDocumentEditedState()
        validationLabel.isHidden = true
    }

    private func populateModelPopup(selecting model: String, preferCustom: Bool = false) {
        modelPopup.removeAllItems()
        for option in modelOptions {
            modelPopup.addItem(withTitle: "\(option.title) · \(option.detail)")
            modelPopup.lastItem?.representedObject = option.id
        }
        modelPopup.menu?.addItem(.separator())
        modelPopup.addItem(withTitle: "Custom model…")
        modelPopup.lastItem?.representedObject = ""
        if !preferCustom, let index = modelOptions.firstIndex(where: { $0.id == model }) {
            modelPopup.selectItem(at: index)
        } else {
            modelPopup.selectItem(at: modelPopup.numberOfItems - 1)
        }
    }

    private func discoverModelsIfAvailable() {
        guard preset == .codex, let service else { return }
        discoveryTask = Task { [weak self, service] in
            guard let models = try? await service.discoverCodexModels(), !models.isEmpty else { return }
            let options = models.map {
                CorrectionProviderModelOption(id: $0.id, title: $0.title, detail: $0.detail)
            }
            guard !Task.isCancelled, let self else { return }
            let wasCustom = self.customModelSelected
            let selected = self.selectedModel
            self.modelOptions = options
            self.populateModelPopup(selecting: selected, preferCustom: wasCustom)
            self.updateModelFieldVisibility()
            self.updateCommandPreview()
            self.refreshConnectionButton()
            AccessibilityAnnouncements.post(
                "Available Codex models updated.",
                from: self.modelPopup
            )
        }
    }

    private func beginRuntimePolling() {
        guard preset != .custom, let service else { return }
        runtimeRefreshTask = Task { [weak self, service] in
            while !Task.isCancelled {
                guard let self else { return }
                let states = await service.persistentProviderStates()
                guard !Task.isCancelled else { return }
                self.applyConnectionState(
                    states[TranscriptEditingModel.model(for: self.preset)] ?? .stopped
                )
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func refreshConnectionButton() {
        guard preset != .custom, let service else { return }
        Task { [weak self, service] in
            let states = await service.persistentProviderStates()
            guard let self else { return }
            self.applyConnectionState(
                states[TranscriptEditingModel.model(for: self.preset)] ?? .stopped
            )
        }
    }

    private func applyConnectionState(_ state: PersistentCorrectionRuntimeState) {
        connectionState = state
        connectionButton.title = state.isRunning ? "Stop Provider" : "Start Provider"
        connectionButton.image = NSImage(
            systemSymbolName: state.isRunning ? "stop.circle" : "bolt.horizontal",
            accessibilityDescription: nil
        )
        connectionButton.setAccessibilityHelp(
            state.isRunning
                ? "\(preset.title) is running. Stop the provider."
                : "Start \(preset.title) and keep it ready for correction."
        )
        updateConnectionControl()
    }

    @objc private func toggleProviderConnection() {
        guard let service, connectionTask == nil else { return }
        let configuration = currentConfiguration
        do {
            try configuration.validate()
        } catch {
            showValidationError(error)
            return
        }
        performProviderToggle(
            configuration: configuration,
            service: service,
            sensitiveAccessConfirmed: false
        )
    }

    private func performProviderToggle(
        configuration: CommandLineCorrectionConfiguration,
        service: TranscriptEditingService,
        sensitiveAccessConfirmed: Bool
    ) {
        guard connectionTask == nil else { return }
        let model = TranscriptEditingModel.model(for: preset)
        connectionButton.isEnabled = false
        validationLabel.isHidden = true
        connectionTask = Task { [weak self, service] in
            let states = await service.persistentProviderStates()
            var announcement: String?
            do {
                if states[model]?.isRunning == true {
                    if await service.stopPersistentProvider(model) {
                        self?.testedConfiguration = nil
                        announcement = "\(self?.preset.title ?? "Provider") stopped."
                    } else {
                        announcement = "The provider is currently correcting a transcript."
                    }
                } else if let self {
                    if self.sensitiveWarning(for: configuration) != nil,
                       !sensitiveAccessConfirmed {
                        self.connectionTask = nil
                        self.refreshConnectionButton()
                        self.confirmSensitiveAccess(configuration) { [weak self] in
                            self?.performProviderToggle(
                                configuration: configuration,
                                service: service,
                                sensitiveAccessConfirmed: true
                            )
                        }
                        return
                    }
                    try await service.preparePersistentProvider(model, configuration: configuration)
                    self.testedConfiguration = configuration
                    announcement = "\(self.preset.title) is ready."
                }
            } catch {
                self?.showValidationError(error)
            }
            if let self, let announcement {
                AccessibilityAnnouncements.post(announcement, from: self.connectionButton)
            }
            self?.refreshConnectionButton()
            self?.connectionTask = nil
        }
    }

    @objc private func restorePreset() { load(preset.configuration) }

    @objc private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        executableField.stringValue = url.path
        controlsChanged()
    }

    @objc private func modelChanged() {
        if let represented = modelPopup.selectedItem?.representedObject as? String,
           !represented.isEmpty {
            customModelSelected = false
            modelField.stringValue = represented
        } else {
            customModelSelected = true
        }
        updateModelFieldVisibility()
        controlsChanged()
    }

    @objc private func accessChanged() {
        updateAccessDetail()
        controlsChanged()
    }

    @objc private func controlsChanged() {
        updateConnectionControl()
        updateCommandPreview()
        updateDocumentEditedState()
    }

    @objc private func save() {
        let configuration = currentConfiguration
        if sensitiveWarning(for: configuration) != nil {
            confirmSensitiveAccess(configuration) { [weak self] in
                self?.persist(configuration)
            }
        } else {
            persist(configuration)
        }
    }

    private func confirmSensitiveAccess(
        _ configuration: CommandLineCorrectionConfiguration,
        action: @escaping () -> Void
    ) {
        guard let warning = sensitiveWarning(for: configuration) else {
            action()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.title
        alert.informativeText = warning.detail
        alert.addButton(withTitle: "Allow Access")
        alert.addButton(withTitle: "Cancel")
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            action()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }

    private func sensitiveWarning(
        for configuration: CommandLineCorrectionConfiguration
    ) -> (title: String, detail: String)? {
        if configuration.usesExplicitArguments {
            return (
                "Allow Custom Command Arguments?",
                "Dictated text is untrusted input. These arguments control the provider's "
                    + "tools, permissions, and access independently of the disabled controls above."
            )
        }
        guard configuration.accessProfile.requiresWarning else { return nil }
        return (
            configuration.accessProfile.warningTitle,
            configuration.accessProfile.warningDetail
        )
    }

    private func persist(_ configuration: CommandLineCorrectionConfiguration) {
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

    @objc private func cancel() { requestDismissal() }

    private func dismiss() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.close()
    }

    private var selectedModel: String {
        guard preset != .custom else {
            return modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = modelPopup.selectedItem?.representedObject as? String, !value.isEmpty {
            return value
        }
        return modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentConfiguration: CommandLineCorrectionConfiguration {
        CommandLineCorrectionConfiguration(
            preset: preset,
            executablePath: executableField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            model: selectedModel,
            arguments: argumentsEditor.arguments,
            connectionMode: selectedConnectionMode,
            accessProfile: selectedAccessProfile,
            reasoningEffort: selectedEffort,
            idleTimeoutSeconds: idlePopup.selectedTag()
        )
    }

    private var selectedConnectionMode: CorrectionProviderConnectionMode {
        selected(connectionPopup) ?? .commandLine
    }

    private var selectedAccessProfile: CorrectionProviderAccessProfile {
        selected(accessPopup) ?? .correctionOnly
    }

    private var selectedEffort: CorrectionProviderReasoningEffort {
        selected(effortPopup) ?? .automatic
    }

    private func selected<T: RawRepresentable>(_ popup: NSPopUpButton) -> T? where T.RawValue == String {
        guard let rawValue = popup.selectedItem?.representedObject as? String else { return nil }
        return T(rawValue: rawValue)
    }

    private func select(_ popup: NSPopUpButton, rawValue: String) {
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == rawValue }) {
            popup.select(item)
        }
    }

    private func updateModelFieldVisibility() {
        modelFieldRow?.isHidden =
            (modelPopup.selectedItem?.representedObject as? String)?.isEmpty == false
    }

    private func updateAccessDetail() {
        accessDetail.stringValue = selectedAccessProfile.detail
        accessDetail.textColor = selectedAccessProfile.requiresWarning ? .systemRed : .secondaryLabelColor
    }

    private func updateConnectionControl() {
        let usesCommandLine = selectedConnectionMode == .commandLine
        let usesExplicitArguments = currentConfiguration.usesExplicitArguments
        connectionDetail.stringValue = selectedConnectionMode.detail
            + (usesExplicitArguments
                ? " Custom arguments set access and effort; clear them to use those controls."
                : "")
        accessPopup.isEnabled = !usesExplicitArguments
        effortPopup.isEnabled = !usesExplicitArguments
        argumentsSection.isHidden = !usesCommandLine
        commandPreviewLabel.isHidden = !usesCommandLine
        commandPreviewScroll.isHidden = !usesCommandLine
        connectionButton.isEnabled = connectionState != .starting
            && connectionState != .correcting
            && (connectionState.isRunning || selectedConnectionMode == .enhanced)
        resizePanelIfNeeded(usesCommandLine: usesCommandLine)
    }

    private func resizePanelIfNeeded(usesCommandLine: Bool) {
        guard preset != .custom, lastUsesCommandLine != usesCommandLine, let window else { return }
        lastUsesCommandLine = usesCommandLine
        let targetHeight: CGFloat = usesCommandLine ? 650 : 430
        window.minSize = NSSize(width: 580, height: usesCommandLine ? 560 : 420)
        window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: targetHeight))
    }

    private func updateCommandPreview() {
        guard preset != .custom else { return }
        let configuration = currentConfiguration
        commandPreview.string = ([configuration.executablePath] + configuration.effectiveArguments.map {
            $0.replacingOccurrences(of: "{model}", with: configuration.model)
        }).map(Self.shellQuoted).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:{}"))
        if value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func timeoutTitle(_ seconds: Int) -> String {
        guard seconds % 60 == 0 else { return "\(seconds) seconds" }
        let minutes = seconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private func updateDocumentEditedState() {
        window?.isDocumentEdited = currentConfiguration != savedConfiguration
    }

    private func showValidationError(_ error: Error) {
        validationLabel.stringValue = error.localizedDescription
        validationLabel.isHidden = false
        AccessibilityAnnouncements.post(error.localizedDescription, from: validationLabel)
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
        alert.messageText = "Discard Provider Changes?"
        alert.informativeText = "Your unsaved \(preset.title) correction settings will be lost."
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
