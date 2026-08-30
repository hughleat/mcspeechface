import AppKit
import AVFoundation

enum TranscriptReviewMode: Equatable {
    case transcript
    case repaired

    func afterRepair(failed: Bool) -> Self {
        failed ? self : .repaired
    }
}

enum TranscriptReviewCorrectionReason: Equatable {
    case repair
    case additionalDictation
}

struct TranscriptReviewDraft {
    enum Action {
        case paste
        case copy

        var statusTitle: String { self == .paste ? "Ready to paste" : "Ready to copy" }
        var buttonTitle: String { self == .paste ? "Paste" : "Copy" }
    }

    let originalText: String
    let revisedText: String
    let explanation: String
    let audioURL: URL?
    let duration: TimeInterval
    let action: Action
    let allowsCorrection: Bool
    let correctionIsAvailable: Bool
    let mode: TranscriptReviewMode
    let allowsAdditionalDictation: Bool
    let additionalDictationShortcut: String?

    init(
        originalText: String,
        revisedText: String,
        explanation: String,
        audioURL: URL?,
        duration: TimeInterval,
        action: Action,
        allowsCorrection: Bool = false,
        correctionIsAvailable: Bool = true,
        mode: TranscriptReviewMode = .transcript,
        allowsAdditionalDictation: Bool = true,
        additionalDictationShortcut: String? = nil
    ) {
        self.originalText = originalText
        self.revisedText = revisedText
        self.explanation = explanation
        self.audioURL = audioURL
        self.duration = duration
        self.action = action
        self.allowsCorrection = allowsCorrection
        self.correctionIsAvailable = correctionIsAvailable
        self.mode = mode
        self.allowsAdditionalDictation = allowsAdditionalDictation
        self.additionalDictationShortcut = additionalDictationShortcut
    }

    var textChanged: Bool { originalText != revisedText }
}

enum TranscriptReviewResult: Equatable {
    case accepted(String)
    case correctionRequested(
        text: String,
        originalText: String,
        fallbackText: String,
        reason: TranscriptReviewCorrectionReason
    )
    case cancelled
}

enum TranscriptReviewVersion: Equatable {
    case corrected
    case original

    func acceptedText(original: String, editedCorrection: String) -> String {
        self == .original ? original : editedCorrection
    }
}

private final class TranscriptReviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let selector: Selector? = switch (key, event.modifierFlags.contains(.shift)) {
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
final class TranscriptReviewWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let statusLabel = NSTextField(labelWithString: "Ready to paste")
    private let statusDot = NSView()
    private let durationLabel = NSTextField(labelWithString: "00:00")
    private let playButton = NSButton()
    private let playbackSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let comparisonControl = NSSegmentedControl(
        labels: ["Corrected", "Original"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let changeLabel = NSTextField(labelWithString: "")
    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private let textView = NSTextView()
    private let acceptButton = NSButton()
    private let correctionButton = NSButton()
    private let instructionButton = NSButton()
    private let cancelButton = NSButton()
    private weak var surfaceView: NSView?
    private var continuation: CheckedContinuation<TranscriptReviewResult, Never>?
    private var draft: TranscriptReviewDraft?
    private var revisedText = ""
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var isBusy = false
    var onCancelBusy: (() -> Void)?
    var onRequestAdditionalDictation: (() -> Void)?

    var isReviewing: Bool { continuation != nil }
    var canRequestCorrection: Bool {
        isReviewing
            && draft?.allowsCorrection == true
            && draft?.correctionIsAvailable == true
            && !isBusy
    }
    var canAddDictation: Bool {
        isReviewing
            && draft?.allowsAdditionalDictation == true
            && !isBusy
    }

    init() {
        let panel = TranscriptReviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = makeContentView()
    }

    required init?(coder: NSCoder) { nil }

    func review(_ draft: TranscriptReviewDraft) async -> TranscriptReviewResult {
        guard continuation == nil else { return .cancelled }
        self.draft = draft
        isBusy = false
        updateSurfaceAppearance()
        revisedText = draft.revisedText
        statusLabel.stringValue = draft.action.statusTitle
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        acceptButton.title = draft.action.buttonTitle
        acceptButton.isEnabled = true
        acceptButton.setAccessibilityLabel("Accept and \(draft.action.buttonTitle.lowercased()) transcription")
        durationLabel.stringValue = Self.timeText(draft.duration)
        playbackSlider.doubleValue = 0
        playbackSlider.maxValue = max(1, draft.duration)
        configureAudio(url: draft.audioURL)
        configureComparison(for: draft)
        configureCorrectionButton(for: draft)
        configureInstructionButton(for: draft)
        setInteractive(true)
        showCorrectedText()
        positionOnActiveScreen()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(textView)
        let announcement = draft.explanation.isEmpty
            ? "Transcription ready to review."
            : "Transcription ready to review. \(draft.explanation)"
        AccessibilityAnnouncements.post(announcement, from: textView)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func accept() {
        guard isReviewing, let draft else { return }
        if selectedVersion == .corrected {
            revisedText = textView.string
        }
        resolve(with: .accepted(selectedVersion.acceptedText(
            original: draft.originalText,
            editedCorrection: revisedText
        )))
    }

    func requestCorrection() {
        submitCorrectionRequest()
    }

    private func submitCorrectionRequest() {
        guard canRequestCorrection, let draft else { return }
        if selectedVersion == .corrected { revisedText = textView.string }
        let text = selectedVersion.acceptedText(
            original: draft.originalText,
            editedCorrection: revisedText
        )
        showCorrectionProgress(providerName: nil, phase: "Correcting")
        resolve(
            with: .correctionRequested(
                text: text,
                originalText: draft.originalText,
                fallbackText: text,
                reason: .repair
            ),
            hidesWindow: false
        )
    }

    func beginAdditionalDictation() -> Bool {
        guard canAddDictation else { return false }
        if selectedVersion == .corrected { revisedText = textView.string }
        showBusyStatus("Listening for more…")
        instructionButton.title = "Done"
        instructionButton.image = NSImage(
            systemSymbolName: "stop.fill",
            accessibilityDescription: nil
        )
        instructionButton.isEnabled = true
        instructionButton.setAccessibilityLabel("Finish additional dictation")
        instructionButton.toolTip = "Finish recording the additional dictation"
        return true
    }

    func showAdditionalDictationTranscriptionProgress() {
        configureInstructionButtonForIdleState()
        showBusyStatus("Transcribing the addition…")
    }

    func showAdditionalDictationFailure(_ message: String) {
        guard let draft else { return }
        isBusy = false
        statusLabel.stringValue = draft.action.statusTitle
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        explanationLabel.stringValue = message
        explanationLabel.isHidden = false
        configureInstructionButton(for: draft)
        setInteractive(true)
        AccessibilityAnnouncements.post(message, from: explanationLabel)
        window?.makeFirstResponder(textView)
    }

    func appendAdditionalTranscription(_ addition: String) {
        guard isReviewing, let currentDraft = draft else { return }
        let trimmedAddition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddition.isEmpty else {
            showAdditionalDictationFailure("No additional speech was detected.")
            return
        }
        if selectedVersion == .corrected { revisedText = textView.string }
        let expandedOriginal = Self.appending(trimmedAddition, to: currentDraft.originalText)
        let expandedVisibleText = Self.appending(trimmedAddition, to: revisedText)
        let expandedDraft = TranscriptReviewDraft(
            originalText: expandedOriginal,
            revisedText: expandedVisibleText,
            explanation: "",
            audioURL: currentDraft.audioURL,
            duration: currentDraft.duration,
            action: currentDraft.action,
            allowsCorrection: currentDraft.allowsCorrection,
            correctionIsAvailable: currentDraft.correctionIsAvailable,
            mode: currentDraft.mode,
            allowsAdditionalDictation: currentDraft.allowsAdditionalDictation,
            additionalDictationShortcut: currentDraft.additionalDictationShortcut
        )
        draft = expandedDraft
        revisedText = expandedVisibleText
        comparisonControl.selectedSegment = 0
        isBusy = false
        if currentDraft.mode == .repaired, currentDraft.correctionIsAvailable {
            showCorrectionProgress(providerName: nil, phase: "Correcting")
            resolve(
                with: .correctionRequested(
                    text: expandedVisibleText,
                    originalText: expandedOriginal,
                    fallbackText: expandedVisibleText,
                    reason: .additionalDictation
                ),
                hidesWindow: false
            )
        } else {
            statusLabel.stringValue = expandedDraft.action.statusTitle
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            configureComparison(for: expandedDraft)
            configureCorrectionButton(for: expandedDraft)
            configureInstructionButton(for: expandedDraft)
            configureAudio(url: expandedDraft.audioURL)
            setInteractive(true)
            showCorrectedText()
            AccessibilityAnnouncements.post("Additional dictation added.", from: textView)
            window?.makeFirstResponder(textView)
        }
    }

    private static func appending(_ addition: String, to text: String) -> String {
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? addition : "\(base)\n\n\(addition)"
    }

    func showCorrectionProgress(providerName: String?, phase: String) {
        let suffix = providerName.map { " with \($0)" } ?? ""
        showBusyStatus("\(phase)\(suffix)…")
    }

    func cancel() {
        if continuation != nil {
            resolve(with: .cancelled)
        } else {
            resetAndHide()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if isBusy { onCancelBusy?() }
        else { cancel() }
    }

    private func makeContentView() -> NSView {
        let root = NSView()
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = Self.surfaceColor(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        ).cgColor
        root.layer?.cornerRadius = 9
        root.layer?.masksToBounds = true
        surfaceView = root

        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusDot.layer?.cornerRadius = 7
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 14).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 14).isActive = true

        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.textColor = .white
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        durationLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        let header = NSStackView(views: [statusDot, statusLabel, NSView(), durationLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        configureIconButton(playButton, symbol: "play.fill", toolTip: "Play recording")
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        playbackSlider.target = self
        playbackSlider.action = #selector(seekPlayback)
        playbackSlider.isContinuous = true
        playbackSlider.setAccessibilityLabel("Recording playback position")
        let playback = NSStackView(views: [playButton, playbackSlider])
        playback.orientation = .horizontal
        playback.alignment = .centerY
        playback.spacing = 10

        comparisonControl.selectedSegment = 0
        comparisonControl.target = self
        comparisonControl.action = #selector(comparisonChanged)
        comparisonControl.setAccessibilityLabel("Transcript version")
        changeLabel.textColor = .secondaryLabelColor
        changeLabel.font = .systemFont(ofSize: 12)
        let comparisonHeader = NSStackView(views: [changeLabel, NSView(), comparisonControl])
        comparisonHeader.orientation = .horizontal
        comparisonHeader.alignment = .centerY
        comparisonHeader.spacing = 8

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = self
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .white
        textView.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.6)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.frame = NSRect(x: 0, y: 0, width: 0, height: 115)
        textView.insertionPointColor = .white
        textView.setAccessibilityLabel("Corrected transcription")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 7
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor

        explanationLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        explanationLabel.font = .systemFont(ofSize: 12)
        explanationLabel.maximumNumberOfLines = 2

        configureIconButton(cancelButton, symbol: "xmark", toolTip: "Cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancelReview)

        let undoButton = NSButton()
        configureIconButton(undoButton, symbol: "arrow.uturn.backward", toolTip: "Restore corrected text")
        undoButton.target = self
        undoButton.action = #selector(restoreRevision)

        correctionButton.title = "Repair"
        correctionButton.image = NSImage(
            systemSymbolName: "wand.and.sparkles",
            accessibilityDescription: nil
        )
        correctionButton.imagePosition = .imageLeading
        correctionButton.target = self
        correctionButton.action = #selector(requestTranscriptCorrection)
        correctionButton.bezelStyle = .rounded
        correctionButton.toolTip = "Repair transcription"

        instructionButton.title = "Add more"
        instructionButton.image = NSImage(
            systemSymbolName: "mic.fill",
            accessibilityDescription: nil
        )
        instructionButton.imagePosition = .imageLeading
        instructionButton.target = self
        instructionButton.action = #selector(requestAdditionalDictation)
        instructionButton.bezelStyle = .rounded

        acceptButton.title = "Paste"
        acceptButton.target = self
        acceptButton.action = #selector(acceptReview)
        acceptButton.isBordered = false
        acceptButton.wantsLayer = true
        acceptButton.layer?.cornerRadius = 7
        acceptButton.layer?.masksToBounds = true
        acceptButton.font = .systemFont(ofSize: 13, weight: .semibold)
        acceptButton.contentTintColor = .white
        acceptButton.isEnabled = true
        updateAcceptButtonAppearance()
        acceptButton.keyEquivalent = "\r"
        acceptButton.keyEquivalentModifierMask = .command
        acceptButton.setAccessibilityLabel("Accept and paste transcription")
        let actions = NSStackView(views: [
            cancelButton, undoButton, NSView(), instructionButton, correctionButton, acceptButton,
        ])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let stack = NSStackView(views: [header, playback, comparisonHeader, scroll, explanationLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, playback, comparisonHeader, scroll, explanationLabel, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 115),
            playButton.widthAnchor.constraint(equalToConstant: 30),
            playButton.heightAnchor.constraint(equalToConstant: 28),
            cancelButton.widthAnchor.constraint(equalToConstant: 34),
            undoButton.widthAnchor.constraint(equalToConstant: 34),
            instructionButton.heightAnchor.constraint(equalToConstant: 32),
            correctionButton.heightAnchor.constraint(equalToConstant: 32),
            acceptButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            acceptButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        return root
    }

    static func surfaceColor(reduceTransparency: Bool) -> NSColor {
        NSColor(calibratedWhite: 0.08, alpha: reduceTransparency ? 1 : 0.94)
    }

    static let rawTranscriptColor = NSColor(calibratedWhite: 0.76, alpha: 1)
    static let correctedTranscriptColor = NSColor.white

    private func updateSurfaceAppearance() {
        surfaceView?.layer?.backgroundColor = Self.surfaceColor(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        ).cgColor
    }

    private func configureIconButton(_ button: NSButton, symbol: String, toolTip: String) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.isBordered = false
        button.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        button.toolTip = toolTip
    }

    private func configureComparison(for draft: TranscriptReviewDraft) {
        comparisonControl.setLabel(draft.mode == .repaired ? "Corrected" : "Transcript", forSegment: 0)
        updateDifferenceSummary(
            TranscriptDifference(original: draft.originalText, revised: draft.revisedText),
            original: draft.originalText,
            revised: draft.revisedText
        )
        comparisonControl.selectedSegment = 0
        explanationLabel.stringValue = draft.explanation
        explanationLabel.isHidden = draft.explanation.isEmpty
    }

    private func configureCorrectionButton(for draft: TranscriptReviewDraft) {
        correctionButton.isHidden = !draft.allowsCorrection
        correctionButton.isEnabled = draft.allowsCorrection && draft.correctionIsAvailable
        correctionButton.setAccessibilityLabel("Repair transcription")
        correctionButton.toolTip = if !draft.correctionIsAvailable {
            "Choose a correction model in Settings > Models"
        } else {
            "Repair transcription"
        }
    }

    private func configureInstructionButton(for draft: TranscriptReviewDraft) {
        configureInstructionButtonForIdleState()
        instructionButton.isHidden = !draft.allowsAdditionalDictation
        instructionButton.isEnabled = draft.allowsAdditionalDictation
        instructionButton.toolTip = if let shortcut = draft.additionalDictationShortcut {
            "Dictate more, or hold \(shortcut)"
        } else {
            "Dictate more"
        }
        let accessibilityLabel = if let shortcut = draft.additionalDictationShortcut {
            "Add more dictation. Shortcut: hold \(shortcut)."
        } else {
            "Add more dictation"
        }
        instructionButton.setAccessibilityLabel(accessibilityLabel)
    }

    private func configureInstructionButtonForIdleState() {
        instructionButton.title = "Add more"
        instructionButton.image = NSImage(
            systemSymbolName: "mic.fill",
            accessibilityDescription: nil
        )
    }

    private func setInteractive(_ interactive: Bool) {
        isBusy = !interactive
        acceptButton.isEnabled = interactive
        updateAcceptButtonAppearance()
        cancelButton.isEnabled = true
        correctionButton.isEnabled = interactive
            && draft?.allowsCorrection == true
            && draft?.correctionIsAvailable == true
        instructionButton.isEnabled = interactive
            && draft?.allowsAdditionalDictation == true
        comparisonControl.isEnabled = interactive
        textView.isEditable = interactive && selectedVersion == .corrected
    }

    private func updateAcceptButtonAppearance() {
        let color = NSColor(
            calibratedRed: 0.04,
            green: 0.42,
            blue: 0.18,
            alpha: acceptButton.isEnabled ? 1 : 0.35
        )
        acceptButton.layer?.backgroundColor = color.cgColor
    }

    private func showBusyStatus(_ title: String) {
        let changed = statusLabel.stringValue != title
        isBusy = true
        statusLabel.stringValue = title
        statusDot.layer?.backgroundColor = NSColor.systemYellow.cgColor
        setInteractive(false)
        if changed { AccessibilityAnnouncements.post(title, from: statusLabel) }
    }

    private func updateDifferenceSummary(
        _ difference: TranscriptDifference,
        original: String,
        revised: String
    ) {
        changeLabel.stringValue = difference.changeCount == 0
            ? "No corrections"
            : "\(difference.changeCount) \(difference.changeCount == 1 ? "change" : "changes")"
        changeLabel.setAccessibilityLabel(changeDescription(
            difference,
            original: original,
            revised: revised
        ))
        comparisonControl.setEnabled(original != revised, forSegment: 1)
    }

    private func changeDescription(
        _ difference: TranscriptDifference,
        original: String,
        revised: String
    ) -> String {
        guard difference.changeCount > 0 else { return "No corrections" }
        let originalWords = words(in: original, ranges: difference.originalRanges)
        let revisedWords = words(in: revised, ranges: difference.revisedRanges)
        return "\(changeLabel.stringValue). Original: \(originalWords). Corrected: \(revisedWords)."
    }

    private func words(in text: String, ranges: [NSRange]) -> String {
        let value = text as NSString
        return ranges.map(value.substring(with:)).joined(separator: ", ")
    }

    private var selectedVersion: TranscriptReviewVersion {
        comparisonControl.selectedSegment == 1 ? .original : .corrected
    }

    private func showCorrectedText() {
        guard let draft else { return }
        comparisonControl.selectedSegment = 0
        textView.isEditable = true
        textView.setAccessibilityLabel(
            draft.mode == .repaired ? "Corrected transcription" : "Transcription"
        )
        let difference = TranscriptDifference(original: draft.originalText, revised: revisedText)
        updateDifferenceSummary(difference, original: draft.originalText, revised: revisedText)
        if draft.allowsCorrection, draft.mode == .transcript, difference.changeCount == 0 {
            changeLabel.stringValue = "Not repaired"
            changeLabel.setAccessibilityLabel("The transcript has not been repaired.")
        }
        display(
            revisedText,
            highlightedRanges: difference.revisedRanges,
            original: false,
            foregroundColor: draft.mode == .repaired
                ? Self.correctedTranscriptColor
                : Self.rawTranscriptColor
        )
    }

    private func showOriginalText() {
        guard let draft else { return }
        revisedText = textView.string
        textView.isEditable = false
        textView.setAccessibilityLabel("Original transcription")
        let difference = TranscriptDifference(original: draft.originalText, revised: revisedText)
        updateDifferenceSummary(difference, original: draft.originalText, revised: revisedText)
        display(
            draft.originalText,
            highlightedRanges: difference.originalRanges,
            original: true,
            foregroundColor: Self.rawTranscriptColor
        )
    }

    private func display(
        _ text: String,
        highlightedRanges: [NSRange],
        original: Bool,
        foregroundColor: NSColor
    ) {
        textView.string = text
        textView.textColor = foregroundColor
        textView.typingAttributes[.foregroundColor] = foregroundColor
        textView.textStorage?.addAttribute(
            .foregroundColor,
            value: foregroundColor,
            range: NSRange(location: 0, length: text.utf16.count)
        )
        applyHighlights(highlightedRanges, original: original)
    }

    private func applyHighlights(_ highlightedRanges: [NSRange], original: Bool) {
        guard let layoutManager = textView.layoutManager else { return }
        let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)
        let color = original ? NSColor.systemRed : NSColor.systemBlue
        for range in highlightedRanges where NSMaxRange(range) <= fullRange.length {
            layoutManager.addTemporaryAttributes([
                .backgroundColor: color.withAlphaComponent(0.22),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: color,
            ], forCharacterRange: range)
        }
    }

    private func configureAudio(url: URL?) {
        stopPlayback()
        guard let url else {
            audioPlayer = nil
            playButton.isEnabled = false
            playbackSlider.isEnabled = false
            return
        }
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.prepareToPlay()
        playButton.isEnabled = audioPlayer != nil
        playbackSlider.isEnabled = audioPlayer != nil
        if let duration = audioPlayer?.duration {
            durationLabel.stringValue = Self.timeText(duration)
            playbackSlider.maxValue = max(1, duration)
        }
    }

    private func positionOnActiveScreen() {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame, let window else { return }
        window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.maxY - window.frame.height - 16))
    }

    private func resolve(
        with result: TranscriptReviewResult,
        hidesWindow: Bool = true
    ) {
        guard let continuation else { return }
        self.continuation = nil
        stopPlayback()
        if hidesWindow { resetAndHide() }
        continuation.resume(returning: result)
    }

    private func resetAndHide() {
        stopPlayback()
        audioPlayer = nil
        window?.orderOut(nil)
        draft = nil
        isBusy = false
    }

    private func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        audioPlayer?.stop()
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play recording")
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPlayback() }
        }
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshPlayback() {
        guard let player = audioPlayer else { return }
        playbackSlider.doubleValue = player.currentTime
        if !player.isPlaying { stopPlayback() }
    }

    private static func timeText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func comparisonChanged() {
        if comparisonControl.selectedSegment == 0 { showCorrectedText() }
        else { showOriginalText() }
    }

    func textDidChange(_ notification: Notification) {
        guard selectedVersion == .corrected, let draft else { return }
        revisedText = textView.string
        let difference = TranscriptDifference(original: draft.originalText, revised: revisedText)
        updateDifferenceSummary(difference, original: draft.originalText, revised: revisedText)
        applyHighlights(difference.revisedRanges, original: false)
    }

    @objc private func togglePlayback() {
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            player.pause()
            playbackTimer?.invalidate()
            playbackTimer = nil
            playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play recording")
        } else {
            player.play()
            playButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause recording")
            startPlaybackTimer()
        }
    }

    @objc private func seekPlayback() {
        audioPlayer?.currentTime = playbackSlider.doubleValue
    }

    @objc private func restoreRevision() {
        guard let draft else { return }
        revisedText = draft.revisedText
        showCorrectedText()
        window?.makeFirstResponder(textView)
    }

    @objc private func cancelReview() {
        if isBusy { onCancelBusy?() }
        else { cancel() }
    }
    @objc private func acceptReview() { accept() }
    @objc private func requestTranscriptCorrection() { requestCorrection() }
    @objc private func requestAdditionalDictation() { onRequestAdditionalDictation?() }
}
