import AVFoundation
import Foundation

enum ReviewAudioAssembler {
    static func append(_ additionURL: URL, to recordingURL: URL) throws {
        let recording = try AVAudioFile(forReading: recordingURL)
        let addition = try AVAudioFile(forReading: additionURL)
        guard recording.processingFormat == addition.processingFormat else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let temporaryURL = recordingURL.deletingLastPathComponent()
            .appendingPathComponent(".\(recordingURL.lastPathComponent).\(UUID().uuidString).tmp.wav")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let output = try AVAudioFile(
            forWriting: temporaryURL,
            settings: recording.fileFormat.settings,
            commonFormat: recording.processingFormat.commonFormat,
            interleaved: recording.processingFormat.isInterleaved
        )
        try copy(recording, to: output)
        try copy(addition, to: output)
        _ = try FileManager.default.replaceItemAt(recordingURL, withItemAt: temporaryURL)
    }

    private static func copy(_ input: AVAudioFile, to output: AVAudioFile) throws {
        let capacity: AVAudioFrameCount = 4_096
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: input.processingFormat,
            frameCapacity: capacity
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        while input.framePosition < input.length {
            let remaining = input.length - input.framePosition
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), remaining)))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }
}
