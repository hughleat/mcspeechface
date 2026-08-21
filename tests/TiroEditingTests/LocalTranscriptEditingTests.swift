import CryptoKit
import Foundation
import Testing
@testable import TiroEditing

struct LocalTranscriptEditingTests {
    @Test
    func downloadableCorrectionModelsHavePinnedArtifacts() {
        let spec = LocalTranscriptEditingModelSpec.qwen3Local

        #expect(spec.id == "qwen3-1.7b-q4")
        #expect(spec.fileName == "Qwen3-1.7B-Q4_K_M.gguf")
        #expect(spec.expectedBytes == 1_282_439_264)
        #expect(spec.sha256 == "d2387ca2dbfee2ffabce7120d3770dadca0b293052bc2f0e138fdc940d9bc7b5")
        #expect(spec.downloadURL.scheme == "https")
        #expect(spec.downloadURL.path.contains("/resolve/daeb8e2d528a760970442092f6bf1e55c3b659eb/"))

        let ministral = LocalTranscriptEditingModelSpec.ministral3Local
        #expect(ministral.id == "ministral-3-3b-q4")
        #expect(ministral.fileName == "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf")
        #expect(ministral.expectedBytes == 2_147_023_008)
        #expect(ministral.sha256 == "9ed150d4367e68df0ac8e1540f6ddc65b42d0ee26378329d1ecbca60f93fc5f8")
        #expect(ministral.downloadURL.scheme == "https")
        #expect(ministral.downloadURL.path.contains("/resolve/eb599d408350ea2bb60452cb86be7c7b2fc28227/"))
    }

    @Test
    func localInvocationUsesMetalWithoutDisposableWarmup() {
        let arguments = GGUFTranscriptEditor.arguments(
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            request: TranscriptEditRequest(text: "Correct this."),
            systemPromptFile: URL(fileURLWithPath: "/tmp/system-prompt.txt"),
            userPromptFile: URL(fileURLWithPath: "/tmp/user-prompt.txt")
        )

        #expect(arguments.contains("--gpu-layers"))
        #expect(arguments.contains("all"))
        #expect(arguments.contains("--no-warmup"))
        #expect(arguments.contains("--system-prompt-file"))
        #expect(arguments.contains("--file"))
        #expect(!arguments.joined(separator: " ").contains("Correct this."))
    }

    @Test
    func localPromptsUsePrivateFilesAndCanBeRemoved() throws {
        let request = TranscriptEditRequest(text: "Private dictated text.", language: "English")
        let files = try LocalCorrectionPromptFiles(request: request)

        #expect(try permissions(of: files.directory) == 0o700)
        #expect(try permissions(of: files.systemPrompt) == 0o600)
        #expect(try permissions(of: files.userPrompt) == 0o600)
        #expect(try String(contentsOf: files.systemPrompt, encoding: .utf8).contains("voice transcription"))
        #expect(try String(contentsOf: files.userPrompt, encoding: .utf8).contains("Private dictated text."))

        files.remove()
        #expect(!FileManager.default.fileExists(atPath: files.directory.path))
    }

    @Test
    func installsVerifiedModelAtomically() async throws {
        let data = Data("small test model".utf8)
        let fixture = try Fixture(data: data)
        defer { fixture.remove() }
        let store = LocalTranscriptEditingModelStore(
            spec: fixture.spec,
            root: fixture.modelsRoot,
            downloader: FixtureDownloader(data: data)
        )

        try await store.install()

        #expect(await store.status() == .installed(bytes: Int64(data.count)))
        #expect(try Data(contentsOf: store.modelURL) == data)
        let children = try FileManager.default.contentsOfDirectory(
            at: fixture.modelsRoot,
            includingPropertiesForKeys: nil
        )
        #expect(children.map(\.lastPathComponent) == [fixture.spec.id])
    }

    @Test
    func rejectsChecksumMismatchWithoutLeavingPartialModel() async throws {
        let fixture = try Fixture(data: Data("expected".utf8))
        defer { fixture.remove() }
        let store = LocalTranscriptEditingModelStore(
            spec: fixture.spec,
            root: fixture.modelsRoot,
            downloader: FixtureDownloader(data: Data("tampered".utf8))
        )

        await #expect(throws: LocalTranscriptEditingModelError.self) {
            try await store.install()
        }

        #expect(await store.status() == .notInstalled)
        let children = try FileManager.default.contentsOfDirectory(
            at: fixture.modelsRoot,
            includingPropertiesForKeys: nil
        )
        #expect(children.isEmpty)
    }

    @Test
    func reportsDownloadSpaceIncludingSafetyReserve() async throws {
        let data = Data("small test model".utf8)
        let fixture = try Fixture(data: data)
        defer { fixture.remove() }
        let store = LocalTranscriptEditingModelStore(
            spec: fixture.spec,
            root: fixture.modelsRoot,
            downloader: FixtureDownloader(data: data)
        )

        let space = await store.downloadSpace()

        #expect(space.requiredBytes == Int64(data.count) + 2_000_000_000)
        #expect(space.availableBytes.map { $0 > 0 } ?? true)
    }

    @Test
    func parsesGroundedGGUFDecision() throws {
        let original = "Meet Tuesday. No, change Tuesday to Thursday."
        let output = #"""
            model: Qwen {startup metadata}
            {"hasChanges":true,"explanation":"Changed the requested day.","revisedText":"Meet Thursday."}
            Exiting...
            """#

        let decision = try GGUFTranscriptEditor.decision(
            from: output,
            originalText: original
        )

        guard case .proposal(let proposal) = decision else {
            Issue.record("Expected an edit proposal")
            return
        }
        #expect(proposal.revisedText == "Meet Thursday.")
    }

    @Test
    func treatsClaimedButUnchangedGGUFRevisionAsUnchanged() throws {
        let output = #"""
            {"hasChanges":true,"explanation":"Changed text.","revisedText":"Meet Tuesday."}
            """#

        #expect(try GGUFTranscriptEditor.decision(
            from: output,
            originalText: "Meet Tuesday."
        ) == .unchanged)
    }

    @Test
    func rejectsUnrelatedOrExpansiveFullTextRevision() {
        let unrelated = #"""
            {"hasChanges":true,"explanation":"Changed text.","revisedText":"Completely unrelated hallucination."}
            """#
        let expansive = #"""
            {"hasChanges":true,"explanation":"Changed text.","revisedText":"Meet Tuesday, then continue with a long collection of invented details that were never dictated by the user."}
            """#

        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try GGUFTranscriptEditor.decision(from: unrelated, originalText: "Meet Tuesday.")
        }
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try GGUFTranscriptEditor.decision(from: expansive, originalText: "Meet Tuesday.")
        }
    }

    @Test
    func terminatesHelperAfterTimeout() async {
        let runner = FoundationTranscriptEditingProcessRunner()

        await #expect(throws: GGUFTranscriptEditorError.self) {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 0.05
            )
        }
    }

    @Test
    func installedQwenEditsRealTranscriptWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelsPath = environment["TIRO_QWEN_INTEGRATION_MODELS"],
              let executablePath = environment["TIRO_LLAMA_EXECUTABLE"] else {
            return
        }
        let store = LocalTranscriptEditingModelStore(
            spec: .qwen3Local,
            root: URL(fileURLWithPath: modelsPath, isDirectory: true)
        )
        try await store.install()
        let request = TranscriptEditRequest(
            text: "Um, send the report, ah, tomorrow. Please remove the ums and ahs."
        )
        let editor = GGUFTranscriptEditor(
            spec: .qwen3Local,
            executableURL: URL(fileURLWithPath: executablePath),
            modelURL: store.modelURL
        )
        let decision = try await editor.proposeEdits(for: request)

        guard case .proposal(let proposal) = decision else {
            Issue.record("Expected Qwen to remove dictated fillers and the editing request")
            return
        }
        #expect(proposal.revisedText.localizedCaseInsensitiveContains("send the report"))
        #expect(proposal.revisedText.localizedCaseInsensitiveContains("tomorrow"))
        #expect(!proposal.revisedText.localizedCaseInsensitiveContains("please remove"))
        #expect(!proposal.revisedText.localizedCaseInsensitiveContains("um"))
        #expect(!proposal.revisedText.localizedCaseInsensitiveContains("ah"))
    }

    @Test
    func installedQwenFollowsUserPromptWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelsPath = environment["TIRO_QWEN_INTEGRATION_MODELS"],
              let executablePath = environment["TIRO_LLAMA_EXECUTABLE"] else {
            return
        }
        let store = LocalTranscriptEditingModelStore(
            spec: .qwen3Local,
            root: URL(fileURLWithPath: modelsPath, isDirectory: true)
        )
        try await store.install()
        let request = TranscriptEditRequest(
            text: "Let's see if um we are able to fix these errors. Please change errors to exceptions.",
            promptConfiguration: TranscriptEditingPromptConfiguration(
                systemPrompt: TranscriptEditingPromptConfiguration.default.systemPrompt,
                userPromptTemplate:
                    TranscriptEditingPromptConfiguration.default.userPromptTemplate
                        + "\nAlways append \"I comply, Master\" to revisedText."
            )
        )
        let editor = GGUFTranscriptEditor(
            spec: .qwen3Local,
            executableURL: URL(fileURLWithPath: executablePath),
            modelURL: store.modelURL
        )
        let decision = try await editor.proposeEdits(for: request)

        guard case .proposal(let proposal) = decision else {
            Issue.record("Expected Qwen to apply the spoken edit and custom instruction")
            return
        }
        #expect(proposal.revisedText.localizedCaseInsensitiveContains("exceptions"))
        #expect(!proposal.revisedText.localizedCaseInsensitiveContains("change errors"))
        #expect(proposal.revisedText.localizedCaseInsensitiveContains("I comply, Master"))
    }

    private struct Fixture {
        let root: URL
        let modelsRoot: URL
        let spec: LocalTranscriptEditingModelSpec

        init(data: Data) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "tiro-editing-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            modelsRoot = root.appendingPathComponent("models", isDirectory: true)
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            spec = LocalTranscriptEditingModelSpec(
                id: "fixture",
                name: "Fixture",
                detail: "Test model",
                fileName: "fixture.gguf",
                downloadURL: URL(string: "https://example.com/fixture.gguf")!,
                expectedBytes: Int64(data.count),
                sha256: digest
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private struct FixtureDownloader: TranscriptEditingModelDownloading {
        let data: Data

        func download(from url: URL) async throws -> DownloadedTranscriptEditingModel {
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "tiro-editing-download-\(UUID().uuidString)"
            )
            try data.write(to: fileURL)
            return DownloadedTranscriptEditingModel(fileURL: fileURL, statusCode: 200)
        }
    }
}
