# Changelog

Notable changes to Tiro are recorded here. Tiro is currently in public beta,
so releases may also refine existing behaviour and compatibility.

## Unreleased

### Added

- Added opt-in transcript correction to the `tiro` command-line helper, with
  per-command model selection and one-off instructions.
- Added `tiro correction-models` for discovering available correction providers
  and stable scripting keys.

## 0.1.0-beta.7 - 2026-08-01

### Fixed

- Prevented unavailable or temporarily busy model rows from briefly appearing
  selected before Tiro restored the active model.

## 0.1.0-beta.6 - 2026-08-01

### Added

- Parakeet Unified English 0.6B as an optional local Core ML model. Tiro uses
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
