import CryptoKit
import Foundation
import Testing
@testable import TiroEditing

struct LocalTranscriptEditingTests {
    @Test
    func downloadableCorrectionModelsHavePinnedArtifacts() {
        let artifacts: [(LocalTranscriptEditingModelSpec, String, Int64, String)] = [
            (.qwen35SmallLocal, "8fea620810c4afa23dd6443f999a48574c1611a3", 563_036_064,
             "57d1997790d1744fba5b40a7317df71ea5e2acee28c47e78f0cce39c0703f8cf"),
            (.qwen3SmallLocal, "b5f37287796e5be0ea3dab2e7430873fb3f73e49", 428_970_080,
             "da2572f16c06133561ce56accaa822216f2391ef4d37fba427801cd6736417d4"),
            (.qwen3Local, "daeb8e2d528a760970442092f6bf1e55c3b659eb", 1_282_439_264,
             "d2387ca2dbfee2ffabce7120d3770dadca0b293052bc2f0e138fdc940d9bc7b5"),
            (.granite4Local, "b27c2fe3f211b7f44e80fa620177aea371099aaa", 1_023_645_440,
             "22ec0f9cc99a90185312de3c882c84e7bd6789bdd050389844380a01a831d7f1"),
            (.smolLM3Local, "4965cb60b150737b68a0408c36aeefb65078f894", 1_915_305_312,
             "8334b850b7bd46238c16b0c550df2138f0889bf433809008cc17a8b05761863e"),
            (.ministral3Local, "eb599d408350ea2bb60452cb86be7c7b2fc28227", 2_147_023_008,
             "9ed150d4367e68df0ac8e1540f6ddc65b42d0ee26378329d1ecbca60f93fc5f8"),
        ]

        for (spec, revision, bytes, checksum) in artifacts {
            #expect(spec.downloadURL.scheme == "https")
            #expect(spec.downloadURL.path.contains("/resolve/\(revision)/"))
            #expect(spec.expectedBytes == bytes)
            #expect(spec.sha256 == checksum)
        }
    }

    @Test
    func localEditorUsesPersistentRuntimeLifecycle() async throws {
        let model = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fixture-\(UUID().uuidString).gguf"
        )
        try Data("fixture".utf8).write(to: model)
        defer { try? FileManager.default.removeItem(at: model) }
        let server = RecordingLocalCorrectionServer()
        let editor = GGUFTranscriptEditor(
            spec: .qwen3Local,
            modelURL: model,
            server: server
        )

        try await editor.prepare()
        #expect(await editor.runtimeState() == .ready)
        let decision = try await editor.proposeEdits(for: TranscriptEditRequest(
            text: "Um, send it today."
        ))
        await editor.updateIdleTimeout(30)
        await editor.stop()

        guard case .proposal(let proposal) = decision else {
            Issue.record("Expected the persistent runtime's proposal")
            return
        }
        #expect(proposal.revisedText == "Send it today.")
        #expect(await server.prepareCount == 1)
        #expect(await server.generateCount == 1)
        #expect(await server.idleTimeout == 30)
        #expect(await editor.runtimeState() == .stopped)
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
    func installedQwenEditsRealTranscriptWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelsPath = environment["TIRO_QWEN_INTEGRATION_MODELS"],
              let executablePath = environment["TIRO_LLAMA_SERVER_EXECUTABLE"] else {
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
              let executablePath = environment["TIRO_LLAMA_SERVER_EXECUTABLE"] else {
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

private actor RecordingLocalCorrectionServer: LocalCorrectionServing {
    private(set) var prepareCount = 0
    private(set) var generateCount = 0
    private(set) var useCount = 0
    private(set) var idleTimeout: TimeInterval = 600
    private var state = LocalCorrectionRuntimeState.stopped

    func runtimeState() -> LocalCorrectionRuntimeState { state }

    func updateIdleTimeout(_ timeout: TimeInterval) {
        idleTimeout = timeout
    }

    func beginUse() {
        useCount += 1
    }

    func endUse() {
        useCount = max(0, useCount - 1)
    }

    func prepare() {
        prepareCount += 1
        state = .ready
    }

    func generate(request: TranscriptEditRequest, grammar: String) -> String {
        generateCount += 1
        state = .ready
        return #"{"hasChanges":true,"explanation":"Removed a filler.","revisedText":"Send it today."}"#
    }

    func stop() {
        state = .stopped
    }
}
