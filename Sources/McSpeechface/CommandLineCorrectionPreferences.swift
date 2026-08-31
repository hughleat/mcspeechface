import Foundation
import McSpeechfaceEditing

enum CorrectionProviderConnectionMode: String, Codable, CaseIterable, Sendable {
    case enhanced
    case commandLine

    var title: String {
        switch self {
        case .enhanced: "Fast streaming"
        case .commandLine: "Command line"
        }
    }

    var detail: String {
        switch self {
        case .enhanced: "Use native streaming and prepare the provider while recording"
        case .commandLine: "Start a fresh provider process for each correction"
        }
    }
}

enum CorrectionProviderConversationMode: String, Codable, CaseIterable, Sendable {
    case fresh
    case continueUntilStopped

    var title: String {
        switch self {
        case .fresh: "Fresh for each correction"
        case .continueUntilStopped: "Continue until stopped"
        }
    }

    var detail: String {
        switch self {
        case .fresh:
            "Each correction starts without earlier transcript context"
        case .continueUntilStopped:
            "Reset context on Stop, timeout, settings or system prompt change, or app exit"
        }
    }
}

enum CorrectionProviderAccessProfile: String, Codable, CaseIterable, Sendable {
    case correctionOnly
    case readOnly
    case standard
    case unrestricted

    var title: String {
        switch self {
        case .correctionOnly: "Isolated correction"
        case .readOnly: "Read-only tools"
        case .standard: "Agent tools (provider policy)"
        case .unrestricted: "Unrestricted"
        }
    }

    var detail: String {
        switch self {
        case .correctionOnly:
            "No file or network tools; the transcript is still sent to the provider"
        case .readOnly:
            "Allow read-only tools while preventing changes"
        case .standard:
            "Allow configured tools under the provider's normal permission policy"
        case .unrestricted:
            "Allow all configured tools without approval prompts"
        }
    }

    var requiresWarning: Bool { self == .standard || self == .unrestricted }

    var warningTitle: String {
        switch self {
        case .standard: "Allow Agent Tools?"
        case .unrestricted: "Allow Unrestricted Agent Access?"
        case .correctionOnly, .readOnly: ""
        }
    }

    var warningDetail: String {
        switch self {
        case .standard:
            "Dictated text is untrusted input. The provider may request actions that read "
                + "or modify files within its sandbox."
        case .unrestricted:
            "Dictated text is untrusted input. The provider may run tools or modify files "
                + "without approval prompts."
        case .correctionOnly, .readOnly: ""
        }
    }
}

enum CorrectionProviderReasoningEffort: String, Codable, CaseIterable, Sendable {
    case automatic
    case low
    case medium
    case high
    case xhigh
    case max

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .low: "Low (fastest)"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Maximum"
        }
    }

    var commandLineValue: String? { self == .automatic ? nil : rawValue }
}

struct CorrectionProviderModelOption: Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
}

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
                model: "gpt-5.6-luna",
                arguments: [],
                connectionMode: .enhanced,
                accessProfile: .correctionOnly,
                reasoningEffort: .low
            )
        case .claude:
            CommandLineCorrectionConfiguration(
                preset: self,
                executablePath: Self.defaultClaudePath,
                model: "haiku",
                arguments: [],
                connectionMode: .enhanced,
                accessProfile: .correctionOnly,
                reasoningEffort: .low
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
    var connectionMode: CorrectionProviderConnectionMode
    var accessProfile: CorrectionProviderAccessProfile
    var reasoningEffort: CorrectionProviderReasoningEffort
    var conversationMode: CorrectionProviderConversationMode
    var idleTimeoutSeconds: Int

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
        arguments: [String],
        connectionMode: CorrectionProviderConnectionMode = .commandLine,
        accessProfile: CorrectionProviderAccessProfile = .correctionOnly,
        reasoningEffort: CorrectionProviderReasoningEffort = .automatic,
        conversationMode: CorrectionProviderConversationMode = .fresh,
        idleTimeoutSeconds: Int = 600
    ) {
        self.preset = preset
        self.executablePath = executablePath
        self.model = model
        self.arguments = arguments
        self.connectionMode = preset == .custom ? .commandLine : connectionMode
        self.accessProfile = accessProfile
        self.reasoningEffort = reasoningEffort
        self.conversationMode = conversationMode
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }

    var modelOptions: [CorrectionProviderModelOption] {
        switch preset {
        case .codex:
            [
                .init(id: "gpt-5.6-luna", title: "GPT-5.6 Luna", detail: "Fastest"),
                .init(id: "gpt-5.6-terra", title: "GPT-5.6 Terra", detail: "Balanced"),
                .init(id: "gpt-5.6-sol", title: "GPT-5.6 Sol", detail: "Most capable"),
            ]
        case .claude:
            [
                .init(id: "haiku", title: "Claude Haiku", detail: "Fastest"),
                .init(id: "sonnet", title: "Claude Sonnet", detail: "Balanced"),
                .init(id: "opus", title: "Claude Opus", detail: "Most capable"),
            ]
        case .custom: []
        }
    }

    var effectiveArguments: [String] {
        guard preset != .custom else { return arguments }
        if usesExplicitArguments { return arguments }
        var result: [String]
        switch preset {
        case .codex:
            result = ["exec", "--ephemeral", "--skip-git-repo-check"]
            switch accessProfile {
            case .correctionOnly:
                result += ["--sandbox", "read-only", "--ignore-user-config", "--ignore-rules"]
            case .readOnly:
                result += ["--sandbox", "read-only"]
            case .standard:
                result += ["--sandbox", "workspace-write", "--approve-for-me"]
            case .unrestricted:
                result += ["--dangerously-bypass-approvals-and-sandbox"]
            }
            result += ["--model", "{model}"]
            if let effort = reasoningEffort.commandLineValue {
                result += ["-c", "model_reasoning_effort=\"\(effort)\""]
            }
            result += [
                "--output-schema", "{schemaFile}",
                "--output-last-message", "{outputFile}",
                "--json", "-",
            ]
        case .claude:
            result = ["-p", "--no-session-persistence"]
            switch accessProfile {
            case .correctionOnly:
                result += [
                    "--tools", "", "--disallowedTools", "mcp__*",
                    "--permission-mode", "dontAsk", "--disable-slash-commands",
                    "--setting-sources", "", "--settings", #"{"autoMemoryEnabled":false}"#,
                    "--max-turns", "1",
                ]
            case .readOnly:
                result += [
                    "--tools", "Read,Glob,Grep,WebSearch,WebFetch",
                    "--disallowedTools", "mcp__*", "--permission-mode", "dontAsk",
                ]
            case .standard:
                result += ["--tools", "default", "--permission-mode", "default"]
            case .unrestricted:
                result += ["--tools", "default", "--dangerously-skip-permissions"]
            }
            result += ["--model", "{model}"]
            if let effort = reasoningEffort.commandLineValue {
                result += ["--effort", effort]
            }
            result += [
                "--json-schema", "{schemaJSON}",
                "--output-format", "stream-json", "--verbose",
            ]
        case .custom:
            result = arguments
        }
        return result
    }

    var usesExplicitArguments: Bool {
        preset != .custom && connectionMode == .commandLine && !arguments.isEmpty
    }

    var codexAccess: CodexCorrectionAccess {
        switch accessProfile {
        case .correctionOnly: .correctionOnly
        case .readOnly: .readOnly
        case .standard: .standard
        case .unrestricted: .unrestricted
        }
    }

    func validate() throws {
        guard executablePath.hasPrefix("/") else {
            throw CommandLineCorrectionConfigurationError.executableMustBeAbsolute
        }
        guard !executablePath.contains("\n"), !model.contains("\n") else {
            throw CommandLineCorrectionConfigurationError.invalidValue
        }
        guard !effectiveArguments.contains(where: { $0.contains("{model}") }) || !model.isEmpty else {
            throw CommandLineCorrectionConfigurationError.modelRequired
        }
        for placeholder in ["{schemaFile}", "{schemaJSON}", "{outputFile}"] {
            if effectiveArguments.contains(where: { $0.contains(placeholder) && $0 != placeholder }) {
                throw CommandLineCorrectionConfigurationError.placeholderMustBeWholeArgument(
                    placeholder
                )
            }
        }
        guard executablePath.count <= 2_048,
              model.count <= 256,
              effectiveArguments.count <= 128,
              effectiveArguments.allSatisfy({ $0.count <= 4_096 }),
              (0...86_400).contains(idleTimeoutSeconds) else {
            throw CommandLineCorrectionConfigurationError.invalidValue
        }
    }

    static func load(
        preset: CommandLineCorrectionPreset,
        from defaults: UserDefaults = .standard
    ) -> Self {
        if let configuration = decode(from: defaults, key: storageKey(for: preset)),
           configuration.preset == preset {
            return configuration.addingStructuredDefaultsWhenUsingLegacyConfiguration()
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

    private func addingStructuredDefaultsWhenUsingLegacyConfiguration() -> Self {
        var migrated = self
        switch preset {
        case .codex:
            guard arguments == Self.legacyCodexArguments,
                  let insertionIndex = arguments.firstIndex(of: "-") else { return migrated }
            migrated.connectionMode = .enhanced
            migrated.reasoningEffort = .low
            migrated.arguments.insert("--json", at: insertionIndex)
        case .claude:
            if arguments == Self.legacyClaudeArguments {
                migrated.connectionMode = .enhanced
                migrated.reasoningEffort = .low
                migrated.arguments.append(
                    contentsOf: ["--output-format", "stream-json", "--verbose"]
                )
            } else if arguments == Self.streamingClaudeArgumentsWithBare {
                migrated.connectionMode = .enhanced
                migrated.reasoningEffort = .low
                migrated.arguments.removeAll(where: { $0 == "--bare" })
            } else {
                return migrated
            }
        case .custom:
            return migrated
        }
        return migrated
    }

    private enum CodingKeys: String, CodingKey {
        case preset, executablePath, model, arguments, connectionMode, accessProfile
        case reasoningEffort, conversationMode, idleTimeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = try container.decode(CommandLineCorrectionPreset.self, forKey: .preset)
        executablePath = try container.decode(String.self, forKey: .executablePath)
        model = try container.decode(String.self, forKey: .model)
        arguments = try container.decode([String].self, forKey: .arguments)
        connectionMode = try container.decodeIfPresent(
            CorrectionProviderConnectionMode.self,
            forKey: .connectionMode
        ) ?? .commandLine
        accessProfile = try container.decodeIfPresent(
            CorrectionProviderAccessProfile.self,
            forKey: .accessProfile
        ) ?? .correctionOnly
        reasoningEffort = try container.decodeIfPresent(
            CorrectionProviderReasoningEffort.self,
            forKey: .reasoningEffort
        ) ?? .automatic
        conversationMode = try container.decodeIfPresent(
            CorrectionProviderConversationMode.self,
            forKey: .conversationMode
        ) ?? .fresh
        idleTimeoutSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .idleTimeoutSeconds
        ) ?? 600
        if preset == .custom { connectionMode = .commandLine }
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
