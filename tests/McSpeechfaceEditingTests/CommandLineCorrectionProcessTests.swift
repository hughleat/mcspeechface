import Foundation
import Testing
@testable import McSpeechfaceEditing

struct CommandLineCorrectionProcessTests {
    @Test
    func configurationRejectsRelativePathsInvalidArgumentsAndUnboundedTimeouts() {
        #expect(throws: CommandLineCorrectionError.executablePathMustBeAbsolute) {
            try configuration(executablePath: "bin/tool")
        }
        #expect(throws: CommandLineCorrectionError.invalidArgument) {
            try configuration(arguments: ["valid", "bad\0argument"])
        }
        #expect(throws: CommandLineCorrectionError.invalidTimeout) {
            try configuration(timeout: 0)
        }
        #expect(throws: CommandLineCorrectionError.invalidTimeout) {
            try configuration(timeout: 301)
        }
    }

    @Test
    func argumentsArePassedLiterallyWithoutShellInterpretation() async throws {
        let runner = FoundationCommandLineCorrectionProcessRunner()
        let result = try await runner.run(
            configuration: configuration(
                executablePath: "/bin/echo",
                arguments: ["hello world; $(touch should-not-exist)"]
            ),
            standardInput: Data()
        )

        #expect(result.standardOutput == "hello world; $(touch should-not-exist)")
        #expect(!FileManager.default.fileExists(
            atPath: result.workingDirectory.appendingPathComponent("should-not-exist").path
        ))
    }

    @Test
    func promptTravelsOnStandardInput() async throws {
        let runner = FoundationCommandLineCorrectionProcessRunner()
        let result = try await runner.run(
            configuration: configuration(executablePath: "/bin/cat"),
            standardInput: Data("private dictated text\nsecond line".utf8)
        )

        #expect(result.standardOutput == "private dictated text\nsecond line")
    }

    @Test
    func closedChildInputCannotDeliverSIGPIPEToTheApp() async {
        let runner = FoundationCommandLineCorrectionProcessRunner()

        await #expect(throws: CommandLineCorrectionError.inputWriteFailed) {
            _ = try await runner.run(
                configuration: configuration(executablePath: "/usr/bin/true"),
                standardInput: Data(repeating: 0x41, count: 1_000_000)
            )
        }
    }

    @Test
    func schemaPlaceholdersProvideTheCanonicalSchemaAsWholeArguments() async throws {
        let runner = FoundationCommandLineCorrectionProcessRunner()
        let fileResult = try await runner.run(
            configuration: configuration(
                executablePath: "/bin/cat",
                arguments: [CommandLineCorrectionArgumentPlaceholder.schemaFile]
            ),
            standardInput: Data()
        )
        let jsonResult = try await runner.run(
            configuration: configuration(
                executablePath: "/bin/echo",
                arguments: [CommandLineCorrectionArgumentPlaceholder.schemaJSON]
            ),
            standardInput: Data()
        )
        let permissionsResult = try await runner.run(
            configuration: configuration(
                executablePath: "/usr/bin/stat",
                arguments: [
                    "-f",
                    "%Lp",
                    CommandLineCorrectionArgumentPlaceholder.schemaFile,
                ]
            ),
            standardInput: Data()
        )

        #expect(fileResult.standardOutput == TranscriptCorrectionOutputSchema.json)
        #expect(jsonResult.standardOutput == TranscriptCorrectionOutputSchema.json)
        #expect(permissionsResult.standardOutput == "600")
        #expect(TranscriptCorrectionOutputSchema.data == Data(
            TranscriptCorrectionOutputSchema.json.utf8
        ))
        let schema = try JSONSerialization.jsonObject(
            with: TranscriptCorrectionOutputSchema.data
        ) as? [String: Any]
        #expect(schema?["type"] as? String == "object")
        #expect(schema?["additionalProperties"] as? Bool == false)
        #expect(Set(schema?["required"] as? [String] ?? []) == [
            "hasChanges",
            "explanation",
            "revisedText",
        ])
    }

    @Test
    func placeholdersEmbeddedInsideArgumentsRemainLiteral() async throws {
        let runner = FoundationCommandLineCorrectionProcessRunner()
        let argument = "prefix-{schemaJSON}-suffix"
        let result = try await runner.run(
            configuration: configuration(
                executablePath: "/bin/echo",
                arguments: [argument, "{model}"]
            ),
            standardInput: Data()
        )

        #expect(result.standardOutput == "\(argument) {model}")
    }

    @Test
    func nonemptyOutputFileTakesPrecedenceOverStandardOutput() async throws {
        let runner = FoundationCommandLineCorrectionProcessRunner()
        let program = #"BEGIN { print "from stdout"; print "from output file" > ARGV[1]; close(ARGV[1]); ARGV[1] = "" }"#
        let result = try await runner.run(
            configuration: configuration(
                executablePath: "/usr/bin/awk",
                arguments: [program, CommandLineCorrectionArgumentPlaceholder.outputFile]
            ),
            standardInput: Data()
        )

        #expect(result.standardOutput == "from output file")
    }

    @Test
    func emptyOutputFileFallsBackToStandardOutput() async throws {
        let runner = FoundationCommandLineCorrectionProcessRunner()
        let program = #"BEGIN { printf "%s", "" > ARGV[1]; close(ARGV[1]); ARGV[1] = ""; print "from stdout" }"#
        let result = try await runner.run(
            configuration: configuration(
                executablePath: "/usr/bin/awk",
                arguments: [program, CommandLineCorrectionArgumentPlaceholder.outputFile]
            ),
            standardInput: Data()
        )

        #expect(result.standardOutput == "from stdout")
    }

    @Test
    func rejectsOversizedOutputFile() async {
        let runner = FoundationCommandLineCorrectionProcessRunner(maximumOutputBytes: 64)
        let program = #"BEGIN { for (i = 0; i < 100; i++) print "too much output" > ARGV[1]; close(ARGV[1]); ARGV[1] = "" }"#

        await #expect(throws: CommandLineCorrectionError.outputTooLarge) {
            _ = try await runner.run(
                configuration: configuration(
                    executablePath: "/usr/bin/awk",
                    arguments: [program, CommandLineCorrectionArgumentPlaceholder.outputFile]
                ),
                standardInput: Data()
            )
        }
    }

    @Test
    func rejectsOutputFileSymlinksOutsideTheWorkingDirectory() async throws {
        let externalFile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mcspeechface-command-external-output-\(UUID().uuidString)"
        )
        try Data("external content".utf8).write(to: externalFile)
        defer { try? FileManager.default.removeItem(at: externalFile) }
        let runner = FoundationCommandLineCorrectionProcessRunner()

        await #expect(throws: CommandLineCorrectionError.unsafeOutputFile) {
            _ = try await runner.run(
                configuration: configuration(
                    executablePath: "/bin/ln",
                    arguments: [
                        "-s",
                        externalFile.path,
                        CommandLineCorrectionArgumentPlaceholder.outputFile,
                    ]
                ),
                standardInput: Data()
            )
        }
    }

    @Test
    func rejectsOutputFileFIFOWithoutBlocking() async {
        let runner = FoundationCommandLineCorrectionProcessRunner()
        let startedAt = ProcessInfo.processInfo.systemUptime

        await #expect(throws: CommandLineCorrectionError.unsafeOutputFile) {
            _ = try await runner.run(
                configuration: configuration(
                    executablePath: "/usr/bin/mkfifo",
                    arguments: [CommandLineCorrectionArgumentPlaceholder.outputFile]
                ),
                standardInput: Data()
            )
        }
        #expect(ProcessInfo.processInfo.systemUptime - startedAt < 2)
    }

    @Test
    func processRunsInPrivateDirectoryAndRemovesItAfterwards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mcspeechface-command-runner-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FoundationCommandLineCorrectionProcessRunner(temporaryRoot: root)

        let result = try await runner.run(
            configuration: configuration(executablePath: "/bin/pwd"),
            standardInput: Data()
        )

        #expect(
            URL(fileURLWithPath: result.standardOutput).lastPathComponent
                == result.workingDirectory.lastPathComponent
        )
        #expect(result.standardOutput.contains(root.lastPathComponent))
        #expect(
            result.workingDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
                == root.resolvingSymlinksInPath()
        )
        #expect(!FileManager.default.fileExists(atPath: result.workingDirectory.path))
    }

    @Test
    func workingDirectoryUsesPrivatePermissions() async throws {
        let runner = FoundationCommandLineCorrectionProcessRunner()
        let result = try await runner.run(
            configuration: configuration(
                executablePath: "/usr/bin/stat",
                arguments: ["-f", "%Lp", "."]
            ),
            standardInput: Data()
        )

        #expect(result.standardOutput == "700")
    }

    @Test
    func concurrentlyDrainsBothPipesAndRejectsBoundedOutput() async {
        let runner = FoundationCommandLineCorrectionProcessRunner(
            maximumOutputBytes: 1_024,
            maximumErrorOutputBytes: 1_024
        )
        let program = #"BEGIN { for (i = 0; i < 5000; i++) { print "output"; print "error" > "/dev/stderr" } }"#

        await #expect(throws: CommandLineCorrectionError.outputTooLarge) {
            _ = try await runner.run(
                configuration: configuration(
                    executablePath: "/usr/bin/awk",
                    arguments: [program]
                ),
                standardInput: Data()
            )
        }
    }

    @Test
    func rejectsBoundedErrorOutputEvenWhenStandardOutputIsSmall() async {
        let runner = FoundationCommandLineCorrectionProcessRunner(
            maximumOutputBytes: 1_024,
            maximumErrorOutputBytes: 128
        )
        let program = #"BEGIN { print "ok"; for (i = 0; i < 500; i++) print "error" > "/dev/stderr" }"#

        await #expect(throws: CommandLineCorrectionError.errorOutputTooLarge) {
            _ = try await runner.run(
                configuration: configuration(
                    executablePath: "/usr/bin/awk",
                    arguments: [program]
                ),
                standardInput: Data()
            )
        }
    }

    @Test
    func timeoutTerminatesTheProcessPromptlyAndCleansItsDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mcspeechface-command-timeout-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FoundationCommandLineCorrectionProcessRunner(temporaryRoot: root)
        let startedAt = ProcessInfo.processInfo.systemUptime

        await #expect(throws: CommandLineCorrectionError.timedOut) {
            _ = try await runner.run(
                configuration: configuration(
                    executablePath: "/bin/sleep",
                    arguments: ["5"],
                    timeout: 0.05
                ),
                standardInput: Data()
            )
        }
        #expect(ProcessInfo.processInfo.systemUptime - startedAt < 5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test
    func cancellationTerminatesTheProcessPromptlyAndCleansItsDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mcspeechface-command-cancellation-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FoundationCommandLineCorrectionProcessRunner(temporaryRoot: root)
        let task = Task {
            try await runner.run(
                configuration: configuration(
                    executablePath: "/bin/sleep",
                    arguments: ["5"]
                ),
                standardInput: Data()
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let startedAt = ProcessInfo.processInfo.systemUptime
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(ProcessInfo.processInfo.systemUptime - startedAt < 5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test
    func doesNotExposeStandardErrorForNonzeroExit() async {
        let runner = FoundationCommandLineCorrectionProcessRunner()
        let program = #"BEGIN { print "concise failure" > "/dev/stderr"; exit 7 }"#

        do {
            _ = try await runner.run(
                configuration: configuration(
                    executablePath: "/usr/bin/awk",
                    arguments: [program]
                ),
                standardInput: Data()
            )
            Issue.record("Expected command failure")
        } catch let error as CommandLineCorrectionError {
            #expect(error == .failed(exitCode: 7))
            #expect(!error.localizedDescription.contains("concise failure"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func configuration(
        executablePath: String = "/bin/echo",
        arguments: [String] = [],
        timeout: TimeInterval = 2
    ) throws -> CommandLineCorrectionConfiguration {
        try CommandLineCorrectionConfiguration(
            id: "test-command",
            name: "Test Command",
            executablePath: executablePath,
            arguments: arguments,
            timeout: timeout
        )
    }
}
