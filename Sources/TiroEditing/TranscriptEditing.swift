import Foundation

public struct TranscriptEditRequest: Equatable, Sendable {
    public let text: String
    public let language: String?
    public let promptConfiguration: TranscriptEditingPromptConfiguration

    public init(
        text: String,
        language: String? = nil,
        promptConfiguration: TranscriptEditingPromptConfiguration = .default
    ) {
        self.text = text
        self.language = language
        self.promptConfiguration = promptConfiguration
    }
}

public struct TranscriptEditingPromptConfiguration: Codable, Equatable, Sendable {
    public static let transcriptPlaceholder = "{transcript}"
    public static let languagePlaceholder = "{language}"
    public static let languageLinePlaceholder = "{languageLine}"
    public static let maximumSystemPromptLength = 8_000
    public static let maximumUserPromptTemplateLength = 8_000
    static let localModelMaximumInputUTF8Bytes = 3_350
    static let maximumCorrectionTranscriptUTF8Bytes = 3_500
    private static let minimumLocalModelTranscriptUTF8Bytes = 700

    public static let `default` = TranscriptEditingPromptConfiguration(
        systemPrompt: """
        You will be given text from a voice transcription. The person dictating needs you to improve
        their text. Remove fillers like "um", "er", "you know", etc. Fix obvious grammar errors or
        repeats that are most likely caused by the person stumbling during their dictation. They may
        also give instructions about fixing mistakes they made. Preserve everything else. If unsure,
        don't make changes.

        The transcript to fix will be given inside <transcript> tags.
        Return the complete result in revisedText. Set explanation to a brief description of the
        changes. When nothing changes, set hasChanges to false, use an empty explanation.
        """,
        userPromptTemplate: """
        {languageLine}
        <transcript>
        {transcript}
        </transcript>
        """
    )

    public let systemPrompt: String
    public let userPromptTemplate: String
    public var isCustom: Bool { self != Self.default }

    public init(systemPrompt: String, userPromptTemplate: String) {
        self.systemPrompt = systemPrompt
        self.userPromptTemplate = userPromptTemplate
    }

    public func validate() throws {
        guard !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptEditingPromptError.emptySystemPrompt
        }
        guard systemPrompt.count <= Self.maximumSystemPromptLength else {
            throw TranscriptEditingPromptError.systemPromptTooLong
        }
        guard !systemPrompt.contains(Self.transcriptPlaceholder) else {
            throw TranscriptEditingPromptError.transcriptPlaceholderInSystemPrompt
        }
        let transcriptPlaceholderCount = userPromptTemplate.components(
            separatedBy: Self.transcriptPlaceholder
        ).count - 1
        guard transcriptPlaceholderCount > 0 else {
            throw TranscriptEditingPromptError.missingTranscriptPlaceholder
        }
        guard transcriptPlaceholderCount == 1 else {
            throw TranscriptEditingPromptError.repeatedTranscriptPlaceholder
        }
        guard userPromptTemplate.count <= Self.maximumUserPromptTemplateLength else {
            throw TranscriptEditingPromptError.userPromptTemplateTooLong
        }
    }

    public func validateForSharedModels() throws {
        try validate()
        let request = TranscriptEditRequest(
            text: String(repeating: "x", count: Self.minimumLocalModelTranscriptUTF8Bytes),
            language: String(repeating: "x", count: 64),
            promptConfiguration: self
        )
        guard TranscriptEditingPrompt.combinedUTF8ByteCount(request)
                <= TranscriptEditingPrompt.localMaximumCombinedUTF8Bytes(request) else {
            throw TranscriptEditingPromptError.insufficientLocalModelTranscriptCapacity
        }
    }

    func renderedSystemPrompt(language: String?) -> String {
        Self.render(systemPrompt, text: nil, language: language)
    }

    func renderedUserPrompt(text: String, language: String?) -> String {
        Self.render(userPromptTemplate, text: text, language: language)
    }

    private static func render(_ template: String, text: String?, language: String?) -> String {
        var rendered = template
        if let language {
            rendered = rendered.replacingOccurrences(
                of: Self.languageLinePlaceholder,
                with: "Language: \(language)"
            )
        } else {
            rendered = rendered.replacingOccurrences(
                of: Self.languageLinePlaceholder + "\n",
                with: ""
            )
            rendered = rendered.replacingOccurrences(of: Self.languageLinePlaceholder, with: "")
        }
        rendered = rendered
            .replacingOccurrences(of: Self.languagePlaceholder, with: language ?? "")
        if let text {
            rendered = rendered.replacingOccurrences(of: Self.transcriptPlaceholder, with: text)
        }
        return rendered
    }

    private enum CodingKeys: String, CodingKey {
        case systemPrompt
        case userPromptTemplate
        case promptTemplate
        case instructions
        case requestTemplate
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let systemPrompt = try values.decodeIfPresent(String.self, forKey: .systemPrompt),
           let userPromptTemplate = try values.decodeIfPresent(
               String.self,
               forKey: .userPromptTemplate
           ) {
            self.systemPrompt = systemPrompt
            self.userPromptTemplate = userPromptTemplate
            return
        }
        if let promptTemplate = try values.decodeIfPresent(String.self, forKey: .promptTemplate) {
            systemPrompt = Self.default.systemPrompt
            userPromptTemplate = promptTemplate
            return
        }
        let instructions = try values.decode(String.self, forKey: .instructions)
        let requestTemplate = try values.decode(String.self, forKey: .requestTemplate)
        systemPrompt = Self.default.systemPrompt
        userPromptTemplate = """
            \(requestTemplate)

            Additional instructions:
            \(Self.literalizedLegacyInstructions(instructions))
            """
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(systemPrompt, forKey: .systemPrompt)
        try values.encode(userPromptTemplate, forKey: .userPromptTemplate)
    }

    private static func literalizedLegacyInstructions(_ instructions: String) -> String {
        instructions
            .replacingOccurrences(of: transcriptPlaceholder, with: "{ transcript }")
            .replacingOccurrences(of: languagePlaceholder, with: "{ language }")
            .replacingOccurrences(of: languageLinePlaceholder, with: "{ languageLine }")
    }
}

public enum TranscriptEditingPromptError: LocalizedError, Equatable {
    case emptySystemPrompt
    case transcriptPlaceholderInSystemPrompt
    case missingTranscriptPlaceholder
    case repeatedTranscriptPlaceholder
    case systemPromptTooLong
    case userPromptTemplateTooLong
    case renderedPromptTooLong
    case insufficientLocalModelTranscriptCapacity

    public var errorDescription: String? {
        switch self {
        case .emptySystemPrompt: "The system prompt cannot be empty."
        case .transcriptPlaceholderInSystemPrompt:
            "Put {transcript} in the user prompt template, not the system prompt."
        case .missingTranscriptPlaceholder:
            "The transcript template must contain {transcript}."
        case .repeatedTranscriptPlaceholder:
            "The transcript template must contain {transcript} exactly once."
        case .systemPromptTooLong:
            "The system prompt must be \(TranscriptEditingPromptConfiguration.maximumSystemPromptLength) characters or fewer."
        case .userPromptTemplateTooLong:
            "The user prompt template must be \(TranscriptEditingPromptConfiguration.maximumUserPromptTemplateLength) characters or fewer."
        case .renderedPromptTooLong:
            "This transcript and prompt are too long for the selected correction model."
        case .insufficientLocalModelTranscriptCapacity:
            "Shorten the prompt so the local correction model has room for dictated text."
        }
    }
}

public struct TranscriptEditProposal: Equatable, Sendable {
    public let originalText: String
    public let revisedText: String
    public let explanation: String

    public init(
        originalText: String,
        revisedText: String,
        explanation: String
    ) {
        self.originalText = originalText
        self.revisedText = revisedText
        self.explanation = explanation
    }
}

public enum TranscriptEditDecision: Equatable, Sendable {
    case unchanged
    case proposal(TranscriptEditProposal)
}

public enum TranscriptEditorAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

public enum TranscriptEditingProgressPhase: Equatable, Sendable {
    case starting
    case working
    case receiving
}

public struct TranscriptEditingProgress: Equatable, Sendable {
    public let providerName: String
    public let phase: TranscriptEditingProgressPhase

    public init(providerName: String, phase: TranscriptEditingProgressPhase) {
        self.providerName = providerName
        self.phase = phase
    }
}

public protocol TranscriptEditor: Sendable {
    var id: String { get }
    var name: String { get }

    func availability() async -> TranscriptEditorAvailability
    func proposeEdits(for request: TranscriptEditRequest) async throws -> TranscriptEditDecision
}

enum TranscriptEditingPrompt {
    static func instructions(_ request: TranscriptEditRequest) -> String {
        request.promptConfiguration.renderedSystemPrompt(language: request.language)
    }

    static func request(_ request: TranscriptEditRequest) -> String {
        request.promptConfiguration.renderedUserPrompt(
            text: request.text,
            language: request.language
        )
    }

    static func validate(
        _ request: TranscriptEditRequest,
        maximumCombinedUTF8Bytes: Int? = nil
    ) throws {
        try request.promptConfiguration.validate()
        guard request.text.utf8.count
                <= TranscriptEditingPromptConfiguration.maximumCorrectionTranscriptUTF8Bytes else {
            throw TranscriptEditingPromptError.renderedPromptTooLong
        }
        if let maximumCombinedUTF8Bytes,
           combinedUTF8ByteCount(request) > maximumCombinedUTF8Bytes {
            throw TranscriptEditingPromptError.renderedPromptTooLong
        }
    }

    static func combinedUTF8ByteCount(_ request: TranscriptEditRequest) -> Int {
        instructions(request).utf8.count + self.request(request).utf8.count
    }

    static func maximumResponseTokens(_ request: TranscriptEditRequest) -> Int {
        min(4_096, max(700, request.text.utf8.count + 256))
    }

    static func localMaximumCombinedUTF8Bytes(_ request: TranscriptEditRequest) -> Int {
        min(
            TranscriptEditingPromptConfiguration.localModelMaximumInputUTF8Bytes,
            4_096 - maximumResponseTokens(request) - 64
        )
    }
}

public enum TranscriptEditValidationError: LocalizedError, Equatable {
    case emptyTranscript
    case explanationTooLong
    case resultTooLong
    case ungroundedRevision

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript: "The transcript is empty."
        case .explanationTooLong: "The correction explanation is too long."
        case .resultTooLong: "The proposed transcript is too long."
        case .ungroundedRevision: "The proposed transcript is not grounded in the dictation."
        }
    }
}

public enum TranscriptEditValidator {
    private static let maximumTranscriptLength = 100_000
    private static let maximumExplanationLength = 1_000

    public static func decision(
        hasChanges: Bool,
        originalText: String,
        revisedText: String,
        explanation: String,
        requiresGrounding: Bool = true
    ) throws -> TranscriptEditDecision {
        guard !originalText.isEmpty else { throw TranscriptEditValidationError.emptyTranscript }
        guard originalText.count <= maximumTranscriptLength,
              revisedText.count <= maximumTranscriptLength else {
            throw TranscriptEditValidationError.resultTooLong
        }
        guard !hasChanges || explanation.count <= maximumExplanationLength else {
            throw TranscriptEditValidationError.explanationTooLong
        }
        guard hasChanges, revisedText != originalText else { return .unchanged }
        if requiresGrounding {
            try validateFullTextRevision(originalText: originalText, revisedText: revisedText)
        }
        return .proposal(TranscriptEditProposal(
            originalText: originalText,
            revisedText: revisedText,
            explanation: explanation
        ))
    }

    public static func validateFullTextRevision(
        originalText: String,
        revisedText: String
    ) throws {
        guard revisedText.count <= originalText.count + max(64, originalText.count / 4) else {
            throw TranscriptEditValidationError.ungroundedRevision
        }
        let revisedTokens = groundingTokens(revisedText)
        let protectedSource = protectedSourceTokenCandidates(from: originalText)
        let protectedCandidates = protectedSource.candidates
            .map(contentTokens)
        guard !revisedTokens.isEmpty else {
            guard protectedCandidates.contains(where: \.isEmpty) else {
                throw TranscriptEditValidationError.ungroundedRevision
            }
            return
        }
        guard protectedCandidates.contains(contentTokens(revisedTokens)) else {
            throw TranscriptEditValidationError.ungroundedRevision
        }
    }

    private static func groundingTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""

        func appendWord() {
            guard !word.isEmpty else { return }
            tokens.append(word)
            word = ""
        }

        for character in text.lowercased() {
            let scalars = character.unicodeScalars
            guard scalars.allSatisfy(CharacterSet.alphanumerics.contains) else {
                appendWord()
                continue
            }
            if scalars.contains(where: isUnsegmentedScript) {
                appendWord()
                tokens.append(String(character))
            } else {
                word.append(character)
            }
        }
        appendWord()
        return tokens
    }

    private static let nonsemanticFillers: Set<String> = ["um", "uh", "erm", "ah", "mm", "hmm"]

    private static func contentTokens(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var index = tokens.startIndex
        while index < tokens.endIndex {
            if nonsemanticFillers.contains(tokens[index]) {
                index += 1
            } else {
                result.append(tokens[index])
                index += 1
            }
        }
        return result
    }

    private static func protectedSourceTokenCandidates(from text: String) -> ProtectedSource {
        let normalized = text.lowercased()
        let fillerRequests = [
            "please remove the ums and ahs",
            "remove the ums and ahs",
            "please remove the uhs and ahs",
            "remove the uhs and ahs",
        ]
        for request in fillerRequests {
            if let range = normalized.range(of: request, options: .backwards),
               normalized[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                .isEmpty {
                return ProtectedSource(
                    candidates: [sourceTokens(String(text[..<range.lowerBound]))]
                )
            }
        }

        let sentenceSeparators = CharacterSet(charactersIn: ".!?\n")
        let trailingCharacters = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var commandEnd = normalized.endIndex
        while commandEnd > normalized.startIndex {
            let preceding = normalized.index(before: commandEnd)
            guard normalized[preceding].unicodeScalars.allSatisfy(trailingCharacters.contains) else {
                break
            }
            commandEnd = preceding
        }
        if let boundary = normalized.rangeOfCharacter(
            from: sentenceSeparators,
            options: .backwards,
            range: normalized.startIndex..<commandEnd
        ) {
            let suffix = normalized[boundary.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let correction = trailingCorrection(in: suffix) {
                let precedingText = String(text[..<boundary.upperBound])
                switch correction {
                case .instruction(let command):
                    let precedingTokens = sourceTokens(precedingText)
                    return ProtectedSource(
                        candidates: [precedingTokens] + instructionCandidates(
                            precedingTokens: precedingTokens,
                            command: command
                        )
                    )
                case .replacement(let replacement):
                    let replacementTokens = groundingTokens(replacement)
                    guard replacementTokens.count >= 3 else {
                        return ProtectedSource(
                            candidates: [sourceTokens(precedingText)]
                        )
                    }
                    let earlierText = text[..<boundary.lowerBound]
                    let stablePrefix: Substring
                    if let earlierBoundary = earlierText.rangeOfCharacter(
                        from: sentenceSeparators,
                        options: .backwards
                    ) {
                        stablePrefix = text[..<earlierBoundary.upperBound]
                    } else {
                        stablePrefix = text[..<text.startIndex]
                    }
                    return ProtectedSource(
                        candidates: [
                            sourceTokens(precedingText),
                            sourceTokens(String(stablePrefix) + " " + replacement),
                        ]
                    )
                }
            }
        }

        if let marker = trailingDiscourseMarker(in: text),
           !contentTokens(groundingTokens(String(text[marker.upperBound...]))).isEmpty {
            let beforeMarker = text[..<marker.lowerBound]
            guard isPlausibleInlineCorrection(
                marker: String(text[marker]),
                before: String(beforeMarker),
                replacement: String(text[marker.upperBound...])
            ) else {
                return ProtectedSource(candidates: [sourceTokens(text)])
            }
            let stablePrefix: Substring
            if let boundary = beforeMarker.rangeOfCharacter(
                from: CharacterSet(charactersIn: ".!?\n"),
                options: .backwards
            ) {
                stablePrefix = beforeMarker[..<boundary.upperBound]
            } else {
                stablePrefix = beforeMarker[..<beforeMarker.startIndex]
            }
            let correctedCandidate = String(stablePrefix) + " " + String(text[marker.upperBound...])
            return ProtectedSource(
                candidates: [
                    sourceTokens(String(beforeMarker)),
                    sourceTokens(correctedCandidate),
                ]
            )
        }
        return ProtectedSource(candidates: [sourceTokens(text)])
    }

    private static func sourceTokens(_ text: String) -> [String] {
        var tokens = groundingTokens(text)
        let leadingText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if (leadingText.hasPrefix("you know,") || leadingText.hasPrefix("you know ,")),
           tokens.starts(with: ["you", "know"]) {
            tokens.removeFirst(2)
        }
        return tokens
    }

    private static func isPlausibleInlineCorrection(
        marker: String,
        before: String,
        replacement: String
    ) -> Bool {
        let normalizedMarker = marker.lowercased()
        guard normalizedMarker.contains("sorry") else { return true }
        let replacementTokens = contentTokens(groundingTokens(replacement))
        guard replacementTokens.count >= 2 else {
            return false
        }
        let finalClause = before.split(whereSeparator: { ".!?\n".contains($0) }).last ?? ""
        return containsSubsequence(
            Array(replacementTokens.prefix(2)),
            in: contentTokens(groundingTokens(String(finalClause)))
        )
    }

    private static func containsSubsequence(_ sought: [String], in source: [String]) -> Bool {
        guard !sought.isEmpty, sought.count <= source.count else { return false }
        return source.indices.contains { start in
            let end = source.index(start, offsetBy: sought.count, limitedBy: source.endIndex)
            return end.map { Array(source[start..<$0]) == sought } ?? false
        }
    }

    private static func instructionCandidates(
        precedingTokens: [String],
        command: String
    ) -> [[String]] {
        if command.hasPrefix("i mean ") {
            let replacement = contentTokens(groundingTokens(String(command.dropFirst(7))))
            guard !precedingTokens.isEmpty, !replacement.isEmpty else { return [] }
            return precedingTokens.indices.map { index in
                Array(precedingTokens[..<index])
                    + replacement
                    + Array(precedingTokens[precedingTokens.index(after: index)...])
            }
        }

        let normalized = command
            .replacingOccurrences(of: "go back and ", with: "")
            .replacingOccurrences(of: "please ", with: "")
        for (verb, separator) in [("change ", " to "), ("replace ", " with ")] {
            guard normalized.hasPrefix(verb),
                  let separatorRange = normalized.range(of: separator) else { continue }
            let source = contentTokens(groundingTokens(String(
                normalized[normalized.index(normalized.startIndex, offsetBy: verb.count)..<separatorRange.lowerBound]
            )))
            let replacement = contentTokens(groundingTokens(String(normalized[separatorRange.upperBound...])))
            if let candidate = replacing(source, with: replacement, in: precedingTokens) {
                return [candidate]
            }
        }
        for verb in ["remove ", "delete "] where normalized.hasPrefix(verb) {
            let source = contentTokens(groundingTokens(String(normalized.dropFirst(verb.count))))
            if let candidate = replacing(source, with: [], in: precedingTokens) {
                return [candidate]
            }
        }
        return []
    }

    private static func replacing(
        _ source: [String],
        with replacement: [String],
        in tokens: [String]
    ) -> [String]? {
        guard !source.isEmpty, source.count <= tokens.count else { return nil }
        for start in tokens.indices {
            guard let end = tokens.index(start, offsetBy: source.count, limitedBy: tokens.endIndex),
                  Array(tokens[start..<end]) == source else { continue }
            return Array(tokens[..<start]) + replacement + Array(tokens[end...])
        }
        return nil
    }

    private static func trailingDiscourseMarker(in text: String) -> Range<String.Index>? {
        let pattern = #",\s*(?:no|sorry|i mean)\b[,\s]*"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.matches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ).last else {
            return nil
        }
        return Range(match.range, in: text)
    }

    private static func trailingCorrection(in suffix: String) -> TrailingCorrection? {
        var command = suffix.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters)
        )
        var hasNoLead = false
        while let lead = ["no,", "no ", "sorry,", "sorry "]
            .first(where: command.hasPrefix) {
            command = command.dropFirst(lead.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            hasNoLead = hasNoLead || lead.hasPrefix("no")
        }
        if command.hasPrefix("i mean ") {
            return .instruction(command)
        }
        let withoutPlease = command.hasPrefix("please ")
            ? String(command.dropFirst("please ".count))
            : command
        if isEditInstruction(withoutPlease) {
            return .instruction(withoutPlease)
        }
        guard hasNoLead, !command.isEmpty else { return nil }
        return .replacement(command)
    }

    private static func isEditInstruction(_ command: String) -> Bool {
        let goesBackToEdit = command.hasPrefix("go back and change ")
            || command.hasPrefix("go back and replace ")
            || command.hasPrefix("go back and remove ")
            || command.hasPrefix("go back and delete ")
        return (command.hasPrefix("change ") && command.contains(" to "))
            || (command.hasPrefix("replace ") && command.contains(" with "))
            || goesBackToEdit
            || command == "scratch that"
            || command == "delete that"
            || command == "remove that"
    }

    private enum TrailingCorrection {
        case instruction(String)
        case replacement(String)
    }

    private struct ProtectedSource {
        let candidates: [[String]]
    }

    private static func isUnsegmentedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, // Japanese kana
             0x3400...0x9FFF, // CJK ideographs
             0xAC00...0xD7AF, // Hangul syllables
             0x20000...0x3134F: // CJK extensions
            true
        default:
            false
        }
    }
}
