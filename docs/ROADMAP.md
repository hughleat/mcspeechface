# Roadmap

This document records product ideas that are worth exploring but are not yet
committed features. McSpeechface's core remains fast, private, local transcription.

## Transcript Editing

McSpeechface now supports optional transcript correction through Apple Intelligence,
downloadable local models, and configurable Codex, Claude, or custom command-line
providers. Remaining work should improve evaluation, speed, and review ergonomics
without weakening the existing privacy boundaries.

Examples include:

- "Go back and change Tuesday to Thursday."
- "I made a mistake there; her name is Janne."
- "Delete that last sentence."
- "Actually, make that three hundred pounds."

The current implementation can:

- run entirely on the Mac with Apple Intelligence or a local model;
- treat Apple Foundation Models as one provider, not as a dependency of the
  transcript-editing pipeline;
- offer a growing catalogue of downloadable third-party models with source,
  licence, language, size, and hardware information;
- download only the model the person explicitly selects and support removing it;
- preserve the verbatim transcript alongside any proposed revision;
- present changes for review rather than silently rewriting uncertain text;
- distinguish editing instructions from words intended for the document;
- make accepting the unchanged transcript quick and predictable;
- work without changing the existing transcription engines; and
- remain optional so it does not add latency or disk use for other users.

The next work is to evaluate and refine that foundation:

- benchmark correction quality and first-result latency across supported Macs;
- expand the pinned local model catalogue without making first-run setup noisy;
- make model memory, speed, language, and privacy tradeoffs easier to compare;
- improve instruction-following for paragraphs, Markdown, and spoken revisions;
- make review changes and explanations easier to inspect at a glance;
- validate imported local GGUF files without trusting filenames or mutable URLs;
- explore bounded context from earlier dictations only when the user explicitly
  chooses it; and
- keep correction completely out of the fast path when it is off or on request.

Questions still to answer:

- Which small external language models are accurate enough on Apple Silicon?
- Should commands be interpreted within one recording, in a follow-up recording,
  or both?
- How should McSpeechface resolve references such as "that name" or "the previous
  sentence" without retaining more context than the user expects?
- What latency, memory, and download-size limits keep ordinary dictation feeling
  immediate?
