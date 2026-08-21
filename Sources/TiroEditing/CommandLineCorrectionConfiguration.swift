import Foundation

public struct CommandLineCorrectionConfiguration: Equatable, Sendable {
    public static let maximumTimeout: TimeInterval = 300
    public static let defaultTimeout: TimeInterval = 45

    public let id: String
    public let name: String
    public let executablePath: String
    public let arguments: [String]
    public let timeout: TimeInterval

    public init(
        id: String,
        name: String,
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval = Self.defaultTimeout
    ) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandLineCorrectionError.invalidIdentifier
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandLineCorrectionError.invalidName
        }
        guard (executablePath as NSString).isAbsolutePath,
              !executablePath.contains("\0") else {
            throw CommandLineCorrectionError.executablePathMustBeAbsolute
        }
        guard timeout > 0, timeout <= Self.maximumTimeout else {
            throw CommandLineCorrectionError.invalidTimeout
        }
        guard arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw CommandLineCorrectionError.invalidArgument
        }

        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.timeout = timeout
    }

    var executableURL: URL {
        URL(fileURLWithPath: executablePath).standardizedFileURL
    }
}

public enum CommandLineCorrectionError: LocalizedError, Equatable {
    case invalidIdentifier
    case invalidName
    case executablePathMustBeAbsolute
    case executableNotFound
    case executableNotRunnable
    case invalidArgument
    case invalidTimeout
    case couldNotCreateWorkingDirectory
    case couldNotLaunch(String)
    case inputWriteFailed
    case timedOut
    case outputTooLarge
    case errorOutputTooLarge
    case couldNotWriteSchema
    case couldNotReadOutputFile
    case unsafeOutputFile
    case failed(exitCode: Int32)
    case invalidUTF8Output
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "The command-line correction identifier cannot be empty."
        case .invalidName: "The command-line correction name cannot be empty."
        case .executablePathMustBeAbsolute:
            "The command-line correction executable must use an absolute path."
        case .executableNotFound: "The command-line correction executable could not be found."
        case .executableNotRunnable: "The command-line correction executable is not runnable."
        case .invalidArgument: "A command-line correction argument is invalid."
        case .invalidTimeout:
            "The command-line correction timeout must be greater than zero and no more than "
                + "\(Int(CommandLineCorrectionConfiguration.maximumTimeout)) seconds."
        case .couldNotCreateWorkingDirectory:
            "A private working directory could not be created for command-line correction."
        case .couldNotLaunch(let message):
            "The command-line correction process could not start: \(message)"
        case .inputWriteFailed: "The correction prompt could not be sent to the process."
        case .timedOut: "The command-line correction process timed out."
        case .outputTooLarge: "The command-line correction output was too large."
        case .errorOutputTooLarge: "The command-line correction error output was too large."
        case .couldNotWriteSchema:
            "The command-line correction schema could not be written."
        case .couldNotReadOutputFile:
            "The command-line correction output file could not be read."
        case .unsafeOutputFile:
            "The command-line correction output file is not a safe regular file."
        case .failed(let exitCode):
            "The command-line correction process exited with code \(exitCode)."
        case .invalidUTF8Output: "The command-line correction process returned invalid text."
        case .invalidResponse:
            "The command-line correction process returned an invalid structured response."
        }
    }
}
