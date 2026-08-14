import CryptoKit
import Foundation
import Testing
@testable import TiroEditing

struct LocalTranscriptEditingTests {
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
        let output = try await FoundationTranscriptEditingProcessRunner().run(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: GGUFTranscriptEditor.arguments(modelURL: store.modelURL, request: request),
            timeout: 90
        )
        if environment["TIRO_QWEN_DUMP_OUTPUT"] == "1" {
            print("Qwen fixture output:\n\(output)")
        }
        let decision = try GGUFTranscriptEditor.decision(
            from: output,
            originalText: request.text
        )

        guard case .proposal(let proposal) = decision else {
            Issue.record("Expected Qwen to remove dictated fillers and the editing request")
            return
        }
        #expect(proposal.revisedText == "Send the report tomorrow.")
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
