import Foundation

public struct TranscriptCorrectionProvider: Sendable {
    public let id: String
    public let name: String

    private let editor: any TranscriptEditor

    public init(editor: any TranscriptEditor) {
        id = editor.id
        name = editor.name
        self.editor = editor
    }

    fileprivate func proposeEdits(
        for request: TranscriptEditRequest
    ) async throws -> TranscriptEditDecision {
        try await editor.proposeEdits(for: request)
    }
}

public struct TranscriptCorrectionFailure: Equatable, Sendable {
    public let typeName: String
    public let message: String
    public let domain: String
    public let code: Int

    public init(error: any Error) {
        let nsError = error as NSError
        typeName = String(reflecting: type(of: error))
        message = error.localizedDescription
        domain = nsError.domain
        code = nsError.code
    }
}

public enum TranscriptCorrectionOutcome: Equatable, Sendable {
    case completed(TranscriptEditDecision)
    case failed(TranscriptCorrectionFailure)
}

public struct TranscriptCorrectionResult: Equatable, Sendable {
    public let providerID: String
    public let providerName: String
    public let latency: Duration
    public let outcome: TranscriptCorrectionOutcome

    public init(
        providerID: String,
        providerName: String,
        latency: Duration,
        outcome: TranscriptCorrectionOutcome
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.latency = latency
        self.outcome = outcome
    }
}

public struct TranscriptCorrectionComparison: Equatable, Sendable {
    public let request: TranscriptEditRequest
    public let results: [TranscriptCorrectionResult]

    public init(
        request: TranscriptEditRequest,
        results: [TranscriptCorrectionResult]
    ) {
        self.request = request
        self.results = results
    }
}

public struct TranscriptCorrectionComparator: Sendable {
    public init() {}

    public func compare(
        request: TranscriptEditRequest,
        providers: [TranscriptCorrectionProvider]
    ) async throws -> TranscriptCorrectionComparison {
        let clock = ContinuousClock()
        var results: [TranscriptCorrectionResult] = []
        results.reserveCapacity(providers.count)

        for provider in providers {
            try Task.checkCancellation()
            let startedAt = clock.now
            let outcome: TranscriptCorrectionOutcome

            do {
                let decision = try await provider.proposeEdits(for: request)
                try Task.checkCancellation()
                outcome = .completed(decision)
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                outcome = .failed(TranscriptCorrectionFailure(error: error))
            }

            results.append(TranscriptCorrectionResult(
                providerID: provider.id,
                providerName: provider.name,
                latency: startedAt.duration(to: clock.now),
                outcome: outcome
            ))
        }

        return TranscriptCorrectionComparison(request: request, results: results)
    }
}
