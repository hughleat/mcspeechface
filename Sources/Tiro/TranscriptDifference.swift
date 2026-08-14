import Foundation

struct TranscriptDifference: Equatable {
    let originalRanges: [NSRange]
    let revisedRanges: [NSRange]

    var changeCount: Int { max(originalRanges.count, revisedRanges.count) }

    init(original: String, revised: String) {
        let originalTokens = Self.tokens(in: original)
        let revisedTokens = Self.tokens(in: revised)
        let changes = revisedTokens.map(\.value).difference(from: originalTokens.map(\.value))
        originalRanges = changes.removals.compactMap { change in
            guard case let .remove(offset, _, _) = change,
                  originalTokens.indices.contains(offset) else { return nil }
            return originalTokens[offset].range
        }
        revisedRanges = changes.insertions.compactMap { change in
            guard case let .insert(offset, _, _) = change,
                  revisedTokens.indices.contains(offset) else { return nil }
            return revisedTokens[offset].range
        }
    }

    private struct Token {
        let value: String
        let range: NSRange
    }

    private static func tokens(in text: String) -> [Token] {
        let expression = try! NSRegularExpression(pattern: #"[\p{L}\p{N}']+|[^\s]"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else { return nil }
            return Token(value: String(text[tokenRange]), range: match.range)
        }
    }
}
