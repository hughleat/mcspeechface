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
        try await proposeEdits(for: request, progressHandler: nil)
    }

    public func proposeEdits(
        for request: TranscriptEditRequest,
        progressHandler: (@Sendable (TranscriptEditingProgress) -> Void)?
    ) async throws -> TranscriptEditDecision {
        guard !request.text.isEmpty else { return .unchanged }
        try TranscriptEditingPrompt.validate(request)
        guard case .available = await availability() else {
            if !FileManager.default.fileExists(atPath: configuration.executableURL.path) {
                throw CommandLineCorrectionError.executableNotFound
            }
            throw CommandLineCorrectionError.executableNotRunnable
        }

        let progressReporter = CommandLineProgressReporter(
            providerName: name,
            progressHandler: progressHandler
        )
        progressReporter.report(.starting)
        let result = try await runner.run(
            configuration: configuration,
            standardInput: Self.promptData(for: request),
            eventHandler: { line in
                guard let phase = Self.progressPhase(from: line) else { return }
                progressReporter.report(phase)
            }
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
        let structuredOutput = streamedResult(in: output) ?? output
        guard let data = structuredOutput.data(using: .utf8),
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

    static func streamedResult(in output: String) -> String? {
        for line in output.split(whereSeparator: \Character.isNewline).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if object["type"] as? String == "result",
               let structuredOutput = object["structured_output"],
               let result = jsonString(from: structuredOutput) {
                return result
            }
            if object["type"] as? String == "result",
               let result = object["result"] {
                if let result = result as? String { return result }
                if let result = jsonString(from: result) { return result }
            }
            if object["type"] as? String == "item.completed",
               let item = object["item"] as? [String: Any],
               item["type"] as? String == "agent_message",
               let text = item["text"] as? String {
                return text
            }
        }
        return nil
    }

    private static func jsonString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private static func progressPhase(from line: String) -> TranscriptEditingProgressPhase? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "thread.started", "system", "session.started":
            return .working
        case "item.completed", "assistant", "content_block_delta":
            return .receiving
        case "turn.started", "message_start", "message_delta":
            return .working
        case "result", "turn.completed":
            return .receiving
        default:
            return nil
        }
    }

    private struct GeneratedDecision: Decodable {
        let hasChanges: Bool
        let explanation: String
        let revisedText: String
    }
}

private final class CommandLineProgressReporter: @unchecked Sendable {
    private let providerName: String
    private let progressHandler: (@Sendable (TranscriptEditingProgress) -> Void)?
    private let lock = NSLock()
    private var highestPhase = -1

    init(
        providerName: String,
        progressHandler: (@Sendable (TranscriptEditingProgress) -> Void)?
    ) {
        self.providerName = providerName
        self.progressHandler = progressHandler
    }

    func report(_ phase: TranscriptEditingProgressPhase) {
        let rank = switch phase {
        case .starting: 0
        case .working: 1
        case .receiving: 2
        }
        lock.lock()
        guard rank > highestPhase else {
            lock.unlock()
            return
        }
        highestPhase = rank
        lock.unlock()
        progressHandler?(TranscriptEditingProgress(providerName: providerName, phase: phase))
    }
}
