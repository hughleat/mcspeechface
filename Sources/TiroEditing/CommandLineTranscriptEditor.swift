import Foundation

public actor CommandLineTranscriptEditor: TranscriptEditor {
    public nonisolated let id: String
    public nonisolated let name: String

    private let configuration: CommandLineCorrectionConfiguration
    private let runner: any CommandLineCorrectionProcessRunning
    private let requiresGrounding: Bool

    public init(
        configuration: CommandLineCorrectionConfiguration,
        requiresGrounding: Bool = true
    ) {
        id = configuration.id
        name = configuration.name
        self.configuration = configuration
        self.requiresGrounding = requiresGrounding
        runner = FoundationCommandLineCorrectionProcessRunner()
    }

    init(
        configuration: CommandLineCorrectionConfiguration,
        runner: any CommandLineCorrectionProcessRunning
    ) {
        id = configuration.id
        name = configuration.name
        self.configuration = configuration
        requiresGrounding = true
        self.runner = runner
    }

    public func availability() async -> TranscriptEditorAvailability {
        let fileManager = FileManager.default
        let executableURL = configuration.executableURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: executableURL.path) else {
            return .unavailable(reason: CommandLineCorrectionError.executableNotFound.localizedDescription)
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: executableURL.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            return .unavailable(reason: CommandLineCorrectionError.executableNotRunnable.localizedDescription)
        }
        return .available
    }

    public func proposeEdits(
        for request: TranscriptEditRequest
    ) async throws -> TranscriptEditDecision {
        guard !request.text.isEmpty else { return .unchanged }
        try TranscriptEditingPrompt.validate(request)
        guard case .available = await availability() else {
            if !FileManager.default.fileExists(atPath: configuration.executableURL.path) {
                throw CommandLineCorrectionError.executableNotFound
            }
            throw CommandLineCorrectionError.executableNotRunnable
        }

        let result = try await runner.run(
            configuration: configuration,
            standardInput: Self.promptData(for: request)
        )
        return try Self.decision(
            from: result.standardOutput,
            originalText: request.text,
            requiresGrounding: requiresGrounding && !request.promptConfiguration.isCustom
        )
    }

    static func promptData(for request: TranscriptEditRequest) -> Data {
        Data("""
            <system>
            \(TranscriptEditingPrompt.instructions(request))
            </system>
            <user>
            \(TranscriptEditingPrompt.request(request))
            </user>
            """.utf8)
    }

    static func decision(
        from output: String,
        originalText: String,
        requiresGrounding: Bool = true
    ) throws -> TranscriptEditDecision {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["hasChanges", "explanation", "revisedText"],
              let response = try? JSONDecoder().decode(GeneratedDecision.self, from: data) else {
            throw CommandLineCorrectionError.invalidResponse
        }
        return try TranscriptEditValidator.decision(
            hasChanges: response.hasChanges,
            originalText: originalText,
            revisedText: response.revisedText,
            explanation: response.explanation,
            requiresGrounding: requiresGrounding
        )
    }

    private struct GeneratedDecision: Decodable {
        let hasChanges: Bool
        let explanation: String
        let revisedText: String
    }
}
