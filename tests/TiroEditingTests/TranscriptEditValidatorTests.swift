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
        let instructions = TranscriptEditingPrompt.instructions(request)
        #expect(instructions.contains("isolated \"um\", \"uh\", \"erm\", and \"ah\""))
        #expect(instructions.contains("remove the ums and ahs"))
        #expect(instructions.contains("commands that clearly ask to edit"))
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
        #expect(rendered.hasPrefix("Find spoken corrections"))
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
    func defaultFullTextPromptLeavesRoomForLocalDictation() throws {
        try TranscriptEditingPromptConfiguration.default.validateForSharedModels()
    }

    @Test
    func fullTextRevisionMustRemainGroundedInTheDictation() throws {
        try TranscriptEditValidator.validateFullTextRevision(
            originalText: "Um, send the report, ah, tomorrow. Please remove the ums and ahs.",
            revisedText: "Send the report tomorrow."
        )
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try TranscriptEditValidator.validateFullTextRevision(
                originalText: "Send the report tomorrow.",
                revisedText: "Here is an unrelated answer about something else entirely."
            )
        }
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try TranscriptEditValidator.validateFullTextRevision(
                originalText: "Please send the report to Janne tomorrow morning.",
                revisedText: "Please send the novel to Alice after lunch."
            )
        }
    }

    @Test
    func fullTextGroundingSupportsLanguagesWithoutSpaces() throws {
        try TranscriptEditValidator.validateFullTextRevision(
            originalText: "我明天去北经。",
            revisedText: "我明天去北京。"
        )
    }

    @Test
    func fullTextGroundingRejectsMeaningChangingDeletion() {
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try TranscriptEditValidator.validateFullTextRevision(
                originalText: "Please do not send the confidential report.",
                revisedText: "Please send the report."
            )
        }
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try TranscriptEditValidator.validateFullTextRevision(
                originalText: "This entire sentence should remain intact.",
                revisedText: "sentence"
            )
        }
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try TranscriptEditValidator.validateFullTextRevision(
                originalText: "Do not send the confidential report. Change Tuesday to Thursday.",
                revisedText: "Thursday"
            )
        }
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try TranscriptEditValidator.validateFullTextRevision(
                originalText: "Climate change leads to flooding.",
                revisedText: "Climate"
            )
        }
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try TranscriptEditValidator.validateFullTextRevision(
                originalText: "We met at noon. Go back home after the meeting.",
                revisedText: "We met at noon."
            )
        }
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try TranscriptEditValidator.validateFullTextRevision(
                originalText: "There was rain, nothing unusual happened.",
                revisedText: "There was rain."
            )
        }
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try TranscriptEditValidator.validateFullTextRevision(
                originalText: "Do not send the confidential report. Send the invoice to Alice, sorry, send the invoice to Bob.",
                revisedText: "Send the invoice to Bob."
            )
        }
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try TranscriptEditValidator.validateFullTextRevision(
                originalText: "Do not send the confidential report, sorry.",
                revisedText: "Do"
            )
        }
    }

    @Test
    func fullTextGroundingAllowsFillerAndRequestedDeletion() throws {
        try TranscriptEditValidator.validateFullTextRevision(
            originalText: "Um, uh, send it tomorrow, ah.",
            revisedText: "Send it tomorrow."
        )
        try TranscriptEditValidator.validateFullTextRevision(
            originalText: "Send it tomorrow. Please remove the ums and ahs.",
            revisedText: "Send it tomorrow."
        )
        try TranscriptEditValidator.validateFullTextRevision(
            originalText: "We meet Tuesday. No, change Tuesday to Thursday.",
            revisedText: "We meet Thursday."
        )
        try TranscriptEditValidator.validateFullTextRevision(
            originalText: "Send the report to Alice in London, sorry, send the invoice to Bob in Paris.",
            revisedText: "Send the invoice to Bob in Paris."
        )
        try TranscriptEditValidator.validateFullTextRevision(
            originalText: "Keep this sentence. Send the invoice to Alice, sorry, send the invoice to Bob.",
            revisedText: "Keep this sentence. Send the invoice to Bob."
        )
        try TranscriptEditValidator.validateFullTextRevision(
            originalText: "You know, send it tomorrow.",
            revisedText: "Send it tomorrow."
        )
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
    func ignoresSuperfluousOccurrenceWhenSourceIsUnambiguous() throws {
        let proposal = try TranscriptEditValidator.proposal(
            for: "Please remove the ums and ahs.",
            edits: [TranscriptEditOperation(
                exactText: "Please remove the ums and ahs.",
                replacement: "",
                occurrence: 2
            )],
            explanation: "Removed the spoken editing request."
        )

        #expect(proposal.revisedText.isEmpty)
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
