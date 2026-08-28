import Foundation

public enum PersistentCorrectionRuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case correcting
    case failed(String)

    public var isRunning: Bool {
        switch self {
        case .starting, .ready, .correcting: true
        case .stopped, .failed: false
        }
    }
}

public enum CodexCorrectionAccess: String, Sendable {
    case correctionOnly
    case readOnly
    case standard
    case unrestricted
}

public struct CodexAppServerConfiguration: Equatable, Sendable {
    public let executablePath: String
    public let model: String
    public let reasoningEffort: String?
    public let access: CodexCorrectionAccess
    public let idleTimeout: TimeInterval

    public init(
        executablePath: String,
        model: String,
        reasoningEffort: String?,
        access: CodexCorrectionAccess,
        idleTimeout: TimeInterval
    ) {
        self.executablePath = executablePath
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.access = access
        self.idleTimeout = idleTimeout
    }
}

public struct CodexModelOption: Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let supportedReasoningEfforts: [String]
    public let defaultReasoningEffort: String

    init(object: [String: Any]) throws {
        guard let id = object["model"] as? String,
              let title = object["displayName"] as? String,
              let detail = object["description"] as? String,
              let defaultEffort = object["defaultReasoningEffort"] as? String else {
            throw CodexAppServerError.invalidResponse
        }
        self.id = id
        self.title = title
        self.detail = detail
        defaultReasoningEffort = defaultEffort
        supportedReasoningEfforts = (object["supportedReasoningEfforts"] as? [[String: Any]])?
            .compactMap { $0["reasoningEffort"] as? String } ?? []
    }
}

public enum CodexAppServerError: LocalizedError, Equatable {
    case executableUnavailable
    case couldNotStart(String)
    case connectionClosed
    case requestTimedOut
    case outputTooLarge
    case invalidResponse
    case providerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable: "The installed Codex app server is unavailable."
        case .couldNotStart(let reason): "Codex could not start: \(reason)"
        case .connectionClosed: "The Codex connection closed unexpectedly."
        case .requestTimedOut: "Codex took too long to respond."
        case .outputTooLarge: "Codex returned too much data."
        case .invalidResponse: "Codex returned an invalid response."
        case .providerFailed(let reason): "Codex failed: \(reason)"
        }
    }
}

public actor CodexAppServerTranscriptEditor: PersistentTranscriptEditor {
    public nonisolated let id = "codex-app-server"
    public nonisolated let name = "Codex"

    private let configuration: CodexAppServerConfiguration
    private let client: CodexAppServerClient

    public init(configuration: CodexAppServerConfiguration) {
        self.configuration = configuration
        client = CodexAppServerClient(configuration: configuration)
    }

    public func availability() async -> TranscriptEditorAvailability {
        FileManager.default.isExecutableFile(atPath: configuration.executablePath)
            ? .available
            : .unavailable(reason: CodexAppServerError.executableUnavailable.localizedDescription)
    }

    public func runtimeState() async -> PersistentCorrectionRuntimeState {
        await client.runtimeState()
    }

    public func prepare() async throws {
        try await client.prepare()
    }

    public func stop() async {
        await client.stop()
    }

    public func supportedModels() async throws -> [CodexModelOption] {
        try await client.supportedModels()
    }

    public func proposeEdits(
        for request: TranscriptEditRequest
    ) async throws -> TranscriptEditDecision {
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

private actor CodexAppServerClient {
    private struct Preparation {
        let generation: Int
        let task: Task<Void, Error>
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct ActiveCorrection {
        let threadID: String
        var turnID: String?
        var text = ""
        var result: Result<String, Error>?
        var continuation: CheckedContinuation<String, Error>?
        var timeoutTask: Task<Void, Never>?
        let progressHandler: (@Sendable (TranscriptEditingProgress) -> Void)?
    }

    private let configuration: CodexAppServerConfiguration
    private var process: Process?
    private var usesProcessGroup = false
    private var input: FileHandle?
    private var outputPump: JSONLinePump?
    private var errorDrain: PipeDrain?
    private var runtimeDirectory: URL?
    private var state = PersistentCorrectionRuntimeState.stopped
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var activeCorrection: ActiveCorrection?
    private var preparation: Preparation?
    private var correctionReserved = false
    private var idleTask: Task<Void, Never>?
    private var lifecycleGeneration = 0

    init(configuration: CodexAppServerConfiguration) {
        self.configuration = configuration
    }

    func runtimeState() -> PersistentCorrectionRuntimeState {
        refreshExitedProcess()
        return state
    }

    func prepare() async throws {
        refreshExitedProcess()
        if process?.isRunning == true, state != .starting { return }
        if let preparation {
            try await preparation.task.value
            return
        }
        let generation = lifecycleGeneration + 1
        let task = Task { try await self.startProcess() }
        preparation = Preparation(generation: generation, task: task)
        do {
            try await task.value
            if preparation?.generation == generation { preparation = nil }
        } catch {
            if preparation?.generation == generation { preparation = nil }
            throw error
        }
    }

    private func startProcess() async throws {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else {
            throw CodexAppServerError.executableUnavailable
        }
        state = .starting
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        let directory = try Self.makeRuntimeDirectory()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let launch = try codexLaunchConfiguration(runtimeDirectory: directory)
        if let launcher = FoundationCommandLineCorrectionProcessRunner.bundledProcessLauncherURL {
            process.executableURL = launcher
            process.arguments = [configuration.executablePath] + launch.arguments
            usesProcessGroup = true
        } else {
            process.executableURL = URL(fileURLWithPath: configuration.executablePath)
            process.arguments = launch.arguments
            usesProcessGroup = false
        }
        process.currentDirectoryURL = directory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = launch.environment
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
            throw CodexAppServerError.couldNotStart(error.localizedDescription)
        }
        self.process = process
        input = inputPipe.fileHandleForWriting
        outputPump = pump
        errorDrain = drain
        runtimeDirectory = directory
        pump.start()
        drain.start()

        do {
            _ = try await request(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "tiro",
                        "title": "Tiro",
                        "version": "1",
                    ],
                    "capabilities": ["experimentalApi": false],
                ],
                timeout: 15
            )
            try sendNotification(method: "initialized", params: [:])
            state = .ready
            scheduleIdleStop()
        } catch {
            if generation == lifecycleGeneration {
                stopProcess(failure: error)
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func supportedModels() async throws -> [CodexModelOption] {
        try await prepare()
        cancelIdleStop()
        defer { scheduleIdleStop() }
        var cursor: String?
        var models: [CodexModelOption] = []
        var seenCursors = Set<String>()
        for _ in 0..<10 {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let result = try await request(method: "model/list", params: params, timeout: 15)
            guard let values = result["data"] as? [[String: Any]] else {
                throw CodexAppServerError.invalidResponse
            }
            guard models.count + values.count <= 1_000 else {
                throw CodexAppServerError.invalidResponse
            }
            models += try values.map(CodexModelOption.init(object:))
            guard let nextCursor = result["nextCursor"] as? String else { return models }
            guard seenCursors.insert(nextCursor).inserted else {
                throw CodexAppServerError.invalidResponse
            }
            cursor = nextCursor
        }
        throw CodexAppServerError.invalidResponse
    }

    func correct(
        systemPrompt: String,
        userPrompt: String,
        progressHandler: (@Sendable (TranscriptEditingProgress) -> Void)?
    ) async throws -> String {
        try Task.checkCancellation()
        try await prepare()
        try Task.checkCancellation()
        cancelIdleStop()
        guard !correctionReserved, activeCorrection == nil else {
            throw CodexAppServerError.providerFailed("Another correction is already running.")
        }
        correctionReserved = true
        defer { correctionReserved = false }
        state = .correcting
        do {
            let directory = try Self.workingDirectory(
                access: configuration.access,
                runtimeDirectory: runtimeDirectory
            )
            let threadResult = try await request(
                method: "thread/start",
                params: threadParameters(systemPrompt: systemPrompt, cwd: directory.path),
                timeout: 20
            )
            guard let thread = threadResult["thread"] as? [String: Any],
                  let threadID = thread["id"] as? String else {
                throw CodexAppServerError.invalidResponse
            }
            activeCorrection = ActiveCorrection(
                threadID: threadID,
                progressHandler: progressHandler
            )
            progressHandler?(TranscriptEditingProgress(providerName: "Codex", phase: .working))
            let turnResult = try await request(
                method: "turn/start",
                params: turnParameters(threadID: threadID, prompt: userPrompt),
                timeout: 20
            )
            guard let turn = turnResult["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else {
                throw CodexAppServerError.invalidResponse
            }
            activeCorrection?.turnID = turnID
            startCorrectionTimeout(threadID: threadID)
            let result = try await waitForActiveCorrection(threadID: threadID)
            try Task.checkCancellation()
            state = .ready
            scheduleIdleStop()
            return result
        } catch {
            let turnMayBeRunning = activeCorrection?.turnID == nil && activeCorrection != nil
            activeCorrection?.timeoutTask?.cancel()
            activeCorrection = nil
            if turnMayBeRunning {
                lifecycleGeneration += 1
                stopProcess(failure: error)
                state = .stopped
            } else if process?.isRunning == true {
                state = .ready
                scheduleIdleStop()
            }
            throw error
        }
    }

    func stop() {
        preparation?.task.cancel()
        preparation = nil
        lifecycleGeneration += 1
        stopProcess(failure: CancellationError())
        state = .stopped
    }

    private func request(
        method: String,
        params: [String: Any],
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        try Task.checkCancellation()
        let id = nextRequestID
        nextRequestID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    await self?.requestTimedOut(id: id)
                }
                pending[id] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                do {
                    try send(["id": id, "method": method, "params": params])
                } catch {
                    finishRequest(id: id, result: .failure(error))
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        try send(["method": method, "params": params])
    }

    private func send(_ object: [String: Any]) throws {
        guard let input, process?.isRunning == true else {
            throw CodexAppServerError.connectionClosed
        }
        let data = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
        try input.write(contentsOf: data)
    }

    private func receive(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }
        if object["method"] is String, let id = object["id"] {
            denyServerRequest(id: id)
            return
        }
        if let id = object["id"] as? Int {
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown provider error"
                finishRequest(id: id, result: .failure(CodexAppServerError.providerFailed(message)))
            } else if let result = object["result"] as? [String: Any] {
                finishRequest(id: id, result: .success(result))
            } else {
                finishRequest(id: id, result: .failure(CodexAppServerError.invalidResponse))
            }
            return
        }
        guard let method = object["method"] as? String,
              let params = object["params"] as? [String: Any] else { return }
        receiveNotification(method: method, params: params)
    }

    private func denyServerRequest(id: Any) {
        try? send([
            "id": id,
            "error": [
                "code": -32_600,
                "message": "Tiro correction sessions do not accept interactive requests.",
            ],
        ])
    }

    private func receiveNotification(method: String, params: [String: Any]) {
        guard var active = activeCorrection,
              params["threadId"] as? String == active.threadID else { return }
        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                guard active.text.utf8.count + delta.utf8.count <= 512_000 else {
                    protocolOutputTooLarge()
                    return
                }
                active.text += delta
                active.progressHandler?(
                    TranscriptEditingProgress(providerName: "Codex", phase: .receiving)
                )
            }
        case "item/completed":
            if let item = params["item"] as? [String: Any],
               item["type"] as? String == "agentMessage",
               let text = item["text"] as? String {
                guard text.utf8.count <= 512_000 else {
                    protocolOutputTooLarge()
                    return
                }
                active.text = text
            }
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any],
                  turn["status"] as? String == "completed" else {
                let turn = params["turn"] as? [String: Any]
                let message = ((turn?["error"] as? [String: Any])?["message"] as? String)
                    ?? "The correction turn did not complete."
                active.result = .failure(CodexAppServerError.providerFailed(message))
                break
            }
            if active.text.isEmpty {
                active.result = .failure(CodexAppServerError.invalidResponse)
            } else {
                active.result = .success(active.text)
            }
        default:
            break
        }
        activeCorrection = active
        resumeActiveCorrectionIfFinished()
    }

    private func waitForActiveCorrection(threadID: String) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard var active = activeCorrection, active.threadID == threadID else {
                    continuation.resume(throwing: CodexAppServerError.connectionClosed)
                    return
                }
                active.continuation = continuation
                activeCorrection = active
                resumeActiveCorrectionIfFinished()
            }
        } onCancel: {
            Task { await self.cancelActiveCorrection() }
        }
    }

    private func resumeActiveCorrectionIfFinished() {
        guard let active = activeCorrection,
              let result = active.result,
              let continuation = active.continuation else { return }
        activeCorrection = nil
        active.timeoutTask?.cancel()
        continuation.resume(with: result)
    }

    private func startCorrectionTimeout(threadID: String) {
        guard var active = activeCorrection, active.threadID == threadID else { return }
        active.timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            await self?.correctionTimedOut(threadID: threadID)
        }
        activeCorrection = active
    }

    private func correctionTimedOut(threadID: String) {
        guard activeCorrection?.threadID == threadID else { return }
        lifecycleGeneration += 1
        stopProcess(failure: CodexAppServerError.requestTimedOut)
        state = .stopped
    }

    private func cancelActiveCorrection() {
        guard activeCorrection != nil else { return }
        lifecycleGeneration += 1
        stopProcess(failure: CancellationError())
        state = .stopped
    }

    private func finishRequest(id: Int, result: Result<[String: Any], Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(with: result)
    }

    private func requestTimedOut(id: Int) {
        finishRequest(id: id, result: .failure(CodexAppServerError.requestTimedOut))
    }

    private func cancelRequest(id: Int) {
        finishRequest(id: id, result: .failure(CancellationError()))
    }

    private func threadParameters(systemPrompt: String, cwd: String) -> [String: Any] {
        var params: [String: Any] = [
            "baseInstructions": systemPrompt,
            "cwd": cwd,
            "ephemeral": true,
            "model": configuration.model,
            "personality": "none",
            "sandbox": sandboxName,
            "approvalPolicy": approvalPolicy,
            "approvalsReviewer": approvalsReviewer,
            "threadSource": "tiro-correction",
        ]
        if configuration.access == .correctionOnly {
            params["developerInstructions"] =
                "Correct only the supplied transcript. Do not call tools or inspect files."
        }
        return params
    }

    private func codexLaunchConfiguration(
        runtimeDirectory: URL
    ) throws -> (arguments: [String], environment: [String: String]) {
        var environment = CommandLineCorrectionEnvironment.minimum(
            workingDirectory: runtimeDirectory
        )
        guard configuration.access == .correctionOnly || configuration.access == .readOnly else {
            return (["app-server", "--stdio"], environment)
        }
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.createSymbolicLink(
                at: runtimeDirectory.appendingPathComponent("auth.json"),
                withDestinationURL: source
            )
        }
        environment["CODEX_HOME"] = runtimeDirectory.path
        var disabledFeatures = [
            "apps", "plugins", "computer_use", "image_generation", "multi_agent",
        ]
        if configuration.access == .correctionOnly {
            disabledFeatures += [
                "browser_use", "skill_search", "workspace_dependencies", "shell_tool",
                "view_image",
            ]
        }
        let featureArguments = disabledFeatures.flatMap { ["--disable", $0] }
        return (["app-server"] + featureArguments + ["--stdio"], environment)
    }

    private func turnParameters(threadID: String, prompt: String) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": threadID,
            "input": [["type": "text", "text": prompt]],
            "outputSchema": Self.outputSchema,
            "sandboxPolicy": sandboxPolicy,
        ]
        if let effort = configuration.reasoningEffort { params["effort"] = effort }
        return params
    }

    private var sandboxName: String {
        switch configuration.access {
        case .correctionOnly, .readOnly: "read-only"
        case .standard: "workspace-write"
        case .unrestricted: "danger-full-access"
        }
    }

    private var sandboxPolicy: [String: Any] {
        switch configuration.access {
        case .correctionOnly, .readOnly:
            ["type": "readOnly", "networkAccess": configuration.access == .readOnly]
        case .standard:
            ["type": "workspaceWrite", "writableRoots": [], "networkAccess": true]
        case .unrestricted:
            ["type": "dangerFullAccess"]
        }
    }

    private var approvalPolicy: String {
        configuration.access == .standard ? "on-request" : "never"
    }

    private var approvalsReviewer: String {
        configuration.access == .standard ? "auto_review" : "user"
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
        stopProcess(failure: CodexAppServerError.connectionClosed)
        if state.isRunning { state = .failed(CodexAppServerError.connectionClosed.localizedDescription) }
    }

    private func stopProcess(failure: Error) {
        cancelIdleStop()
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: failure)
        }
        activeCorrection?.continuation?.resume(throwing: failure)
        activeCorrection?.timeoutTask?.cancel()
        activeCorrection = nil
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
    }

    private func protocolOutputTooLarge() {
        let error = CodexAppServerError.outputTooLarge
        lifecycleGeneration += 1
        stopProcess(failure: error)
        state = .failed(error.localizedDescription)
    }

    private static func makeRuntimeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiro-codex-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return directory
        } catch {
            throw CodexAppServerError.couldNotStart("Could not create a private working directory.")
        }
    }

    private static func workingDirectory(
        access: CodexCorrectionAccess,
        runtimeDirectory: URL?
    ) throws -> URL {
        if access == .correctionOnly, let runtimeDirectory { return runtimeDirectory }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static let outputSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "hasChanges": ["type": "boolean"],
            "explanation": ["type": "string"],
            "revisedText": ["type": "string"],
        ],
        "required": ["hasChanges", "explanation", "revisedText"],
    ]
}
