import Foundation

public enum TranscriptCorrectionOutputSchema {
    public static let json = """
        {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "hasChanges": { "type": "boolean" },
            "explanation": { "type": "string" },
            "revisedText": { "type": "string" }
          },
          "required": ["hasChanges", "explanation", "revisedText"]
        }
        """

    public static let data = Data(json.utf8)
}

public enum CommandLineCorrectionArgumentPlaceholder {
    public static let schemaFile = "{schemaFile}"
    public static let schemaJSON = "{schemaJSON}"
    public static let outputFile = "{outputFile}"
}
