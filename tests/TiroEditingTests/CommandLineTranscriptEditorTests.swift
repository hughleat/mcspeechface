import Foundation
import Testing
@testable import TiroEditing

struct CommandLineTranscriptEditorTests {
    @Test
    func availabilityRequiresAnExecutableFile() async throws {
        let missing = try editor(executablePath: "/private/tmp/missing-\(UUID().uuidString)")
        guard case .unavailable = await missing.availability() else {
            Issue.record("Expected missing executable to be unavailable")
            return
        }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let notExecutable = try editor(executablePath: file.path)
        guard case .unavailable = await notExecutable.availability() else {
            Issue.record("Expected non-executable file to be unavailable")
            return
        }
    }

    @Test
    func sendsRenderedPromptsOnStandardInputAndUsesSharedValidator() async throws {
        let configuration = try CommandLineCorrectionConfiguration(
            id: "fixture",
            name: "Fixture",
            executablePath: "/usr/bin/awk",
            arguments: [#"index($0, "Language: English") { language = 1 } index($0, "Change Tuesday to Thursday") { transcript = 1 } END { if (language && transcript) print "{\"hasChanges\":true,\"explanation\":\"Changed the requested day.\",\"revisedText\":\"Meet Thursday.\"}"; else exit 8 }"#],
            timeout: 2
        )
        let editor = CommandLineTranscriptEditor(configuration: configuration)

        let decision = try await editor.proposeEdits(for: TranscriptEditRequest(
            text: "Meet Tuesday. Change Tuesday to Thursday.",
            language: "English"
        ))

        guard case .proposal(let proposal) = decision else {
            Issue.record("Expected a proposal")
            return
        }
        #expect(proposal.revisedText == "Meet Thursday.")
        #expect(proposal.explanation == "Changed the requested day.")
    }

    @Test
    func decodesAndValidatesStructuredOutputFromOutputFile() async throws {
        let program = #"BEGIN { print "not JSON"; print "{\"hasChanges\":true,\"explanation\":\"Removed a filler.\",\"revisedText\":\"Send it today.\"}" > ARGV[1]; close(ARGV[1]); ARGV[1] = "" } { consumed = $0 }"#
        let configuration = try CommandLineCorrectionConfiguration(
            id: "file-fixture",
            name: "File Fixture",
            executablePath: "/usr/bin/awk",
            arguments: [program, CommandLineCorrectionArgumentPlaceholder.outputFile],
            timeout: 2
        )
        let editor = CommandLineTranscriptEditor(configuration: configuration)

        let decision = try await editor.proposeEdits(for: TranscriptEditRequest(
            text: "Um, send it today."
        ))

        guard case .proposal(let proposal) = decision else {
            Issue.record("Expected a proposal")
            return
        }
        #expect(proposal.revisedText == "Send it today.")
        #expect(proposal.explanation == "Removed a filler.")
    }

    @Test
    func rejectsMalformedExtraAndUngroundedResponses() throws {
        #expect(throws: CommandLineCorrectionError.invalidResponse) {
            try CommandLineTranscriptEditor.decision(
                from: #"{"hasChanges":false,"explanation":""}"#,
                originalText: "Original"
            )
        }
        #expect(throws: CommandLineCorrectionError.invalidResponse) {
            try CommandLineTranscriptEditor.decision(
                from: #"{"hasChanges":false,"explanation":"","revisedText":"Original","extra":true}"#,
                originalText: "Original"
            )
        }
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try CommandLineTranscriptEditor.decision(
                from: #"{"hasChanges":true,"explanation":"Replaced everything.","revisedText":"Entirely unrelated material."}"#,
                originalText: "Meet Tuesday."
            )
        }
    }

    @Test
    func emptyTranscriptDoesNotLaunchTheCommand() async throws {
        let runner = RecordingRunner()
        let configuration = try CommandLineCorrectionConfiguration(
            id: "fixture",
            name: "Fixture",
            executablePath: "/bin/echo",
            arguments: []
        )
        let editor = CommandLineTranscriptEditor(configuration: configuration, runner: runner)

        #expect(try await editor.proposeEdits(for: TranscriptEditRequest(text: "")) == .unchanged)
        #expect(await runner.callCount == 0)
    }

    private func editor(executablePath: String) throws -> CommandLineTranscriptEditor {
        CommandLineTranscriptEditor(configuration: try CommandLineCorrectionConfiguration(
            id: "fixture",
            name: "Fixture",
            executablePath: executablePath,
            arguments: []
        ))
    }
}

private actor RecordingRunner: CommandLineCorrectionProcessRunning {
    private(set) var callCount = 0

    func run(
        configuration: CommandLineCorrectionConfiguration,
        standardInput: Data
    ) async throws -> CommandLineCorrectionProcessResult {
        callCount += 1
        return CommandLineCorrectionProcessResult(
            standardOutput: #"{"hasChanges":false,"explanation":"","revisedText":""}"#,
            standardError: "",
            workingDirectory: FileManager.default.temporaryDirectory
        )
    }
}
