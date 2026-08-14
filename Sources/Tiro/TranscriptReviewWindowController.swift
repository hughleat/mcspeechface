import AppKit
import AVFoundation

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

    var textChanged: Bool { originalText != revisedText }
}

enum TranscriptReviewResult: Equatable {
    case accepted(String)
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
}

@MainActor
final class TranscriptReviewWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let statusLabel = NSTextField(labelWithString: "Ready to paste")
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
    private var continuation: CheckedContinuation<TranscriptReviewResult, Never>?
    private var draft: TranscriptReviewDraft?
    private var revisedText = ""
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?

    var isReviewing: Bool { continuation != nil }

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
        revisedText = draft.revisedText
        statusLabel.stringValue = draft.action.statusTitle
        acceptButton.title = draft.action.buttonTitle
        acceptButton.setAccessibilityLabel("Accept and \(draft.action.buttonTitle.lowercased()) transcription")
        durationLabel.stringValue = Self.timeText(draft.duration)
        playbackSlider.doubleValue = 0
        playbackSlider.maxValue = max(1, draft.duration)
        configureAudio(url: draft.audioURL)
        configureComparison(for: draft)
        showCorrectedText()
        positionOnActiveScreen()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(textView)
        AccessibilityAnnouncements.post("Transcription ready to review.", from: textView)

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

    func cancel() {
        resolve(with: .cancelled)
    }

    func windowWillClose(_ notification: Notification) {
        cancel()
    }

    private func makeContentView() -> NSView {
        let root = NSVisualEffectView()
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true

        let statusDot = NSView()
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
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = self
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .white
        textView.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.6)
        textView.textContainerInset = NSSize(width: 10, height: 10)
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

        let cancelButton = NSButton()
        configureIconButton(cancelButton, symbol: "xmark", toolTip: "Cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancelReview)

        let undoButton = NSButton()
        configureIconButton(undoButton, symbol: "arrow.uturn.backward", toolTip: "Restore corrected text")
        undoButton.target = self
        undoButton.action = #selector(restoreRevision)

        acceptButton.title = "Paste"
        acceptButton.target = self
        acceptButton.action = #selector(acceptReview)
        acceptButton.bezelStyle = .rounded
        acceptButton.keyEquivalent = "\r"
        acceptButton.keyEquivalentModifierMask = .command
        acceptButton.setAccessibilityLabel("Accept and paste transcription")
        let actions = NSStackView(views: [cancelButton, undoButton, NSView(), acceptButton])
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
        ])
        return root
    }

    private func configureIconButton(_ button: NSButton, symbol: String, toolTip: String) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.bezelStyle = .texturedRounded
        button.toolTip = toolTip
    }

    private func configureComparison(for draft: TranscriptReviewDraft) {
        updateDifferenceSummary(
            TranscriptDifference(original: draft.originalText, revised: draft.revisedText),
            original: draft.originalText,
            revised: draft.revisedText
        )
        comparisonControl.selectedSegment = 0
        explanationLabel.stringValue = draft.explanation
        explanationLabel.isHidden = draft.explanation.isEmpty
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
        textView.setAccessibilityLabel("Corrected transcription")
        let difference = TranscriptDifference(original: draft.originalText, revised: revisedText)
        updateDifferenceSummary(difference, original: draft.originalText, revised: revisedText)
        display(revisedText, highlightedRanges: difference.revisedRanges, original: false)
    }

    private func showOriginalText() {
        guard let draft else { return }
        revisedText = textView.string
        textView.isEditable = false
        textView.setAccessibilityLabel("Original transcription")
        let difference = TranscriptDifference(original: draft.originalText, revised: revisedText)
        updateDifferenceSummary(difference, original: draft.originalText, revised: revisedText)
        display(draft.originalText, highlightedRanges: difference.originalRanges, original: true)
    }

    private func display(_ text: String, highlightedRanges: [NSRange], original: Bool) {
        textView.string = text
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

    private func resolve(with result: TranscriptReviewResult) {
        guard let continuation else { return }
        self.continuation = nil
        stopPlayback()
        audioPlayer = nil
        window?.orderOut(nil)
        draft = nil
        continuation.resume(returning: result)
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

    @objc private func cancelReview() { cancel() }
    @objc private func acceptReview() { accept() }
}
