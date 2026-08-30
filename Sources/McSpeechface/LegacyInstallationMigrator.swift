import Foundation

enum LegacyInstallationMigrator {
    struct FileReport: Equatable {
        let movedItems: [String]
        let skippedItems: [String]

        var didMoveData: Bool { !movedItems.isEmpty }
    }

    struct MigrationError: LocalizedError {
        let detail: String

        var errorDescription: String? { detail }
    }

    static let currentBundleIdentifier = "com.hughleat.mcspeechface"

    // These identifiers are intentionally isolated here so older beta data can move once.
    static let previousBundleIdentifier = "local.tiro.dictation"
    static let previousApplicationName = "Tiro.app"
    static let previousCommandName = "tiro"
    private static let previousApplicationSupportName = "Tiro"
    private static let conflictArchiveName = "Previous Installation Conflicts"

    static var previousApplicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(previousApplicationSupportName, isDirectory: true)
    }

    @discardableResult
    static func migratePreferences(
        defaults: UserDefaults = .standard,
        previousDomain: String = previousBundleIdentifier,
        currentDomain: String = currentBundleIdentifier
    ) -> Int {
        guard let previous = defaults.persistentDomain(forName: previousDomain) else { return 0 }
        var current = defaults.persistentDomain(forName: currentDomain) ?? [:]
        var migratedCount = 0

        for (key, value) in previous where current[key] == nil {
            current[key] = value
            migratedCount += 1
        }
        guard migratedCount > 0 else { return 0 }

        defaults.setPersistentDomain(current, forName: currentDomain)
        return migratedCount
    }

    @discardableResult
    static func removePreviousPreferencesAfterMigration(
        defaults: UserDefaults = .standard,
        previousDomain: String = previousBundleIdentifier,
        currentDomain: String = currentBundleIdentifier
    ) throws -> Bool {
        guard let previous = defaults.persistentDomain(forName: previousDomain) else {
            if previousDomain == previousBundleIdentifier,
               currentDomain == currentBundleIdentifier {
                try removeEmptyPreferenceFileIfPresent(domain: previousDomain)
            }
            return false
        }
        if previous.isEmpty {
            if previousDomain == previousBundleIdentifier,
               currentDomain == currentBundleIdentifier {
                try removeSystemPreferenceDomain(previousDomain)
            }
            return false
        }
        let current = defaults.persistentDomain(forName: currentDomain) ?? [:]
        let missingKeys = previous.keys.filter { current[$0] == nil }.sorted()
        guard missingKeys.isEmpty else {
            throw MigrationError(
                detail: "The earlier preferences were not removed because McSpeechface is missing: \(missingKeys.joined(separator: ", "))"
            )
        }

        defaults.removePersistentDomain(forName: previousDomain)
        if previousDomain == previousBundleIdentifier,
           currentDomain == currentBundleIdentifier {
            try removeSystemPreferenceDomain(previousDomain)
        }
        return true
    }

    private static func removeSystemPreferenceDomain(_ domain: String) throws {
        let applicationID = domain as CFString
        if let keys = CFPreferencesCopyKeyList(
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String] {
            for key in keys {
                CFPreferencesSetValue(
                    key as CFString,
                    nil,
                    applicationID,
                    kCFPreferencesCurrentUser,
                    kCFPreferencesAnyHost
                )
            }
        }
        guard CFPreferencesSynchronize(
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else {
            throw MigrationError(detail: "The earlier preference domain could not be synchronized.")
        }

        let remainingKeys = CFPreferencesCopyKeyList(
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String]
        guard remainingKeys?.isEmpty != false else {
            throw MigrationError(detail: "The earlier preference domain still contains values.")
        }

        let preferencesDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        try removeEmptyPreferenceFileIfPresent(
            domain: domain,
            preferencesDirectory: preferencesDirectory
        )
    }

    static func removeEmptyPreferenceFileIfPresent(
        domain: String,
        preferencesDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let directory = preferencesDirectory
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences", isDirectory: true)
        let file = directory.appendingPathComponent("\(domain).plist")
        guard fileManager.fileExists(atPath: file.path) else { return }

        let data = try Data(contentsOf: file)
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = value as? [String: Any], dictionary.isEmpty else {
            throw MigrationError(
                detail: "The earlier preference file still contains values and was not removed."
            )
        }
        try fileManager.removeItem(at: file)
    }

    @discardableResult
    static func migrateApplicationSupportIfNeeded(
        currentDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> FileReport {
        let previousDirectory = currentDirectory.deletingLastPathComponent()
            .appendingPathComponent(previousApplicationSupportName, isDirectory: true)
        return try migrateDirectory(
            from: previousDirectory,
            to: currentDirectory,
            fileManager: fileManager
        )
    }

    @discardableResult
    static func migrateDirectory(
        from previousDirectory: URL,
        to currentDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> FileReport {
        guard fileManager.fileExists(atPath: previousDirectory.path) else {
            return FileReport(movedItems: [], skippedItems: [])
        }
        guard itemType(previousDirectory, fileManager: fileManager) == .typeDirectory else {
            throw MigrationError(detail: "The earlier data path is not a normal directory: \(previousDirectory.path)")
        }

        if !fileManager.fileExists(atPath: currentDirectory.path) {
            try fileManager.createDirectory(
                at: currentDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: previousDirectory, to: currentDirectory)
            return FileReport(movedItems: ["."], skippedItems: [])
        }
        guard itemType(currentDirectory, fileManager: fileManager) == .typeDirectory else {
            throw MigrationError(detail: "The McSpeechface data path is not a normal directory: \(currentDirectory.path)")
        }

        var movedItems: [String] = []
        var skippedItems: [String] = []
        let conflictArchive = currentDirectory
            .appendingPathComponent(conflictArchiveName, isDirectory: true)
        try mergeDirectory(
            from: previousDirectory,
            to: currentDirectory,
            conflictArchive: conflictArchive,
            relativePath: "",
            fileManager: fileManager,
            movedItems: &movedItems,
            skippedItems: &skippedItems
        )
        removeIfEmpty(previousDirectory, fileManager: fileManager)
        return FileReport(movedItems: movedItems, skippedItems: skippedItems)
    }

    private static func mergeDirectory(
        from source: URL,
        to destination: URL,
        conflictArchive: URL,
        relativePath: String,
        fileManager: FileManager,
        movedItems: inout [String],
        skippedItems: inout [String]
    ) throws {
        for child in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            let label = relativePath.isEmpty
                ? child.lastPathComponent
                : "\(relativePath)/\(child.lastPathComponent)"
            let target = destination.appendingPathComponent(child.lastPathComponent)
            if itemType(child, fileManager: fileManager) == .typeSymbolicLink {
                skippedItems.append(label)
                continue
            }
            let targetExists = fileManager.fileExists(atPath: target.path)
            let childIsDirectory = itemType(child, fileManager: fileManager) == .typeDirectory

            guard targetExists else {
                try fileManager.moveItem(at: child, to: target)
                movedItems.append(label)
                continue
            }
            guard childIsDirectory,
                  itemType(target, fileManager: fileManager) == .typeDirectory else {
                if itemType(target, fileManager: fileManager) == .typeSymbolicLink {
                    skippedItems.append(label)
                } else {
                    let archived = try archiveConflict(
                        child,
                        relativePath: label,
                        in: conflictArchive,
                        fileManager: fileManager
                    )
                    movedItems.append("\(label) -> \(archived)")
                }
                continue
            }

            try mergeDirectory(
                from: child,
                to: target,
                conflictArchive: conflictArchive,
                relativePath: label,
                fileManager: fileManager,
                movedItems: &movedItems,
                skippedItems: &skippedItems
            )
            removeIfEmpty(child, fileManager: fileManager)
        }
    }

    private static func archiveConflict(
        _ source: URL,
        relativePath: String,
        in conflictArchive: URL,
        fileManager: FileManager
    ) throws -> String {
        let proposed = conflictArchive.appendingPathComponent(relativePath)
        try ensureSafeDirectory(
            proposed.deletingLastPathComponent(),
            rootedAt: conflictArchive,
            fileManager: fileManager
        )

        var destination = proposed
        var suffix = 2
        while let destinationType = itemType(destination, fileManager: fileManager) {
            if destinationType != .typeSymbolicLink,
               fileManager.contentsEqual(atPath: source.path, andPath: destination.path) {
                try fileManager.removeItem(at: source)
                return archivedLabel(for: destination, archive: conflictArchive)
            }
            let extensionName = proposed.pathExtension
            let baseName = proposed.deletingPathExtension().lastPathComponent
            let archivedName = extensionName.isEmpty
                ? "\(baseName)-\(suffix)"
                : "\(baseName)-\(suffix).\(extensionName)"
            destination = proposed.deletingLastPathComponent()
                .appendingPathComponent(archivedName)
            suffix += 1
        }

        try fileManager.moveItem(at: source, to: destination)
        return archivedLabel(for: destination, archive: conflictArchive)
    }

    private static func ensureSafeDirectory(
        _ directory: URL,
        rootedAt root: URL,
        fileManager: FileManager
    ) throws {
        let rootPath = root.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        guard directoryPath == rootPath || directoryPath.hasPrefix(rootPath + "/") else {
            throw MigrationError(detail: "The conflict archive path escaped McSpeechface data.")
        }

        var current = root
        let relative = String(directoryPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = relative.isEmpty ? [] : relative.split(separator: "/").map(String.init)
        for component in [""] + components {
            if !component.isEmpty {
                current.appendPathComponent(component, isDirectory: true)
            }
            if let type = itemType(current, fileManager: fileManager) {
                guard type == .typeDirectory else {
                    throw MigrationError(
                        detail: "The conflict archive contains an unsafe path: \(current.path)"
                    )
                }
            } else {
                try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
    }

    private static func archivedLabel(for destination: URL, archive: URL) -> String {
        destination.path.replacingOccurrences(
            of: archive.path + "/",
            with: conflictArchiveName + "/"
        )
    }

    private static func removeIfEmpty(_ directory: URL, fileManager: FileManager) {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
              contents.isEmpty else { return }
        try? fileManager.removeItem(at: directory)
    }

    private static func itemType(_ url: URL, fileManager: FileManager) -> FileAttributeType? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.type] as? FileAttributeType
    }
}
