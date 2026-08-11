# Roadmap

This document records product ideas that are worth exploring but are not yet
committed features. Tiro's core remains fast, private, local transcription.

## Local Transcript Editing

Explore an optional, locally installed language model that can interpret spoken
self-corrections and propose edits to a completed transcript.

Examples include:

- "Go back and change Tuesday to Thursday."
- "I made a mistake there; her name is Janne."
- "Delete that last sentence."
- "Actually, make that three hundred pounds."

The first version should:

- run entirely on the Mac and require an explicit model download;
- preserve the verbatim transcript alongside any proposed revision;
- present changes for review rather than silently rewriting uncertain text;
- distinguish editing instructions from words intended for the document;
- make accepting the unchanged transcript quick and predictable;
- work without changing the existing transcription engines; and
- remain optional so it does not add latency or disk use for other users.

This may require a richer recording panel that can show the original text, the
proposed result, a concise explanation of the change, and accept, reject, or
edit controls. Straightforward, high-confidence corrections could eventually
support an opt-in automatic mode after the review workflow has proved reliable.

Questions to answer during prototyping:

- Which small Core ML language models are accurate enough on Apple Silicon?
- Should commands be interpreted within one recording, in a follow-up recording,
  or both?
- How should Tiro resolve references such as "that name" or "the previous
  sentence" without retaining more context than the user expects?
- What latency, memory, and download-size limits keep ordinary dictation feeling
  immediate?
- How should proposed edits be represented in history and command-line output?
