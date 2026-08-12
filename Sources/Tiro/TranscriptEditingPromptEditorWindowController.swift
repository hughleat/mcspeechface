import AppKit
import TiroEditing

@MainActor
final class TranscriptEditingPromptEditorWindowController: NSWindowController,
    NSWindowDelegate,
    NSTextViewDelegate {
    var onDismiss: (() -> Void)?

    private let preferences: TranscriptEditingPromptPreferences
    private let instructionsTextView = NSTextView()
    private let templateTextView = NSTextView()
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
        window.title = "Shared Correction Prompts"
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
        instructionsTextView.setAccessibilityHelp(nil)
        setTemplateAccessibilityHelp()
        window?.isDocumentEdited = currentConfiguration != loadedConfiguration
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        let instructionsLabel = NSTextField(labelWithString: "Additional Instructions")
        instructionsLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let templateLabel = NSTextField(labelWithString: "Transcript Template")
        templateLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let instructionsScroll = makeEditor(
            instructionsTextView,
            accessibilityLabel: "Correction prompt instructions"
        )
        let templateScroll = makeEditor(
            templateTextView,
            accessibilityLabel: "Correction transcript template"
        )
        setTemplateAccessibilityHelp()
        let placeholderLabel = NSTextField(
            labelWithString: "Placeholders: {transcript} required; {language} value; "
                + "{languageLine} optional line"
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
            instructionsLabel,
            instructionsScroll,
            templateLabel,
            templateScroll,
            placeholderLabel,
            statusLabel,
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: instructionsScroll)
        stack.setCustomSpacing(4, after: templateScroll)
        stack.setCustomSpacing(12, after: placeholderLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            instructionsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            templateScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            instructionsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            templateScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func makeEditor(
        _ textView: NSTextView,
        accessibilityLabel: String
    ) -> NSScrollView {
        textView.isRichText = false
        textView.allowsUndo = true
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
        return scrollView
    }

    private func load() {
        loadedConfiguration = preferences.load()
        apply(loadedConfiguration)
        window?.isDocumentEdited = false
    }

    private func apply(_ configuration: TranscriptEditingPromptConfiguration) {
        isApplyingConfiguration = true
        instructionsTextView.string = configuration.instructions
        templateTextView.string = configuration.requestTemplate
        isApplyingConfiguration = false
        statusLabel.isHidden = true
        instructionsTextView.setAccessibilityHelp(nil)
        setTemplateAccessibilityHelp()
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
            instructions: instructionsTextView.string,
            requestTemplate: templateTextView.string
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
            instructions: instructionsTextView.string,
            requestTemplate: templateTextView.string
        )
    }

    private func setTemplateAccessibilityHelp() {
        templateTextView.setAccessibilityHelp(
            "Include {transcript} exactly once. {language} inserts the language value, and "
                + "{languageLine} inserts an optional labelled line."
        )
    }

    private func showValidationError(_ error: Error) {
        let message = error.localizedDescription
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = false
        if let promptError = error as? TranscriptEditingPromptError {
            switch promptError {
            case .emptyInstructions, .instructionsTooLong:
                instructionsTextView.setAccessibilityHelp(message)
                window?.makeFirstResponder(instructionsTextView)
            case .missingTranscriptPlaceholder, .repeatedTranscriptPlaceholder,
                    .templateTooLong, .renderedPromptTooLong,
                    .insufficientLocalModelTranscriptCapacity:
                templateTextView.setAccessibilityHelp(message)
                window?.makeFirstResponder(templateTextView)
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
        alert.informativeText = "Your unsaved prompt changes will be lost."
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
