import Foundation
import Testing
@testable import TiroEditing

struct TranscriptEditValidatorTests {
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
