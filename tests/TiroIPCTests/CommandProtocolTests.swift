import Foundation
import Testing
@testable import TiroIPC

struct CommandProtocolTests {
    @Test
    func requestUsesStableWireKeys() throws {
        let id = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let request = TiroCommandRequest.transcribe(
            path: "/tmp/meeting.m4a",
            model: "coreml-compact",
            copy: true,
            saveHistory: false,
            diarize: true,
            correction: TiroCommandCorrection(
                model: "qwen-3-0.6b",
                instructions: "Use short paragraphs."
            ),
            id: id
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any]
        )
        #expect(object["v"] as? Int == 3)
        #expect(object["id"] as? String == id.uuidString.lowercased())
        #expect(object["command"] as? String == "transcribe")
        let arguments = try #require(object["arguments"] as? [String: Any])
        #expect(arguments["path"] as? String == "/tmp/meeting.m4a")
        #expect(arguments["save_history"] as? Bool == false)
        #expect(arguments["diarize"] as? Bool == true)
        let correction = try #require(arguments["correction"] as? [String: Any])
        #expect(correction["model"] as? String == "qwen-3-0.6b")
        #expect(correction["instructions"] as? String == "Use short paragraphs.")
    }

    @Test
    func resultUsesStructuredCorrectionMetadata() throws {
        let result = TiroCommandResult(
            kind: "transcript",
            text: "Send it today.",
            originalText: "Um, send it today.",
            correction: TiroCommandCorrectionResult(
                model: "qwen-3-0.6b",
                changed: true,
                seconds: 0.75,
                explanation: "Removed a filler.",
                reviewRecommended: false
            )
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
                as? [String: Any]
        )
        #expect(object["original_text"] as? String == "Um, send it today.")
        let correction = try #require(object["correction"] as? [String: Any])
        #expect(correction["model"] as? String == "qwen-3-0.6b")
        #expect(correction["changed"] as? Bool == true)
        #expect(correction["review_recommended"] as? Bool == false)
    }

    @Test
    func resultUsesFoundationOnlyStructuredSegments() throws {
        let result = TiroCommandResult(
            kind: "transcript",
            text: "Hello.",
            segments: [
                TiroCommandSegment(
                    text: "Hello.",
                    startTime: 1.25,
                    endTime: 2.5,
                    speakerID: "speaker-1"
                ),
            ]
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
                as? [String: Any]
        )
        let segments = try #require(object["segments"] as? [[String: Any]])
        #expect(segments.first?["text"] as? String == "Hello.")
        #expect(segments.first?["start"] as? Double == 1.25)
        #expect(segments.first?["end"] as? Double == 2.5)
        #expect(segments.first?["speaker_id"] as? String == "speaker-1")
    }

    @Test
    func validationRejectsDiarizeOnRecordingCommands() {
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandRequest(
                command: .recordStart,
                arguments: TiroCommandArguments(diarize: true)
            ).validated()
        }
    }

    @Test
    func validationBoundsCorrectionRequests() throws {
        #expect(try TiroCommandRequest.recordStart(
            model: nil,
            saveHistory: false,
            correction: TiroCommandCorrection(model: "codex", instructions: "Be concise.")
        ).validated().arguments?.correction?.model == "codex")
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandRequest(
                command: .transcribe,
                arguments: TiroCommandArguments(
                    path: "/tmp/audio.wav",
                    correction: TiroCommandCorrection(instructions: "   ")
                )
            ).validated()
        }
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandRequest(
                command: .recordStop,
                arguments: TiroCommandArguments(
                    session: UUID().uuidString,
                    correction: TiroCommandCorrection()
                )
            ).validated()
        }
    }

    @Test
    func validationRejectsArgumentsOwnedByOtherCommands() {
        let session = UUID().uuidString
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandRequest(
                command: .transcribe,
                arguments: TiroCommandArguments(path: "/tmp/audio.wav", session: session)
            ).validated()
        }
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandRequest(
                command: .recordStop,
                arguments: TiroCommandArguments(path: "/tmp/audio.wav", session: session)
            ).validated()
        }
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandRequest(
                command: .recordCancel,
                arguments: TiroCommandArguments(copy: true, session: session)
            ).validated()
        }
    }

    @Test
    func protocolVersionTwoIsRejectedAfterCorrectionSupport() throws {
        let request = TiroCommandRequest.status()
        let oldResponse = TiroCommandMessage(
            version: 2,
            id: request.id,
            type: .success,
            result: TiroCommandResult(kind: "status", state: "idle")
        )
        #expect(throws: TiroProtocolError.self) {
            try oldResponse.validated(for: request)
        }
        let oldRequest = try JSONDecoder().decode(
            TiroCommandRequest.self,
            from: Data(
                #"{"v":2,"id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","command":"status"}"#
                    .utf8
            )
        )
        #expect(throws: TiroProtocolError.self) {
            try oldRequest.validated()
        }
    }

    @Test
    func validationRejectsWrongResponseAndProgress() throws {
        let request = TiroCommandRequest.status()
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandMessage.success(
                id: UUID().uuidString,
                result: TiroCommandResult(kind: "status")
            ).validated(for: request)
        }
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandMessage.event(
                id: request.id,
                name: "working",
                fraction: 1.1
            ).validated(for: request)
        }
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandMessage.success(
                id: request.id,
                result: TiroCommandResult(kind: "models", models: [])
            ).validated(for: request)
        }
        let transcribe = TiroCommandRequest.transcribe(
            path: "/tmp/audio.wav",
            model: nil,
            copy: false,
            saveHistory: false
        )
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandMessage.success(
                id: transcribe.id,
                result: TiroCommandResult(kind: "transcript", model: "test")
            ).validated(for: transcribe)
        }
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandMessage.success(
                id: transcribe.id,
                result: TiroCommandResult(
                    kind: "transcript",
                    text: "Changed",
                    originalText: "Original",
                    model: "test",
                    correction: TiroCommandCorrectionResult(
                        model: "codex",
                        changed: false,
                        seconds: 0.1,
                        explanation: "",
                        reviewRecommended: false
                    )
                )
            ).validated(for: transcribe)
        }
        let correctedTranscribe = TiroCommandRequest.transcribe(
            path: "/tmp/audio.wav",
            model: nil,
            copy: false,
            saveHistory: false,
            correction: TiroCommandCorrection(model: "codex")
        )
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandMessage.success(
                id: correctedTranscribe.id,
                result: TiroCommandResult(
                    kind: "transcript",
                    text: "Uncorrected",
                    model: "test"
                )
            ).validated(for: correctedTranscribe)
        }
        let leasedRecording = TiroCommandRequest.recordStart(
            model: nil,
            saveHistory: false,
            lease: true
        )
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandMessage.success(
                id: leasedRecording.id,
                result: TiroCommandResult(
                    kind: "recording",
                    state: "recording",
                    session: UUID().uuidString
                )
            ).validated(for: leasedRecording)
        }
    }

    @Test
    func recordingRequestsRequireAValidSession() throws {
        let session = UUID()
        #expect(try TiroCommandRequest.recordStart(
            model: nil,
            saveHistory: true,
            lease: true
        ).validated().arguments?.lease == true)
        #expect(try TiroCommandRequest.recordStop(
            session: session.uuidString,
            copy: true
        ).validated().arguments?.session == session.uuidString)
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandRequest(
                command: .recordCancel,
                arguments: TiroCommandArguments(session: "not-a-session")
            ).validated()
        }
    }

    @Test
    func socketOverrideAndFallbackAreBounded() throws {
        let override = TiroCommandSocketPath.defaultURL(
            environment: ["TIRO_COMMAND_SOCKET": "/tmp/Tiro/custom-tiro.sock"]
        )
        #expect(override.path == "/tmp/Tiro/custom-tiro.sock")
        try TiroCommandSocketPath.validate(override)

        let unsafeOverride = TiroCommandSocketPath.defaultURL(
            environment: ["TIRO_COMMAND_SOCKET": "/tmp/custom-tiro.sock"]
        )
        #expect(throws: TiroSocketError.unsafeSocketDirectory) {
            try TiroCommandSocketPath.validate(unsafeOverride)
        }

        let excessive = URL(fileURLWithPath: "/" + String(repeating: "x", count: 200))
        #expect(throws: TiroSocketError.self) {
            try TiroCommandSocketPath.validate(excessive)
        }
    }
}
