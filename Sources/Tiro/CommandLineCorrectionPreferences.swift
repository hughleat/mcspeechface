import Foundation

enum CommandLineCorrectionPreset: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case custom

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .custom: "Custom"
        }
    }

    var configuration: CommandLineCorrectionConfiguration {
        switch self {
        case .codex:
            CommandLineCorrectionConfiguration(
                preset: self,
                executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex",
                model: "gpt-5.3-codex-spark",
                arguments: [
                    "exec",
                    "--ephemeral",
                    "--skip-git-repo-check",
                    "--sandbox", "read-only",
                    "--ignore-user-config",
                    "--ignore-rules",
                    "--model", "{model}",
                    "--output-schema", "{schemaFile}",
                    "--output-last-message", "{outputFile}",
                    "-",
                ]
            )
        case .claude:
            CommandLineCorrectionConfiguration(
                preset: self,
                executablePath: Self.defaultClaudePath,
                model: "haiku",
                arguments: [
                    "-p",
                    "--no-session-persistence",
                    "--safe-mode",
                    "--tools", "",
                    "--disallowedTools", "mcp__*",
                    "--model", "{model}",
                    "--json-schema", "{schemaJSON}",
                ]
            )
        case .custom:
            CommandLineCorrectionConfiguration(
                preset: self,
                executablePath: "",
                model: "",
                arguments: []
            )
        }
    }

    private static var defaultClaudePath: String {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/claude",
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            ?? candidates[0]
    }
}

struct CommandLineCorrectionConfiguration: Codable, Equatable, Sendable {
    static let defaultsKey = "commandLineCorrectionConfiguration"
    static let `default` = CommandLineCorrectionPreset.codex.configuration

    var preset: CommandLineCorrectionPreset
    var executablePath: String
    var model: String
    var arguments: [String]

    var isExecutableAvailable: Bool {
        guard executablePath.hasPrefix("/") else { return false }
        let fileManager = FileManager.default
        let resolvedPath = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath().path
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolvedPath),
              (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return false
        }
        return fileManager.isExecutableFile(atPath: resolvedPath)
    }

    var argumentsText: String {
        arguments.map { $0.isEmpty ? "\"\"" : $0 }.joined(separator: "\n")
    }

    init(
        preset: CommandLineCorrectionPreset,
        executablePath: String,
        model: String,
        arguments: [String]
    ) {
        self.preset = preset
        self.executablePath = executablePath
        self.model = model
        self.arguments = arguments
    }

    init(
        preset: CommandLineCorrectionPreset,
        executablePath: String,
        model: String,
        argumentsText: String
    ) {
        self.init(
            preset: preset,
            executablePath: executablePath,
            model: model,
            arguments: argumentsText.components(separatedBy: .newlines).compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
                return trimmed == "\"\"" ? "" : trimmed
            }
        )
    }

    func validate() throws {
        guard executablePath.hasPrefix("/") else {
            throw CommandLineCorrectionConfigurationError.executableMustBeAbsolute
        }
        guard !executablePath.contains("\n"), !model.contains("\n") else {
            throw CommandLineCorrectionConfigurationError.invalidValue
        }
        guard !arguments.contains(where: { $0.contains("{model}") }) || !model.isEmpty else {
            throw CommandLineCorrectionConfigurationError.modelRequired
        }
        guard executablePath.count <= 2_048,
              model.count <= 256,
              arguments.count <= 128,
              arguments.allSatisfy({ $0.count <= 4_096 }) else {
            throw CommandLineCorrectionConfigurationError.invalidValue
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let configuration = try? JSONDecoder().decode(Self.self, from: data),
              (try? configuration.validate()) != nil else {
            return .default
        }
        return configuration
    }

    func save(to defaults: UserDefaults = .standard) throws {
        try validate()
        defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

enum CommandLineCorrectionConfigurationError: LocalizedError {
    case executableMustBeAbsolute
    case modelRequired
    case invalidValue

    var errorDescription: String? {
        switch self {
        case .executableMustBeAbsolute:
            "Choose an executable using its full path."
        case .modelRequired:
            "Enter a model name or remove {model} from the arguments."
        case .invalidValue:
            "The command-line correction settings are invalid."
        }
    }
}
