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

The implemented foundation can:

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

This may require a richer recording panel that can show the original text, the
proposed result, a concise explanation of the change, and accept, reject, or
edit controls. Straightforward, high-confidence corrections could eventually
support an opt-in automatic mode after the review workflow has proved reliable.

The implementation should define a small transcript-editor protocol shared by
all providers. The first providers to prototype are:

- Apple's on-device Foundation Models framework, where available; and
- a bundled native llama.cpp runtime for selected quantized GGUF models fetched
  from pinned Hugging Face revisions.

McSpeechface should invoke the selected provider in-process, without requiring Python,
MLX, Ollama, a local server, or an account. Third-party downloads should use the
same staged installation, validation, disk-space checks, cancellation, and safe
removal behaviour as speech models. Compatible models should be addable through
verified catalogue metadata rather than provider-specific application code, so
the library can grow without increasing architectural complexity. Catalogue
entries must pin the source revision and describe the model's licence, prompt
format, tokenizer, output quality, and memory requirements. Importing compatible
local GGUF files or adding a model from a URL can be considered once McSpeechface can
validate those properties safely.

Questions to answer during prototyping:

- Which small external language models are accurate enough on Apple Silicon?
- What common provider contract supports Apple Foundation Models, GGUF models,
  and possible future Core ML language models without exposing runtime details
  to the transcription pipeline?
- Should commands be interpreted within one recording, in a follow-up recording,
  or both?
- How should McSpeechface resolve references such as "that name" or "the previous
  sentence" without retaining more context than the user expects?
- What latency, memory, and download-size limits keep ordinary dictation feeling
  immediate?
