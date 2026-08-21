import AppKit
import TiroEditing

private final class PromptTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (key, modifiers) {
        case ("a", [.command]):
            selectAll(nil)
        case ("c", [.command]):
            copy(nil)
        case ("x", [.command]):
            cut(nil)
        case ("v", [.command]):
            paste(nil)
        case ("z", [.command]):
            guard undoManager?.canUndo == true else {
                return super.performKeyEquivalent(with: event)
            }
            undoManager?.undo()
        case ("z", [.command, .shift]):
            guard undoManager?.canRedo == true else {
                return super.performKeyEquivalent(with: event)
            }
            undoManager?.redo()
        case ("f", [.command]):
            showFindPanel(.showFindInterface)
        case ("g", [.command]):
            showFindPanel(.nextMatch)
        case ("g", [.command, .shift]):
            showFindPanel(.previousMatch)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func showFindPanel(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performFindPanelAction(sender)
    }
}

@MainActor
final class TranscriptEditingPromptEditorWindowController: NSWindowController,
    NSWindowDelegate,
    NSTextViewDelegate {
    var onDismiss: (() -> Void)?

    private let preferences: TranscriptEditingPromptPreferences
    private let systemPromptTextView = PromptTextView()
    private let userPromptTextView = PromptTextView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var loadedConfiguration = TranscriptEditingPromptConfiguration.default
    private var isApplyingConfiguration = false
    private var allowsClose = false
    private var discardAlertVisible = false

    init(preferences: TranscriptEditingPromptPreferences = .init()) {
        self.preferences = preferences
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 570),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Correction Prompts"
        window.minSize = NSSize(width: 560, height: 490)
        super.init(window: window)
        window.delegate = self
        buildContent()
        load()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        onDismiss?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !allowsClose, sender.isDocumentEdited else { return true }
        presentDiscardAlert(on: sender)
        return false
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingConfiguration else { return }
        statusLabel.isHidden = true
        setPromptAccessibilityHelp()
        window?.isDocumentEdited = currentConfiguration != loadedConfiguration
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        let systemPromptLabel = NSTextField(labelWithString: "System Prompt")
        systemPromptLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let systemPromptScroll = makeEditor(
            systemPromptTextView,
            accessibilityLabel: "Correction system prompt"
        )
        let userPromptLabel = NSTextField(labelWithString: "User Prompt Template")
        userPromptLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let userPromptScroll = makeEditor(
            userPromptTextView,
            accessibilityLabel: "Correction user prompt template"
        )
        let splitView = makeEditorSplitView(
            systemLabel: systemPromptLabel,
            systemEditor: systemPromptScroll,
            userLabel: userPromptLabel,
            userEditor: userPromptScroll
        )
        setPromptAccessibilityHelp()
        let riskLabel = NSTextField(
            wrappingLabelWithString: "These are the complete prompts sent to the model. Custom "
                + "prompts permit unrestricted rewrites, so results are always shown for review."
        )
        riskLabel.font = .systemFont(ofSize: 11)
        riskLabel.textColor = .secondaryLabelColor
        let placeholderLabel = NSTextField(
            wrappingLabelWithString: "The user prompt must contain {transcript}. {language} inserts the selected "
                + "transcription language; {languageLine} inserts a complete Language line, or "
                + "nothing when language is automatic."
        )
        placeholderLabel.font = .systemFont(ofSize: 11)
        placeholderLabel.textColor = .secondaryLabelColor

        statusLabel.textColor = .systemRed
        statusLabel.isHidden = true
        statusLabel.maximumNumberOfLines = 2

        let resetButton = NSButton(
            title: "Use Defaults",
            target: self,
            action: #selector(resetDefaults)
        )
        resetButton.bezelStyle = .rounded
        let cancelButton = NSButton(
            title: "Cancel",
            target: self,
            action: #selector(cancel)
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(
            title: "Save",
            target: self,
            action: #selector(save)
        )
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [resetButton, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        let stack = NSStackView(views: [
            splitView,
            riskLabel,
            placeholderLabel,
            statusLabel,
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: splitView)
        stack.setCustomSpacing(12, after: placeholderLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            splitView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            riskLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            placeholderLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window?.initialFirstResponder = systemPromptTextView
        systemPromptTextView.nextKeyView = userPromptTextView
        userPromptTextView.nextKeyView = resetButton
    }

    private func makeEditorSplitView(
        systemLabel: NSTextField,
        systemEditor: NSScrollView,
        userLabel: NSTextField,
        userEditor: NSScrollView
    ) -> NSSplitView {
        func makePane(label: NSTextField, editor: NSScrollView) -> NSStackView {
            let pane = NSStackView(views: [label, editor])
            pane.orientation = .vertical
            pane.alignment = .leading
            pane.spacing = 8
            editor.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
            pane.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            return pane
        }

        let splitView = NSSplitView()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.autosaveName = "CorrectionPromptEditorSplit"
        splitView.addArrangedSubview(makePane(label: systemLabel, editor: systemEditor))
        splitView.addArrangedSubview(makePane(label: userLabel, editor: userEditor))
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        return splitView
    }

    private func makeEditor(
        _ textView: NSTextView,
        accessibilityLabel: String
    ) -> NSScrollView {
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel(accessibilityLabel)

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        textView.frame = scrollView.contentView.bounds
        textView.autoresizingMask = [.width]
        return scrollView
    }

    private func load() {
        loadedConfiguration = preferences.load()
        apply(loadedConfiguration)
        window?.isDocumentEdited = false
    }

    private func apply(_ configuration: TranscriptEditingPromptConfiguration) {
        isApplyingConfiguration = true
        systemPromptTextView.string = configuration.systemPrompt
        userPromptTextView.string = configuration.userPromptTemplate
        isApplyingConfiguration = false
        statusLabel.isHidden = true
        setPromptAccessibilityHelp()
    }

    @objc private func resetDefaults() {
        apply(.default)
        window?.isDocumentEdited = loadedConfiguration != .default
        statusLabel.stringValue = "Defaults loaded. Save to apply."
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = false
        AccessibilityAnnouncements.post(statusLabel.stringValue, from: statusLabel)
    }

    @objc private func cancel() {
        requestDismissal()
    }

    @objc private func save() {
        let configuration = TranscriptEditingPromptConfiguration(
            systemPrompt: systemPromptTextView.string,
            userPromptTemplate: userPromptTextView.string
        )
        do {
            try preferences.save(configuration)
            loadedConfiguration = configuration
            window?.isDocumentEdited = false
            allowsClose = true
            dismiss()
        } catch {
            showValidationError(error)
        }
    }

    private var currentConfiguration: TranscriptEditingPromptConfiguration {
        TranscriptEditingPromptConfiguration(
            systemPrompt: systemPromptTextView.string,
            userPromptTemplate: userPromptTextView.string
        )
    }

    private func setPromptAccessibilityHelp() {
        systemPromptTextView.setAccessibilityHelp(
            "Complete system prompt sent to every correction model."
        )
        userPromptTextView.setAccessibilityHelp(
            "Complete user prompt. Include {transcript} exactly once. {language} inserts the "
                + "selected language; {languageLine} inserts an optional labelled line."
        )
    }

    private func showValidationError(_ error: Error) {
        let message = error.localizedDescription
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = false
        if let promptError = error as? TranscriptEditingPromptError {
            switch promptError {
            case .emptySystemPrompt, .systemPromptTooLong,
                    .transcriptPlaceholderInSystemPrompt:
                systemPromptTextView.setAccessibilityHelp(message)
                window?.makeFirstResponder(systemPromptTextView)
            case .missingTranscriptPlaceholder, .repeatedTranscriptPlaceholder,
                    .userPromptTemplateTooLong, .renderedPromptTooLong,
                    .insufficientLocalModelTranscriptCapacity:
                userPromptTextView.setAccessibilityHelp(message)
                window?.makeFirstResponder(userPromptTextView)
            }
        }
        AccessibilityAnnouncements.post(message, from: statusLabel)
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
        alert.messageText = "Discard Prompt Changes?"
        alert.informativeText = "Your unsaved correction prompts will be lost."
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

    private func dismiss() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.close()
    }
}
