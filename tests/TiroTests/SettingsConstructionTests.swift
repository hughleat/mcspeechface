import AppKit
import Foundation
import Testing
import TiroEditing
@testable import Tiro

@Suite
struct SettingsConstructionTests {
    @Test @MainActor
    func inlineErrorStateOffersAnAccessibleRetryActionOnlyWhenRequested() throws {
        _ = NSApplication.shared
        let state = InlineRetryStateView()

        state.show("Nothing here yet.")
        #expect(state.displayedMessage == "Nothing here yet.")
        #expect(!state.offersRetry)

        var retryCount = 0
        state.show("Could not load history.", retryLabel: "Retry loading history") {
            retryCount += 1
        }
        let retry = try #require(state.arrangedSubviews.compactMap { $0 as? NSButton }.first)
        #expect(state.offersRetry)
        #expect(retry.accessibilityLabel() == "Retry loading history")

        retry.performClick(nil)
        #expect(retryCount == 1)
    }

    @Test @MainActor
    func shortcutRecorderExposesCaptureInstructionsAccessibly() throws {
        _ = NSApplication.shared
        let recorder = ShortcutRecorderView(shortcut: .default)
        recorder.beginCapture()
        defer { recorder.endCapture() }

        let button = try #require(
            recorder.arrangedSubviews
                .compactMap { $0 as? NSStackView }
                .flatMap(\.arrangedSubviews)
                .compactMap { $0 as? NSButton }
                .first
        )
        let instruction = try #require(
            recorder.arrangedSubviews.compactMap { $0 as? NSTextField }.first
        )
        #expect(button.accessibilityLabel() == "Recording dictation shortcut")
        #expect(instruction.stringValue == "Press a shortcut")
        #expect(!instruction.isHidden)
    }

    @Test @MainActor
    func settingsWindowCanBeConstructedDuringLaunch() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController(service: TiroService())

        #expect(controller.window != nil)
        let contentView = try #require(controller.window?.contentView)
        let timing = allSubviews(
            of: NSPopUpButton.self,
            in: contentView
        ).first { $0.accessibilityLabel() == "Correction timing" }
        #expect(timing?.itemTitles == CorrectionTimingPreference.allCases.map(\.title))

        controller.window?.setContentSize(NSSize(width: 720, height: 520))
        contentView.layoutSubtreeIfNeeded()
        let timingRow = try #require(timing?.superview as? NSStackView)
        let generalStack = try #require(timingRow.superview as? NSStackView)
        #expect(timingRow.frame.width <= generalStack.bounds.width + 0.5)
    }

    @Test @MainActor
    func permissionRowsStayCompactWhenThePageIsTall() {
        _ = NSApplication.shared
        let view = PermissionSettingsView(frame: NSRect(x: 0, y: 0, width: 520, height: 500))

        view.layoutSubtreeIfNeeded()

        for index in [0, 2, 4] {
            let row = view.arrangedSubviews[index]
            #expect(row.frame.height <= 100)
            let explanation = allSubviews(of: NSTextField.self, in: row)
                .first { $0.stringValue.contains("McSpeechface")
                    || $0.stringValue.contains("global shortcut")
                    || $0.stringValue.contains("Apple Speech") }
            #expect(explanation?.frame.width ?? 0 > 200)
            #expect(explanation?.frame.height ?? 0 >= explanation?.fittingSize.height ?? 0)
        }
        #expect(view.arrangedSubviews.last?.frame.height ?? 0 > 100)
    }

    @Test @MainActor
    func settingsTabsCanBeSelectedProgrammatically() {
        _ = NSApplication.shared
        let tabs = SettingsTabbedContentView(tabs: [
            .init(title: "First", view: NSView()),
            .init(title: "Second", view: NSView())
        ])

        tabs.selectTab(at: 1)
        #expect(tabs.selectedTabIndex == 1)
        #expect(tabs.selectedTabTitle == "Second")

        tabs.selectTab(at: 8)
        #expect(tabs.selectedTabIndex == 1)
    }

    @Test @MainActor
    func modelSettingsRoutesSelectTheirNamedTabs() {
        _ = NSApplication.shared
        let controller = SettingsWindowController(service: TiroService())
        defer { controller.close() }

        controller.showCorrectionModelsSettings()
        #expect(controller.selectedModelsTabTitle == "Corrections")

        controller.showTranscriptionModelsSettings()
        #expect(controller.selectedModelsTabTitle == "Transcription")

        let segmentedControl = allSubviews(
            of: NSSegmentedControl.self,
            in: controller.window!.contentView!
        ).first { $0.accessibilityLabel() == "Model category" }
        #expect(segmentedControl?.segmentCount == 2)
    }

    @Test
    func correctionModelSnapshotUsesCanonicalLocalStatus() {
        let incomplete = TranscriptEditingModelSnapshot(
            appleAvailability: .unavailable(reason: "Unavailable"),
            commandLineAvailability: Dictionary(
                uniqueKeysWithValues: TranscriptEditingModel.commandLineModels.map {
                    ($0, .unavailable(reason: "Unavailable"))
                }
            ),
            localStatuses: Dictionary(
                uniqueKeysWithValues: TranscriptEditingModel.localModels.map { ($0, .notInstalled) }
            )
        )
        #expect(incomplete.canSelect(.off))
        #expect(!incomplete.canSelect(.appleFoundation))
        #expect(TranscriptEditingModel.localModels.allSatisfy { !incomplete.canSelect($0) })

        let ready = TranscriptEditingModelSnapshot(
            appleAvailability: .available,
            commandLineAvailability: Dictionary(
                uniqueKeysWithValues: TranscriptEditingModel.commandLineModels.map {
                    ($0, .available)
                }
            ),
            localStatuses: Dictionary(
                uniqueKeysWithValues: TranscriptEditingModel.localModels.map {
                    ($0, .installed(bytes: 1))
                }
            )
        )
        #expect(ready.canSelect(.appleFoundation))
        #expect(ready.canSelect(.codexCommandLine))
        #expect(ready.canSelect(.claudeCommandLine))
        #expect(ready.canSelect(.customCommandLine))
        #expect(TranscriptEditingModel.localModels.allSatisfy { ready.canSelect($0) })
    }

    @Test
    func commandLineCorrectionConfigurationRoundTripsLiteralArguments() throws {
        let suite = "command-line-correction-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = CommandLineCorrectionConfiguration(
            preset: .custom,
            executablePath: "/usr/bin/true",
            model: "example model",
            arguments: ["--literal", "$(never-run)", "", "{schemaJSON}"]
        )

        try configuration.save(to: defaults)

        #expect(CommandLineCorrectionConfiguration.load(
            preset: .custom,
            from: defaults
        ) == configuration)
        #expect(configuration.arguments.contains(""))
        #expect(CommandLineCorrectionPreset.codex.configuration.effectiveArguments.contains("{outputFile}"))
        #expect(CommandLineCorrectionPreset.claude.configuration.effectiveArguments.contains("{schemaJSON}"))
        #expect(CommandLineCorrectionPreset.codex.configuration.effectiveArguments.contains("--json"))
        #expect(CommandLineCorrectionPreset.claude.configuration.effectiveArguments.contains("stream-json"))
        #expect(!CommandLineCorrectionPreset.claude.configuration.effectiveArguments.contains("--bare"))
        #expect(CommandLineCorrectionPreset.codex.configuration.connectionMode == .enhanced)
        #expect(CommandLineCorrectionPreset.claude.configuration.accessProfile == .correctionOnly)

        var invalid = configuration
        invalid.arguments = ["--schema={schemaJSON}"]
        #expect(throws: CommandLineCorrectionConfigurationError.self) {
            try invalid.validate()
        }
    }

    @Test
    func commandLineProvidersKeepIndependentConfigurations() throws {
        let suite = "command-line-provider-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var codex = CommandLineCorrectionPreset.codex.configuration
        var claude = CommandLineCorrectionPreset.claude.configuration
        codex.model = "codex-test-model"
        claude.model = "claude-test-model"

        try codex.save(to: defaults)
        try claude.save(to: defaults)

        #expect(CommandLineCorrectionConfiguration.load(
            preset: .codex,
            from: defaults
        ) == codex)
        #expect(CommandLineCorrectionConfiguration.load(
            preset: .claude,
            from: defaults
        ) == claude)
        #expect(CommandLineCorrectionConfiguration.load(
            preset: .custom,
            from: defaults
        ) == CommandLineCorrectionPreset.custom.configuration)

        codex.connectionMode = .commandLine
        codex.reasoningEffort = .automatic
        try codex.save(to: defaults)
        #expect(CommandLineCorrectionConfiguration.load(
            preset: .codex,
            from: defaults
        ) == codex)
    }

    @Test
    func providerAccessProfilesGenerateExpectedSafeguards() {
        var codex = CommandLineCorrectionPreset.codex.configuration
        codex.accessProfile = .unrestricted
        #expect(codex.effectiveArguments.contains("--dangerously-bypass-approvals-and-sandbox"))

        var claude = CommandLineCorrectionPreset.claude.configuration
        #expect(claude.effectiveArguments.contains("--setting-sources"))
        #expect(claude.effectiveArguments.contains(#"{"autoMemoryEnabled":false}"#))
        claude.accessProfile = .unrestricted
        #expect(claude.effectiveArguments.contains("--dangerously-skip-permissions"))
    }

    @Test
    func defaultCommandLineConfigurationsGainStreamingWithoutChangingCustomArguments() throws {
        let suite = "command-line-streaming-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var oldCodex = CommandLineCorrectionPreset.codex.configuration
        oldCodex.arguments.removeAll(where: { $0 == "--json" })
        try oldCodex.save(to: defaults)
        #expect(CommandLineCorrectionConfiguration.load(
            preset: .codex,
            from: defaults
        ).effectiveArguments.contains("--json"))

        var oldClaude = CommandLineCorrectionPreset.claude.configuration
        oldClaude.arguments.removeAll(where: {
            ["--bare", "--output-format", "stream-json", "--verbose"].contains($0)
        })
        try oldClaude.save(to: defaults)
        let migratedClaude = CommandLineCorrectionConfiguration.load(
            preset: .claude,
            from: defaults
        )
        #expect(migratedClaude.effectiveArguments.contains("stream-json"))
        #expect(!migratedClaude.arguments.contains("--bare"))

        var customizedClaude = oldClaude
        customizedClaude.connectionMode = .commandLine
        customizedClaude.arguments.append("--custom-flag")
        try customizedClaude.save(to: defaults)
        let loadedCustomization = CommandLineCorrectionConfiguration.load(
            preset: .claude,
            from: defaults
        )
        #expect(loadedCustomization == customizedClaude)
        #expect(loadedCustomization.effectiveArguments.contains("--custom-flag"))
    }

    @Test
    func localCorrectionIdleTimeoutRoundTripsAndDefaultsToTenMinutes() throws {
        let suite = "local-correction-idle-timeout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(LocalCorrectionIdleTimeout.load(from: defaults) == .tenMinutes)
        for timeout in LocalCorrectionIdleTimeout.allCases {
            timeout.save(to: defaults)
            #expect(LocalCorrectionIdleTimeout.load(from: defaults) == timeout)
        }
    }

    @Test
    func legacyCommandLineSelectionMigratesEveryConfiguredProvider() throws {
        let suite = "command-line-selection-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for preset in CommandLineCorrectionPreset.allCases {
            defaults.removePersistentDomain(forName: suite)
            var legacy = preset.configuration
            if preset == .custom { legacy.executablePath = "/usr/bin/true" }
            defaults.set("commandLine", forKey: TranscriptEditingModel.defaultsKey)
            defaults.set(
                try JSONEncoder().encode(legacy),
                forKey: CommandLineCorrectionConfiguration.defaultsKey
            )

            #expect(TranscriptEditingModel.load(from: defaults) ==
                TranscriptEditingModel.model(for: preset))
            #expect(CommandLineCorrectionConfiguration.load(
                preset: preset,
                from: defaults
            ) == legacy)
        }

        defaults.removePersistentDomain(forName: suite)
        defaults.set("commandLine", forKey: TranscriptEditingModel.defaultsKey)
        defaults.set(Data("not-json".utf8), forKey: CommandLineCorrectionConfiguration.defaultsKey)
        #expect(TranscriptEditingModel.load(from: defaults) == .codexCommandLine)
    }

    @Test
    func providerSettingsTakePrecedenceOverLegacyConfiguration() throws {
        let suite = "command-line-provider-precedence-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacy = CommandLineCorrectionPreset.codex.configuration
        legacy.model = "legacy-model"
        defaults.set(
            try JSONEncoder().encode(legacy),
            forKey: CommandLineCorrectionConfiguration.defaultsKey
        )
        var current = CommandLineCorrectionPreset.codex.configuration
        current.model = "current-model"
        try current.save(to: defaults)

        #expect(CommandLineCorrectionConfiguration.load(
            preset: .codex,
            from: defaults
        ) == current)
    }

    @Test @MainActor
    func commandLineProviderEditorShowsStructuredArguments() throws {
        _ = NSApplication.shared
        let suite = "command-line-editor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = CommandLineCorrectionPreset.claude.configuration
        try configuration.save(to: defaults)
        let controller = CommandLineCorrectionEditorWindowController(
            preset: .claude,
            defaults: defaults
        )
        defer { controller.close() }
        let content = try #require(controller.window?.contentView)
        let modelPopup = allSubviews(of: NSPopUpButton.self, in: content).first {
            $0.accessibilityLabel() == "Correction model"
        }
        let accessPopup = allSubviews(of: NSPopUpButton.self, in: content).first {
            $0.accessibilityLabel() == "Provider access"
        }
        let connectionPopup = try #require(
            allSubviews(of: NSPopUpButton.self, in: content).first {
                $0.accessibilityLabel() == "Provider connection mode"
            }
        )

        #expect(controller.window?.title == "Claude Correction")
        #expect(controller.window?.contentLayoutRect.height == 430)
        #expect(modelPopup?.selectedItem?.representedObject as? String == configuration.model)
        #expect(accessPopup?.selectedItem?.representedObject as? String ==
            CorrectionProviderAccessProfile.correctionOnly.rawValue)
        let argumentTable = try #require(allSubviews(of: NSTableView.self, in: content).first)
        var view: NSView? = argumentTable
        var isEffectivelyHidden = false
        while let current = view {
            isEffectivelyHidden = isEffectivelyHidden || current.isHidden
            view = current.superview
        }
        #expect(isEffectivelyHidden)

        connectionPopup.selectItem(withTitle: CorrectionProviderConnectionMode.commandLine.title)
        _ = NSApp.sendAction(
            try #require(connectionPopup.action),
            to: connectionPopup.target,
            from: connectionPopup
        )
        view = argumentTable
        isEffectivelyHidden = false
        while let current = view {
            isEffectivelyHidden = isEffectivelyHidden || current.isHidden
            view = current.superview
        }
        #expect(!isEffectivelyHidden)
        #expect(controller.window?.contentLayoutRect.height == 650)
    }

    @Test
    func customCommandLineSelectionRoutesAndRefreshesConfiguration() async throws {
        let suite = "command-line-provider-routing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = TranscriptEditingService(defaults: defaults)
        let response = transcriptionResponse(language: "English", text: "Um, send it.")

        func configuration(
            preset: CommandLineCorrectionPreset,
            model: String,
            marker: String
        ) -> Tiro.CommandLineCorrectionConfiguration {
            let program = #"{ consumed = 1 } END { if (configured != "\#(model)") exit 7; print "{\"hasChanges\":true,\"explanation\":\"\#(marker)\",\"revisedText\":\"Send it.\"}" }"#
            return Tiro.CommandLineCorrectionConfiguration(
                preset: preset,
                executablePath: "/usr/bin/awk",
                model: model,
                arguments: ["-v", "configured={model}", program]
            )
        }

        try configuration(
            preset: .custom,
            model: "custom-model",
            marker: "custom"
        ).save(to: defaults)
        TranscriptEditingModel.save(.customCommandLine, to: defaults)
        let initial = try await service.proposeEdits(to: response)
        guard case .proposal(let initialProposal) = initial.decision else {
            Issue.record("Expected a proposal from the custom command")
            return
        }
        #expect(initialProposal.explanation == "custom")

        let refreshed = configuration(
            preset: .custom,
            model: "custom-refreshed-model",
            marker: "custom refreshed"
        )
        try refreshed.save(to: defaults)
        TranscriptEditingModel.save(.customCommandLine, to: defaults)
        let result = try await service.proposeEdits(to: response)
        guard case .proposal(let proposal) = result.decision else {
            Issue.record("Expected a proposal from the refreshed custom command")
            return
        }
        #expect(proposal.explanation == "custom refreshed")
    }

    @Test
    func correctionExecutionSnapshotDoesNotFollowLaterSettingsChanges() async throws {
        let suite = "correction-execution-snapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = TranscriptEditingService(defaults: defaults)
        let firstCommand = Tiro.CommandLineCorrectionConfiguration(
            preset: .custom,
            executablePath: "/usr/bin/true",
            model: "first",
            arguments: []
        )
        try firstCommand.save(to: defaults)
        let firstPrompt = TranscriptEditingPromptConfiguration(
            systemPrompt: "First system prompt",
            userPromptTemplate: "{transcript}"
        )
        try TranscriptEditingPromptPreferences(defaults: defaults).save(firstPrompt)

        let snapshot = await service.executionSnapshot(for: .customCommandLine)
        let firstUseToken = try await service.reserveExecution(for: snapshot)
        let secondUseToken = try await service.reserveExecution(for: snapshot)

        let secondCommand = Tiro.CommandLineCorrectionConfiguration(
            preset: .custom,
            executablePath: "/usr/bin/false",
            model: "second",
            arguments: []
        )
        try secondCommand.save(to: defaults)
        TranscriptEditingPromptPreferences(defaults: defaults).reset()
        let changedSnapshot = await service.executionSnapshot(for: .customCommandLine)

        #expect(snapshot.commandLineConfiguration == firstCommand)
        #expect(snapshot.promptConfiguration == firstPrompt)
        #expect(await service.stopPersistentProvider(.customCommandLine) == false)
        await service.releaseExecution(firstUseToken)
        await service.releaseExecution(firstUseToken)
        await #expect(throws: TranscriptEditingServiceError.self) {
            try await service.proposeEdits(
                to: transcriptionResponse(language: "English"),
                snapshot: changedSnapshot
            )
        }
        await service.releaseExecution(secondUseToken)
        #expect(await service.stopPersistentProvider(.customCommandLine))
    }

    @Test @MainActor
    func correctionModelsCanOnlyBeSelectedWhenReady() {
        #expect(TranscriptEditingSettingsView.allowsSelection(
            of: .off,
            appleAvailable: false,
            localStatus: .notInstalled,
            operationInProgress: false
        ))
        #expect(!TranscriptEditingSettingsView.allowsSelection(
            of: .appleFoundation,
            appleAvailable: false,
            localStatus: .notInstalled,
            operationInProgress: false
        ))
        #expect(TranscriptEditingSettingsView.allowsSelection(
            of: .appleFoundation,
            appleAvailable: true,
            localStatus: .notInstalled,
            operationInProgress: false
        ))
        for model in TranscriptEditingModel.commandLineModels {
            #expect(!TranscriptEditingSettingsView.allowsSelection(
                of: model,
                appleAvailable: true,
                commandLineAvailable: false,
                localStatus: .notInstalled,
                operationInProgress: false
            ))
            #expect(TranscriptEditingSettingsView.allowsSelection(
                of: model,
                appleAvailable: true,
                commandLineAvailable: true,
                localStatus: .notInstalled,
                operationInProgress: false
            ))
        }
        for model in TranscriptEditingModel.localModels {
            #expect(!TranscriptEditingSettingsView.allowsSelection(
                of: model,
                appleAvailable: true,
                localStatus: .notInstalled,
                operationInProgress: false
            ))
            #expect(TranscriptEditingSettingsView.allowsSelection(
                of: model,
                appleAvailable: true,
                localStatus: .installed(bytes: 1),
                operationInProgress: false
            ))
        }
        #expect(!TranscriptEditingSettingsView.allowsSelection(
            of: .off,
            appleAvailable: true,
            localStatus: .installed(bytes: 1_282_439_264),
            operationInProgress: true
        ))
    }

    @Test
    func correctionPromptPreferencesRoundTripAndReset() throws {
        let suiteName = "tiro-prompt-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = TranscriptEditingPromptPreferences(defaults: defaults)
        let custom = TranscriptEditingPromptConfiguration(
            systemPrompt: "Use my explicit correction rules.",
            userPromptTemplate: "Review this:\n{transcript}"
        )

        #expect(preferences.load() == .default)
        try preferences.save(custom)
        #expect(preferences.load() == custom)
        #expect(defaults.data(forKey: TranscriptEditingPromptPreferences.storageKey) != nil)

        preferences.reset()
        #expect(preferences.load() == .default)
    }

    @Test
    func invalidStoredCorrectionPromptFallsBackToDefaults() throws {
        let suiteName = "tiro-invalid-prompt-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let invalid = TranscriptEditingPromptConfiguration(
            systemPrompt: "Instructions",
            userPromptTemplate: "Missing placeholder"
        )
        defaults.set(
            try JSONEncoder().encode(invalid),
            forKey: TranscriptEditingPromptPreferences.storageKey
        )

        #expect(TranscriptEditingPromptPreferences(defaults: defaults).load() == .default)
    }

    @Test
    func correctionPromptPreferencesRejectPromptsThatCrowdOutTranscripts() throws {
        let suiteName = "tiro-oversized-prompt-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = TranscriptEditingPromptPreferences(defaults: defaults)
        let crowded = TranscriptEditingPromptConfiguration(
            systemPrompt: String(repeating: "x", count: 3_000),
            userPromptTemplate: "{transcript}"
        )

        #expect(throws: TranscriptEditingPromptError.insufficientLocalModelTranscriptCapacity) {
            try preferences.save(crowded)
        }
        #expect(preferences.load() == .default)
    }

    @Test
    func correctionRequestReceivesSelectedLanguageAndOmitsAutomaticLanguage() {
        let english = transcriptionResponse(language: TiroService.finalizationLanguage(for: .english))
        let automatic = transcriptionResponse(language: TiroService.finalizationLanguage(for: .auto))

        #expect(TranscriptEditingService.request(
            for: english,
            promptConfiguration: .default
        ).language == "English")
        #expect(TranscriptEditingService.request(
            for: automatic,
            promptConfiguration: .default
        ).language == nil)
    }

    @Test @MainActor
    func correctionPromptEditorCanResetSavedOverrides() throws {
        _ = NSApplication.shared
        let suiteName = "tiro-prompt-editor-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = TranscriptEditingPromptPreferences(defaults: defaults)
        try preferences.save(TranscriptEditingPromptConfiguration(
            systemPrompt: "Custom instructions",
            userPromptTemplate: "Custom {transcript}"
        ))
        let controller = TranscriptEditingPromptEditorWindowController(
            preferences: preferences
        )
        #expect(controller.window?.title == "Correction Prompts")
        let contentView = try #require(controller.window?.contentView)
        let buttons = allSubviews(of: NSButton.self, in: contentView)
        let reset = try #require(buttons.first { $0.title == "Use Defaults" })
        let save = try #require(buttons.first { $0.title == "Save" })

        reset.performClick(nil)
        save.performClick(nil)

        #expect(preferences.load() == .default)
        #expect(defaults.data(forKey: TranscriptEditingPromptPreferences.storageKey) == nil)
    }

    @Test
    func correctionPromptPreferencesLoadLegacyCustomPrompts() throws {
        let suiteName = "tiro-legacy-prompt-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = Data(#"{"instructions":"Append marker and keep {transcript} literal.","requestTemplate":"Review {transcript}"}"#.utf8)
        defaults.set(legacy, forKey: TranscriptEditingPromptPreferences.storageKey)

        let configuration = TranscriptEditingPromptPreferences(defaults: defaults).load()

        #expect(configuration.isCustom)
        #expect(configuration.userPromptTemplate.contains("Append marker"))
        #expect(configuration.userPromptTemplate.contains("{ transcript }"))
        #expect(configuration.userPromptTemplate.contains("Review {transcript}"))
    }

    @Test @MainActor
    func correctionInstructionsAreVisibleAsASetting() throws {
        _ = NSApplication.shared
        let suiteName = "tiro-correction-selection-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let view = TranscriptEditingSettingsView(
            service: TranscriptEditingService(),
            defaults: defaults
        )
        view.cancelWork()
        view.apply(
            snapshot: TranscriptEditingModelSnapshot(
                appleAvailability: .available,
                commandLineAvailability: Dictionary(
                    uniqueKeysWithValues: TranscriptEditingModel.commandLineModels.map {
                        ($0, .available)
                    }
                ),
                localStatuses: Dictionary(
                    uniqueKeysWithValues: TranscriptEditingModel.localModels.map {
                        ($0, .installed(bytes: 1))
                    }
                )
            ),
            downloadSpaces: Dictionary(
                uniqueKeysWithValues: TranscriptEditingModel.localModels.map {
                    ($0, LocalTranscriptEditingModelDownloadSpace(
                        requiredBytes: 1,
                        availableBytes: 2
                    ))
                }
            )
        )
        let labels = allSubviews(of: NSTextField.self, in: view).map(\.stringValue)
        let editButton = allSubviews(of: NSButton.self, in: view).first { $0.title == "Edit…" }
        let modelTable = try #require(allSubviews(of: NSTableView.self, in: view).first)
        var selections: [TranscriptEditingModel] = []
        view.onModelChanged = { selections.append($0) }

        #expect(labels.contains("Correction Prompts"))
        #expect(editButton != nil)
        #expect(editButton?.accessibilityLabel() == "Edit correction prompts")
        #expect(modelTable.target === view)
        #expect(modelTable.action != nil)
        #expect(modelTable.numberOfRows == TranscriptEditingModel.allCases.count)
        #expect(TranscriptEditingModel.commandLineModels.map(\.title) == [
            "Codex", "Claude", "Custom Command",
        ])

        let qwenRow = try #require(TranscriptEditingModel.allCases.firstIndex(of: .qwenLocal))
        modelTable.selectRowIndexes(IndexSet(integer: qwenRow), byExtendingSelection: false)
        #expect(TranscriptEditingModel.load(from: defaults) == .qwenLocal)
        #expect(selections == [.qwenLocal])

        TranscriptEditingModel.save(.off, to: defaults)
        selections.removeAll()
        _ = modelTable.sendAction(modelTable.action, to: modelTable.target)
        #expect(TranscriptEditingModel.load(from: defaults) == .qwenLocal)
        #expect(selections == [.qwenLocal])

        _ = modelTable.sendAction(modelTable.action, to: modelTable.target)
        #expect(selections == [.qwenLocal])
    }

    @Test @MainActor
    func correctionPromptEditorTracksUnsavedChanges() throws {
        _ = NSApplication.shared
        let controller = TranscriptEditingPromptEditorWindowController()
        let contentView = try #require(controller.window?.contentView)
        let editor = try #require(allSubviews(of: NSTextView.self, in: contentView).first)

        editor.string.append(" Changed")
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))

        #expect(controller.window?.isDocumentEdited == true)
    }

    @Test @MainActor
    func correctionPromptEditorsShareAResizableRememberedSplit() async throws {
        _ = NSApplication.shared
        let autosaveKey = "NSSplitView Subview Frames CorrectionPromptEditorSplitV3"
        UserDefaults.standard.removeObject(forKey: autosaveKey)
        defer { UserDefaults.standard.removeObject(forKey: autosaveKey) }
        let controller = TranscriptEditingPromptEditorWindowController()
        let window = try #require(controller.window)
        let contentView = try #require(controller.window?.contentView)
        let splitView = try #require(allSubviews(of: NSSplitView.self, in: contentView).first)

        #expect(splitView.isVertical == false)
        #expect(splitView.arrangedSubviews.count == 2)
        #expect(splitView.autosaveName == "CorrectionPromptEditorSplitV3")
        #expect(allSubviews(of: NSTextView.self, in: splitView).count == 2)
        await Task.yield()
        contentView.layoutSubtreeIfNeeded()
        #expect(splitView.arrangedSubviews[0].frame.height > splitView.arrangedSubviews[1].frame.height)
        window.setFrame(
            NSRect(origin: window.frame.origin, size: window.minSize),
            display: false
        )
        contentView.layoutSubtreeIfNeeded()
        #expect(splitView.frame.height >= 260)
        #expect(splitView.frame.minY >= 190)
    }

    @Test
    func historyActionLabelsIncludeConciseTranscriptContext() {
        #expect(
            HistoryAccessibility.actionLabel(
                "Copy transcript",
                transcript: "  A   short\ntranscript  "
            ) == "Copy transcript, A short transcript"
        )
        let long = String(repeating: "word ", count: 20)
        let label = HistoryAccessibility.actionLabel("Play recording", transcript: long)
        #expect(label.hasPrefix("Play recording, "))
        #expect(label.hasSuffix("..."))
        #expect(label.count == "Play recording, ".count + 60)
        #expect(
            HistoryAccessibility.actionLabel("Delete transcription", transcript: "")
                == "Delete transcription, Untitled transcription"
        )
    }

    @Test @MainActor
    func settingsSidebarIconsAreDecorative() {
        let imageView = NSImageView()
        SettingsNavigationController.configureSidebarIcon(imageView, symbolName: "gearshape")

        #expect(imageView.isAccessibilityElement() == false)
    }

    @Test
    func commandLineInstallerRejectsRegularFileAndUnrelatedLink() throws {
        let fixture = try CommandLineInstallerFixture()
        defer { fixture.remove() }

        try Data("occupied".utf8).write(to: fixture.linkURL)
        #expect(fixture.installer.state == .conflict)
        #expect(throws: CommandLineToolError.self) { try fixture.installer.install() }
        #expect(throws: CommandLineToolError.self) { try fixture.installer.uninstall() }

        try FileManager.default.removeItem(at: fixture.linkURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.linkURL,
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        #expect(fixture.installer.state == .conflict)
    }

    @Test
    func commandLineInstallerRecognizesOnlyValidatedTiroLinks() throws {
        let fixture = try CommandLineInstallerFixture()
        defer { fixture.remove() }

        try FileManager.default.createSymbolicLink(
            at: fixture.linkURL,
            withDestinationURL: fixture.helperURL
        )
        #expect(fixture.installer.state == .installed)

        try FileManager.default.removeItem(at: fixture.linkURL)
        let oldHelper = try fixture.makeApp(in: "old", bundleIdentifier: "local.tiro.dictation")
        try FileManager.default.createSymbolicLink(
            at: fixture.linkURL,
            withDestinationURL: oldHelper
        )
        #expect(fixture.installer.state == .needsRepair)

        try FileManager.default.removeItem(at: fixture.linkURL)
        let unrelatedHelper = try fixture.makeApp(in: "other", bundleIdentifier: "example.other")
        try FileManager.default.createSymbolicLink(
            at: fixture.linkURL,
            withDestinationURL: unrelatedHelper
        )
        #expect(fixture.installer.state == .conflict)
    }

    @Test
    func correctionModelsHaveStableCommandLineKeys() {
        let mappings = TranscriptEditingModel.allCases.map { ($0.rawValue, $0.cliKey) }
        #expect(mappings.map(\.1) == [
            "off",
            "apple-foundation",
            "codex",
            "claude",
            "custom-command",
            "qwen-3.5-0.8b",
            "qwen-3-0.6b",
            "qwen-3-1.7b",
            "granite-4-1b",
            "smollm3-3b",
            "ministral-3-3b",
        ])
        #expect(Set(mappings.map(\.1)).count == mappings.count)
        #expect(TranscriptEditingModel.model(cliKey: "apple-foundation") == .appleFoundation)
        #expect(TranscriptEditingModel.model(cliKey: "codex") == .codexCommandLine)
        #expect(TranscriptEditingModel.model(cliKey: "qwen-3-0.6b") == .qwen3SmallLocal)
        #expect(TranscriptEditingModel.model(cliKey: "missing") == nil)
    }
}

@MainActor
private func allSubviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
    view.subviews.compactMap { $0 as? T }
        + view.subviews.flatMap { allSubviews(of: type, in: $0) }
}

private func transcriptionResponse(
    language: String?,
    text: String = "Test transcript"
) -> TranscriptionResponse {
    TranscriptionResponse(
        id: "test",
        timestamp: "2026-08-12T00:00:00Z",
        model: "test-model",
        audio_file: nil,
        transcription_seconds: 1,
        text: text,
        language: language,
        origin_bundle_id: nil,
        origin_app_name: nil,
        source_filename: nil,
        segments: [],
        saved_to_history: false
    )
}

private struct CommandLineInstallerFixture {
    let root: URL
    let bundleURL: URL
    let helperURL: URL
    let linkURL: URL

    var installer: CommandLineToolInstaller {
        CommandLineToolInstaller(bundleURL: bundleURL, linkURL: linkURL)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiro-installer-tests-\(UUID().uuidString)", isDirectory: true)
        bundleURL = root.appendingPathComponent("Tiro.app", isDirectory: true)
        linkURL = root.appendingPathComponent("bin/tiro")
        try FileManager.default.createDirectory(
            at: linkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        helperURL = try Self.makeApp(
            at: bundleURL,
            bundleIdentifier: "local.tiro.dictation"
        )
    }

    func makeApp(in directory: String, bundleIdentifier: String) throws -> URL {
        try Self.makeApp(
            at: root
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent("Tiro.app", isDirectory: true),
            bundleIdentifier: bundleIdentifier
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeApp(at appURL: URL, bundleIdentifier: String) throws -> URL {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let helper = contents
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("tiro")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleIdentifier],
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return helper
    }
}
