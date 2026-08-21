import AppKit
import TiroEditing

@MainActor
final class CorrectionComparisonView: NSStackView {
    private static let externalComparisonConsentKey = "externalCorrectionComparisonConsent"
    private let historyService: TiroService
    private let editingService: TranscriptEditingService
    private let defaults: UserDefaults
    private let recordingPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelChoices = NSStackView()
    private let compareButton = NSButton(title: "Compare", target: nil, action: nil)
    private let activityIndicator = NSProgressIndicator()
    private let resultsContainer = NSView()
    private let resultsScrollView = NSScrollView()
    private let resultsStack = NSStackView()
    private let stateView = InlineRetryStateView()
    private var history: [HistoryEntry] = []
    private var availableModels: [TranscriptEditingModel] = []
    private var selectedModels: Set<TranscriptEditingModel> = []
    private var modelButtons: [NSButton] = []
    private var refreshTask: Task<Void, Never>?
    private var comparisonTask: Task<Void, Never>?
    private var comparisonGeneration = 0

    init(
        historyService: TiroService,
        editingService: TranscriptEditingService,
        defaults: UserDefaults = .standard
    ) {
        self.historyService = historyService
        self.editingService = editingService
        self.defaults = defaults
        super.init(frame: .zero)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        refreshTask?.cancel()
        comparisonTask?.cancel()
    }

    func refresh() {
        cancelComparison()
        refreshTask?.cancel()
        showState("Loading transcripts and correction models...")
        refreshTask = Task { [weak self, historyService, editingService] in
            do {
                async let loadedHistory = historyService.searchHistory(limit: 200)
                async let snapshot = editingService.modelSnapshot()
                let (entries, modelSnapshot) = try await (loadedHistory, snapshot)
                guard !Task.isCancelled, let self else { return }
                history = entries.filter { !$0.text.isEmpty }
                availableModels = TranscriptEditingModel.allCases.filter {
                    $0 != .off && modelSnapshot.canSelect($0)
                }
                selectedModels.formIntersection(availableModels)
                if selectedModels.isEmpty {
                    selectedModels.formUnion(
                        availableModels.filter { !$0.isCommandLine }.prefix(2)
                    )
                }
                rebuildRecordingPicker()
                rebuildModelChoices()
                showInitialState()
            } catch {
                guard !Task.isCancelled, let self else { return }
                history = []
                availableModels = []
                rebuildRecordingPicker()
                rebuildModelChoices()
                showState(
                    "Could not load correction comparison.\n\(error.localizedDescription)",
                    retryAction: { [weak self] in self?.refresh() }
                )
            }
        }
    }

    func cancelWork() {
        refreshTask?.cancel()
        refreshTask = nil
        cancelComparison()
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 8

        let transcriptLabel = NSTextField(labelWithString: "Transcript")
        transcriptLabel.textColor = .secondaryLabelColor
        recordingPicker.setAccessibilityLabel("Transcript to compare corrections for")
        recordingPicker.target = self
        recordingPicker.action = #selector(selectionChanged)
        let recordingRow = NSStackView(views: [transcriptLabel, recordingPicker])
        recordingRow.orientation = .horizontal
        recordingRow.alignment = .centerY
        recordingRow.spacing = 8

        modelChoices.orientation = .vertical
        modelChoices.alignment = .leading
        modelChoices.spacing = 5
        let privacyLabel = NSTextField(wrappingLabelWithString:
            "Command-line correction can send the selected transcript to an external service."
        )
        privacyLabel.font = .systemFont(ofSize: 11)
        privacyLabel.textColor = .secondaryLabelColor

        compareButton.image = NSImage(
            systemSymbolName: "rectangle.split.3x1",
            accessibilityDescription: "Compare corrections"
        )
        compareButton.imagePosition = .imageLeading
        compareButton.target = self
        compareButton.action = #selector(compare)
        activityIndicator.style = .spinning
        activityIndicator.controlSize = .small
        activityIndicator.isDisplayedWhenStopped = false
        let choiceStack = NSStackView(views: [modelChoices, privacyLabel])
        choiceStack.orientation = .vertical
        choiceStack.alignment = .leading
        choiceStack.spacing = 4
        let actionRow = NSStackView(views: [choiceStack, NSView(), activityIndicator, compareButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        resultsStack.orientation = .horizontal
        resultsStack.alignment = .top
        resultsStack.distribution = .fillEqually
        resultsStack.spacing = 14
        resultsStack.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(resultsStack)
        resultsScrollView.documentView = document
        resultsScrollView.hasHorizontalScroller = true
        resultsScrollView.hasVerticalScroller = false
        resultsScrollView.drawsBackground = false
        NSLayoutConstraint.activate([
            resultsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            resultsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            resultsStack.topAnchor.constraint(equalTo: document.topAnchor),
            resultsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.heightAnchor.constraint(equalTo: resultsScrollView.contentView.heightAnchor),
        ])

        stateView.translatesAutoresizingMaskIntoConstraints = false
        resultsScrollView.translatesAutoresizingMaskIntoConstraints = false
        resultsContainer.addSubview(resultsScrollView)
        resultsContainer.addSubview(stateView)
        NSLayoutConstraint.activate([
            resultsScrollView.leadingAnchor.constraint(equalTo: resultsContainer.leadingAnchor),
            resultsScrollView.trailingAnchor.constraint(equalTo: resultsContainer.trailingAnchor),
            resultsScrollView.topAnchor.constraint(equalTo: resultsContainer.topAnchor),
            resultsScrollView.bottomAnchor.constraint(equalTo: resultsContainer.bottomAnchor),
            stateView.centerXAnchor.constraint(equalTo: resultsContainer.centerXAnchor),
            stateView.centerYAnchor.constraint(equalTo: resultsContainer.centerYAnchor),
            stateView.leadingAnchor.constraint(greaterThanOrEqualTo: resultsContainer.leadingAnchor, constant: 16),
            stateView.trailingAnchor.constraint(lessThanOrEqualTo: resultsContainer.trailingAnchor, constant: -16),
        ])

        addArrangedSubview(recordingRow)
        addArrangedSubview(actionRow)
        addArrangedSubview(resultsContainer)
        recordingRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        actionRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        resultsContainer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        resultsContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        updateCompareButton()
    }

    private func rebuildRecordingPicker() {
        let selectedID = selectedEntry?.id
        recordingPicker.removeAllItems()
        recordingPicker.addItems(withTitles: history.map(Self.transcriptTitle))
        if let selectedID, let index = history.firstIndex(where: { $0.id == selectedID }) {
            recordingPicker.selectItem(at: index)
        }
        recordingPicker.isEnabled = !history.isEmpty && comparisonTask == nil
        updateCompareButton()
    }

    private func rebuildModelChoices() {
        for view in modelChoices.arrangedSubviews {
            modelChoices.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        modelButtons = availableModels.enumerated().map { index, model in
            let button = NSButton(
                checkboxWithTitle: model.isCommandLine
                    ? "\(model.title) (may send text off-device)"
                    : model.title,
                target: self,
                action: #selector(modelChoiceChanged(_:))
            )
            button.tag = index
            button.state = selectedModels.contains(model) ? .on : .off
            return button
        }
        for start in stride(from: 0, to: modelButtons.count, by: 2) {
            let row = NSStackView(views: Array(
                modelButtons[start..<min(start + 2, modelButtons.count)]
            ))
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            modelChoices.addArrangedSubview(row)
        }
        if modelButtons.isEmpty {
            let label = NSTextField(labelWithString: "No correction models are ready")
            label.textColor = .secondaryLabelColor
            modelChoices.addArrangedSubview(label)
        }
        updateCompareButton()
    }

    private func showInitialState() {
        if history.isEmpty {
            showState("No saved transcripts are available yet.")
        } else if availableModels.isEmpty {
            showState("Install or configure a correction model to compare results.")
        } else {
            showState("Choose correction models, then compare their results.")
        }
    }

    @objc private func modelChoiceChanged(_ sender: NSButton) {
        guard availableModels.indices.contains(sender.tag) else { return }
        let model = availableModels[sender.tag]
        if sender.state == .on { selectedModels.insert(model) }
        else { selectedModels.remove(model) }
        updateCompareButton()
    }

    @objc private func selectionChanged() {
        updateCompareButton()
    }

    @objc private func compare() {
        if comparisonTask != nil {
            cancelComparison()
            showState("Comparison cancelled.")
            AccessibilityAnnouncements.post("Correction comparison cancelled.", from: compareButton)
            return
        }
        guard let entry = selectedEntry else { return }
        let models = availableModels.filter(selectedModels.contains)
        guard !models.isEmpty else { return }
        if models.contains(where: \.isCommandLine),
           !defaults.bool(forKey: Self.externalComparisonConsentKey) {
            confirmExternalComparison(entry: entry, models: models)
            return
        }
        startComparison(entry: entry, models: models)
    }

    private func confirmExternalComparison(
        entry: HistoryEntry,
        models: [TranscriptEditingModel]
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Send This Transcript to a Command-Line Provider?"
        alert.informativeText = "The configured command may send the saved transcript to an "
            + "external service. McSpeechface cannot control how that service stores or uses it."
        alert.addButton(withTitle: "Allow and Compare")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.defaults.set(true, forKey: Self.externalComparisonConsentKey)
            self.startComparison(entry: entry, models: models)
        }
    }

    private func startComparison(
        entry: HistoryEntry,
        models: [TranscriptEditingModel]
    ) {
        comparisonGeneration += 1
        let generation = comparisonGeneration
        setComparing(true)
        showState("Comparing corrections...")
        comparisonTask = Task { [weak self, editingService] in
            do {
                let comparison = try await editingService.compareCorrections(
                    text: entry.text,
                    language: entry.language,
                    models: models
                )
                guard !Task.isCancelled, let self,
                      self.comparisonGeneration == generation else { return }
                comparisonTask = nil
                setComparing(false)
                show(comparison)
                AccessibilityAnnouncements.post(
                    "Correction comparison complete.",
                    from: resultsContainer
                )
            } catch is CancellationError {
                guard let self, self.comparisonGeneration == generation else { return }
                comparisonTask = nil
                setComparing(false)
                showState("Comparison cancelled.")
                AccessibilityAnnouncements.post(
                    "Correction comparison cancelled.",
                    from: compareButton
                )
            } catch {
                guard let self, self.comparisonGeneration == generation else { return }
                comparisonTask = nil
                setComparing(false)
                showState("Comparison failed.\n\(error.localizedDescription)")
                AccessibilityAnnouncements.post(
                    "Correction comparison failed: \(error.localizedDescription)",
                    from: stateView
                )
            }
        }
    }

    private func cancelComparison() {
        comparisonGeneration += 1
        comparisonTask?.cancel()
        comparisonTask = nil
        setComparing(false)
    }

    private var selectedEntry: HistoryEntry? {
        let index = recordingPicker.indexOfSelectedItem
        return history.indices.contains(index) ? history[index] : nil
    }

    private func setComparing(_ comparing: Bool) {
        recordingPicker.isEnabled = !comparing && !history.isEmpty
        modelButtons.forEach { $0.isEnabled = !comparing }
        if comparing { activityIndicator.startAnimation(nil) }
        else { activityIndicator.stopAnimation(nil) }
        compareButton.title = comparing ? "Cancel" : "Compare"
        compareButton.image = NSImage(
            systemSymbolName: comparing ? "xmark" : "rectangle.split.3x1",
            accessibilityDescription: comparing ? "Cancel comparison" : "Compare corrections"
        )
        updateCompareButton()
    }

    private func updateCompareButton() {
        compareButton.isEnabled = comparisonTask != nil
            || (selectedEntry != nil && !selectedModels.isEmpty)
    }

    private func show(_ comparison: TranscriptCorrectionComparison) {
        clearResults()
        addResultColumn(CorrectionComparisonResultView(
            name: "Original",
            detail: nil,
            text: comparison.request.text,
            original: comparison.request.text,
            explanation: "",
            error: nil
        ))
        for result in comparison.results {
            let text: String
            let explanation: String
            let error: String?
            switch result.outcome {
            case .completed(.unchanged):
                text = comparison.request.text
                explanation = "No changes"
                error = nil
            case .completed(.proposal(let proposal)):
                text = proposal.revisedText
                explanation = proposal.explanation
                error = nil
            case .failed(let failure):
                text = ""
                explanation = ""
                error = failure.message
            }
            addResultColumn(CorrectionComparisonResultView(
                name: result.providerName,
                detail: Self.seconds(result.latency),
                text: text,
                original: comparison.request.text,
                explanation: explanation,
                error: error
            ))
        }
        stateView.show(nil)
        resultsScrollView.isHidden = false
    }

    private func addResultColumn(_ column: NSView) {
        resultsStack.addArrangedSubview(column)
        column.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        column.heightAnchor.constraint(equalTo: resultsStack.heightAnchor).isActive = true
    }

    private func showState(_ message: String, retryAction: (() -> Void)? = nil) {
        clearResults()
        stateView.show(message, retryLabel: "Retry", retryAction: retryAction)
        resultsScrollView.isHidden = true
    }

    private func clearResults() {
        for view in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private static func transcriptTitle(_ entry: HistoryEntry) -> String {
        let text = entry.text.replacingOccurrences(of: "\n", with: " ")
        let excerpt = text.count > 72 ? String(text.prefix(69)) + "..." : text
        guard let date = ISO8601DateFormatter.correctionComparison.date(from: entry.timestamp) else {
            return excerpt
        }
        return "\(correctionComparisonDate.string(from: date)) — \(excerpt)"
    }

    private static func seconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return String(format: "%.2f seconds", value)
    }

    private static let correctionComparisonDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private final class CorrectionComparisonResultView: NSStackView {
    init(
        name: String,
        detail: String?,
        text: String,
        original: String,
        explanation: String,
        error: String?
    ) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 5

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail ?? "")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isHidden = detail == nil

        let textView = CorrectionComparisonTextView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        textView.frame = scroll.contentView.bounds
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.setAccessibilityLabel("\(name) correction result")
        if let error {
            textView.string = error
            textView.textColor = .systemRed
        } else {
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: [.foregroundColor: NSColor.textColor]
            )
            let difference = TranscriptDifference(original: original, revised: text)
            for range in difference.revisedRanges where NSMaxRange(range) <= attributed.length {
                attributed.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.28),
                    range: range
                )
            }
            textView.textStorage?.setAttributedString(attributed)
        }
        scroll.borderType = .bezelBorder

        let explanationLabel = NSTextField(wrappingLabelWithString: explanation)
        explanationLabel.font = .systemFont(ofSize: 11)
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.maximumNumberOfLines = 3
        explanationLabel.isHidden = explanation.isEmpty

        addArrangedSubview(nameLabel)
        addArrangedSubview(detailLabel)
        addArrangedSubview(scroll)
        addArrangedSubview(explanationLabel)
        for view in arrangedSubviews { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }
}

private final class CorrectionComparisonTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "a": selectAll(nil)
        case "c": copy(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

private extension ISO8601DateFormatter {
    static let correctionComparison: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
