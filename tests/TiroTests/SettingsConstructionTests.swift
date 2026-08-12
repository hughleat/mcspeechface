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
    func settingsWindowCanBeConstructedDuringLaunch() {
        _ = NSApplication.shared
        let controller = SettingsWindowController(service: TiroService())

        #expect(controller.window != nil)
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
        #expect(!TranscriptEditingSettingsView.allowsSelection(
            of: .qwenLocal,
            appleAvailable: true,
            localStatus: .notInstalled,
            operationInProgress: false
        ))
        #expect(TranscriptEditingSettingsView.allowsSelection(
            of: .qwenLocal,
            appleAvailable: true,
            localStatus: .installed(bytes: 1_282_439_264),
            operationInProgress: false
        ))
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
            instructions: "Use my explicit correction rules.",
            requestTemplate: "Review this:\n{transcript}"
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
            instructions: "Instructions",
            requestTemplate: "Missing placeholder"
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
            instructions: String(repeating: "x", count: 2_000),
            requestTemplate: "{transcript}"
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
            instructions: "Custom instructions",
            requestTemplate: "Custom {transcript}"
        ))
        let controller = TranscriptEditingPromptEditorWindowController(
            preferences: preferences
        )
        let contentView = try #require(controller.window?.contentView)
        let buttons = allSubviews(of: NSButton.self, in: contentView)
        let reset = try #require(buttons.first { $0.title == "Use Defaults" })
        let save = try #require(buttons.first { $0.title == "Save" })

        reset.performClick(nil)
        save.performClick(nil)

        #expect(preferences.load() == .default)
        #expect(defaults.data(forKey: TranscriptEditingPromptPreferences.storageKey) == nil)
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
}

@MainActor
private func allSubviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
    view.subviews.compactMap { $0 as? T }
        + view.subviews.flatMap { allSubviews(of: type, in: $0) }
}

private func transcriptionResponse(language: String?) -> TranscriptionResponse {
    TranscriptionResponse(
        id: "test",
        timestamp: "2026-08-12T00:00:00Z",
        model: "test-model",
        audio_file: nil,
        transcription_seconds: 1,
        text: "Test transcript",
        language: language,
        origin_bundle_id: nil,
        origin_app_name: nil,
        source_filename: nil,
        segments: []
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
