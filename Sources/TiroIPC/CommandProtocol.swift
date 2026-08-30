import Foundation

public enum TiroProtocolLimits {
    public static let version = 3
    public static let maximumRequestBytes = 64 * 1_024
    public static let maximumMessageBytes = 1_024 * 1_024
    public static let maximumResponseBytes = 4 * 1_024 * 1_024
    public static let maximumMessages = 1_024
    public static let maximumPathBytes = 4_096
    public static let maximumModelKeyBytes = 128
    public static let maximumInstructionsBytes = 8_000
    public static let maximumSocketPathBytes = 103
    public static let defaultResponseTimeout: TimeInterval = 3_600
}

public enum TiroCommandName: String, Codable, Sendable {
    case status
    case models
    case correctionModels = "correction_models"
    case transcribe
    case recordStart = "record_start"
    case recordStop = "record_stop"
    case recordCancel = "record_cancel"
}

public struct TiroCommandCorrection: Codable, Equatable, Sendable {
    public let model: String?
    public let instructions: String?

    public init(model: String? = nil, instructions: String? = nil) {
        self.model = model
        self.instructions = instructions
    }
}

public struct TiroCommandArguments: Codable, Equatable, Sendable {
    public let path: String?
    public let model: String?
    public let copy: Bool?
    public let saveHistory: Bool?
    public let diarize: Bool?
    public let session: String?
    public let lease: Bool?
    public let correction: TiroCommandCorrection?

    public init(
        path: String? = nil,
        model: String? = nil,
        copy: Bool? = nil,
        saveHistory: Bool? = nil,
        diarize: Bool? = nil,
        session: String? = nil,
        lease: Bool? = nil,
        correction: TiroCommandCorrection? = nil
    ) {
        self.path = path
        self.model = model
        self.copy = copy
        self.saveHistory = saveHistory
        self.diarize = diarize
        self.session = session
        self.lease = lease
        self.correction = correction
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case model
        case copy
        case saveHistory = "save_history"
        case diarize
        case session
        case lease
        case correction
    }
}

public struct TiroCommandRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let command: TiroCommandName
    public let arguments: TiroCommandArguments?

    public init(
        id: UUID = UUID(),
        command: TiroCommandName,
        arguments: TiroCommandArguments? = nil
    ) {
        version = TiroProtocolLimits.version
        self.id = id.uuidString.lowercased()
        self.command = command
        self.arguments = arguments
    }

    public static func status(id: UUID = UUID()) -> TiroCommandRequest {
        TiroCommandRequest(id: id, command: .status)
    }

    public static func models(id: UUID = UUID()) -> TiroCommandRequest {
        TiroCommandRequest(id: id, command: .models)
    }

    public static func correctionModels(id: UUID = UUID()) -> TiroCommandRequest {
        TiroCommandRequest(id: id, command: .correctionModels)
    }

    public static func transcribe(
        path: String,
        model: String?,
        copy: Bool,
        saveHistory: Bool,
        diarize: Bool = false,
        correction: TiroCommandCorrection? = nil,
        id: UUID = UUID()
    ) -> TiroCommandRequest {
        TiroCommandRequest(
            id: id,
            command: .transcribe,
            arguments: TiroCommandArguments(
                path: path,
                model: model,
                copy: copy,
                saveHistory: saveHistory,
                diarize: diarize,
                correction: correction
            )
        )
    }

    public static func recordStart(
        model: String?,
        saveHistory: Bool,
        lease: Bool = false,
        correction: TiroCommandCorrection? = nil,
        id: UUID = UUID()
    ) -> TiroCommandRequest {
        TiroCommandRequest(
            id: id,
            command: .recordStart,
            arguments: TiroCommandArguments(
                model: model,
                saveHistory: saveHistory,
                lease: lease ? true : nil,
                correction: correction
            )
        )
    }

    public static func recordStop(
        session: String,
        copy: Bool,
        id: UUID = UUID()
    ) -> TiroCommandRequest {
        TiroCommandRequest(
            id: id,
            command: .recordStop,
            arguments: TiroCommandArguments(copy: copy, session: session)
        )
    }

    public static func recordCancel(
        session: String,
        id: UUID = UUID()
    ) -> TiroCommandRequest {
        TiroCommandRequest(
            id: id,
            command: .recordCancel,
            arguments: TiroCommandArguments(session: session)
        )
    }

    public func validated() throws -> TiroCommandRequest {
        guard version == TiroProtocolLimits.version else {
            throw TiroProtocolError.unsupportedVersion(version)
        }
        guard UUID(uuidString: id) != nil else {
            throw TiroProtocolError.invalidRequest("The request ID is invalid.")
        }
        switch command {
        case .status, .models, .correctionModels:
            guard arguments == nil else {
                throw TiroProtocolError.invalidRequest(
                    "This command does not accept arguments."
                )
            }
        case .transcribe:
            guard let arguments, let path = arguments.path, !path.isEmpty,
                  arguments.session == nil,
                  arguments.lease == nil else {
                throw TiroProtocolError.invalidRequest(
                    "The transcribe command has invalid arguments."
                )
            }
            guard path.utf8.count <= TiroProtocolLimits.maximumPathBytes else {
                throw TiroProtocolError.invalidRequest("The file path is too long.")
            }
            if let model = arguments.model {
                guard !model.isEmpty,
                      model.utf8.count <= TiroProtocolLimits.maximumModelKeyBytes else {
                    throw TiroProtocolError.invalidRequest("The model key is invalid.")
                }
            }
            try Self.validateCorrection(arguments)
        case .recordStart:
            guard let arguments,
                  arguments.path == nil,
                  arguments.session == nil,
                  arguments.diarize == nil,
                  arguments.copy == nil else {
                throw TiroProtocolError.invalidRequest(
                    "The record start command has invalid arguments."
                )
            }
            try Self.validateModel(arguments.model)
            try Self.validateCorrection(arguments)
        case .recordStop:
            guard let arguments,
                  arguments.path == nil,
                  arguments.model == nil,
                  arguments.saveHistory == nil,
                  arguments.diarize == nil,
                  arguments.lease == nil,
                  arguments.correction == nil else {
                throw TiroProtocolError.invalidRequest(
                    "The record stop command has invalid arguments."
                )
            }
            try Self.validateSession(arguments.session)
        case .recordCancel:
            guard let arguments,
                  arguments.path == nil,
                  arguments.model == nil,
                  arguments.copy == nil,
                  arguments.saveHistory == nil,
                  arguments.diarize == nil,
                  arguments.lease == nil,
                  arguments.correction == nil else {
                throw TiroProtocolError.invalidRequest(
                    "The record cancel command has invalid arguments."
                )
            }
            try Self.validateSession(arguments.session)
        }
        return self
    }

    private static func validateModel(_ model: String?) throws {
        guard let model else { return }
        guard !model.isEmpty,
              model.utf8.count <= TiroProtocolLimits.maximumModelKeyBytes else {
            throw TiroProtocolError.invalidRequest("The model key is invalid.")
        }
    }

    private static func validateCorrection(_ arguments: TiroCommandArguments) throws {
        guard let correction = arguments.correction else { return }
        if let model = correction.model {
            guard !model.isEmpty,
                  model.utf8.count <= TiroProtocolLimits.maximumModelKeyBytes else {
                throw TiroProtocolError.invalidRequest("The correction model key is invalid.")
            }
        }
        if let instructions = correction.instructions {
            guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  instructions.utf8.count <= TiroProtocolLimits.maximumInstructionsBytes else {
                throw TiroProtocolError.invalidRequest("The correction instructions are invalid.")
            }
        }
    }

    private static func validateSession(_ session: String?) throws {
        guard let session, UUID(uuidString: session) != nil else {
            throw TiroProtocolError.invalidRequest("The recording session is invalid.")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case id
        case command
        case arguments
    }
}

public enum TiroCommandMessageType: String, Codable, Sendable {
    case event
    case success
    case failure
}

public struct TiroCommandEvent: Codable, Equatable, Sendable {
    public let name: String
    public let fraction: Double?
    public let detail: String?

    public init(name: String, fraction: Double? = nil, detail: String? = nil) {
        self.name = name
        self.fraction = fraction
        self.detail = detail
    }
}

public struct TiroCommandResult: Codable, Equatable, Sendable {
    public let kind: String
    public let text: String?
    public let originalText: String?
    public let model: String?
    public let correction: TiroCommandCorrectionResult?
    public let historyID: String?
    public let transcriptionSeconds: Double?
    public let state: String?
    public let selectedModel: String?
    public let session: String?
    public let segments: [TiroCommandSegment]?
    public let models: [TiroCommandModel]?
    public let correctionModels: [TiroCommandCorrectionModel]?

    public init(
        kind: String,
        text: String? = nil,
        originalText: String? = nil,
        model: String? = nil,
        correction: TiroCommandCorrectionResult? = nil,
        historyID: String? = nil,
        transcriptionSeconds: Double? = nil,
        state: String? = nil,
        selectedModel: String? = nil,
        session: String? = nil,
        segments: [TiroCommandSegment]? = nil,
        models: [TiroCommandModel]? = nil,
        correctionModels: [TiroCommandCorrectionModel]? = nil
    ) {
        self.kind = kind
        self.text = text
        self.originalText = originalText
        self.model = model
        self.correction = correction
        self.historyID = historyID
        self.transcriptionSeconds = transcriptionSeconds
        self.state = state
        self.selectedModel = selectedModel
        self.session = session
        self.segments = segments
        self.models = models
        self.correctionModels = correctionModels
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case originalText = "original_text"
        case model
        case correction
        case historyID = "history_id"
        case transcriptionSeconds = "transcription_seconds"
        case state
        case selectedModel = "selected_model"
        case session
        case segments
        case models
        case correctionModels = "correction_models"
    }
}

public struct TiroCommandCorrectionResult: Codable, Equatable, Sendable {
    public let model: String
    public let changed: Bool
    public let seconds: Double
    public let explanation: String
    public let reviewRecommended: Bool

    public init(
        model: String,
        changed: Bool,
        seconds: Double,
        explanation: String,
        reviewRecommended: Bool
    ) {
        self.model = model
        self.changed = changed
        self.seconds = seconds
        self.explanation = explanation
        self.reviewRecommended = reviewRecommended
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case changed
        case seconds
        case explanation
        case reviewRecommended = "review_recommended"
    }
}

public struct TiroCommandCorrectionModel: Codable, Equatable, Sendable {
    public let key: String
    public let name: String
    public let available: Bool
    public let selected: Bool
    public let local: Bool
    public let installed: Bool?
    public let reason: String?

    public init(
        key: String,
        name: String,
        available: Bool,
        selected: Bool,
        local: Bool,
        installed: Bool? = nil,
        reason: String? = nil
    ) {
        self.key = key
        self.name = name
        self.available = available
        self.selected = selected
        self.local = local
        self.installed = installed
        self.reason = reason
    }
}

public struct TiroCommandModel: Codable, Equatable, Sendable {
    public let key: String
    public let name: String
    public let installed: Bool
    public let transcription: Bool

    public init(key: String, name: String, installed: Bool, transcription: Bool) {
        self.key = key
        self.name = name
        self.installed = installed
        self.transcription = transcription
    }
}

public struct TiroCommandSegment: Codable, Equatable, Sendable {
    public let text: String
    public let startTime: Double
    public let endTime: Double
    public let speakerID: String?

    public init(
        text: String,
        startTime: Double,
        endTime: Double,
        speakerID: String? = nil
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speakerID = speakerID
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case startTime = "start"
        case endTime = "end"
        case speakerID = "speaker_id"
    }
}

public struct TiroCommandFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct TiroCommandMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let type: TiroCommandMessageType
    public let event: TiroCommandEvent?
    public let result: TiroCommandResult?
    public let error: TiroCommandFailure?

    public init(
        version: Int = TiroProtocolLimits.version,
        id: String,
        type: TiroCommandMessageType,
        event: TiroCommandEvent? = nil,
        result: TiroCommandResult? = nil,
        error: TiroCommandFailure? = nil
    ) {
        self.version = version
        self.id = id
        self.type = type
        self.event = event
        self.result = result
        self.error = error
    }

    public static func event(
        id: String,
        name: String,
        fraction: Double? = nil,
        detail: String? = nil
    ) -> TiroCommandMessage {
        TiroCommandMessage(
            id: id,
            type: .event,
            event: TiroCommandEvent(name: name, fraction: fraction, detail: detail)
        )
    }

    public static func success(
        id: String,
        result: TiroCommandResult
    ) -> TiroCommandMessage {
        TiroCommandMessage(id: id, type: .success, result: result)
    }

    public static func failure(
        id: String,
        code: String,
        message: String
    ) -> TiroCommandMessage {
        TiroCommandMessage(
            id: id,
            type: .failure,
            error: TiroCommandFailure(code: code, message: message)
        )
    }

    public func validated(for request: TiroCommandRequest) throws -> TiroCommandMessage {
        guard version == TiroProtocolLimits.version else {
            throw TiroProtocolError.unsupportedVersion(version)
        }
        guard id == request.id else {
            throw TiroProtocolError.unexpectedResponse(
                "The response ID does not match the request."
            )
        }
        switch type {
        case .event:
            guard let event, result == nil, error == nil, !event.name.isEmpty else {
                throw TiroProtocolError.unexpectedResponse("The event response is malformed.")
            }
            if let fraction = event.fraction,
               (!fraction.isFinite || !(0...1).contains(fraction)) {
                throw TiroProtocolError.unexpectedResponse(
                    "The event progress value is invalid."
                )
            }
        case .success:
            guard let result, event == nil, error == nil else {
                throw TiroProtocolError.unexpectedResponse(
                    "The success response is malformed."
                )
            }
            try Self.validate(result, for: request)
        case .failure:
            guard let error, event == nil, result == nil,
                  !error.code.isEmpty, !error.message.isEmpty else {
                throw TiroProtocolError.unexpectedResponse(
                    "The failure response is malformed."
                )
            }
        }
        return self
    }

    private static func validate(
        _ result: TiroCommandResult,
        for request: TiroCommandRequest
    ) throws {
        switch request.command {
        case .status:
            guard result.kind == "status", result.state?.isEmpty == false else {
                throw TiroProtocolError.unexpectedResponse("The status result is malformed.")
            }
        case .models:
            guard result.kind == "models", result.models != nil else {
                throw TiroProtocolError.unexpectedResponse("The model result is malformed.")
            }
        case .correctionModels:
            guard result.kind == "correction_models", result.correctionModels != nil else {
                throw TiroProtocolError.unexpectedResponse(
                    "The correction model result is malformed."
                )
            }
        case .transcribe, .recordStop:
            try validateTranscript(result)
            if request.command == .transcribe {
                guard (result.correction != nil) == (request.arguments?.correction != nil) else {
                    throw TiroProtocolError.unexpectedResponse(
                        "The transcript correction result does not match the request."
                    )
                }
            }
        case .recordStart:
            let expectedKind = request.arguments?.lease == true
                ? "lease_released"
                : "recording"
            guard result.kind == expectedKind,
                  let session = result.session,
                  UUID(uuidString: session) != nil else {
                throw TiroProtocolError.unexpectedResponse("The recording result is malformed.")
            }
        case .recordCancel:
            guard result.kind == "cancelled" else {
                throw TiroProtocolError.unexpectedResponse("The cancellation result is malformed.")
            }
        }
    }

    private static func validateTranscript(_ result: TiroCommandResult) throws {
        guard result.kind == "transcript",
              let text = result.text,
              result.model?.isEmpty == false,
              result.transcriptionSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
              result.historyID.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw TiroProtocolError.unexpectedResponse("The transcript result is malformed.")
        }
        if let correction = result.correction {
            guard let originalText = result.originalText,
                  !correction.model.isEmpty,
                  correction.seconds.isFinite,
                  correction.seconds >= 0,
                  correction.changed == (text != originalText),
                  !correction.changed || result.segments == nil else {
                throw TiroProtocolError.unexpectedResponse(
                    "The correction result is malformed."
                )
            }
        } else if result.originalText != nil {
            throw TiroProtocolError.unexpectedResponse(
                "The transcript contains correction data without a correction result."
            )
        }
        if let segments = result.segments {
            guard segments.allSatisfy({
                $0.startTime.isFinite && $0.endTime.isFinite
                    && $0.startTime >= 0 && $0.endTime >= $0.startTime
            }) else {
                throw TiroProtocolError.unexpectedResponse(
                    "The transcript segments are malformed."
                )
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case id
        case type
        case event
        case result
        case error
    }
}

public enum TiroProtocolError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case invalidRequest(String)
    case unexpectedResponse(String)
    case requestTooLarge
    case messageTooLarge
    case responseTooLarge
    case tooManyMessages
    case incompleteResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Tiro command protocol version \(version) is not supported."
        case .invalidRequest(let message), .unexpectedResponse(let message):
            message
        case .requestTooLarge:
            "The Tiro command request is too large."
        case .messageTooLarge:
            "A response from Tiro exceeded the message limit."
        case .responseTooLarge:
            "The complete response from Tiro exceeded the size limit."
        case .tooManyMessages:
            "Tiro sent too many response messages."
        case .incompleteResponse:
            "Tiro closed the connection without a final response."
        }
    }
}
