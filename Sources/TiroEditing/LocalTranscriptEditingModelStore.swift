import CryptoKit
import Foundation

public struct LocalTranscriptEditingModelSpec: Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let fileName: String
    public let downloadURL: URL
    public let expectedBytes: Int64
    public let sha256: String

    public init(
        id: String,
        name: String,
        detail: String,
        fileName: String,
        downloadURL: URL,
        expectedBytes: Int64,
        sha256: String
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.fileName = fileName
        self.downloadURL = downloadURL
        self.expectedBytes = expectedBytes
        self.sha256 = sha256
    }

    public static let qwen3Local = LocalTranscriptEditingModelSpec(
        id: "qwen3-1.7b-q4",
        name: "Qwen 3 1.7B",
        detail: "Local · 1.28 GB · Multilingual",
        fileName: "Qwen3-1.7B-Q4_K_M.gguf",
        downloadURL: URL(string:
            "https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/resolve/" +
            "daeb8e2d528a760970442092f6bf1e55c3b659eb/Qwen3-1.7B-Q4_K_M.gguf?download=true"
        )!,
        expectedBytes: 1_282_439_264,
        sha256: "d2387ca2dbfee2ffabce7120d3770dadca0b293052bc2f0e138fdc940d9bc7b5"
    )

    public static let ministral3Local = LocalTranscriptEditingModelSpec(
        id: "ministral-3-3b-q4",
        name: "Ministral 3 3B",
        detail: "Local · 2.15 GB · Multilingual",
        fileName: "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
        downloadURL: URL(string:
            "https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/" +
            "eb599d408350ea2bb60452cb86be7c7b2fc28227/" +
            "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf?download=true"
        )!,
        expectedBytes: 2_147_023_008,
        sha256: "9ed150d4367e68df0ac8e1540f6ddc65b42d0ee26378329d1ecbca60f93fc5f8"
    )

}

public enum LocalTranscriptEditingModelStatus: Equatable, Sendable {
    case notInstalled
    case installing
    case installed(bytes: Int64)
}

public struct LocalTranscriptEditingModelDownloadSpace: Equatable, Sendable {
    public let requiredBytes: Int64
    public let availableBytes: Int64?

    public init(requiredBytes: Int64, availableBytes: Int64?) {
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
    }

    public var hasEnoughSpace: Bool {
        availableBytes.map { $0 >= requiredBytes } ?? true
    }
}

public enum LocalTranscriptEditingModelError: LocalizedError {
    case operationInProgress
    case unsafeModelsDirectory
    case insufficientSpace(required: Int64, available: Int64)
    case downloadFailed
    case unexpectedFileSize
    case checksumMismatch
    case incompleteInstallation

    public var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "A local editing model operation is already in progress."
        case .unsafeModelsDirectory:
            "The local editing model folder is not safe to modify."
        case .insufficientSpace(let required, let available):
            "The model needs \(Self.bytes(required)) free; \(Self.bytes(available)) is available."
        case .downloadFailed:
            "The local editing model download failed."
        case .unexpectedFileSize:
            "The downloaded editing model has an unexpected size."
        case .checksumMismatch:
            "The downloaded editing model failed its security check."
        case .incompleteInstallation:
            "The local editing model installation is incomplete."
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

public struct DownloadedTranscriptEditingModel: Sendable {
    public let fileURL: URL
    public let statusCode: Int?

    public init(fileURL: URL, statusCode: Int?) {
        self.fileURL = fileURL
        self.statusCode = statusCode
    }
}

public protocol TranscriptEditingModelDownloading: Sendable {
    func download(from url: URL) async throws -> DownloadedTranscriptEditingModel
}

public struct URLSessionTranscriptEditingModelDownloader: TranscriptEditingModelDownloading {
    public init() {}

    public func download(from url: URL) async throws -> DownloadedTranscriptEditingModel {
        let (fileURL, response) = try await URLSession.shared.download(from: url)
        return DownloadedTranscriptEditingModel(
            fileURL: fileURL,
            statusCode: (response as? HTTPURLResponse)?.statusCode
        )
    }
}

public actor LocalTranscriptEditingModelStore {
    public nonisolated let spec: LocalTranscriptEditingModelSpec
    public nonisolated let modelURL: URL

    private static let safetyReserveBytes: Int64 = 2_000_000_000

    private let root: URL
    private let downloader: any TranscriptEditingModelDownloading
    private let fileManager: FileManager
    private var operationInProgress = false

    public init(
        spec: LocalTranscriptEditingModelSpec,
        root: URL,
        downloader: any TranscriptEditingModelDownloading =
            URLSessionTranscriptEditingModelDownloader(),
        fileManager: FileManager = .default
    ) {
        self.spec = spec
        self.root = root.standardizedFileURL
        self.downloader = downloader
        self.fileManager = fileManager
        modelURL = root
            .appendingPathComponent(spec.id, isDirectory: true)
            .appendingPathComponent(spec.fileName)
            .standardizedFileURL
    }

    public func status() -> LocalTranscriptEditingModelStatus {
        if operationInProgress { return .installing }
        return installedBytes().map(LocalTranscriptEditingModelStatus.installed)
            ?? .notInstalled
    }

    public func downloadSpace() -> LocalTranscriptEditingModelDownloadSpace {
        var probe = root
        while !fileManager.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { break }
            probe = parent
        }
        let available = try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        return LocalTranscriptEditingModelDownloadSpace(
            requiredBytes: spec.expectedBytes + Self.safetyReserveBytes,
            availableBytes: available.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    public func install() async throws {
        guard !operationInProgress else {
            throw LocalTranscriptEditingModelError.operationInProgress
        }
        operationInProgress = true
        defer { operationInProgress = false }

        try prepareSafeRoot()
        if installedBytes() != nil { return }
        try ensureCapacity()

        let stagedDirectory = root.appendingPathComponent(
            ".\(spec.id)-download-\(UUID().uuidString)",
            isDirectory: true
        )
        var downloadedURL: URL?
        defer {
            if let downloadedURL { try? fileManager.removeItem(at: downloadedURL) }
            try? fileManager.removeItem(at: stagedDirectory)
        }

        let downloaded = try await downloader.download(from: spec.downloadURL)
        downloadedURL = downloaded.fileURL
        guard downloaded.statusCode.map({ $0 == 200 }) ?? true else {
            throw LocalTranscriptEditingModelError.downloadFailed
        }
        try Task.checkCancellation()
        try verify(downloaded.fileURL)

        try fileManager.createDirectory(
            at: stagedDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let stagedModel = stagedDirectory.appendingPathComponent(spec.fileName)
        try fileManager.moveItem(at: downloaded.fileURL, to: stagedModel)
        downloadedURL = nil
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedModel.path)
        try writeManifest(to: stagedDirectory)

        let destination = modelURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: stagedDirectory, to: destination)
        guard installedBytes() != nil else {
            throw LocalTranscriptEditingModelError.incompleteInstallation
        }
    }

    public func delete() throws {
        guard !operationInProgress else {
            throw LocalTranscriptEditingModelError.operationInProgress
        }
        try prepareSafeRoot()
        let directory = modelURL.deletingLastPathComponent()
        guard isDescendant(directory, of: root) else {
            throw LocalTranscriptEditingModelError.unsafeModelsDirectory
        }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func installedBytes() -> Int64? {
        let manifestURL = modelURL.deletingLastPathComponent()
            .appendingPathComponent("installation.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(InstallationManifest.self, from: data),
              manifest == InstallationManifest(spec: spec),
              let attributes = try? fileManager.attributesOfItem(atPath: modelURL.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value == spec.expectedBytes else {
            return nil
        }
        return size.int64Value
    }

    private func prepareSafeRoot() throws {
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard root.resolvingSymlinksInPath().standardizedFileURL == root,
              isDescendant(modelURL, of: root) else {
            throw LocalTranscriptEditingModelError.unsafeModelsDirectory
        }
    }

    private func ensureCapacity() throws {
        let space = downloadSpace()
        guard let available = space.availableBytes else { return }
        guard space.hasEnoughSpace else {
            throw LocalTranscriptEditingModelError.insufficientSpace(
                required: space.requiredBytes,
                available: available
            )
        }
    }

    private func verify(_ fileURL: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == spec.expectedBytes else {
            throw LocalTranscriptEditingModelError.unexpectedFileSize
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == spec.sha256 else {
            throw LocalTranscriptEditingModelError.checksumMismatch
        }
    }

    private func writeManifest(to directory: URL) throws {
        let data = try JSONEncoder().encode(InstallationManifest(spec: spec))
        try data.write(
            to: directory.appendingPathComponent("installation.json"),
            options: [.atomic]
        )
    }

    private func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return childPath.hasPrefix(parentPath + "/")
    }

    private struct InstallationManifest: Codable, Equatable {
        let id: String
        let fileName: String
        let expectedBytes: Int64
        let sha256: String

        init(spec: LocalTranscriptEditingModelSpec) {
            id = spec.id
            fileName = spec.fileName
            expectedBytes = spec.expectedBytes
            sha256 = spec.sha256
        }
    }
}
