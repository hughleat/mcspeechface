import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private enum ModelsTab {
        case transcription
        case corrections
    }

    var onModelChanged: ((DictationModel) -> Void)?
    var onModelsChanged: (([ManagedModel]) -> Void)?
    var onCorrectionModelChanged: ((TranscriptEditingModel) -> Void)?
    var onAutoPasteChanged: ((Bool) -> Void)?
    var onAutomaticUpdateChecksChanged: ((Bool) -> Void)?
    var onShortcutChanged: ((DictationShortcut) -> Void)?
    var onShortcutCaptureChanged: ((Bool, Set<UInt16>) -> Void)?
    var onPrivacySettingsLoaded: (() -> Void)?

    private let autoPasteButton = NSButton(checkboxWithTitle: "Paste after transcription", target: nil, action: nil)
    private let correctionTimingButton = NSPopUpButton()
    private let correctionTimingDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let reviewPreferenceButton = NSPopUpButton()
    private let soundFeedbackButton = NSButton(checkboxWithTitle: "Recording feedback", target: nil, action: nil)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "Launch McSpeechface at login", target: nil, action: nil)
    private let shortcutRecorder = ShortcutRecorderView()
    private let dictationPreferencesView = DictationPreferencesView()
    private let transcriptEditingView: TranscriptEditingSettingsView
    private let snippetEditor: SnippetEditorView
    private let vocabularyEditor: VocabularyEditorView
    private let suggestionsView: VocabularySuggestionsView
    private let historyView: HistoryView
    private let modelManagementView: ModelManagementView
    private let modelComparisonView: ModelComparisonView
    private let correctionComparisonView: CorrectionComparisonView
    private let permissionSettingsView = PermissionSettingsView()
    private let commandLineToolView = CommandLineToolSettingsView()
    private let privacySettingsView: PrivacySettingsView
    private let automaticUpdateChecksButton = NSButton(
        checkboxWithTitle: "Check for updates automatically",
        target: nil,
        action: nil
    )
    private let updateStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let checkUpdatesButton = NSButton()
    private let openReleaseButton = NSButton()
    private var checkedReleaseURL: URL?
    private var navigationController: SettingsNavigationController?
    private var modelsTabbedView: SettingsTabbedContentView?
    private var modelTabOrder: [ModelsTab] = []
    private var modelComparisonWindow: ModelComparisonWindowController?

    var selectedModelsTabTitle: String? { modelsTabbedView?.selectedTabTitle }

    init(
        service: McSpeechfaceService,
        transcriptEditingService: TranscriptEditingService = TranscriptEditingService()
    ) {
        transcriptEditingView = TranscriptEditingSettingsView(service: transcriptEditingService)
        vocabularyEditor = VocabularyEditorView(service: service)
        snippetEditor = SnippetEditorView(service: service)
        suggestionsView = VocabularySuggestionsView(service: service)
        historyView = HistoryView(service: service)
        modelManagementView = ModelManagementView(service: service)
        modelComparisonView = ModelComparisonView(service: service)
        correctionComparisonView = CorrectionComparisonView(
            historyService: service,
            editingService: transcriptEditingService
        )
        privacySettingsView = PrivacySettingsView(service: service)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "McSpeechface Settings"
        window.center()
        window.minSize = NSSize(width: 720, height: 520)
        window.setFrameAutosaveName("McSpeechfaceSettingsWindow")
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self
        modelManagementView.onModelChanged = { [weak self] model in
            self?.dictationPreferencesView.setModel(model)
            self?.onModelChanged?(model)
        }
        modelManagementView.onModelsChanged = { [weak self, weak modelComparisonView] models in
            modelComparisonView?.setModels(models)
            self?.onModelsChanged?(models)
        }
        modelManagementView.onCompareModels = { [weak self] in
            self?.showModelComparison()
        }
        transcriptEditingView.onModelChanged = { [weak self] model in
            self?.onCorrectionModelChanged?(model)
        }
        transcriptEditingView.onCompareModels = { [weak self] in
            self?.showModelComparison(selecting: 1)
        }
        permissionSettingsView.onPermissionChanged = { [weak modelManagementView] in
            modelManagementView?.refresh()
        }
        suggestionsView.onSuggestionsChanged = { [weak vocabularyEditor, weak historyView] in
            vocabularyEditor?.load()
            historyView?.refresh()
        }
        historyView.onCorrectionSaved = { [weak suggestionsView, weak modelComparisonView] in
            suggestionsView?.refresh()
            modelComparisonView?.refresh()
        }
        privacySettingsView.onStoredDataChanged = { [weak historyView, weak suggestionsView, weak modelComparisonView] in
            historyView?.refresh()
            suggestionsView?.refresh()
            modelComparisonView?.refresh()
        }
        privacySettingsView.onSettingsLoaded = { [weak self] in
            self?.onPrivacySettingsLoaded?()
        }
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        shortcutRecorder.endCapture()
        modelManagementView.cancelWork()
        snippetEditor.cancelWork()
        privacySettingsView.cancelWork()
        transcriptEditingView.cancelWork()
    }

    func windowDidResignKey(_ notification: Notification) {
        shortcutRecorder.endCapture()
    }

    func refresh() {
        refreshModel()
        dictationPreferencesView.refresh()
        dictationPreferencesView.setModel(DictationModel.selected)
        transcriptEditingView.refresh()
        snippetEditor.load()
        autoPasteButton.state = UserDefaults.standard.bool(forKey: "autoPaste") ? .on : .off
        selectCorrectionTiming(CorrectionTimingPreference.load())
        selectReviewPreference(TranscriptReviewPreference.load())
        soundFeedbackButton.state = UserDefaults.standard.bool(forKey: "soundFeedback") ? .on : .off
        let automaticUpdates = UserDefaults.standard.bool(
            forKey: AutomaticUpdateCheckPolicy.enabledDefaultsKey
        )
        automaticUpdateChecksButton.state = automaticUpdates ? .on : .off
        updateStatusLabel.stringValue = automaticUpdates
            ? "McSpeechface checks GitHub Releases once a day."
            : "Updates are checked only when you ask."
        refreshLaunchAtLogin()
        vocabularyEditor.load()
        suggestionsView.refresh()
        refreshHistory()
        permissionSettingsView.refresh()
        privacySettingsView.refresh()
        commandLineToolView.refresh()
    }

    func showGeneralSettings() { showSettings(.general) }
    func showModelsSettings() { showTranscriptionModelsSettings() }
    func showTranscriptionModelsSettings() { showModelsTab(.transcription) }
    func showCorrectionModelsSettings() { showModelsTab(.corrections) }
    func showPermissionsSettings() { showSettings(.permissions) }
    func showPrivacySettings() { showSettings(.privacy) }

    func refreshModel() {
        dictationPreferencesView.setModel(DictationModel.selected)
        modelManagementView.refresh()
    }

    func refreshCorrectionModel() {
        transcriptEditingView.refresh()
    }

    func refreshHistory() {
        historyView.refresh()
    }

    private func buildContent() {
        shortcutRecorder.onShortcutChanged = { [weak self] shortcut in
            self?.onShortcutChanged?(shortcut)
        }
        shortcutRecorder.onCaptureStarted = { [weak self] in
            self?.onShortcutCaptureChanged?(true, [])
        }
        shortcutRecorder.onCaptureEnded = { [weak self] suppressedKeys in
            self?.onShortcutCaptureChanged?(false, suppressedKeys)
        }

        autoPasteButton.target = self
        autoPasteButton.action = #selector(autoPasteChanged)
        correctionTimingButton.target = self
        correctionTimingButton.action = #selector(correctionTimingChanged)
        correctionTimingButton.removeAllItems()
        correctionTimingButton.addItems(withTitles: CorrectionTimingPreference.allCases.map(\.title))
        correctionTimingButton.setAccessibilityLabel("Correction timing")
        correctionTimingDetailLabel.textColor = .secondaryLabelColor
        correctionTimingDetailLabel.font = .systemFont(ofSize: 12)
        correctionTimingDetailLabel.maximumNumberOfLines = 2
        reviewPreferenceButton.target = self
        reviewPreferenceButton.action = #selector(reviewPreferenceChanged)
        reviewPreferenceButton.removeAllItems()
        reviewPreferenceButton.addItems(withTitles: TranscriptReviewPreference.allCases.map(\.title))
        reviewPreferenceButton.setAccessibilityLabel("Review before pasting")
        soundFeedbackButton.target = self
        soundFeedbackButton.action = #selector(soundFeedbackChanged)
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(launchAtLoginChanged)

        let general = SettingsPageViewController(title: "General", contentView: makeGeneralView())
        let modelTabDefinitions: [(ModelsTab, String, NSView)] = [
            (.transcription, "Transcription", modelManagementView),
            (.corrections, "Corrections", transcriptEditingView)
        ]
        modelTabOrder = modelTabDefinitions.map(\.0)
        let modelTabs = SettingsTabbedContentView(
            tabs: modelTabDefinitions.map { .init(title: $0.1, view: $0.2) },
            accessibilityLabel: "Model category"
        )
        modelsTabbedView = modelTabs
        let models = SettingsPageViewController(
            title: "Models",
            contentView: modelTabs
        )
        let vocabulary = SettingsPageViewController(
            title: "Vocabulary",
            contentView: SettingsTabbedContentView(tabs: [
                .init(title: "Replacements", view: vocabularyEditor),
                .init(title: "Snippets", view: snippetEditor),
                .init(title: "Suggestions", view: suggestionsView)
            ])
        )
        let history = SettingsPageViewController(title: "History", contentView: historyView)
        let permissions = SettingsPageViewController(title: "Permissions", contentView: permissionSettingsView)
        let privacy = SettingsPageViewController(
            title: "Privacy",
            contentView: SettingsScrollView(document: privacySettingsView)
        )
        let about = SettingsPageViewController(title: "About", contentView: makeAboutView())
        let navigation = SettingsNavigationController(items: [
            .init(section: .general, title: "General", symbolName: "gearshape", viewController: general),
            .init(section: .models, title: "Models", symbolName: "square.stack.3d.up", viewController: models),
            .init(section: .permissions, title: "Permissions", symbolName: "lock.shield", viewController: permissions),
            .init(section: .privacy, title: "Privacy", symbolName: "hand.raised", viewController: privacy),
            .init(section: .vocabulary, title: "Vocabulary", symbolName: "text.book.closed", viewController: vocabulary),
            .init(section: .history, title: "History", symbolName: "clock.arrow.circlepath", viewController: history),
            .init(section: .about, title: "About", symbolName: "info.circle", viewController: about)
        ])
        navigationController = navigation
        contentViewController = navigation
    }

    func showSettings(_ section: SettingsSection) {
        showWindow(nil)
        navigationController?.show(section)
    }

    private func showModelsTab(_ tab: ModelsTab) {
        guard let index = modelTabOrder.firstIndex(of: tab) else { return }
        showSettings(.models)
        modelsTabbedView?.selectTab(at: index)
    }

    private func showModelComparison(selecting tab: Int = 0) {
        let controller: ModelComparisonWindowController
        if let modelComparisonWindow {
            controller = modelComparisonWindow
        } else {
            controller = ModelComparisonWindowController(
                transcriptionView: modelComparisonView,
                correctionView: correctionComparisonView
            )
            modelComparisonWindow = controller
        }
        controller.selectTab(at: tab)
        controller.showWindow(nil)
    }

    private func makeGeneralView() -> NSView {
        let dictationLabel = sectionLabel("Dictation")
        let shortcutLabel = sectionLabel("Shortcut")
        let commandLineLabel = SettingsInfoLabel(
            "Command Line",
            helpText: "The command-line tool is named mcspeechface. Installing it makes the command available at /usr/local/bin/mcspeechface. Run mcspeechface --help in Terminal to see its recording, transcription, correction, and status commands.",
            font: .systemFont(ofSize: 13, weight: .medium)
        )
        let correctionTiming = correctionTimingRow()
        let reviewPreference = reviewPreferenceRow()
        let soundFeedback = soundFeedbackRow()
        let stack = NSStackView(views: [
            dictationLabel, dictationPreferencesView,
            shortcutLabel, shortcutRecorder,
            autoPasteButton, correctionTiming, correctionTimingDetailLabel, reviewPreference,
            soundFeedback, launchAtLoginButton,
            commandLineLabel, commandLineToolView,
            NSView()
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: dictationPreferencesView)
        stack.setCustomSpacing(18, after: shortcutRecorder)
        stack.setCustomSpacing(20, after: launchAtLoginButton)
        dictationPreferencesView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        shortcutRecorder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        commandLineToolView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        correctionTiming.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        reviewPreference.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        soundFeedback.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        correctionTimingDetailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
        return stack
    }

    private func makeAboutView() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let name = NSTextField(labelWithString: "McSpeechface")
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let versionLabel = NSTextField(labelWithString: Self.versionText(version: version, build: build))
        versionLabel.textColor = .secondaryLabelColor
        var detailViews: [NSView] = [name, versionLabel]
#if MCSPEECHFACE_SPONSORSHIP_ENABLED
        let supportButton = NSButton(
            title: BuildFeatures.sponsorshipButtonTitle!,
            target: self,
            action: #selector(supportMcSpeechface)
        )
        supportButton.bezelStyle = .rounded
        detailViews.append(supportButton)
#endif
        let details = NSStackView(views: detailViews)
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 4
        let row = NSStackView(views: [icon, details, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        let updatesLabel = sectionLabel("Updates")
        updateStatusLabel.textColor = .secondaryLabelColor
        automaticUpdateChecksButton.target = self
        automaticUpdateChecksButton.action = #selector(automaticUpdateChecksChanged)
        checkUpdatesButton.title = "Check for Updates"
        checkUpdatesButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        checkUpdatesButton.imagePosition = .imageLeading
        checkUpdatesButton.bezelStyle = .rounded
        checkUpdatesButton.target = self
        checkUpdatesButton.action = #selector(checkForUpdates)
        openReleaseButton.title = "View Release"
        openReleaseButton.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
        openReleaseButton.imagePosition = .imageLeading
        openReleaseButton.bezelStyle = .rounded
        openReleaseButton.target = self
        openReleaseButton.action = #selector(openCheckedRelease)
        openReleaseButton.isHidden = true
        let updateButtons = NSStackView(views: [checkUpdatesButton, openReleaseButton])
        updateButtons.orientation = .horizontal
        updateButtons.spacing = 8

        let helpLabel = sectionLabel("Help")
        let copyDiagnostics = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnostics))
        copyDiagnostics.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyDiagnostics.imagePosition = .imageLeading
        copyDiagnostics.bezelStyle = .rounded
        let reportIssue = NSButton(title: "Report an Issue", target: self, action: #selector(reportIssue))
        reportIssue.image = NSImage(systemSymbolName: "exclamationmark.bubble", accessibilityDescription: nil)
        reportIssue.imagePosition = .imageLeading
        reportIssue.bezelStyle = .rounded
        let helpButtons = NSStackView(views: [copyDiagnostics, reportIssue])
        helpButtons.orientation = .horizontal
        helpButtons.spacing = 8

        let stack = NSStackView(views: [
            row, updatesLabel, automaticUpdateChecksButton, updateStatusLabel,
            updateButtons, helpLabel, helpButtons, NSView(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(26, after: row)
        stack.setCustomSpacing(24, after: updateButtons)
        updateStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
        return stack
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        return label
    }

    private func reviewPreferenceRow() -> NSView {
        let label = SettingsInfoLabel(
            "Review before pasting",
            helpText: "Choose when the editable transcript preview appears before text is pasted or copied. 'When corrections change text' normally skips the preview when text is unchanged, but a provider that requires review or a correction failure may still show it. If Correction timing is On request, the preview also offers Repair."
        )
        let row = NSStackView(views: [label, NSView(), reviewPreferenceButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func soundFeedbackRow() -> NSView {
        let info = SettingsInfoButton(
            topic: "Recording feedback",
            helpText: "Plays brief sounds when recording starts and stops. This does not control whether recordings are kept."
        )
        let row = NSStackView(views: [soundFeedbackButton, info, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        return row
    }

    private func correctionTimingRow() -> NSView {
        let label = SettingsInfoLabel(
            "Correction timing",
            helpText: "Choose whether the selected correction model runs after every transcription, only when you press Repair in the preview, or not at all. On request avoids correction delay during ordinary dictation."
        )
        let row = NSStackView(views: [label, NSView(), correctionTimingButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func selectCorrectionTiming(_ preference: CorrectionTimingPreference) {
        guard let index = CorrectionTimingPreference.allCases.firstIndex(of: preference) else {
            return
        }
        correctionTimingButton.selectItem(at: index)
        updateCorrectionTimingControls(preference)
    }

    private func updateCorrectionTimingControls(_ preference: CorrectionTimingPreference) {
        reviewPreferenceButton.isEnabled = preference != .onRequest
        correctionTimingDetailLabel.stringValue = switch preference {
        case .automatic: "The selected correction model runs after transcription."
        case .onRequest: "Correction waits until you choose Repair in the transcript preview."
        case .off: "The selected correction model is not used."
        }
    }

    private func selectReviewPreference(_ preference: TranscriptReviewPreference) {
        guard let index = TranscriptReviewPreference.allCases.firstIndex(of: preference) else {
            return
        }
        reviewPreferenceButton.selectItem(at: index)
    }

    private static func versionText(version: String?, build: String?) -> String {
        switch (version, build) {
        case let (version?, build?) where version != build: return "Version \(version) (\(build))"
        case let (version?, _): return "Version \(version)"
        case let (_, build?): return "Build \(build)"
        default: return "Local development build"
        }
    }

    @objc private func autoPasteChanged() {
        let enabled = autoPasteButton.state == .on
        UserDefaults.standard.set(enabled, forKey: "autoPaste")
        onAutoPasteChanged?(enabled)
    }

    @objc private func reviewPreferenceChanged() {
        let preferences = TranscriptReviewPreference.allCases
        guard preferences.indices.contains(reviewPreferenceButton.indexOfSelectedItem) else { return }
        preferences[reviewPreferenceButton.indexOfSelectedItem].save()
    }

    @objc private func correctionTimingChanged() {
        let preferences = CorrectionTimingPreference.allCases
        guard preferences.indices.contains(correctionTimingButton.indexOfSelectedItem) else { return }
        let preference = preferences[correctionTimingButton.indexOfSelectedItem]
        preference.save()
        updateCorrectionTimingControls(preference)
    }

    @objc private func soundFeedbackChanged() {
        UserDefaults.standard.set(soundFeedbackButton.state == .on, forKey: "soundFeedback")
    }

    @objc private func launchAtLoginChanged() {
        do {
            try LoginItemManager.setEnabled(launchAtLoginButton.state == .on)
            refreshLaunchAtLogin()
        } catch {
            refreshLaunchAtLogin()
            window?.presentError(error)
        }
    }

    @objc private func checkForUpdates() {
        checkUpdatesButton.isEnabled = false
        updateStatusLabel.stringValue = "Checking GitHub Releases…"
        openReleaseButton.isHidden = true
        let currentTag = Bundle.main.object(forInfoDictionaryKey: "McSpeechfaceReleaseTag") as? String
        Task { [weak self] in
            do {
                let result = try await UpdateChecker.check(currentTag: currentTag)
                self?.showUpdateResult(result)
            } catch {
                self?.showUpdateStatus(
                    "Could not check for updates: \(error.localizedDescription)"
                )
            }
            self?.checkUpdatesButton.isEnabled = true
        }
    }

    @objc private func automaticUpdateChecksChanged() {
        let enabled = automaticUpdateChecksButton.state == .on
        UserDefaults.standard.set(
            enabled,
            forKey: AutomaticUpdateCheckPolicy.enabledDefaultsKey
        )
        showUpdateStatus(
            enabled
                ? "McSpeechface checks GitHub Releases once a day."
                : "Updates are checked only when you ask."
        )
        onAutomaticUpdateChecksChanged?(enabled)
    }

    private func showUpdateResult(_ result: UpdateCheckResult) {
        let release: GitHubRelease
        switch result {
        case .updateAvailable(let available):
            release = available
            showUpdateStatus("\(available.tagName) is available.")
        case .current(let current):
            release = current
            showUpdateStatus("McSpeechface is up to date (\(current.tagName)).")
        case .untaggedBuild(let latest):
            release = latest
            showUpdateStatus(
                "Latest published release: \(latest.tagName). This is an untagged build."
            )
        }
        checkedReleaseURL = release.pageURL
        openReleaseButton.isHidden = false
    }

    @objc private func openCheckedRelease() {
        NSWorkspace.shared.open(checkedReleaseURL ?? BuildFeatures.releasesURL)
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(DiagnosticsReport.text(), forType: .string)
        AccessibilityAnnouncements.post(
            copied ? "Diagnostics copied." : "Diagnostics could not be copied.",
            from: window?.contentView ?? updateStatusLabel
        )
    }

    private func showUpdateStatus(_ message: String) {
        updateStatusLabel.stringValue = message
        AccessibilityAnnouncements.post(message, from: updateStatusLabel)
    }

    @objc private func reportIssue() {
        NSWorkspace.shared.open(BuildFeatures.newIssueURL)
    }

#if MCSPEECHFACE_SPONSORSHIP_ENABLED
    @objc private func supportMcSpeechface() {
        NSWorkspace.shared.open(BuildFeatures.sponsorsURL)
    }
#endif

    private func refreshLaunchAtLogin() {
        launchAtLoginButton.state = LoginItemManager.isEnabled ? .on : .off
    }
}

@MainActor
private final class ModelComparisonWindowController: NSWindowController, NSWindowDelegate {
    private let transcriptionView: ModelComparisonView
    private let correctionView: CorrectionComparisonView
    private let tabs: SettingsTabbedContentView

    init(transcriptionView: ModelComparisonView, correctionView: CorrectionComparisonView) {
        self.transcriptionView = transcriptionView
        self.correctionView = correctionView
        tabs = SettingsTabbedContentView(tabs: [
            .init(title: "Transcription", view: transcriptionView),
            .init(title: "Corrections", view: correctionView),
        ], accessibilityLabel: "Comparison category")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Compare Models"
        window.minSize = NSSize(width: 680, height: 480)
        window.center()
        super.init(window: window)
        window.delegate = self
        contentViewController = SettingsPageViewController(
            title: "Compare Models",
            contentView: tabs
        )
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        transcriptionView.refresh()
        correctionView.refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        transcriptionView.cancelWork()
        correctionView.cancelWork()
    }

    func selectTab(at index: Int) {
        tabs.selectTab(at: index)
    }
}

enum AccessibilityAnnouncements {
    static func post(_ message: String, from element: Any) {
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
