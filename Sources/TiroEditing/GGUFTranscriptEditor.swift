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

    private let modelURL: URL
    private let executableURL: URL?
    private let server: any LocalCorrectionServing

    public init(
        spec: LocalTranscriptEditingModelSpec,
        executableURL: URL,
        modelURL: URL,
        idleTimeout: TimeInterval = 600
    ) {
        id = spec.id
        name = spec.name
        self.modelURL = modelURL
        self.executableURL = executableURL
        server = PersistentLlamaServer(
            executableURL: executableURL,
            modelURL: modelURL,
            idleTimeout: idleTimeout
        )
    }

    init(
        spec: LocalTranscriptEditingModelSpec,
        modelURL: URL,
        server: any LocalCorrectionServing
    ) {
        id = spec.id
        name = spec.name
        self.modelURL = modelURL
        executableURL = nil
        self.server = server
    }

    public func availability() async -> TranscriptEditorAvailability {
        if let executableURL,
           !FileManager.default.isExecutableFile(atPath: executableURL.path) {
            return .unavailable(
                reason: GGUFTranscriptEditorError.runtimeUnavailable.localizedDescription
            )
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            return .unavailable(reason: GGUFTranscriptEditorError.modelNotInstalled.localizedDescription)
        }
        return .available
    }

    public func runtimeState() async -> LocalCorrectionRuntimeState {
        await server.runtimeState()
    }

    public func updateIdleTimeout(_ timeout: TimeInterval) async {
        await server.updateIdleTimeout(timeout)
    }

    public func beginUse() async {
        await server.beginUse()
    }

    public func endUse() async {
        await server.endUse()
    }

    public func prepare() async throws {
        guard case .available = await availability() else {
            if let executableURL,
               !FileManager.default.isExecutableFile(atPath: executableURL.path) {
                throw GGUFTranscriptEditorError.runtimeUnavailable
            }
            throw GGUFTranscriptEditorError.modelNotInstalled
        }
        try await server.prepare()
    }

    public func stop() async {
        await server.stop()
    }

    public func proposeEdits(
        for request: TranscriptEditRequest
    ) async throws -> TranscriptEditDecision {
        guard case .available = await availability() else {
            if let executableURL,
               !FileManager.default.isExecutableFile(atPath: executableURL.path) {
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

        let output = try await server.generate(
            request: request,
            grammar: Self.jsonGrammar
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
