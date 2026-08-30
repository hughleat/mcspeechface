import Darwin
import Foundation

public final class McSpeechfaceCommandSocketClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (McSpeechfaceCommandEvent) -> Void

    public let socketURL: URL
    public let timeout: TimeInterval

    public init(
        socketURL: URL = McSpeechfaceCommandSocketPath.defaultURL(),
        timeout: TimeInterval = McSpeechfaceProtocolLimits.defaultResponseTimeout
    ) {
        self.socketURL = socketURL
        self.timeout = timeout
    }

    public func send(
        _ request: McSpeechfaceCommandRequest,
        onEvent: EventHandler? = nil
    ) throws -> McSpeechfaceCommandMessage {
        _ = try request.validated()
        try McSpeechfaceCommandSocketPath.validate(socketURL)
        guard timeout.isFinite, timeout > 0,
              timeout <= McSpeechfaceProtocolLimits.defaultResponseTimeout else {
            throw McSpeechfaceSocketError.invalidTimeout
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var payload = try encoder.encode(request)
        guard payload.count <= McSpeechfaceProtocolLimits.maximumRequestBytes else {
            throw McSpeechfaceProtocolError.requestTooLarge
        }
        payload.append(0x0A)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw McSpeechfaceSocketError.systemCall("socket", errno)
        }
        defer { close(descriptor) }

        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0 else {
            throw McSpeechfaceSocketError.systemCall("setsockopt", errno)
        }

        try connect(descriptor)
        try McSpeechfaceCommandSocketSecurity.validatePeer(descriptor)
        try writeAll(payload, to: descriptor, timeout: timeout)
        return try readResponse(
            from: descriptor,
            request: request,
            onEvent: onEvent
        )
    }

    private func connect(_ descriptor: Int32) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketURL.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: path)
        }
        let length = socklen_t(
            MemoryLayout<sa_family_t>.size + path.count
        )
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else {
            throw McSpeechfaceSocketError.connectionFailed(path: socketURL.path, code: errno)
        }
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32,
        timeout: TimeInterval
    ) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw McSpeechfaceSocketError.systemCall("fcntl", errno)
        }
        let deadline = Date().addingTimeInterval(timeout)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw McSpeechfaceSocketError.timedOut }
                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                let milliseconds = Int32(
                    min(Double(Int32.max), ceil(remaining * 1_000))
                )
                let pollResult = poll(&pollDescriptor, 1, milliseconds)
                if pollResult < 0, errno == EINTR { continue }
                guard pollResult > 0 else {
                    if pollResult == 0 { throw McSpeechfaceSocketError.timedOut }
                    throw McSpeechfaceSocketError.systemCall("poll", errno)
                }
                guard pollDescriptor.revents & Int16(POLLNVAL | POLLERR) == 0,
                      pollDescriptor.revents & Int16(POLLOUT) != 0 else {
                    throw McSpeechfaceSocketError.connectionClosed
                }

                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, (errno == EINTR || errno == EAGAIN) {
                    continue
                } else if written < 0, (errno == EPIPE || errno == ECONNRESET) {
                    throw McSpeechfaceSocketError.connectionClosed
                } else {
                    throw McSpeechfaceSocketError.systemCall("write", errno)
                }
            }
        }
    }

    private func readResponse(
        from descriptor: Int32,
        request: McSpeechfaceCommandRequest,
        onEvent: EventHandler?
    ) throws -> McSpeechfaceCommandMessage {
        let deadline = Date().addingTimeInterval(timeout)
        let decoder = JSONDecoder()
        var pending = Data()
        var totalBytes = 0
        var messageCount = 0

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw McSpeechfaceSocketError.timedOut }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min(Double(Int32.max), ceil(remaining * 1_000)))
            let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
            if pollResult < 0, errno == EINTR { continue }
            guard pollResult > 0 else {
                if pollResult == 0 { throw McSpeechfaceSocketError.timedOut }
                throw McSpeechfaceSocketError.systemCall("poll", errno)
            }

            var buffer = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw McSpeechfaceSocketError.systemCall("read", errno)
            }
            guard count > 0 else {
                if !pending.isEmpty {
                    throw McSpeechfaceProtocolError.incompleteResponse
                }
                throw McSpeechfaceProtocolError.incompleteResponse
            }

            pending.append(contentsOf: buffer.prefix(count))
            totalBytes += count
            guard totalBytes <= McSpeechfaceProtocolLimits.maximumResponseBytes else {
                throw McSpeechfaceProtocolError.responseTooLarge
            }
            guard pending.count <= McSpeechfaceProtocolLimits.maximumMessageBytes else {
                throw McSpeechfaceProtocolError.messageTooLarge
            }

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                messageCount += 1
                guard messageCount <= McSpeechfaceProtocolLimits.maximumMessages else {
                    throw McSpeechfaceProtocolError.tooManyMessages
                }
                let message: McSpeechfaceCommandMessage
                do {
                    message = try decoder.decode(McSpeechfaceCommandMessage.self, from: line)
                } catch {
                    throw McSpeechfaceProtocolError.unexpectedResponse(
                        "McSpeechface sent malformed command data."
                    )
                }
                _ = try message.validated(for: request)
                if message.type == .event {
                    if let event = message.event { onEvent?(event) }
                } else {
                    return message
                }
            }
        }
    }
}

public enum McSpeechfaceCommandSocketSecurity {
    public static func validatePeer(
        _ descriptor: Int32,
        expectedUID: uid_t = geteuid()
    ) throws {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0 else {
            throw McSpeechfaceSocketError.systemCall("getpeereid", errno)
        }
        guard peerUID == expectedUID else {
            throw McSpeechfaceSocketError.peerUIDMismatch(
                expected: UInt32(expectedUID),
                actual: UInt32(peerUID)
            )
        }
    }
}

public enum McSpeechfaceSocketError: Error, Equatable, LocalizedError {
    case invalidSocketPath
    case unsafeSocketDirectory
    case invalidTimeout
    case connectionFailed(path: String, code: Int32)
    case peerUIDMismatch(expected: UInt32, actual: UInt32)
    case systemCall(String, Int32)
    case connectionClosed
    case timedOut

    public var isRetryableConnectionFailure: Bool {
        if case .connectionFailed(_, let code) = self {
            return code == ENOENT || code == ECONNREFUSED
        }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .invalidSocketPath:
            "The McSpeechface command socket path is invalid."
        case .unsafeSocketDirectory:
            "The McSpeechface command socket must be inside its dedicated app directory."
        case .invalidTimeout:
            "The McSpeechface command timeout is invalid."
        case .connectionFailed(let path, let code):
            "Could not connect to McSpeechface at \(path): \(Self.description(for: code))."
        case .peerUIDMismatch:
            "The McSpeechface command socket belongs to another user."
        case .systemCall(let operation, let code):
            "\(operation) failed: \(Self.description(for: code))."
        case .connectionClosed:
            "The McSpeechface command connection closed unexpectedly."
        case .timedOut:
            "McSpeechface did not respond before the command timed out."
        }
    }

    private static func description(for code: Int32) -> String {
        String(cString: strerror(code))
    }
}
