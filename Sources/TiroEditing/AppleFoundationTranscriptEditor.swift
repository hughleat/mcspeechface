import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleFoundationTranscriptEditorError: LocalizedError {
    case unavailable(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .invalidResponse: "Apple Intelligence returned an invalid edit proposal."
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
public actor AppleFoundationTranscriptEditor: TranscriptEditor {
    public nonisolated let id = "apple-foundation-model"
    public nonisolated let name = "Apple Intelligence"

    private let model: SystemLanguageModel
    private let schema: GenerationSchema

    public init() throws {
        model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        schema = try Self.makeSchema()
    }

    public func availability() async -> TranscriptEditorAvailability {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "This Mac does not support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Turn on Apple Intelligence in System Settings.")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "Apple Intelligence is still preparing its local model.")
        case .unavailable:
            return .unavailable(reason: "Apple Intelligence is unavailable.")
        }
    }

    public func proposeEdits(
        for request: TranscriptEditRequest
    ) async throws -> TranscriptEditDecision {
        let currentAvailability = await availability()
        guard case .available = currentAvailability else {
            if case .unavailable(let reason) = currentAvailability {
                throw AppleFoundationTranscriptEditorError.unavailable(reason)
            }
            throw AppleFoundationTranscriptEditorError.unavailable(
                "Apple Intelligence is unavailable."
            )
        }
        guard !request.text.isEmpty else { return .unchanged }
        try TranscriptEditingPrompt.validate(request)

        let session = LanguageModelSession(
            model: model,
            instructions: TranscriptEditingPrompt.instructions(request)
        )
        let response = try await session.respond(
            to: TranscriptEditingPrompt.request(request),
            schema: schema,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 700)
        )
        let content = response.content
        let hasChanges = try content.value(Bool.self, forProperty: "hasChanges")
        guard hasChanges else { return .unchanged }
        let explanation = try content.value(String.self, forProperty: "explanation")
        let generatedEdits = try content.value(
            [GeneratedContent].self,
            forProperty: "edits"
        )
        let edits = try generatedEdits.map { generated in
            TranscriptEditOperation(
                exactText: try generated.value(String.self, forProperty: "exactText"),
                replacement: try generated.value(String.self, forProperty: "replacement"),
                occurrence: try generated.value(Int?.self, forProperty: "occurrence")
            )
        }
        guard !edits.isEmpty else {
            throw AppleFoundationTranscriptEditorError.invalidResponse
        }
        return .proposal(try TranscriptEditValidator.proposal(
            for: request.text,
            edits: edits,
            explanation: explanation
        ))
    }

    private static func makeSchema() throws -> GenerationSchema {
        let edit = DynamicGenerationSchema(
            name: "TranscriptEdit",
            description: "One exact, source-grounded transcript edit.",
            properties: [
                .init(
                    name: "exactText",
                    description: "An exact substring copied from the transcript.",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
                .init(
                    name: "replacement",
                    description: "Replacement text, or an empty string to delete exactText.",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
                .init(
                    name: "occurrence",
                    description: "One-based occurrence when exactText appears more than once.",
                    schema: DynamicGenerationSchema(type: Int.self),
                    isOptional: true
                ),
            ]
        )
        let decision = DynamicGenerationSchema(
            name: "TranscriptEditDecision",
            description: "A conservative decision about explicit spoken corrections.",
            properties: [
                .init(name: "hasChanges", schema: DynamicGenerationSchema(type: Bool.self)),
                .init(
                    name: "explanation",
                    description: "A short explanation, empty when hasChanges is false.",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
                .init(
                    name: "edits",
                    description: "Exact edits, empty when hasChanges is false.",
                    schema: DynamicGenerationSchema(
                        arrayOf: DynamicGenerationSchema(referenceTo: "TranscriptEdit"),
                        minimumElements: 0,
                        maximumElements: 24
                    )
                ),
            ]
        )
        return try GenerationSchema(root: decision, dependencies: [edit])
    }
}
#else
@available(macOS 26.0, *)
public actor AppleFoundationTranscriptEditor: TranscriptEditor {
    public nonisolated let id = "apple-foundation-model"
    public nonisolated let name = "Apple Intelligence"

    public init() throws {}

    public func availability() async -> TranscriptEditorAvailability {
        .unavailable(reason: "This build does not include Apple Intelligence support.")
    }

    public func proposeEdits(
        for request: TranscriptEditRequest
    ) async throws -> TranscriptEditDecision {
        throw AppleFoundationTranscriptEditorError.unavailable(
            "This build does not include Apple Intelligence support."
        )
    }
}
#endif
