import Foundation
import Testing
@testable import McSpeechfaceIPC

struct CommandProtocolTests {
    @Test
    func requestUsesStableWireKeys() throws {
        let id = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let request = McSpeechfaceCommandRequest.transcribe(
            path: "/tmp/meeting.m4a",
            model: "coreml-compact",
            copy: true,
            saveHistory: false,
            diarize: true,
            correction: McSpeechfaceCommandCorrection(
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
        let result = McSpeechfaceCommandResult(
            kind: "transcript",
            text: "Send it today.",
            originalText: "Um, send it today.",
            correction: McSpeechfaceCommandCorrectionResult(
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
        let result = McSpeechfaceCommandResult(
            kind: "transcript",
            text: "Hello.",
            segments: [
                McSpeechfaceCommandSegment(
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
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandRequest(
                command: .recordStart,
                arguments: McSpeechfaceCommandArguments(diarize: true)
            ).validated()
        }
    }

    @Test
    func validationBoundsCorrectionRequests() throws {
        #expect(try McSpeechfaceCommandRequest.recordStart(
            model: nil,
            saveHistory: false,
            correction: McSpeechfaceCommandCorrection(model: "codex", instructions: "Be concise.")
        ).validated().arguments?.correction?.model == "codex")
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandRequest(
                command: .transcribe,
                arguments: McSpeechfaceCommandArguments(
                    path: "/tmp/audio.wav",
                    correction: McSpeechfaceCommandCorrection(instructions: "   ")
                )
            ).validated()
        }
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandRequest(
                command: .recordStop,
                arguments: McSpeechfaceCommandArguments(
                    session: UUID().uuidString,
                    correction: McSpeechfaceCommandCorrection()
                )
            ).validated()
        }
    }

    @Test
    func validationRejectsArgumentsOwnedByOtherCommands() {
        let session = UUID().uuidString
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandRequest(
                command: .transcribe,
                arguments: McSpeechfaceCommandArguments(path: "/tmp/audio.wav", session: session)
            ).validated()
        }
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandRequest(
                command: .recordStop,
                arguments: McSpeechfaceCommandArguments(path: "/tmp/audio.wav", session: session)
            ).validated()
        }
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandRequest(
                command: .recordCancel,
                arguments: McSpeechfaceCommandArguments(copy: true, session: session)
            ).validated()
        }
    }

    @Test
    func protocolVersionTwoIsRejectedAfterCorrectionSupport() throws {
        let request = McSpeechfaceCommandRequest.status()
        let oldResponse = McSpeechfaceCommandMessage(
            version: 2,
            id: request.id,
            type: .success,
            result: McSpeechfaceCommandResult(kind: "status", state: "idle")
        )
        #expect(throws: McSpeechfaceProtocolError.self) {
            try oldResponse.validated(for: request)
        }
        let oldRequest = try JSONDecoder().decode(
            McSpeechfaceCommandRequest.self,
            from: Data(
                #"{"v":2,"id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","command":"status"}"#
                    .utf8
            )
        )
        #expect(throws: McSpeechfaceProtocolError.self) {
            try oldRequest.validated()
        }
    }

    @Test
    func validationRejectsWrongResponseAndProgress() throws {
        let request = McSpeechfaceCommandRequest.status()
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandMessage.success(
                id: UUID().uuidString,
                result: McSpeechfaceCommandResult(kind: "status")
            ).validated(for: request)
        }
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandMessage.event(
                id: request.id,
                name: "working",
                fraction: 1.1
            ).validated(for: request)
        }
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandMessage.success(
                id: request.id,
                result: McSpeechfaceCommandResult(kind: "models", models: [])
            ).validated(for: request)
        }
        let transcribe = McSpeechfaceCommandRequest.transcribe(
            path: "/tmp/audio.wav",
            model: nil,
            copy: false,
            saveHistory: false
        )
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandMessage.success(
                id: transcribe.id,
                result: McSpeechfaceCommandResult(kind: "transcript", model: "test")
            ).validated(for: transcribe)
        }
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandMessage.success(
                id: transcribe.id,
                result: McSpeechfaceCommandResult(
                    kind: "transcript",
                    text: "Changed",
                    originalText: "Original",
                    model: "test",
                    correction: McSpeechfaceCommandCorrectionResult(
                        model: "codex",
                        changed: false,
                        seconds: 0.1,
                        explanation: "",
                        reviewRecommended: false
                    )
                )
            ).validated(for: transcribe)
        }
        let correctedTranscribe = McSpeechfaceCommandRequest.transcribe(
            path: "/tmp/audio.wav",
            model: nil,
            copy: false,
            saveHistory: false,
            correction: McSpeechfaceCommandCorrection(model: "codex")
        )
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandMessage.success(
                id: correctedTranscribe.id,
                result: McSpeechfaceCommandResult(
                    kind: "transcript",
                    text: "Uncorrected",
                    model: "test"
                )
            ).validated(for: correctedTranscribe)
        }
        let leasedRecording = McSpeechfaceCommandRequest.recordStart(
            model: nil,
            saveHistory: false,
            lease: true
        )
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandMessage.success(
                id: leasedRecording.id,
                result: McSpeechfaceCommandResult(
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
        #expect(try McSpeechfaceCommandRequest.recordStart(
            model: nil,
            saveHistory: true,
            lease: true
        ).validated().arguments?.lease == true)
        #expect(try McSpeechfaceCommandRequest.recordStop(
            session: session.uuidString,
            copy: true
        ).validated().arguments?.session == session.uuidString)
        #expect(throws: McSpeechfaceProtocolError.self) {
            try McSpeechfaceCommandRequest(
                command: .recordCancel,
                arguments: McSpeechfaceCommandArguments(session: "not-a-session")
            ).validated()
        }
    }

    @Test
    func socketOverrideAndFallbackAreBounded() throws {
        let override = McSpeechfaceCommandSocketPath.defaultURL(
            environment: ["MCSPEECHFACE_COMMAND_SOCKET": "/tmp/McSpeechface/custom-mcspeechface.sock"]
        )
        #expect(override.path == "/tmp/McSpeechface/custom-mcspeechface.sock")
        try McSpeechfaceCommandSocketPath.validate(override)

        let unsafeOverride = McSpeechfaceCommandSocketPath.defaultURL(
            environment: ["MCSPEECHFACE_COMMAND_SOCKET": "/tmp/custom-mcspeechface.sock"]
        )
        #expect(throws: McSpeechfaceSocketError.unsafeSocketDirectory) {
            try McSpeechfaceCommandSocketPath.validate(unsafeOverride)
        }

        let excessive = URL(fileURLWithPath: "/" + String(repeating: "x", count: 200))
        #expect(throws: McSpeechfaceSocketError.self) {
            try McSpeechfaceCommandSocketPath.validate(excessive)
        }
    }
}
