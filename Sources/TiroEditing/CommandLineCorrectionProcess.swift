import Darwin
import Foundation

struct CommandLineCorrectionProcessResult: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let workingDirectory: URL
}

protocol CommandLineCorrectionProcessRunning: Sendable {
    func run(
        configuration: CommandLineCorrectionConfiguration,
        standardInput: Data,
        eventHandler: (@Sendable (String) -> Void)?
    ) async throws -> CommandLineCorrectionProcessResult
}

extension CommandLineCorrectionProcessRunning {
    func run(
        configuration: CommandLineCorrectionConfiguration,
        standardInput: Data
    ) async throws -> CommandLineCorrectionProcessResult {
        try await run(
            configuration: configuration,
            standardInput: standardInput,
            eventHandler: nil
        )
    }
}

struct FoundationCommandLineCorrectionProcessRunner: CommandLineCorrectionProcessRunning {
    static let maximumOutputBytes = 512_000
    static let maximumErrorOutputBytes = 128_000

    private let temporaryRoot: URL
    private let maximumOutputBytes: Int
    private let maximumErrorOutputBytes: Int
    private let processLauncherURL: URL?

    init(
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        maximumOutputBytes: Int = Self.maximumOutputBytes,
        maximumErrorOutputBytes: Int = Self.maximumErrorOutputBytes,
        processLauncherURL: URL? = Self.bundledProcessLauncherURL
    ) {
        self.temporaryRoot = temporaryRoot
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumErrorOutputBytes = maximumErrorOutputBytes
        self.processLauncherURL = processLauncherURL
    }

    func run(
        configuration: CommandLineCorrectionConfiguration,
        standardInput: Data,
        eventHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandLineCorrectionProcessResult {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let executableURL = try validatedExecutable(configuration.executableURL)
        let workingDirectory = temporaryRoot.appendingPathComponent(
            "tiro-command-correction-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CommandLineCorrectionError.couldNotCreateWorkingDirectory
        }
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let preparedArguments = try prepareArguments(
            configuration.arguments,
            workingDirectory: workingDirectory
        )
        let execution = CommandLineProcessExecution(
            executableURL: executableURL,
            arguments: preparedArguments.arguments,
            processLauncherURL: processLauncherURL,
            workingDirectory: workingDirectory,
            outputFileURL: preparedArguments.outputFileURL,
            standardInput: standardInput,
            maximumOutputBytes: maximumOutputBytes,
            maximumErrorOutputBytes: maximumErrorOutputBytes,
            eventHandler: eventHandler
        )
        let captured = try await execution.run(timeout: configuration.timeout)
        return CommandLineCorrectionProcessResult(
            standardOutput: captured.standardOutput,
            standardError: captured.standardError,
            workingDirectory: workingDirectory
        )
    }

    static var bundledProcessLauncherURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/tiro-process-launcher")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func validatedExecutable(_ executableURL: URL) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: executableURL.path) else {
            throw CommandLineCorrectionError.executableNotFound
        }
        let resolved = executableURL.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolved.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              fileManager.isExecutableFile(atPath: resolved.path) else {
            throw CommandLineCorrectionError.executableNotRunnable
        }
        return resolved
    }

    private func prepareArguments(
        _ arguments: [String],
        workingDirectory: URL
    ) throws -> (arguments: [String], outputFileURL: URL?) {
        let schemaFileURL = workingDirectory.appendingPathComponent(
            "correction-output.schema.json",
            isDirectory: false
        )
        let outputFileURL = workingDirectory.appendingPathComponent(
            "correction-output.json",
            isDirectory: false
        )
        do {
            try TranscriptCorrectionOutputSchema.data.write(to: schemaFileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: schemaFileURL.path
            )
        } catch {
            throw CommandLineCorrectionError.couldNotWriteSchema
        }

        var usesOutputFile = false
        let prepared = arguments.map { argument in
            switch argument {
            case CommandLineCorrectionArgumentPlaceholder.schemaFile:
                return schemaFileURL.path
            case CommandLineCorrectionArgumentPlaceholder.schemaJSON:
                return TranscriptCorrectionOutputSchema.json
            case CommandLineCorrectionArgumentPlaceholder.outputFile:
                usesOutputFile = true
                return outputFileURL.path
            default:
                return argument
            }
        }
        return (prepared, usesOutputFile ? outputFileURL : nil)
    }
}

enum CommandLineProcessTerminator {
    static func stop(_ process: Process?, usesProcessGroup: Bool) {
        guard let process else { return }
        let identifier = process.processIdentifier
        guard identifier > 0 else { return }
        if usesProcessGroup {
            guard Darwin.kill(-identifier, SIGTERM) == 0 else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                Darwin.kill(-identifier, SIGKILL)
            }
        } else {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                guard process.isRunning, process.processIdentifier == identifier else { return }
                Darwin.kill(identifier, SIGKILL)
            }
        }
    }
}

enum CommandLineCorrectionEnvironment {
    static func minimum(workingDirectory: URL) -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        let commonPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existingPaths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let path = (commonPaths + existingPaths).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }.joined(separator: ":")
        return [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": environment["LANG"] ?? "en_US.UTF-8",
            "PATH": path,
            "TMPDIR": workingDirectory.path,
        ]
    }
}

private struct CapturedCommandLineOutput: Sendable {
    let standardOutput: String
    let standardError: String
}

private final class CommandLineProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorOutput = Pipe()
    private let outputFileURL: URL?
    private let standardInput: Data
    private let maximumOutputBytes: Int
    private let maximumErrorOutputBytes: Int
    private let usesProcessGroup: Bool
    private let eventHandler: (@Sendable (String) -> Void)?
    private let terminationLock = NSLock()

    init(
        executableURL: URL,
        arguments: [String],
        processLauncherURL: URL?,
        workingDirectory: URL,
        outputFileURL: URL?,
        standardInput: Data,
        maximumOutputBytes: Int,
        maximumErrorOutputBytes: Int,
        eventHandler: (@Sendable (String) -> Void)?
    ) {
        if let processLauncherURL {
            process.executableURL = processLauncherURL
            process.arguments = [executableURL.path] + arguments
            usesProcessGroup = true
        } else {
            process.executableURL = executableURL
            process.arguments = arguments
            usesProcessGroup = false
        }
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        process.environment = CommandLineCorrectionEnvironment.minimum(
            workingDirectory: workingDirectory
        )
        self.outputFileURL = outputFileURL
        self.standardInput = standardInput
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumErrorOutputBytes = maximumErrorOutputBytes
        self.eventHandler = eventHandler
    }

    func run(timeout: TimeInterval) async throws -> CapturedCommandLineOutput {
        try Task.checkCancellation()
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw CommandLineCorrectionError.inputWriteFailed
        }
        do {
            try process.run()
        } catch {
            throw CommandLineCorrectionError.couldNotLaunch(error.localizedDescription)
        }

        let outputReader = Task {
            try await Self.performBlocking {
                try Self.readBounded(
                    self.output.fileHandleForReading,
                    maximumBytes: self.maximumOutputBytes,
                    eventHandler: self.eventHandler
                )
            }
        }
        let errorReader = Task {
            try await Self.performBlocking {
                try Self.readBounded(
                    self.errorOutput.fileHandleForReading,
                    maximumBytes: self.maximumErrorOutputBytes,
                    eventHandler: nil
                )
            }
        }
        let inputWriter = Task {
            try await Self.performBlocking {
                defer { try? self.input.fileHandleForWriting.close() }
                do {
                    try self.input.fileHandleForWriting.write(contentsOf: self.standardInput)
                } catch {
                    throw CommandLineCorrectionError.inputWriteFailed
                }
            }
        }

        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                try await waitForExit(timeout: timeout)
            } onCancel: {
                stop()
            }
        } catch {
            stop()
            _ = try? await inputWriter.value
            _ = try? await outputReader.value
            _ = try? await errorReader.value
            throw error
        }

        stopRemainingProcessGroup()
        try await inputWriter.value
        let capturedOutput = try await outputReader.value
        let capturedError = try await errorReader.value
        if capturedOutput.exceededLimit { throw CommandLineCorrectionError.outputTooLarge }
        if capturedError.exceededLimit { throw CommandLineCorrectionError.errorOutputTooLarge }
        guard let outputText = String(data: capturedOutput.data, encoding: .utf8) else {
            throw CommandLineCorrectionError.invalidUTF8Output
        }
        let errorText = String(decoding: capturedError.data, as: UTF8.self)
        guard exitCode == 0 else {
            throw CommandLineCorrectionError.failed(exitCode: exitCode)
        }
        let preferredOutput = try Self.preferredOutput(
            standardOutput: outputText,
            outputFileURL: outputFileURL,
            maximumBytes: maximumOutputBytes
        )
        return CapturedCommandLineOutput(
            standardOutput: preferredOutput,
            standardError: errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func waitForExit(timeout: TimeInterval) async throws -> Int32 {
        enum Completion: Sendable {
            case exited(Int32)
            case timedOut
        }

        return try await withThrowingTaskGroup(of: Completion.self) { group in
            group.addTask {
                await self.waitUntilExit()
                return .exited(self.process.terminationStatus)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timedOut
            }
            guard let completion = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            switch completion {
            case .exited(let status):
                return status
            case .timedOut:
                stop()
                throw CommandLineCorrectionError.timedOut
            }
        }
    }

    private func waitUntilExit() async {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                autoreleasepool {
                    self.process.waitUntilExit()
                    continuation.resume()
                }
            }
        }
    }

    private func stop() {
        terminationLock.lock()
        defer { terminationLock.unlock() }
        guard process.isRunning else { return }
        let identifier = process.processIdentifier
        if usesProcessGroup {
            if Darwin.kill(-identifier, SIGTERM) == 0 {
                scheduleProcessGroupKill(identifier)
            }
        } else {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 0.25
            ) { [process] in
                guard process.isRunning, process.processIdentifier == identifier else { return }
                Darwin.kill(identifier, SIGKILL)
            }
        }
    }

    private func stopRemainingProcessGroup() {
        guard usesProcessGroup else { return }
        let identifier = process.processIdentifier
        if Darwin.kill(-identifier, SIGTERM) == 0 {
            scheduleProcessGroupKill(identifier)
        }
    }

    private func scheduleProcessGroupKill(_ identifier: pid_t) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            Darwin.kill(-identifier, SIGKILL)
        }
    }

    private static func readBounded(
        _ handle: FileHandle,
        maximumBytes: Int,
        eventHandler: (@Sendable (String) -> Void)? = nil
    ) throws -> (data: Data, exceededLimit: Bool) {
        defer { try? handle.close() }
        var data = Data()
        var pendingEventData = Data()
        var exceededLimit = false
        while let chunk = try handle.read(upToCount: 16_384), !chunk.isEmpty {
            let remaining = max(0, maximumBytes - data.count)
            if chunk.count > remaining { exceededLimit = true }
            if remaining > 0 { data.append(chunk.prefix(remaining)) }
            if let eventHandler {
                pendingEventData.append(chunk)
                while let newline = pendingEventData.firstIndex(of: 0x0A) {
                    let lineData = pendingEventData[..<newline]
                    pendingEventData.removeSubrange(...newline)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        eventHandler(line)
                    }
                }
                if pendingEventData.count > 64_000 {
                    pendingEventData.removeAll(keepingCapacity: true)
                }
            }
        }
        if let eventHandler,
           !pendingEventData.isEmpty,
           let line = String(data: pendingEventData, encoding: .utf8) {
            eventHandler(line)
        }
        return (data, exceededLimit)
    }

    private static func performBlocking<Result: Sendable>(
        _ operation: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                autoreleasepool {
                    do {
                        continuation.resume(returning: try operation())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private static func preferredOutput(
        standardOutput: String,
        outputFileURL: URL?,
        maximumBytes: Int
    ) throws -> String {
        let trimmedStandardOutput = standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let outputFileURL,
              let captured = try readOutputFile(outputFileURL, maximumBytes: maximumBytes) else {
            return trimmedStandardOutput
        }
        if captured.exceededLimit { throw CommandLineCorrectionError.outputTooLarge }
        guard let output = String(data: captured.data, encoding: .utf8) else {
            throw CommandLineCorrectionError.invalidUTF8Output
        }
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedOutput.isEmpty ? trimmedStandardOutput : trimmedOutput
    }

    private static func readOutputFile(
        _ outputFileURL: URL,
        maximumBytes: Int
    ) throws -> (data: Data, exceededLimit: Bool)? {
        let descriptor = Darwin.open(
            outputFileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw CommandLineCorrectionError.unsafeOutputFile }
            throw CommandLineCorrectionError.couldNotReadOutputFile
        }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0 else {
            Darwin.close(descriptor)
            throw CommandLineCorrectionError.couldNotReadOutputFile
        }
        guard (fileStatus.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw CommandLineCorrectionError.unsafeOutputFile
        }
        return try readBounded(
            FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            maximumBytes: maximumBytes
        )
    }

}
