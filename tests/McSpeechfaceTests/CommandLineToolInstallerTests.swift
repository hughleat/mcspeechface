import Foundation
import Testing
@testable import McSpeechface

struct CommandLineToolInstallerTests {
    @Test
    func regularFileAndUnrelatedSymlinkAreConflicts() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }
        let installer = CommandLineToolInstaller(
            bundleURL: fixture.currentApp,
            linkURL: fixture.link
        )

        FileManager.default.createFile(atPath: fixture.link.path, contents: Data())
        #expect(installer.state == .conflict)

        try FileManager.default.removeItem(at: fixture.link)
        try FileManager.default.createSymbolicLink(
            at: fixture.link,
            withDestinationURL: fixture.root.appendingPathComponent("someone-elses-tool")
        )
        #expect(installer.state == .conflict)
    }

    @Test
    func onlyValidatedMcSpeechfaceBundleSymlinksAreManaged() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }
        let installer = CommandLineToolInstaller(
            bundleURL: fixture.currentApp,
            linkURL: fixture.link
        )

        let oldApp = try fixture.makeApp(named: "Previous/McSpeechface.app")
        try FileManager.default.createSymbolicLink(
            at: fixture.link,
            withDestinationURL: fixture.helper(in: oldApp)
        )
        #expect(installer.state == .needsRepair)

        try FileManager.default.removeItem(at: fixture.link)
        try FileManager.default.createSymbolicLink(
            at: fixture.link,
            withDestinationURL: fixture.helper(in: fixture.currentApp)
        )
        #expect(installer.state == .installed)
    }

    @Test
    func lookalikeBundleWithWrongIdentifierIsAConflict() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }
        let impostor = try fixture.makeApp(
            named: "Impostor/McSpeechface.app",
            bundleIdentifier: "example.not-mcspeechface"
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.link,
            withDestinationURL: fixture.helper(in: impostor)
        )

        let installer = CommandLineToolInstaller(
            bundleURL: fixture.currentApp,
            linkURL: fixture.link
        )
        #expect(installer.state == .conflict)
    }

    @Test
    func recognisesOnlyTheOwnedPreviousCommandForCleanup() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }
        let previousApp = try fixture.makeApp(
            named: "Previous/Tiro.app",
            bundleIdentifier: LegacyInstallationMigrator.previousBundleIdentifier,
            helperName: LegacyInstallationMigrator.previousCommandName
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.previousLink,
            withDestinationURL: fixture.helper(
                in: previousApp,
                named: LegacyInstallationMigrator.previousCommandName
            )
        )

        let installer = CommandLineToolInstaller(
            bundleURL: fixture.currentApp,
            linkURL: fixture.link,
            legacyLinkURL: fixture.previousLink
        )
        #expect(installer.hasOwnedPreviousCommand)

        try FileManager.default.removeItem(at: fixture.previousLink)
        try FileManager.default.createSymbolicLink(
            at: fixture.previousLink,
            withDestinationURL: fixture.root.appendingPathComponent("unrelated")
        )
        #expect(!installer.hasOwnedPreviousCommand)
    }

    @Test
    func recognisesTheExactOwnedPreviousLinkAfterItsAppWasRemoved() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }
        let previousHelper = fixture.root.appendingPathComponent(
            "Removed/Tiro.app/Contents/Helpers/tiro"
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.previousLink,
            withDestinationURL: previousHelper
        )
        let installer = CommandLineToolInstaller(
            bundleURL: fixture.currentApp,
            linkURL: fixture.link,
            legacyLinkURL: fixture.previousLink,
            previousInstalledHelperURL: previousHelper
        )

        #expect(installer.hasOwnedPreviousCommand)
    }
}

private final class InstallerFixture {
    let root: URL
    let currentApp: URL
    let link: URL
    let previousLink: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcspeechface-installer-\(UUID().uuidString)", isDirectory: true)
        link = root.appendingPathComponent("bin/mcspeechface")
        previousLink = root.appendingPathComponent("bin/tiro")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        currentApp = root.appendingPathComponent("Current/McSpeechface.app", isDirectory: true)
        try Self.createApp(at: currentApp, bundleIdentifier: "com.hughleat.mcspeechface")
    }

    func makeApp(
        named path: String,
        bundleIdentifier: String = "com.hughleat.mcspeechface",
        helperName: String = "mcspeechface"
    ) throws -> URL {
        let app = root.appendingPathComponent(path, isDirectory: true)
        try Self.createApp(
            at: app,
            bundleIdentifier: bundleIdentifier,
            helperName: helperName
        )
        return app
    }

    func helper(in app: URL) -> URL {
        helper(in: app, named: "mcspeechface")
    }

    func helper(in app: URL, named name: String) -> URL {
        app.appendingPathComponent("Contents/Helpers/\(name)")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func createApp(
        at app: URL,
        bundleIdentifier: String,
        helperName: String = "mcspeechface"
    ) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let helper = contents.appendingPathComponent("Helpers/\(helperName)")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8))
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
    }
}
