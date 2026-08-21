import Darwin
import Foundation

public enum LocalCorrectionRuntimeState: Equatable, Sendable {
    case stopped
    case loading
    case ready
    case correcting
    case failed(String)

    public var isRunning: Bool {
        switch self {
        case .loading, .ready, .correcting: true
        case .stopped, .failed: false
        }
    }
}

protocol LocalCorrectionServing: Sendable {
    func runtimeState() async -> LocalCorrectionRuntimeState
    func updateIdleTimeout(_ timeout: TimeInterval) async
    func beginUse() async
    func endUse() async
    func prepare() async throws
    func generate(request: TranscriptEditRequest, grammar: String) async throws -> String
    func stop() async
}

actor PersistentLlamaServer: LocalCorrectionServing {
    private static let startupTimeout: TimeInterval = 45
    private static let requestTimeout: TimeInterval = 90

    private let executableURL: URL
    private let modelURL: URL
    private var process: Process?
    private var endpoint: URL?
    private var apiKey = ""
    private var modelAlias = ""
    private var runtimeDirectory: URL?
    private var logCapture: BoundedProcessLog?
    private var state = LocalCorrectionRuntimeState.stopped
    private var idleTimeout: TimeInterval
    private var idleTask: Task<Void, Never>?
    private var activityGeneration = 0
    private var lifecycleGeneration = 0
    private var useCount = 0
    private var operationInProgress = false

    init(executableURL: URL, modelURL: URL, idleTimeout: TimeInterval) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.idleTimeout = idleTimeout
    }

    deinit {
        idleTask?.cancel()
        process?.terminate()
        if let runtimeDirectory {
            try? FileManager.default.removeItem(at: runtimeDirectory)
        }
    }

    func runtimeState() -> LocalCorrectionRuntimeState {
        refreshExitedProcessState()
        return state
    }

    func updateIdleTimeout(_ timeout: TimeInterval) {
        idleTimeout = timeout
        if state == .ready {
            scheduleIdleStop()
        }
    }

    func beginUse() {
        useCount += 1
        cancelIdleStop()
    }

    func endUse() {
        useCount = max(0, useCount - 1)
        if state == .ready { scheduleIdleStop() }
    }

    func prepare() async throws {
        try await acquireOperation()
        do {
            try await ensureReady()
            operationInProgress = false
            scheduleIdleStop()
        } catch is CancellationError {
            operationInProgress = false
            lifecycleGeneration += 1
            stopProcess()
            state = .stopped
            throw CancellationError()
        } catch {
            operationInProgress = false
            throw error
        }
    }

    func generate(
        request: TranscriptEditRequest,
        grammar: String
    ) async throws -> String {
        try await acquireOperation()
        cancelIdleStop()
        do {
            try await ensureReady()
            guard let endpoint else {
                throw GGUFTranscriptEditorError.generationFailed(
                    "The local correction server has no endpoint."
                )
            }
            state = .correcting
            let generation = lifecycleGeneration
            let completionURL = endpoint
                .appendingPathComponent("v1")
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
            var urlRequest = URLRequest(
                url: completionURL,
                timeoutInterval: Self.requestTimeout
            )
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            urlRequest.httpBody = try JSONEncoder().encode(ChatRequest(
                messages: [
                    .init(
                        role: "system",
                        content: TranscriptEditingPrompt.instructions(request)
                    ),
                    .init(
                        role: "user",
                        content: TranscriptEditingPrompt.request(request)
                    ),
                ],
                maxTokens: TranscriptEditingPrompt.maximumResponseTokens(request),
                grammar: grammar
            ))

            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard generation == lifecycleGeneration,
                  process?.isRunning == true else {
                throw GGUFTranscriptEditorError.generationFailed(
                    "The local correction model was stopped."
                )
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw GGUFTranscriptEditorError.generationFailed(
                    Self.serverErrorMessage(data: data, response: response)
                )
            }
            guard let content = try JSONDecoder().decode(
                ChatResponse.self,
                from: data
            ).choices.first?.message.content else {
                throw GGUFTranscriptEditorError.invalidResponse
            }
            state = .ready
            operationInProgress = false
            scheduleIdleStop()
            return content
        } catch is CancellationError {
            operationInProgress = false
            if state == .loading {
                lifecycleGeneration += 1
                stopProcess()
                state = .stopped
            } else {
                restoreReadyStateAfterRequest()
            }
            throw CancellationError()
        } catch let error as GGUFTranscriptEditorError {
            operationInProgress = false
            restoreReadyStateAfterRequest()
            throw error
        } catch let error as URLError where error.code == .timedOut {
            operationInProgress = false
            restoreReadyStateAfterRequest()
            throw GGUFTranscriptEditorError.generationTimedOut
        } catch {
            operationInProgress = false
            restoreReadyStateAfterRequest()
            throw GGUFTranscriptEditorError.generationFailed(error.localizedDescription)
        }
    }

    func stop() {
        lifecycleGeneration += 1
        cancelIdleStop()
        stopProcess()
        state = .stopped
    }

    private func ensureReady() async throws {
        refreshExitedProcessState()
        if state == .ready { return }
        if state == .loading {
            try await waitUntilReady()
            return
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GGUFTranscriptEditorError.runtimeUnavailable
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw GGUFTranscriptEditorError.modelNotInstalled
        }

        let runtimeDirectory = try Self.makeRuntimeDirectory()
        apiKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        modelAlias = "tiro-\(UUID().uuidString)"
        let apiKeyFile = runtimeDirectory.appendingPathComponent("api-key")
        do {
            try Data(apiKey.utf8).write(to: apiKeyFile, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: apiKeyFile.path
            )
        } catch {
            try? FileManager.default.removeItem(at: runtimeDirectory)
            apiKey = ""
            modelAlias = ""
            throw GGUFTranscriptEditorError.generationFailed(
                "Could not secure the local correction server."
            )
        }
        self.runtimeDirectory = runtimeDirectory
        endpoint = nil

        let process = Process()
        let logCapture = BoundedProcessLog()
        process.executableURL = executableURL
        process.arguments = [
            "--model", modelURL.path,
            "--alias", modelAlias,
            "--host", "127.0.0.1",
            "--port", "0",
            "--api-key-file", apiKeyFile.path,
            "--ctx-size", "4096",
            "--gpu-layers", "all",
            "--parallel", "1",
            "--cache-ram", "256",
            "--jinja",
            "--no-ui",
            "--no-warmup",
            "--no-perf",
            "--log-colors", "off",
            "--log-verbosity", "3",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logCapture.pipe
        self.logCapture = logCapture
        do {
            try process.run()
            try? logCapture.pipe.fileHandleForWriting.close()
        } catch {
            clearRuntimeResources()
            throw GGUFTranscriptEditorError.generationFailed(error.localizedDescription)
        }
        self.process = process
        state = .loading
        try await waitUntilReady()
    }

    private func waitUntilReady() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(Self.startupTimeout))
        while clock.now < deadline {
            try Task.checkCancellation()
            refreshExitedProcessState()
            guard state == .loading else {
                if state == .ready { return }
                if case .failed(let reason) = state {
                    throw GGUFTranscriptEditorError.generationFailed(reason)
                }
                throw GGUFTranscriptEditorError.generationFailed(
                    failureMessage(
                        fallback: "The local correction server stopped while loading the model."
                    )
                )
            }
            if endpoint == nil, let port = logCapture?.listeningPort() {
                endpoint = URL(string: "http://127.0.0.1:\(port)/")
            }
            let generation = lifecycleGeneration
            if endpoint != nil,
               await serverIsReady(),
               generation == lifecycleGeneration,
               state == .loading,
               process?.isRunning == true {
                state = .ready
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let message = failureMessage(fallback: "The model did not finish loading in time.")
        lifecycleGeneration += 1
        stopProcess()
        state = .failed(message)
        throw GGUFTranscriptEditorError.generationTimedOut
    }

    private func serverIsReady() async -> Bool {
        guard let endpoint else { return false }
        var request = URLRequest(
            url: endpoint
                .appendingPathComponent("v1")
                .appendingPathComponent("models"),
            timeoutInterval: 1
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let models = try? JSONDecoder().decode(ModelList.self, from: data) else {
                return false
            }
            return models.data.contains(where: { $0.id == modelAlias })
        } catch {
            return false
        }
    }

    private func restoreReadyStateAfterRequest() {
        guard state == .correcting else { return }
        refreshExitedProcessState()
        if process?.isRunning == true {
            state = .ready
            scheduleIdleStop()
        }
    }

    private func refreshExitedProcessState() {
        guard let process, !process.isRunning else { return }
        logCapture?.drainAfterProcessExit()
        let message = failureMessage(
            fallback: "The local correction server stopped unexpectedly."
        )
        lifecycleGeneration += 1
        self.process = nil
        clearRuntimeResources()
        if state.isRunning {
            state = .failed(message)
        }
    }

    private func scheduleIdleStop() {
        cancelIdleStop()
        guard idleTimeout > 0, useCount == 0, !operationInProgress else { return }
        activityGeneration += 1
        let generation = activityGeneration
        idleTask = Task { [idleTimeout] in
            do {
                try await Task.sleep(for: .seconds(idleTimeout))
            } catch {
                return
            }
            self.stopIfIdle(generation: generation)
        }
    }

    private func stopIfIdle(generation: Int) {
        guard generation == activityGeneration, state == .ready else { return }
        lifecycleGeneration += 1
        stopProcess()
        state = .stopped
        idleTask = nil
    }

    private func cancelIdleStop() {
        activityGeneration += 1
        idleTask?.cancel()
        idleTask = nil
    }

    private func stopProcess() {
        if let process {
            let identifier = process.processIdentifier
            if process.isRunning {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                    guard process.isRunning,
                          process.processIdentifier == identifier else { return }
                    Darwin.kill(identifier, SIGKILL)
                }
            }
        }
        self.process = nil
        clearRuntimeResources()
    }

    private func clearRuntimeResources() {
        endpoint = nil
        apiKey = ""
        modelAlias = ""
        logCapture?.finish()
        logCapture = nil
        if let runtimeDirectory {
            try? FileManager.default.removeItem(at: runtimeDirectory)
            self.runtimeDirectory = nil
        }
    }

    private func failureMessage(fallback: String) -> String {
        guard let detail = logCapture?.lastMeaningfulLine(
            redacting: [modelURL.path, runtimeDirectory?.path].compactMap { $0 }
        ) else { return fallback }
        return "\(fallback) \(detail)"
    }

    private func acquireOperation() async throws {
        while operationInProgress {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        operationInProgress = true
    }

    private static func serverErrorMessage(data: Data, response: URLResponse) -> String {
        if let body = String(data: data.prefix(4_096), encoding: .utf8), !body.isEmpty {
            return body
        }
        if let http = response as? HTTPURLResponse {
            return "The local correction server returned HTTP \(http.statusCode)."
        }
        return "The local correction server returned an invalid response."
    }

    private static func makeRuntimeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tiro-local-correction-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return directory
        } catch {
            throw GGUFTranscriptEditorError.generationFailed(
                "Could not prepare the local correction server."
            )
        }
    }

    private struct ChatRequest: Encodable {
        let messages: [Message]
        let maxTokens: Int
        let grammar: String
        let temperature = 0.0
        let stream = false
        let reasoningFormat = "none"
        let chatTemplateKwargs = ["enable_thinking": false]

        enum CodingKeys: String, CodingKey {
            case messages
            case maxTokens = "max_tokens"
            case grammar
            case temperature
            case stream
            case reasoningFormat = "reasoning_format"
            case chatTemplateKwargs = "chat_template_kwargs"
        }
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct ChatResponse: Decodable {
        let choices: [Choice]
    }

    private struct Choice: Decodable {
        let message: Message
    }

    private struct ModelList: Decodable {
        let data: [Model]
    }

    private struct Model: Decodable {
        let id: String
    }
}

private final class BoundedProcessLog: @unchecked Sendable {
    let pipe = Pipe()

    private let lock = NSLock()
    private var data = Data()
    private let maximumBytes = 16_384

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.append(chunk)
        }
    }

    func finish() {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
    }

    func drainAfterProcessExit() {
        pipe.fileHandleForReading.readabilityHandler = nil
        if let remaining = try? pipe.fileHandleForReading.readToEnd(),
           !remaining.isEmpty {
            append(remaining)
        }
    }

    func lastMeaningfulLine(redacting values: [String]) -> String? {
        lock.lock()
        let snapshot = data
        lock.unlock()
        guard var line = String(decoding: snapshot, as: UTF8.self)
            .split(whereSeparator: \Character.isNewline)
            .reversed()
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        for value in values where !value.isEmpty {
            line = line.replacingOccurrences(of: value, with: "[private path]")
        }
        return String(line.prefix(500))
    }

    func listeningPort() -> UInt16? {
        lock.lock()
        let snapshot = data
        lock.unlock()
        let marker = "server is listening on http://127.0.0.1:"
        guard let line = String(decoding: snapshot, as: UTF8.self)
            .split(whereSeparator: \Character.isNewline)
            .reversed()
            .first(where: { $0.contains(marker) }),
              let markerRange = line.range(of: marker) else { return nil }
        let digits = line[markerRange.upperBound...].prefix(while: \Character.isNumber)
        return UInt16(digits)
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > maximumBytes {
            data.removeFirst(data.count - maximumBytes)
        }
    }
}
