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
        case .invalidResponse: "The local editing model returned an invalid edit proposal."
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
        // A byte is the tokenizer's worst-case fallback token. This leaves room for the chat
        // template and 700 output tokens inside Qwen's 4,096-token context.
        do {
            try TranscriptEditingPrompt.validate(
                request,
                maximumCombinedUTF8Bytes:
                    TranscriptEditingPromptConfiguration.localModelMaximumInputUTF8Bytes
            )
        } catch TranscriptEditingPromptError.renderedPromptTooLong {
            throw GGUFTranscriptEditorError.transcriptTooLong
        }

        let output = try await runner.run(
            executableURL: executableURL,
            arguments: Self.arguments(modelURL: modelURL, request: request),
            timeout: 90
        )
        return try Self.decision(from: output, originalText: request.text)
    }

    static func decision(from output: String, originalText: String) throws -> TranscriptEditDecision {
        let response = jsonObjectData(in: output).lazy.compactMap {
            try? JSONDecoder().decode(GeneratedDecision.self, from: $0)
        }.first
        guard let response else {
            throw GGUFTranscriptEditorError.invalidResponse
        }
        guard response.hasChanges else { return .unchanged }
        let edits = response.edits.map {
            TranscriptEditOperation(
                exactText: $0.exactText,
                replacement: $0.replacement,
                occurrence: $0.occurrence
            )
        }
        return .proposal(try TranscriptEditValidator.proposal(
            for: originalText,
            edits: edits,
            explanation: response.explanation
        ))
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
        request: TranscriptEditRequest
    ) -> [String] {
        [
            "--model", modelURL.path,
            "--system-prompt", TranscriptEditingPrompt.instructions(request),
            "--prompt", TranscriptEditingPrompt.request(request),
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
            "--n-predict", "700",
            "--gpu-layers", "all",
            "--no-perf",
            "--log-disable",
        ]
    }

    private static let jsonGrammar = #"""
        root ::= "{" ws "\"hasChanges\"" ws ":" ws boolean ws "," ws "\"explanation\"" ws ":" ws string ws "," ws "\"edits\"" ws ":" ws edits ws "}"
        boolean ::= "true" | "false"
        edits ::= "[" ws (edit (ws "," ws edit)*)? ws "]"
        edit ::= "{" ws "\"exactText\"" ws ":" ws string ws "," ws "\"replacement\"" ws ":" ws string ws "," ws "\"occurrence\"" ws ":" ws (integer | "null") ws "}"
        integer ::= [1-9] [0-9]*
        string ::= "\"" char* "\""
        char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" hex hex hex hex)
        hex ::= [0-9a-fA-F]
        ws ::= [ \t\n\r]*
        """#

    private struct GeneratedDecision: Decodable {
        let hasChanges: Bool
        let explanation: String
        let edits: [GeneratedEdit]
    }

    private struct GeneratedEdit: Decodable {
        let exactText: String
        let replacement: String
        let occurrence: Int?
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
        let execution = ProcessExecution(executableURL: executableURL, arguments: arguments)
        return try await execution.run(timeout: timeout)
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let errorOutput = Pipe()

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorOutput
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "PATH": "/usr/bin:/bin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
    }

    func run(timeout: TimeInterval) async throws -> String {
        do {
            try process.run()
        } catch {
            throw GGUFTranscriptEditorError.generationFailed(error.localizedDescription)
        }

        return try await withTaskCancellationHandler {
            let timedOut = await wait(timeout: timeout)
            if timedOut {
                throw GGUFTranscriptEditorError.generationTimedOut
            }
            try Task.checkCancellation()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let reason = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let failureReason = reason.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "exit code \(process.terminationStatus)"
                throw GGUFTranscriptEditorError.generationFailed(failureReason)
            }
            guard outputData.count <= 512_000,
                  let text = String(data: outputData, encoding: .utf8) else {
                throw GGUFTranscriptEditorError.invalidResponse
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } onCancel: {
            terminate()
        }
    }

    private func wait(timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForProcessExit()
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return false }
                self.terminate()
                return true
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func waitForProcessExit() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private func terminate() {
        if process.isRunning { process.terminate() }
    }
}
