# McSpeechface Command Line

McSpeechface includes a small command-line helper for scripts and terminal workflows.
The McSpeechface app remains responsible for recording, model loading, transcription,
history, and the clipboard, so the helper does not load a second copy of a
model.

## Install

Choose **Settings** from McSpeechface's waveform menu-bar icon, open **General**, find
**Command Line**, and select **Install...**. McSpeechface links the bundled helper at
`/usr/local/bin/tiro`.

The command remains `tiro` for compatibility with existing scripts.

## Examples

```sh
tiro transcribe meeting.m4a
tiro transcribe interview.m4a --diarize
tiro transcribe notes.m4a --correct
tiro transcribe notes.m4a --correction-model qwen-3-0.6b
tiro transcribe notes.m4a --instructions "Format as Markdown with short paragraphs"
tiro diarize interview.m4a --json
tiro transcribe meeting.m4a --copy --json
tiro record --correct --copy
session="$(tiro record start --correction-model codex)"
tiro record stop "$session" --copy
tiro status --json
tiro models
tiro correction-models
```

Speaker identification requires its separate local model from **Settings >
Models** and a speech model that supplies timestamps. Apple Speech cannot be
used for speaker identification.

Interactive `tiro record` records until Control-D, then transcribes. Control-C
cancels and discards the recording. McSpeechface also cancels if the terminal process
exits unexpectedly.

Correction is opt-in for command-line requests. `--correct` uses the correction
model currently selected in Settings. `--correction-model KEY` selects a model
for that invocation without changing Settings, and `--instructions TEXT` adds
one-off instructions; either option implies `--correct`. Run
`tiro correction-models` to see stable model keys and availability. Correction
failures return a nonzero exit status instead of silently returning raw text.
Use `--instructions=TEXT` when the instruction itself begins with `--`.
Local models and Apple Intelligence keep correction on the Mac. Codex, Claude,
and custom-command providers may send the transcript and prompts to their
configured service; selecting one explicitly opts that command into the
provider's own terms and privacy policy.

Use `--no-history` on `transcribe`, `diarize`, `record`, or `record start` for
one-off work. Plain output contains only the transcript. JSON transcription
output also contains timestamped segments and, when speaker identification is
enabled, speaker IDs. Corrected JSON includes `original_text` and a structured
`correction` object with the model, elapsed time, change status, explanation,
and review recommendation. Timestamped segments are omitted when correction
changes the text because their offsets no longer align. Diagnostics use
standard error output.

Run `tiro help` for the complete syntax summary.

After replacing McSpeechface with a newer build, quit and reopen the app before
using its bundled helper. The app and helper intentionally reject mismatched
command-protocol versions instead of silently ignoring newer options.
