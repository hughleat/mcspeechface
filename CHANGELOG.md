# Changelog

Notable changes to McSpeechface are recorded here. McSpeechface is currently in public beta,
so releases may also refine existing behaviour and compatibility.

## 0.1.0-beta.9 - 2026-08-30

### Changed

- Completed the product-wide McSpeechface identity, including the app bundle,
  command-line tool, data paths, release artifacts, and repository. Existing
  beta data and downloaded models migrate in place on first launch.
- Reworked transcript correction into Off, On request, and Automatic modes with
  a dark, editable review panel and explicit transcript/repair states.
- Kept Codex and Claude correction processes warm between requests, with
  configurable models, access, reasoning, and idle timeouts.

### Added

- Added first-class local, Apple Intelligence, Codex, Claude, and custom
  command correction providers with editable system and user prompt templates.
- Added an **Add more** review action that extends the transcript, original
  recording, playback, and accepted history without implicitly enabling repair.
- Added Parakeet Unified English and a broader local Whisper catalog.
- Added opt-in transcript correction to the `mcspeechface` command-line helper, with
  per-command model selection and one-off instructions.
- Added `mcspeechface correction-models` for discovering available correction providers
  and stable scripting keys.

### Fixed

- Allowed a new recording to begin as soon as the previous paste is dispatched.
- Hardened correction cancellation, process cleanup, and stale-task handling.
- Fixed raw transcript contrast, review layout, action visibility, and model
  selection stability.

## 0.1.0-beta.8 - 2026-08-11

### Added

- Added spoken transcript correction with a local Qwen editing model.
- Added automatic update checks through GitHub Releases.

### Fixed

- Preserved macOS 14 compatibility while using newer release tooling.

## 0.1.0-beta.7 - 2026-08-01

### Fixed

- Prevented unavailable or temporarily busy model rows from briefly appearing
  selected before McSpeechface restored the active model.

## 0.1.0-beta.6 - 2026-08-01

### Added

- Parakeet Unified English 0.6B as an optional local Core ML model. McSpeechface uses
  its offline INT8 encoder for batch transcription with built-in punctuation
  and capitalization.

## 0.1.0-beta.5 - 2026-07-23

### Fixed

- Removed trailing `[BLANK_AUDIO]` markers from Whisper transcripts.
- Coordinated recording with model downloads and deletion.
- Kept the Models comparison view responsive while model state changes.

## 0.1.0-beta.4 - 2026-07-22

### Added

- Expanded local Core ML model management and comparison.
- Audio-file transcription, speaker identification, and subtitle export.
- Optional transcription history, vocabulary, snippets, and command-line tools.
