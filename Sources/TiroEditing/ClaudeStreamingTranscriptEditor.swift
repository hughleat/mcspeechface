import Foundation

public enum ClaudeStreamingError: LocalizedError, Equatable {
    case connectionClosed
    case requestTimedOut
    case requestInProgress
    case invalidResponse
    case outputTooLarge
    case providerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .connectionClosed: "The Claude connection closed unexpectedly."
        case .requestTimedOut: "Claude took too long to respond."
        case .requestInProgress: "Another Claude correction is already running."
        case .invalidResponse: "Claude returned an invalid response."
        case .outputTooLarge: "Claude returned too much data."
        case .providerFailed(let reason): "Claude failed: \(reason)"
        }
    }
}

public struct ClaudeStreamingConfiguration: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let systemPrompt: String
    public let idleTimeout: TimeInterval

    public init(
        executablePath: String,
        arguments: [String],
        systemPrompt: String = TranscriptEditingPromptConfiguration.default.systemPrompt,
        idleTimeout: TimeInterval
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.systemPrompt = systemPrompt
        self.idleTimeout = idleTimeout
    }
}

public actor ClaudeStreamingTranscriptEditor: PersistentTranscriptEditor {
    public nonisolated let id = "claude-streaming"
    public nonisolated let name = "Claude"

    private let configuration: ClaudeStreamingConfiguration
    private let client: ClaudeStreamingClient

    public init(configuration: ClaudeStreamingConfiguration) {
        self.configuration = configuration
        client = ClaudeStreamingClient(configuration: configuration)
    }

    public func availability() async -> TranscriptEditorAvailability {
        FileManager.default.isExecutableFile(atPath: configuration.executablePath)
            ? .available
            : .unavailable(reason: CommandLineCorrectionError.executableNotFound.localizedDescription)
    }

    public func runtimeState() async -> PersistentCorrectionRuntimeState {
        await client.runtimeState()
    }

    public func prepare() async throws {
        try await client.prepareForCorrection(systemPrompt: configuration.systemPrompt)
    }

    public func stop() async {
        await client.stop()
    }

    public func proposeEdits(for request: TranscriptEditRequest) async throws -> TranscriptEditDecision {
        try await proposeEdits(for: request, progressHandler: nil)
    }

    public func proposeEdits(
        for request: TranscriptEditRequest,
        progressHandler: (@Sendable (TranscriptEditingProgress) -> Void)?
    ) async throws -> TranscriptEditDecision {
        guard !request.text.isEmpty else { return .unchanged }
        try TranscriptEditingPrompt.validate(request)
        progressHandler?(TranscriptEditingProgress(providerName: name, phase: .starting))
        let output = try await client.correct(
            systemPrompt: TranscriptEditingPrompt.instructions(request),
            userPrompt: TranscriptEditingPrompt.request(request),
            progressHandler: progressHandler
        )
        return try CommandLineTranscriptEditor.decision(
            from: output,
            originalText: request.text,
            requiresGrounding: false
        )
    }
}

private actor ClaudeStreamingClient {
    private struct ActiveRequest {
        let continuation: CheckedContinuation<String, Error>
        let progressHandler: (@Sendable (TranscriptEditingProgress) -> Void)?
        let timeoutTask: Task<Void, Never>
        var assistantText = ""
    }

    private let configuration: ClaudeStreamingConfiguration
    private var process: Process?
    private var usesProcessGroup = false
    private var input: FileHandle?
    private var outputPump: JSONLinePump?
    private var errorDrain: PipeDrain?
    private var runtimeDirectory: URL?
    private var currentSystemPrompt: String?
    private var state = PersistentCorrectionRuntimeState.stopped
    private var activeRequest: ActiveRequest?
    private var correctionReserved = false
    private var completedCorrections = 0
    private var idleTask: Task<Void, Never>?
    private var lifecycleGeneration = 0

    init(configuration: ClaudeStreamingConfiguration) {
        self.configuration = configuration
    }

    func runtimeState() -> PersistentCorrectionRuntimeState {
        refreshExitedProcess()
        return state
    }

    func prepare(systemPrompt: String) async throws {
        try Task.checkCancellation()
        refreshExitedProcess()
        if process?.isRunning == true, currentSystemPrompt == systemPrompt { return }
        if process?.isRunning == true { stop() }
        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else {
            throw CommandLineCorrectionError.executableNotFound
        }
        state = .starting
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        let directory = try Self.makeRuntimeDirectory()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        var arguments = configuration.arguments
        if !arguments.contains("--input-format") {
            arguments += ["--input-format", "stream-json"]
        }
        if !arguments.contains("--system-prompt") {
            arguments += ["--system-prompt", systemPrompt]
        }
        if let launcher = FoundationCommandLineCorrectionProcessRunner.bundledProcessLauncherURL {
            process.executableURL = launcher
            process.arguments = [configuration.executablePath] + arguments
            usesProcessGroup = true
        } else {
            process.executableURL = URL(fileURLWithPath: configuration.executablePath)
            process.arguments = arguments
            usesProcessGroup = false
        }
        process.currentDirectoryURL = directory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = CommandLineCorrectionEnvironment.minimum(workingDirectory: directory)
        process.terminationHandler = { [weak self] _ in
            Task { await self?.processExited(generation: generation) }
        }
        let pump = JSONLinePump(
            handle: outputPipe.fileHandleForReading,
            onLine: { [weak self] line in await self?.receive(line) },
            onOverflow: { [weak self] in await self?.protocolOutputTooLarge() }
        )
        let drain = PipeDrain(handle: errorPipe.fileHandleForReading)
        do {
            try process.run()
            try? inputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
        } catch {
            pump.stop()
            drain.stop()
            try? FileManager.default.removeItem(at: directory)
            state = .failed(error.localizedDescription)
            throw CommandLineCorrectionError.couldNotLaunch(error.localizedDescription)
        }
        self.process = process
        input = inputPipe.fileHandleForWriting
        outputPump = pump
        errorDrain = drain
        runtimeDirectory = directory
        currentSystemPrompt = systemPrompt
        completedCorrections = 0
        pump.start()
        drain.start()
        do {
            try Task.checkCancellation()
        } catch {
            stop()
            throw error
        }
        state = .ready
        scheduleIdleStop()
    }

    func prepareForCorrection(systemPrompt: String) async throws {
        try await prepare(systemPrompt: systemPrompt)
        guard completedCorrections > 0 else { return }
        stop()
        try await prepare(systemPrompt: systemPrompt)
    }

    func correct(
        systemPrompt: String,
        userPrompt: String,
        progressHandler: (@Sendable (TranscriptEditingProgress) -> Void)?
    ) async throws -> String {
        try Task.checkCancellation()
        try await prepareForCorrection(systemPrompt: systemPrompt)
        try Task.checkCancellation()
        guard !correctionReserved, activeRequest == nil else {
            throw ClaudeStreamingError.requestInProgress
        }
        correctionReserved = true
        defer { correctionReserved = false }
        cancelIdleStop()
        state = .correcting
        progressHandler?(TranscriptEditingProgress(providerName: "Claude", phase: .working))
        do {
            let output = try await sendAndWait(
                prompt: userPrompt,
                progressHandler: progressHandler
            )
            try Task.checkCancellation()
            completedCorrections += 1
            state = .ready
            scheduleIdleStop()
            return output
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        lifecycleGeneration += 1
        stopProcess(failure: CancellationError())
        state = .stopped
    }

    private func sendAndWait(
        prompt: String,
        progressHandler: (@Sendable (TranscriptEditingProgress) -> Void)?
    ) async throws -> String {
        guard activeRequest == nil else {
            throw ClaudeStreamingError.requestInProgress
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    await self?.activeRequestTimedOut()
                }
                activeRequest = ActiveRequest(
                    continuation: continuation,
                    progressHandler: progressHandler,
                    timeoutTask: timeoutTask
                )
                do {
                    try sendUserMessage(prompt)
                } catch {
                    finishActiveRequest(.failure(error))
                }
            }
        } onCancel: {
            Task { await self.cancelActiveRequest() }
        }
    }

    private func sendUserMessage(_ prompt: String) throws {
        guard let input, process?.isRunning == true else {
            throw ClaudeStreamingError.connectionClosed
        }
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": prompt],
            "parent_tool_use_id": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: message) + Data([0x0A])
        try input.write(contentsOf: data)
    }

    private func receive(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return }
        if type == "system", object["subtype"] as? String == "init" { return }
        guard var active = activeRequest else { return }
        switch type {
        case "assistant":
            active.progressHandler?(
                TranscriptEditingProgress(providerName: "Claude", phase: .receiving)
            )
            if let message = object["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                let text = content.compactMap {
                    $0["type"] as? String == "text" ? $0["text"] as? String : nil
                }.joined()
                guard text.utf8.count <= 512_000 else {
                    protocolOutputTooLarge()
                    return
                }
                active.assistantText = text
            }
            activeRequest = active
        case "stream_event":
            active.progressHandler?(
                TranscriptEditingProgress(providerName: "Claude", phase: .receiving)
            )
        case "result":
            guard object["subtype"] as? String == "success" else {
                let message = object["result"] as? String ?? "The correction request failed."
                finishActiveRequest(.failure(ClaudeStreamingError.providerFailed(message)))
                return
            }
            if let structured = object["structured_output"],
                      JSONSerialization.isValidJSONObject(structured),
                      let data = try? JSONSerialization.data(withJSONObject: structured),
                      let text = String(data: data, encoding: .utf8) {
                finishActiveRequest(.success(text))
            } else if let result = object["result"] as? String, !result.isEmpty {
                finishActiveRequest(.success(result))
            } else if !active.assistantText.isEmpty {
                finishActiveRequest(.success(active.assistantText))
            } else {
                finishActiveRequest(.failure(ClaudeStreamingError.invalidResponse))
            }
        default:
            break
        }
    }

    private func finishActiveRequest(_ result: Result<String, Error>) {
        guard let active = activeRequest else { return }
        activeRequest = nil
        active.timeoutTask.cancel()
        active.continuation.resume(with: result)
    }

    private func activeRequestTimedOut() {
        finishActiveRequest(.failure(ClaudeStreamingError.requestTimedOut))
    }

    private func cancelActiveRequest() {
        finishActiveRequest(.failure(CancellationError()))
        stop()
    }

    private func scheduleIdleStop() {
        cancelIdleStop()
        guard configuration.idleTimeout > 0, state == .ready else { return }
        let generation = lifecycleGeneration
        idleTask = Task { [weak self, timeout = configuration.idleTimeout] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            await self?.stopIfIdle(generation: generation)
        }
    }

    private func stopIfIdle(generation: Int) {
        guard generation == lifecycleGeneration, state == .ready else { return }
        stop()
    }

    private func cancelIdleStop() {
        idleTask?.cancel()
        idleTask = nil
    }

    private func refreshExitedProcess() {
        guard let process, !process.isRunning else { return }
        processExited(generation: lifecycleGeneration)
    }

    private func processExited(generation: Int) {
        guard generation == lifecycleGeneration, process != nil else { return }
        stopProcess(failure: ClaudeStreamingError.connectionClosed)
        if state.isRunning { state = .failed(ClaudeStreamingError.connectionClosed.localizedDescription) }
    }

    private func stopProcess(failure: Error) {
        cancelIdleStop()
        if let active = activeRequest {
            activeRequest = nil
            active.continuation.resume(throwing: failure)
        }
        outputPump?.stop()
        errorDrain?.stop()
        try? input?.close()
        CommandLineProcessTerminator.stop(process, usesProcessGroup: usesProcessGroup)
        process = nil
        usesProcessGroup = false
        input = nil
        outputPump = nil
        errorDrain = nil
        if let runtimeDirectory { try? FileManager.default.removeItem(at: runtimeDirectory) }
        runtimeDirectory = nil
        currentSystemPrompt = nil
    }

    private func protocolOutputTooLarge() {
        let error = ClaudeStreamingError.outputTooLarge
        lifecycleGeneration += 1
        stopProcess(failure: error)
        state = .failed(error.localizedDescription)
    }

    private static func makeRuntimeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiro-claude-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return directory
        } catch {
            throw CommandLineCorrectionError.couldNotCreateWorkingDirectory
        }
    }

}
