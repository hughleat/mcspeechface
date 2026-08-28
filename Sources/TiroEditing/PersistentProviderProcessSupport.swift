import Foundation

final class JSONLinePump: @unchecked Sendable {
    private let handle: FileHandle
    private let continuation: AsyncStream<Data>.Continuation
    private let deliveryTask: Task<Void, Never>
    private let maximumLineBytes: Int
    private let lock = NSLock()
    private var buffer = Data()

    init(
        handle: FileHandle,
        maximumLineBytes: Int = 1_048_576,
        onLine: @escaping @Sendable (Data) async -> Void,
        onOverflow: @escaping @Sendable () async -> Void
    ) {
        self.handle = handle
        self.maximumLineBytes = maximumLineBytes
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        self.continuation = continuation
        deliveryTask = Task {
            for await line in stream {
                if line.isEmpty { await onOverflow() }
                else { await onLine(line) }
            }
        }
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
    }

    func stop() {
        handle.readabilityHandler = nil
        continuation.finish()
        deliveryTask.cancel()
        try? handle.close()
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines = lock.withLock {
            var lines: [Data] = []
            var overflowed = false
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.count > maximumLineBytes { overflowed = true }
                else if !line.isEmpty { lines.append(line) }
            }
            if buffer.count > maximumLineBytes {
                buffer.removeAll(keepingCapacity: false)
                overflowed = true
            }
            if overflowed { lines.append(Data()) }
            return lines
        }
        for line in lines {
            if case .dropped = continuation.yield(line) {
                _ = continuation.yield(Data())
            }
        }
    }
}

final class PipeDrain: @unchecked Sendable {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        handle.readabilityHandler = { handle in _ = handle.availableData }
    }

    func stop() {
        handle.readabilityHandler = nil
        try? handle.close()
    }
}
