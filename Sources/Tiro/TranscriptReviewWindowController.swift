import AppKit
import TiroEditing

@MainActor
final class TranscriptReviewWindowController: NSWindowController, NSWindowDelegate {
    private let originalTextView = NSTextView()
    private let revisionTextView = NSTextView()
    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private var continuation: CheckedContinuation<String, Never>?
    private var originalText = ""

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 430),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Review Spoken Correction"
        window.minSize = NSSize(width: 620, height: 340)
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()
    }

    required init?(coder: NSCoder) { nil }

    func review(_ proposal: TranscriptEditProposal) async -> String {
        cancel()
        originalText = proposal.originalText
        originalTextView.string = proposal.originalText
        revisionTextView.string = proposal.revisedText
        explanationLabel.stringValue = proposal.explanation
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        resolve(with: originalText)
    }

    func windowWillClose(_ notification: Notification) {
        resolve(with: originalText)
    }

    private func makeContentView() -> NSView {
        configure(originalTextView, editable: false)
        configure(revisionTextView, editable: true)

        let comparison = NSStackView(views: [
            textColumn(title: "Original", textView: originalTextView),
            textColumn(title: "Revision", textView: revisionTextView),
        ])
        comparison.orientation = .horizontal
        comparison.distribution = .fillEqually
        comparison.spacing = 16

        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.maximumNumberOfLines = 2

        let originalButton = NSButton(
            title: "Use Original",
            target: self,
            action: #selector(useOriginal)
        )
        originalButton.image = NSImage(
            systemSymbolName: "arrow.uturn.backward",
            accessibilityDescription: nil
        )
        originalButton.imagePosition = .imageLeading
        originalButton.keyEquivalent = "\u{1b}"

        let revisionButton = NSButton(
            title: "Use Revision",
            target: self,
            action: #selector(useRevision)
        )
        revisionButton.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: nil
        )
        revisionButton.imagePosition = .imageLeading
        revisionButton.keyEquivalent = "\r"
        revisionButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [NSView(), originalButton, revisionButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [explanationLabel, comparison, buttons])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            comparison.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
        ])
        return root
    }

    private func configure(_ textView: NSTextView, editable: Bool) {
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.setAccessibilityLabel(editable ? "Proposed revision" : "Original transcript")
    }

    private func textColumn(title: String, textView: NSTextView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        let stack = NSStackView(views: [label, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    @objc private func useOriginal() {
        resolve(with: originalText)
    }

    @objc private func useRevision() {
        resolve(with: revisionTextView.string)
    }

    private func resolve(with text: String) {
        guard let continuation else { return }
        self.continuation = nil
        window?.orderOut(nil)
        continuation.resume(returning: text)
    }
}
