import AppKit

if CommandLine.arguments.dropFirst() == ["--print-build-features"] {
    print("sponsorship=\(BuildFeatures.sponsorshipEnabled)")
} else {
    MainActor.assumeIsolated {
        let migratedPreferences = LegacyInstallationMigrator.migratePreferences()
        if migratedPreferences > 0 {
            NSLog("Migrated %d preferences to McSpeechface.", migratedPreferences)
        }
        var migrationError: Error?
        if case .failure(let error) = AppPaths.migrationResult {
            NSLog("McSpeechface data migration failed: %@", error.localizedDescription)
            migrationError = error
        } else {
            migrationError = nil
            do {
                if try LegacyInstallationMigrator.removePreviousPreferencesAfterMigration() {
                    NSLog("Removed the earlier preference domain after migration.")
                }
            } catch {
                NSLog("McSpeechface preference cleanup failed: %@", error.localizedDescription)
                migrationError = error
            }
        }

        if let migrationError {
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            application.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Earlier data could not be imported"
            alert.informativeText = "McSpeechface has not started, so it cannot create data in two places. It left unresolved earlier items in place and will retry next time. \(migrationError.localizedDescription)"
            alert.addButton(withTitle: "Quit McSpeechface")
            let earlierData = LegacyInstallationMigrator.previousApplicationSupportDirectory
            if FileManager.default.fileExists(atPath: earlierData.path) {
                alert.addButton(withTitle: "Show Earlier Data")
            }
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([earlierData])
            }
        } else {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.delegate = delegate
            withExtendedLifetime(delegate) {
                application.run()
            }
        }
    }
}
