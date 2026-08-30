import Foundation

enum McSpeechfaceAppLocator {
    static func appURL(
        executablePath: String = CommandLine.arguments[0],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment["MCSPEECHFACE_APP_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if isMcSpeechfaceApp(url, fileManager: fileManager) { return url }
        }

        let executable = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var candidate = executable.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app",
               isMcSpeechfaceApp(candidate, fileManager: fileManager) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        let installed = [
            URL(fileURLWithPath: "/Applications/McSpeechface.app", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/McSpeechface.app", isDirectory: true),
        ]
        return installed.first { isMcSpeechfaceApp($0, fileManager: fileManager) }
    }

    static func version(
        appURL: URL?
    ) -> String {
        guard let appURL,
              let info = infoDictionary(appURL: appURL),
              let version = info["CFBundleShortVersionString"] as? String else {
            return "McSpeechface development"
        }
        let build = info["CFBundleVersion"] as? String
        if let build, build != version {
            return "McSpeechface \(version) (\(build))"
        }
        return "McSpeechface \(version)"
    }

    private static func isMcSpeechfaceApp(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let info = infoDictionary(appURL: url) else {
            return false
        }
        return info["CFBundleIdentifier"] as? String == "com.hughleat.mcspeechface"
    }

    private static func infoDictionary(appURL: URL) -> [String: Any]? {
        let url = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) else {
            return nil
        }
        return value as? [String: Any]
    }
}

enum McSpeechfaceAppLauncher {
    static func launch(_ appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIExecutionError.appLaunchFailed
        }
    }
}
