import Foundation
import Testing
@testable import TiroEditing

struct TranscriptEditValidatorTests {
    @Test
    func defaultPromptRendersLanguageAndTranscript() {
        let request = TranscriptEditRequest(
            text: "Send it Monday.",
            language: "English"
        )

        let rendered = TranscriptEditingPrompt.request(request)

        #expect(rendered.contains("Language: English\n"))
        #expect(rendered.contains("<transcript>\nSend it Monday.\n</transcript>"))
    }

    @Test
    func customPromptRendersPlaceholdersWithoutRewritingTranscriptContent() throws {
        let configuration = TranscriptEditingPromptConfiguration(
            instructions: "Find corrections only.",
            requestTemplate: "{language}[{transcript}]"
        )
        try configuration.validate()
        let request = TranscriptEditRequest(
            text: "Keep this literal token: {language}",
            language: "English",
            promptConfiguration: configuration
        )

        #expect(
            TranscriptEditingPrompt.request(request)
                == "English[Keep this literal token: {language}]"
        )
        #expect(TranscriptEditingPrompt.instructions(request).contains("Find corrections only."))
        #expect(TranscriptEditingPrompt.instructions(request).contains("untrusted data"))
    }

    @Test
    func languageLineDisappearsCleanlyWhenLanguageIsUnknown() {
        let request = TranscriptEditRequest(text: "Send it Monday.")

        let rendered = TranscriptEditingPrompt.request(request)

        #expect(!rendered.contains("Language:"))
        #expect(rendered.hasPrefix("Find only explicit self-corrections"))
    }

    @Test
    func customPromptRequiresInstructionsAndTranscriptPlaceholder() {
        #expect(throws: TranscriptEditingPromptError.emptyInstructions) {
            try TranscriptEditingPromptConfiguration(
                instructions: "  ",
                requestTemplate: "{transcript}"
            ).validate()
        }
        #expect(throws: TranscriptEditingPromptError.missingTranscriptPlaceholder) {
            try TranscriptEditingPromptConfiguration(
                instructions: "Find corrections.",
                requestTemplate: "No transcript placeholder"
            ).validate()
        }
        #expect(throws: TranscriptEditingPromptError.repeatedTranscriptPlaceholder) {
            try TranscriptEditingPromptConfiguration(
                instructions: "Find corrections.",
                requestTemplate: "{transcript}\n{transcript}"
            ).validate()
        }
    }

    @Test
    func rejectsCombinedPromptBeyondModelBudget() {
        let request = TranscriptEditRequest(text: String(repeating: "word ", count: 100))

        #expect(throws: TranscriptEditingPromptError.renderedPromptTooLong) {
            try TranscriptEditingPrompt.validate(request, maximumCombinedUTF8Bytes: 100)
        }
    }

    @Test
    func promptBudgetCountsUTF8BytesRatherThanCharacters() {
        let request = TranscriptEditRequest(text: "🙂")
        let combinedBytes = TranscriptEditingPrompt.instructions(request).utf8.count
            + TranscriptEditingPrompt.request(request).utf8.count

        #expect(throws: TranscriptEditingPromptError.renderedPromptTooLong) {
            try TranscriptEditingPrompt.validate(
                request,
                maximumCombinedUTF8Bytes: combinedBytes - 1
            )
        }
    }

    @Test
    func sharedPromptMustLeaveRoomForTranscript() {
        let configuration = TranscriptEditingPromptConfiguration(
            instructions: String(repeating: "x", count: 2_000),
            requestTemplate: "{transcript}"
        )

        #expect(throws: TranscriptEditingPromptError.insufficientLocalModelTranscriptCapacity) {
            try configuration.validateForSharedModels()
        }
    }

    @Test
    func appliesExplicitReplacementAndCommandRemoval() throws {
        let original = "We will meet Tuesday. No, change Tuesday to Thursday."
        let proposal = try TranscriptEditValidator.proposal(
            for: original,
            edits: [
                TranscriptEditOperation(
                    exactText: "Tuesday",
                    replacement: "Thursday",
                    occurrence: 1
                ),
                TranscriptEditOperation(
                    exactText: " No, change Tuesday to Thursday.",
                    replacement: ""
                ),
            ],
            explanation: "Changed the explicitly corrected day."
        )

        #expect(proposal.revisedText == "We will meet Thursday.")
    }

    @Test
    func requiresOccurrenceForRepeatedSourceText() {
        #expect(throws: TranscriptEditValidationError.ambiguousSource("Tuesday")) {
            try TranscriptEditValidator.proposal(
                for: "Tuesday follows Tuesday.",
                edits: [TranscriptEditOperation(exactText: "Tuesday", replacement: "Thursday")],
                explanation: ""
            )
        }
    }

    @Test
    func selectsRequestedOccurrence() throws {
        let proposal = try TranscriptEditValidator.proposal(
            for: "Tuesday follows Tuesday.",
            edits: [TranscriptEditOperation(
                exactText: "Tuesday",
                replacement: "Thursday",
                occurrence: 2
            )],
            explanation: "Changed the second occurrence."
        )

        #expect(proposal.revisedText == "Tuesday follows Thursday.")
    }

    @Test
    func rejectsMissingAndOverlappingSourceText() {
        #expect(throws: TranscriptEditValidationError.missingSource("Friday")) {
            try TranscriptEditValidator.proposal(
                for: "Meet Tuesday.",
                edits: [TranscriptEditOperation(exactText: "Friday", replacement: "Thursday")],
                explanation: ""
            )
        }
        #expect(throws: TranscriptEditValidationError.overlappingEdits) {
            try TranscriptEditValidator.proposal(
                for: "Meet Tuesday afternoon.",
                edits: [
                    TranscriptEditOperation(exactText: "Tuesday", replacement: "Thursday"),
                    TranscriptEditOperation(
                        exactText: "Tuesday afternoon",
                        replacement: "Thursday morning"
                    ),
                ],
                explanation: ""
            )
        }
    }

    @Test
    func supportsUnicodeExactText() throws {
        let proposal = try TranscriptEditValidator.proposal(
            for: "Send it to José. Sorry, send it to Janne.",
            edits: [
                TranscriptEditOperation(exactText: "José", replacement: "Janne"),
                TranscriptEditOperation(
                    exactText: " Sorry, send it to Janne.",
                    replacement: ""
                ),
            ],
            explanation: "Changed the recipient."
        )

        #expect(proposal.revisedText == "Send it to Janne.")
    }
}
