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
        #expect(instructions.contains("complete corrected transcript in revisedText"))
        #expect(!instructions.contains("exactText"))
        #expect(instructions.contains("not a list of edits"))
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
    func rejectsTranscriptThatCannotFitInACompleteResponse() {
        let request = TranscriptEditRequest(
            text: String(
                repeating: "x",
                count: TranscriptEditingPromptConfiguration.maximumCorrectionTranscriptUTF8Bytes + 1
            )
        )

        #expect(throws: TranscriptEditingPromptError.renderedPromptTooLong) {
            try TranscriptEditingPrompt.validate(request)
        }
    }

    @Test
    func responseBudgetScalesWithTheTranscript() {
        #expect(TranscriptEditingPrompt.maximumResponseTokens(.init(text: "Short")) == 700)
        #expect(
            TranscriptEditingPrompt.maximumResponseTokens(.init(text: String(repeating: "x", count: 1_000)))
                == 1_256
        )
        let request = TranscriptEditRequest(text: String(repeating: "x", count: 1_000))
        #expect(
            TranscriptEditingPrompt.localMaximumCombinedUTF8Bytes(request)
                + TranscriptEditingPrompt.maximumResponseTokens(request) + 64
                == 4_096
        )
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
                originalText: "Send Alice. No, change Alice to Janne.",
                revisedText: "Send Bob."
            )
        }
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try TranscriptEditValidator.validateFullTextRevision(
                originalText: "I made a mistake, sorry, I need more time.",
                revisedText: "I need more time."
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
            originalText: "我明天去北京，",
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
                originalText: "Do not send the report.",
                revisedText: "Do now send the report."
            )
        }
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try TranscriptEditValidator.validateFullTextRevision(
                originalText: "You know the answer.",
                revisedText: "The answer."
            )
        }
        #expect(throws: TranscriptEditValidationError.ungroundedRevision) {
            try TranscriptEditValidator.validateFullTextRevision(
                originalText: "Do not send the report. Sorry about the delay and confusion.",
                revisedText: "About the delay and confusion."
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
    func fullTextGroundingAllowsFillerAndRequestedDeletion() {
        let cases = [
            ("fillers", "Um, uh, send it tomorrow, ah.", "Send it tomorrow."),
            ("filler request", "Send it tomorrow. Please remove the ums and ahs.", "Send it tomorrow."),
            ("explicit change", "We meet Tuesday. No, change Tuesday to Thursday.", "We meet Thursday."),
            ("inline restart", "Send the report to Alice in London, sorry, send the invoice to Bob in Paris.", "Send the invoice to Bob in Paris."),
            ("stable prefix", "Keep this sentence. Send the invoice to Alice, sorry, send the invoice to Bob.", "Keep this sentence. Send the invoice to Bob."),
            ("empty filler phrase", "You know, send it tomorrow.", "Send it tomorrow."),
            ("corrected name", "Call Yana tomorrow. Sorry, I mean Janne.", "Call Janne tomorrow."),
            ("sentence restart", "Draft the email to Sara in Berlin. No, sorry, send the invoice to Bob in Paris instead.", "Send the invoice to Bob in Paris instead."),
            ("restart with stable prefix", "Keep this sentence. Draft the email to Sara. No, sorry, send the invoice to Bob.", "Keep this sentence. Send the invoice to Bob."),
        ]

        for (name, original, revised) in cases {
            do {
                try TranscriptEditValidator.validateFullTextRevision(
                    originalText: original,
                    revisedText: revised
                )
            } catch {
                Issue.record("Expected \(name) to be accepted, got \(error)")
            }
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
    func sharedDecisionBuildsAFullTextProposal() throws {
        let original = "We will meet Tuesday. No, change Tuesday to Thursday."
        let decision = try TranscriptEditValidator.decision(
            hasChanges: true,
            originalText: original,
            revisedText: "We will meet Thursday.",
            explanation: "Changed the requested day."
        )

        guard case .proposal(let proposal) = decision else {
            Issue.record("Expected a full-text proposal")
            return
        }
        #expect(proposal.originalText == original)
        #expect(proposal.revisedText == "We will meet Thursday.")
        #expect(proposal.explanation == "Changed the requested day.")
    }

    @Test
    func sharedDecisionTreatsUnchangedResponsesAsUnchanged() throws {
        #expect(try TranscriptEditValidator.decision(
            hasChanges: false,
            originalText: "Meet Tuesday.",
            revisedText: "Unexpected replacement.",
            explanation: ""
        ) == .unchanged)
        #expect(try TranscriptEditValidator.decision(
            hasChanges: true,
            originalText: "Meet Tuesday.",
            revisedText: "Meet Tuesday.",
            explanation: "Claimed a change."
        ) == .unchanged)
    }

    @Test
    func sharedDecisionRejectsInvalidBounds() {
        #expect(throws: TranscriptEditValidationError.emptyTranscript) {
            try TranscriptEditValidator.decision(
                hasChanges: true,
                originalText: "",
                revisedText: "Text",
                explanation: ""
            )
        }
        #expect(throws: TranscriptEditValidationError.explanationTooLong) {
            try TranscriptEditValidator.decision(
                hasChanges: true,
                originalText: "Meet Tuesday.",
                revisedText: "Meet Thursday.",
                explanation: String(repeating: "x", count: 1_001)
            )
        }
    }
}
