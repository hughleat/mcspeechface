import Foundation
import Testing
@testable import TiroEditing

struct TranscriptCorrectionComparisonTests {
    @Test
    func comparesSelectedProvidersSequentiallyWithTheSameRequest() async throws {
        let recorder = ComparisonRecorder()
        let request = TranscriptEditRequest(
            text: "Um, send it tomorrow.",
            language: "en-GB",
            promptConfiguration: TranscriptEditingPromptConfiguration(
                systemPrompt: "Correct the transcript.",
                userPromptTemplate: "<transcript>{transcript}</transcript>"
            )
        )
        let proposal = TranscriptEditProposal(
            originalText: request.text,
            revisedText: "Send it tomorrow.",
            explanation: "Removed a filler."
        )
        let providers = [
            TranscriptCorrectionProvider(editor: RecordingEditor(
                id: "first",
                name: "First",
                behavior: .decision(.proposal(proposal)),
                recorder: recorder
            )),
            TranscriptCorrectionProvider(editor: RecordingEditor(
                id: "second",
                name: "Second",
                behavior: .decision(.unchanged),
                recorder: recorder
            )),
        ]

        let comparison = try await TranscriptCorrectionComparator().compare(
            request: request,
            providers: providers
        )

        #expect(comparison.request == request)
        #expect(comparison.results.map(\.providerID) == ["first", "second"])
        #expect(comparison.results.allSatisfy { $0.latency >= .zero })
        #expect(await recorder.requests == [request, request])
        #expect(await recorder.events == [
            .started("first"),
            .finished("first"),
            .started("second"),
            .finished("second"),
        ])
        #expect(comparison.results[0].outcome == .completed(.proposal(proposal)))
        #expect(comparison.results[1].outcome == .completed(.unchanged))
    }

    @Test
    func retainsProviderFailureAndContinuesComparison() async throws {
        let recorder = ComparisonRecorder()
        let request = TranscriptEditRequest(text: "Keep this.", language: "English")
        let providers = [
            TranscriptCorrectionProvider(editor: RecordingEditor(
                id: "failing",
                name: "Failing",
                behavior: .failure,
                recorder: recorder
            )),
            TranscriptCorrectionProvider(editor: RecordingEditor(
                id: "working",
                name: "Working",
                behavior: .decision(.unchanged),
                recorder: recorder
            )),
        ]

        let comparison = try await TranscriptCorrectionComparator().compare(
            request: request,
            providers: providers
        )

        guard case .failed(let failure) = comparison.results[0].outcome else {
            Issue.record("Expected the first provider to fail.")
            return
        }
        #expect(failure.typeName.contains("ComparisonError"))
        #expect(failure.message == "The test provider failed.")
        #expect(!failure.domain.isEmpty)
        #expect(comparison.results[1].outcome == .completed(.unchanged))
        #expect(await recorder.requests == [request, request])
    }

    @Test
    func emptySelectionProducesAnEmptyComparison() async throws {
        let request = TranscriptEditRequest(text: "Nothing to compare.", language: "English")

        let comparison = try await TranscriptCorrectionComparator().compare(
            request: request,
            providers: []
        )

        #expect(comparison == TranscriptCorrectionComparison(request: request, results: []))
    }
}

private enum ComparisonBehavior: Sendable {
    case decision(TranscriptEditDecision)
    case failure
}

private enum ComparisonError: LocalizedError {
    case failed

    var errorDescription: String? { "The test provider failed." }
}

private actor ComparisonRecorder {
    enum Event: Equatable, Sendable {
        case started(String)
        case finished(String)
    }

    private(set) var requests: [TranscriptEditRequest] = []
    private(set) var events: [Event] = []

    func start(providerID: String, request: TranscriptEditRequest) {
        requests.append(request)
        events.append(.started(providerID))
    }

    func finish(providerID: String) {
        events.append(.finished(providerID))
    }
}

private struct RecordingEditor: TranscriptEditor {
    let id: String
    let name: String
    let behavior: ComparisonBehavior
    let recorder: ComparisonRecorder

    func availability() async -> TranscriptEditorAvailability { .available }

    func proposeEdits(for request: TranscriptEditRequest) async throws -> TranscriptEditDecision {
        await recorder.start(providerID: id, request: request)
        await Task.yield()
        await recorder.finish(providerID: id)

        switch behavior {
        case .decision(let decision): return decision
        case .failure: throw ComparisonError.failed
        }
    }
}
