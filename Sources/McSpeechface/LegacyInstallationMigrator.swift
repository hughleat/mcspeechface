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
        return true
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
        try mergeDirectory(
            from: previousDirectory,
            to: currentDirectory,
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
        relativePath: String,
        fileManager: FileManager,
        movedItems: inout [String],
        skippedItems: inout [String]
    ) throws {
        for child in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
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
                skippedItems.append(label)
                continue
            }

            try mergeDirectory(
                from: child,
                to: target,
                relativePath: label,
                fileManager: fileManager,
                movedItems: &movedItems,
                skippedItems: &skippedItems
            )
            removeIfEmpty(child, fileManager: fileManager)
        }
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
