import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleFoundationTranscriptEditorError: LocalizedError {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
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
            options: GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: TranscriptEditingPrompt.maximumResponseTokens(request)
            )
        )
        let content = response.content
        let hasChanges = try content.value(Bool.self, forProperty: "hasChanges")
        let explanation = try content.value(String.self, forProperty: "explanation")
        let revisedText = try content.value(String.self, forProperty: "revisedText")
        return try TranscriptEditValidator.decision(
            hasChanges: hasChanges,
            originalText: request.text,
            revisedText: revisedText,
            explanation: explanation,
            requiresGrounding: !request.promptConfiguration.isCustom
        )
    }

    private static func makeSchema() throws -> GenerationSchema {
        let decision = DynamicGenerationSchema(
            name: "TranscriptEditDecision",
            description: "Structured output with three required fields.",
            properties: [
                .init(name: "hasChanges", schema: DynamicGenerationSchema(type: Bool.self)),
                .init(
                    name: "explanation",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
                .init(
                    name: "revisedText",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
            ]
        )
        return try GenerationSchema(root: decision, dependencies: [])
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
