import Foundation

public enum GGUFTranscriptEditorError: LocalizedError {
    case runtimeUnavailable
    case modelNotInstalled
    case transcriptTooLong
    case generationTimedOut
    case generationFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable: "Tiro's local language model runtime is unavailable."
        case .modelNotInstalled: "Download the local editing model before using it."
        case .transcriptTooLong: "This transcript is too long for the local editing model."
        case .generationTimedOut: "The local editing model took too long to respond."
        case .generationFailed(let reason): "The local editing model failed: \(reason)"
        case .invalidResponse: "The local editing model returned an invalid correction."
        }
    }
}

public actor GGUFTranscriptEditor: TranscriptEditor {
    public nonisolated let id: String
    public nonisolated let name: String

    private let executableURL: URL
    private let modelURL: URL
    private let runner: any TranscriptEditingProcessRunning

    public init(
        spec: LocalTranscriptEditingModelSpec,
        executableURL: URL,
        modelURL: URL
    ) {
        id = spec.id
        name = spec.name
        self.executableURL = executableURL
        self.modelURL = modelURL
        runner = FoundationTranscriptEditingProcessRunner()
    }

    init(
        spec: LocalTranscriptEditingModelSpec,
        executableURL: URL,
        modelURL: URL,
        runner: any TranscriptEditingProcessRunning
    ) {
        id = spec.id
        name = spec.name
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.runner = runner
    }

    public func availability() async -> TranscriptEditorAvailability {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .unavailable(reason: GGUFTranscriptEditorError.runtimeUnavailable.localizedDescription)
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            return .unavailable(reason: GGUFTranscriptEditorError.modelNotInstalled.localizedDescription)
        }
        return .available
    }

    public func proposeEdits(
        for request: TranscriptEditRequest
    ) async throws -> TranscriptEditDecision {
        guard case .available = await availability() else {
            if !FileManager.default.isExecutableFile(atPath: executableURL.path) {
                throw GGUFTranscriptEditorError.runtimeUnavailable
            }
            throw GGUFTranscriptEditorError.modelNotInstalled
        }
        guard !request.text.isEmpty else { return .unchanged }
        // Bound the prompt while the output allowance scales with the transcript, leaving the
        // model room to return the complete revised text instead of a fixed-size fragment.
        do {
            try TranscriptEditingPrompt.validate(
                request,
                maximumCombinedUTF8Bytes:
                    TranscriptEditingPrompt.localMaximumCombinedUTF8Bytes(request)
            )
        } catch TranscriptEditingPromptError.renderedPromptTooLong {
            throw GGUFTranscriptEditorError.transcriptTooLong
        }

        let promptFiles: LocalCorrectionPromptFiles
        do {
            promptFiles = try LocalCorrectionPromptFiles(request: request)
        } catch {
            throw GGUFTranscriptEditorError.generationFailed(
                "The private prompt files could not be created."
            )
        }
        defer { promptFiles.remove() }
        let output = try await runner.run(
            executableURL: executableURL,
            arguments: Self.arguments(
                modelURL: modelURL,
                request: request,
                systemPromptFile: promptFiles.systemPrompt,
                userPromptFile: promptFiles.userPrompt
            ),
            timeout: 90
        )
        return try Self.decision(
            from: output,
            originalText: request.text,
            requiresGrounding: !request.promptConfiguration.isCustom
        )
    }

    static func decision(
        from output: String,
        originalText: String,
        requiresGrounding: Bool = true
    ) throws -> TranscriptEditDecision {
        let response = jsonObjectData(in: output).lazy.compactMap {
            try? JSONDecoder().decode(GeneratedDecision.self, from: $0)
        }.first
        guard let response else {
            throw GGUFTranscriptEditorError.invalidResponse
        }
        return try TranscriptEditValidator.decision(
            hasChanges: response.hasChanges,
            originalText: originalText,
            revisedText: response.revisedText,
            explanation: response.explanation,
            requiresGrounding: requiresGrounding
        )
    }

    private static func jsonObjectData(in output: String) -> [Data] {
        let bytes = Array(output.utf8)
        var objects: [Data] = []
        var attempts = 0
        for start in bytes.indices.reversed() where bytes[start] == 0x7B {
            attempts += 1
            guard attempts <= 64 else { break }
            var depth = 0
            var inString = false
            var escaped = false
            for index in start..<bytes.endIndex {
                let byte = bytes[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        inString = false
                    }
                    continue
                }
                if byte == 0x22 {
                    inString = true
                } else if byte == 0x7B {
                    depth += 1
                } else if byte == 0x7D {
                    depth -= 1
                    if depth == 0 {
                        objects.append(Data(bytes[start...index]))
                        break
                    }
                }
            }
        }
        return objects
    }

    static func arguments(
        modelURL: URL,
        request: TranscriptEditRequest,
        systemPromptFile: URL,
        userPromptFile: URL
    ) -> [String] {
        [
            "--model", modelURL.path,
            "--system-prompt-file", systemPromptFile.path,
            "--file", userPromptFile.path,
            "--grammar", jsonGrammar,
            "--conversation",
            "--single-turn",
            "--jinja",
            "--reasoning", "off",
            "--reasoning-format", "none",
            "--no-display-prompt",
            "--color", "off",
            "--simple-io",
            "--temperature", "0",
            "--ctx-size", "4096",
            "--n-predict", String(TranscriptEditingPrompt.maximumResponseTokens(request)),
            "--gpu-layers", "all",
            "--no-warmup",
            "--no-perf",
            "--log-disable",
        ]
    }

    private static let jsonGrammar = #"""
        root ::= "{" ws "\"hasChanges\"" ws ":" ws boolean ws "," ws "\"explanation\"" ws ":" ws string ws "," ws "\"revisedText\"" ws ":" ws string ws "}"
        boolean ::= "true" | "false"
        string ::= "\"" char* "\""
        char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" hex hex hex hex)
        hex ::= [0-9a-fA-F]
        ws ::= [ \t\n\r]*
        """#

    private struct GeneratedDecision: Decodable {
        let hasChanges: Bool
        let explanation: String
        let revisedText: String
    }
}

struct LocalCorrectionPromptFiles {
    let directory: URL
    let systemPrompt: URL
    let userPrompt: URL

    init(request: TranscriptEditRequest) throws {
        let fileManager = FileManager.default
        directory = fileManager.temporaryDirectory.appendingPathComponent(
            "tiro-local-correction-\(UUID().uuidString)",
            isDirectory: true
        )
        systemPrompt = directory.appendingPathComponent("system-prompt.txt")
        userPrompt = directory.appendingPathComponent("user-prompt.txt")
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(TranscriptEditingPrompt.instructions(request).utf8)
                .write(to: systemPrompt, options: .atomic)
            try Data(TranscriptEditingPrompt.request(request).utf8)
                .write(to: userPrompt, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: systemPrompt.path
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: userPrompt.path
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

protocol TranscriptEditingProcessRunning: Sendable {
    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> String
}

struct FoundationTranscriptEditingProcessRunner: TranscriptEditingProcessRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> String {
        let configuration: CommandLineCorrectionConfiguration
        do {
            configuration = try CommandLineCorrectionConfiguration(
                id: "local-gguf-runtime",
                name: "Local correction runtime",
                executablePath: executableURL.path,
                arguments: arguments,
                timeout: timeout
            )
        } catch {
            throw GGUFTranscriptEditorError.generationFailed(error.localizedDescription)
        }
        do {
            return try await FoundationCommandLineCorrectionProcessRunner().run(
                configuration: configuration,
                standardInput: Data()
            ).standardOutput
        } catch CommandLineCorrectionError.timedOut {
            throw GGUFTranscriptEditorError.generationTimedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch CommandLineCorrectionError.outputTooLarge {
            throw GGUFTranscriptEditorError.invalidResponse
        } catch {
            throw GGUFTranscriptEditorError.generationFailed(error.localizedDescription)
        }
    }
}
