import Foundation
import Testing
@testable import McSpeechface

struct LegacyInstallationMigratorTests {
    @Test func movesAnEntirePreviousDirectoryWithoutCopying() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let previous = fixture.root.appendingPathComponent("Previous", isDirectory: true)
        let current = fixture.root.appendingPathComponent("Current", isDirectory: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: previous.appendingPathComponent("model.bin"))

        let report = try LegacyInstallationMigrator.migrateDirectory(from: previous, to: current)

        #expect(report.movedItems == ["."])
        #expect(!FileManager.default.fileExists(atPath: previous.path))
        #expect(try String(contentsOf: current.appendingPathComponent("model.bin")) == "model")
    }

    @Test func mergesWithoutOverwritingExistingFiles() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let previous = fixture.root.appendingPathComponent("Previous", isDirectory: true)
        let current = fixture.root.appendingPathComponent("Current", isDirectory: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: previous.appendingPathComponent("shared.txt"))
        try Data("new".utf8).write(to: current.appendingPathComponent("shared.txt"))
        try Data("move".utf8).write(to: previous.appendingPathComponent("missing.txt"))

        let report = try LegacyInstallationMigrator.migrateDirectory(from: previous, to: current)

        #expect(report.movedItems == ["missing.txt"])
        #expect(report.skippedItems == ["shared.txt"])
        #expect(try String(contentsOf: current.appendingPathComponent("shared.txt")) == "new")
        #expect(try String(contentsOf: previous.appendingPathComponent("shared.txt")) == "old")
    }

    @Test func preferencesFillOnlyMissingValues() throws {
        let suite = "McSpeechfaceMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let previousDomain = "\(suite).previous"
        let currentDomain = "\(suite).current"
        defer {
            defaults.removePersistentDomain(forName: previousDomain)
            defaults.removePersistentDomain(forName: currentDomain)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.setPersistentDomain(
            ["shared": "old", "previousOnly": 42],
            forName: previousDomain
        )
        defaults.setPersistentDomain(["shared": "new"], forName: currentDomain)

        let count = LegacyInstallationMigrator.migratePreferences(
            defaults: defaults,
            previousDomain: previousDomain,
            currentDomain: currentDomain
        )
        let migrated = try #require(defaults.persistentDomain(forName: currentDomain))

        #expect(count == 1)
        #expect(migrated["shared"] as? String == "new")
        #expect(migrated["previousOnly"] as? Int == 42)
    }

    @Test func previousPreferencesAreRemovedOnlyAfterEveryKeyWasMigrated() throws {
        let suite = "McSpeechfaceLegacyPreferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let previousDomain = "\(suite).previous"
        let currentDomain = "\(suite).current"
        defer {
            defaults.removePersistentDomain(forName: previousDomain)
            defaults.removePersistentDomain(forName: currentDomain)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.setPersistentDomain(["shortcut": "right-command"], forName: previousDomain)
        defaults.setPersistentDomain(["shortcut": "right-command"], forName: currentDomain)

        let removed = try LegacyInstallationMigrator.removePreviousPreferencesAfterMigration(
            defaults: defaults,
            previousDomain: previousDomain,
            currentDomain: currentDomain
        )

        #expect(removed)
        #expect(defaults.persistentDomain(forName: previousDomain) == nil)
        #expect(
            defaults.persistentDomain(forName: currentDomain)?["shortcut"] as? String
                == "right-command"
        )
    }

    @Test func incompletePreferenceMigrationKeepsThePreviousDomain() throws {
        let suite = "McSpeechfaceIncompletePreferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let previousDomain = "\(suite).previous"
        let currentDomain = "\(suite).current"
        defer {
            defaults.removePersistentDomain(forName: previousDomain)
            defaults.removePersistentDomain(forName: currentDomain)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.setPersistentDomain(["shortcut": "right-command"], forName: previousDomain)

        #expect(throws: LegacyInstallationMigrator.MigrationError.self) {
            try LegacyInstallationMigrator.removePreviousPreferencesAfterMigration(
                defaults: defaults,
                previousDomain: previousDomain,
                currentDomain: currentDomain
            )
        }
        #expect(defaults.persistentDomain(forName: previousDomain) != nil)
    }

    @Test func leavesDirectorySymlinksAndTheirTargetsUntouched() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let previous = fixture.root.appendingPathComponent("Previous", isDirectory: true)
        let current = fixture.root.appendingPathComponent("Current", isDirectory: true)
        let external = fixture.root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("external".utf8).write(to: external.appendingPathComponent("model.bin"))
        try FileManager.default.createSymbolicLink(
            at: previous.appendingPathComponent("Models"),
            withDestinationURL: external
        )

        let report = try LegacyInstallationMigrator.migrateDirectory(from: previous, to: current)

        #expect(report.skippedItems == ["Models"])
        #expect(FileManager.default.fileExists(atPath: previous.appendingPathComponent("Models").path))
        #expect(try String(contentsOf: external.appendingPathComponent("model.bin")) == "external")
        #expect(!FileManager.default.fileExists(atPath: current.appendingPathComponent("Models").path))
    }

    @Test func destinationSymlinksCannotRedirectMovedData() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let previous = fixture.root.appendingPathComponent("Previous", isDirectory: true)
        let current = fixture.root.appendingPathComponent("Current", isDirectory: true)
        let external = fixture.root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(
            at: previous.appendingPathComponent("Models"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("model".utf8).write(
            to: previous.appendingPathComponent("Models/model.bin")
        )
        try FileManager.default.createSymbolicLink(
            at: current.appendingPathComponent("Models"),
            withDestinationURL: external
        )

        let report = try LegacyInstallationMigrator.migrateDirectory(from: previous, to: current)

        #expect(report.skippedItems == ["Models"])
        #expect(
            FileManager.default.fileExists(
                atPath: previous.appendingPathComponent("Models/model.bin").path
            )
        )
        #expect(!FileManager.default.fileExists(atPath: external.appendingPathComponent("model.bin").path))
    }
}

private struct MigrationFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("McSpeechfaceMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
