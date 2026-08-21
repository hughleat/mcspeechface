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
                    "--json",
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
                    "--output-format", "stream-json",
                    "--verbose",
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
        for placeholder in ["{schemaFile}", "{schemaJSON}", "{outputFile}"] {
            if arguments.contains(where: { $0.contains(placeholder) && $0 != placeholder }) {
                throw CommandLineCorrectionConfigurationError.placeholderMustBeWholeArgument(
                    placeholder
                )
            }
        }
        guard executablePath.count <= 2_048,
              model.count <= 256,
              arguments.count <= 128,
              arguments.allSatisfy({ $0.count <= 4_096 }) else {
            throw CommandLineCorrectionConfigurationError.invalidValue
        }
    }

    static func load(
        preset: CommandLineCorrectionPreset,
        from defaults: UserDefaults = .standard
    ) -> Self {
        if let configuration = decode(from: defaults, key: storageKey(for: preset)),
           configuration.preset == preset {
            return configuration.addingStreamingOutputWhenUsingLegacyDefaults()
        }
        let legacy = loadLegacy(from: defaults)
        return legacy.preset == preset ? legacy : preset.configuration
    }

    func save(to defaults: UserDefaults = .standard) throws {
        try validate()
        defaults.set(
            try JSONEncoder().encode(self),
            forKey: Self.storageKey(for: preset)
        )
    }

    static func loadLegacy(from defaults: UserDefaults = .standard) -> Self {
        decode(from: defaults, key: defaultsKey) ?? .default
    }

    private static func storageKey(for preset: CommandLineCorrectionPreset) -> String {
        "\(defaultsKey).\(preset.rawValue)"
    }

    private static func decode(from defaults: UserDefaults, key: String) -> Self? {
        guard let data = defaults.data(forKey: key),
              let configuration = try? JSONDecoder().decode(Self.self, from: data),
              (try? configuration.validate()) != nil else {
            return nil
        }
        return configuration
    }

    private func addingStreamingOutputWhenUsingLegacyDefaults() -> Self {
        var migrated = self
        switch preset {
        case .codex:
            guard arguments == Self.legacyCodexArguments,
                  let insertionIndex = arguments.firstIndex(of: "-") else { return self }
            migrated.arguments.insert("--json", at: insertionIndex)
        case .claude:
            if arguments == Self.legacyClaudeArguments {
                migrated.arguments.append(
                    contentsOf: ["--output-format", "stream-json", "--verbose"]
                )
            } else if arguments == Self.streamingClaudeArgumentsWithBare {
                migrated.arguments.removeAll(where: { $0 == "--bare" })
            } else {
                return self
            }
        case .custom:
            return self
        }
        return migrated
    }

    private static let legacyCodexArguments = [
        "exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
        "--ignore-user-config", "--ignore-rules", "--model", "{model}",
        "--output-schema", "{schemaFile}", "--output-last-message", "{outputFile}", "-",
    ]

    private static let legacyClaudeArguments = [
        "-p", "--no-session-persistence", "--safe-mode", "--tools", "",
        "--disallowedTools", "mcp__*", "--model", "{model}",
        "--json-schema", "{schemaJSON}",
    ]

    private static let streamingClaudeArgumentsWithBare = ["-p", "--bare"]
        + Array(legacyClaudeArguments.dropFirst())
        + ["--output-format", "stream-json", "--verbose"]
}

enum CommandLineCorrectionConfigurationError: LocalizedError {
    case executableMustBeAbsolute
    case modelRequired
    case placeholderMustBeWholeArgument(String)
    case invalidValue

    var errorDescription: String? {
        switch self {
        case .executableMustBeAbsolute:
            "Choose an executable using its full path."
        case .modelRequired:
            "Enter a model name or remove {model} from the arguments."
        case .placeholderMustBeWholeArgument(let placeholder):
            "Put \(placeholder) in its own argument row."
        case .invalidValue:
            "The command-line correction settings are invalid."
        }
    }
}
