import Foundation
import Testing
@testable import McSpeechfaceEditing

struct PersistentProviderTranscriptEditorTests {
    @Test
    func codexReusesOneAppServerForIndependentCorrections() async throws {
        let fixture = try ProcessFixture(script: Self.codexScript)
        defer { fixture.remove() }
        let editor = CodexAppServerTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            model: "fixture-model",
            reasoningEffort: "low",
            access: .correctionOnly,
            idleTimeout: 30
        ))

        for text in ["Um, send it.", "Er, send that too."] {
            let decision = try await editor.proposeEdits(for: TranscriptEditRequest(text: text))
            guard case .proposal(let proposal) = decision else {
                Issue.record("Expected a correction proposal")
                continue
            }
            #expect(proposal.revisedText == "Send it.")
        }

        #expect(try fixture.launchCount() == 1)
        #expect(try fixture.threadStartCount() == 2)
        #expect(await editor.runtimeState() == .ready)
        await editor.stop()
    }

    @Test
    func codexCanContinueOneConversationAcrossCorrections() async throws {
        let fixture = try ProcessFixture(script: Self.codexScript)
        defer { fixture.remove() }
        let editor = CodexAppServerTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            model: "fixture-model",
            reasoningEffort: "low",
            access: .correctionOnly,
            continuesConversation: true,
            idleTimeout: 30
        ))

        for text in ["Remember Kablamo means Futon Mess.", "Use Kablamo here."] {
            _ = try await editor.proposeEdits(for: TranscriptEditRequest(text: text))
        }

        #expect(try fixture.launchCount() == 1)
        #expect(try fixture.threadStartCount() == 1)
        await editor.stop()
    }

    @Test
    func codexResetsContinuedConversationAfterInvalidOutput() async throws {
        let script = Self.codexScript.replacingOccurrences(
            of: "__CODEX_DELTA__",
            with: "not-json"
        )
        let fixture = try ProcessFixture(script: script)
        defer { fixture.remove() }
        let editor = CodexAppServerTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            model: "fixture-model",
            reasoningEffort: "low",
            access: .correctionOnly,
            continuesConversation: true,
            idleTimeout: 30
        ))

        for _ in 0..<2 {
            await #expect(throws: Error.self) {
                _ = try await editor.proposeEdits(for: TranscriptEditRequest(text: "Correct me."))
            }
        }

        #expect(try fixture.threadStartCount() == 2)
        await editor.stop()
    }

    @Test
    func codexResetsContinuedConversationWhenRenderedSystemPromptChanges() async throws {
        let fixture = try ProcessFixture(script: Self.codexScript)
        defer { fixture.remove() }
        let editor = CodexAppServerTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            model: "fixture-model",
            reasoningEffort: "low",
            access: .correctionOnly,
            continuesConversation: true,
            idleTimeout: 30
        ))
        let prompts = TranscriptEditingPromptConfiguration(
            systemPrompt: "Correct this {language} transcript.",
            userPromptTemplate: "{transcript}"
        )

        for language in ["English", "French"] {
            _ = try await editor.proposeEdits(for: TranscriptEditRequest(
                text: "Correct me.",
                language: language,
                promptConfiguration: prompts
            ))
        }

        #expect(try fixture.launchCount() == 1)
        #expect(try fixture.threadStartCount() == 2)
        await editor.stop()
    }

    @Test
    func stoppingCodexResetsItsContinuedConversation() async throws {
        let fixture = try ProcessFixture(script: Self.codexScript)
        defer { fixture.remove() }
        let editor = CodexAppServerTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            model: "fixture-model",
            reasoningEffort: "low",
            access: .correctionOnly,
            continuesConversation: true,
            idleTimeout: 30
        ))

        _ = try await editor.proposeEdits(for: TranscriptEditRequest(text: "First."))
        await editor.stop()
        _ = try await editor.proposeEdits(for: TranscriptEditRequest(text: "Second."))

        #expect(try fixture.launchCount() == 2)
        #expect(try fixture.threadStartCount() == 2)
        await editor.stop()
    }

    @Test
    func codexDiscoversModelsThroughThePersistentConnection() async throws {
        let fixture = try ProcessFixture(script: Self.codexScript)
        defer { fixture.remove() }
        let editor = CodexAppServerTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            model: "fixture-model",
            reasoningEffort: nil,
            access: .correctionOnly,
            idleTimeout: 30
        ))

        let models = try await editor.supportedModels()

        #expect(models.map(\.id) == ["fixture-model"])
        #expect(models.first?.supportedReasoningEfforts == ["low"])
        await editor.stop()
    }

    @Test
    func codexRejectsRepeatedModelCursors() async throws {
        let script = Self.codexScript.replacingOccurrences(
            of: #""nextCursor":null"#,
            with: #""nextCursor":"same""#
        )
        let fixture = try ProcessFixture(script: script)
        defer { fixture.remove() }
        let editor = CodexAppServerTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            model: "fixture-model",
            reasoningEffort: nil,
            access: .correctionOnly,
            idleTimeout: 30
        ))

        await #expect(throws: CodexAppServerError.self) {
            _ = try await editor.supportedModels()
        }
        await editor.stop()
    }

    @Test
    func codexPreparationIsSingleFlight() async throws {
        let fixture = try ProcessFixture(script: Self.codexScript)
        defer { fixture.remove() }
        let editor = CodexAppServerTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            model: "fixture-model",
            reasoningEffort: nil,
            access: .correctionOnly,
            idleTimeout: 30
        ))

        async let first: Void = editor.prepare()
        async let second: Void = editor.prepare()
        _ = try await (first, second)

        #expect(try fixture.launchCount() == 1)
        await editor.stop()
    }

    @Test
    func codexRejectsInterruptedTurns() async throws {
        let script = Self.codexScript.replacingOccurrences(
            of: #""status":"completed""#,
            with: #""status":"interrupted""#
        )
        let fixture = try ProcessFixture(script: script)
        defer { fixture.remove() }
        let editor = CodexAppServerTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            model: "fixture-model",
            reasoningEffort: nil,
            access: .correctionOnly,
            idleTimeout: 30
        ))

        await #expect(throws: CodexAppServerError.self) {
            _ = try await editor.proposeEdits(for: TranscriptEditRequest(text: "Um, send it."))
        }
        await editor.stop()
    }

    @Test
    func claudePrewarmsEachFreshStreamingSession() async throws {
        let fixture = try ProcessFixture(script: Self.claudeScript)
        defer { fixture.remove() }
        let editor = ClaudeStreamingTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            arguments: ["-p", "--output-format", "stream-json"],
            systemPrompt: "Fixture system",
            idleTimeout: 30
        ))

        for text in ["Um, send it.", "Ah, send it again."] {
            try await editor.prepare()
            let decision = try await editor.proposeEdits(for: TranscriptEditRequest(text: text))
            guard case .proposal(let proposal) = decision else {
                Issue.record("Expected a correction proposal")
                continue
            }
            #expect(proposal.revisedText == "Send it.")
        }

        #expect(try fixture.launchCount() == 2)
        #expect(await editor.runtimeState() == .ready)
        await editor.stop()
    }

    @Test
    func claudeCanContinueOneStreamingConversationAcrossCorrections() async throws {
        let fixture = try ProcessFixture(script: Self.claudeScript)
        defer { fixture.remove() }
        let editor = ClaudeStreamingTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            arguments: ["-p", "--output-format", "stream-json"],
            systemPrompt: "Fixture system",
            continuesConversation: true,
            idleTimeout: 30
        ))

        for text in ["Remember Kablamo means Futon Mess.", "Use Kablamo here."] {
            _ = try await editor.proposeEdits(for: TranscriptEditRequest(text: text))
        }

        #expect(try fixture.launchCount() == 1)
        await editor.stop()
    }

    @Test
    func claudeResetsContinuedConversationAfterInvalidOutput() async throws {
        let script = Self.claudeScript.replacingOccurrences(
            of: "__CLAUDE_OUTPUT__",
            with: #""not-json""#
        )
        let fixture = try ProcessFixture(script: script)
        defer { fixture.remove() }
        let editor = ClaudeStreamingTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            arguments: ["-p", "--output-format", "stream-json"],
            systemPrompt: "Fixture system",
            continuesConversation: true,
            idleTimeout: 30
        ))

        for _ in 0..<2 {
            await #expect(throws: Error.self) {
                _ = try await editor.proposeEdits(for: TranscriptEditRequest(text: "Correct me."))
            }
        }

        #expect(try fixture.launchCount() == 2)
        await editor.stop()
    }

    @Test
    func claudeResetsContinuedConversationWhenRenderedSystemPromptChanges() async throws {
        let fixture = try ProcessFixture(script: Self.claudeScript)
        defer { fixture.remove() }
        let editor = ClaudeStreamingTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            arguments: ["-p", "--output-format", "stream-json"],
            continuesConversation: true,
            idleTimeout: 30
        ))
        let prompts = TranscriptEditingPromptConfiguration(
            systemPrompt: "Correct this {language} transcript.",
            userPromptTemplate: "{transcript}"
        )

        for language in ["English", "French"] {
            _ = try await editor.proposeEdits(for: TranscriptEditRequest(
                text: "Correct me.",
                language: language,
                promptConfiguration: prompts
            ))
        }

        #expect(try fixture.launchCount() == 2)
        await editor.stop()
    }

    @Test
    func stoppingClaudeResetsItsContinuedConversation() async throws {
        let fixture = try ProcessFixture(script: Self.claudeScript)
        defer { fixture.remove() }
        let editor = ClaudeStreamingTranscriptEditor(configuration: .init(
            executablePath: fixture.executable.path,
            arguments: ["-p", "--output-format", "stream-json"],
            continuesConversation: true,
            idleTimeout: 30
        ))

        _ = try await editor.proposeEdits(for: TranscriptEditRequest(text: "First."))
        await editor.stop()
        _ = try await editor.proposeEdits(for: TranscriptEditRequest(text: "Second."))

        #expect(try fixture.launchCount() == 2)
        await editor.stop()
    }

    private static let codexScript = #"""
        #!/bin/sh
        echo launch >> "__COUNT_FILE__"
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
          case "$line" in
            *'"method":"initialize"'*)
              printf '{"id":%s,"result":{"userAgent":"fixture"}}\n' "$id"
              ;;
            *'"method":"model\/list"'*)
              printf '{"id":%s,"result":{"data":[{"model":"fixture-model","displayName":"Fixture","description":"Fast","defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low"}]}],"nextCursor":null}}\n' "$id"
              ;;
            *'"method":"thread\/start"'*)
              echo thread >> "__COUNT_FILE__"
              pending_thread_id=$id
              printf '{"id":999,"method":"item/commandExecution/requestApproval","params":{}}\n'
              ;;
            *'"id":999'*)
              printf '{"id":%s,"result":{"thread":{"id":"thread-%s"}}}\n' "$pending_thread_id" "$pending_thread_id"
              pending_thread_id=
              ;;
            *'"method":"turn\/start"'*)
              thread=$(printf '%s' "$line" | sed -E 's/.*"threadId":"([^"]+)".*/\1/')
              printf '{"id":%s,"result":{"turn":{"id":"turn-%s"}}}\n' "$id" "$id"
              printf '{"method":"item/agentMessage/delta","params":{"threadId":"%s","turnId":"turn-%s","itemId":"item","delta":"__CODEX_DELTA__"}}\n' "$thread" "$id"
              printf '{"method":"turn/completed","params":{"threadId":"%s","turn":{"id":"turn-%s","status":"completed"}}}\n' "$thread" "$id"
              ;;
          esac
        done
        """#

    private static let claudeScript = #"""
        #!/bin/sh
        echo launch >> "__COUNT_FILE__"
        case "$*" in
          *'--system-prompt'*) ;;
          *) exit 9 ;;
        esac
        while IFS= read -r line; do
          printf '{"type":"system","subtype":"init","slash_commands":[]}\n'
          printf '{"type":"assistant","message":{"content":[{"type":"text","text":"receiving"}]}}\n'
          printf '{"type":"result","subtype":"success","structured_output":__CLAUDE_OUTPUT__}\n'
        done
        """#
}

private struct ProcessFixture {
    let directory: URL
    let executable: URL
    let countFile: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcspeechface-provider-fixture-\(UUID().uuidString)", isDirectory: true)
        executable = directory.appendingPathComponent("provider")
        countFile = directory.appendingPathComponent("launch-count")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let rendered = script
            .replacingOccurrences(of: "__COUNT_FILE__", with: countFile.path)
            .replacingOccurrences(
                of: "__CODEX_DELTA__",
                with: #"{\\"hasChanges\\":true,\\"explanation\\":\\"Removed a filler.\\",\\"revisedText\\":\\"Send it.\\"}"#
            )
            .replacingOccurrences(
                of: "__CLAUDE_OUTPUT__",
                with: #"{"hasChanges":true,"explanation":"Removed a filler.","revisedText":"Send it."}"#
            )
        try Data(rendered.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
    }

    func launchCount() throws -> Int {
        guard FileManager.default.fileExists(atPath: countFile.path) else { return 0 }
        return try String(contentsOf: countFile, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .filter { $0 == "launch" }.count
    }

    func threadStartCount() throws -> Int {
        guard FileManager.default.fileExists(atPath: countFile.path) else { return 0 }
        return try String(contentsOf: countFile, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .filter { $0 == "thread" }.count
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
