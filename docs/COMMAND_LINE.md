# McSpeechface Command Line

McSpeechface includes a small command-line helper for scripts and terminal workflows.
The McSpeechface app remains responsible for recording, model loading, transcription,
history, and the clipboard, so the helper does not load a second copy of a
model.

## Install

Choose **Settings** from McSpeechface's waveform menu-bar icon, open **General**, find
**Command Line**, and select **Install...**. McSpeechface links the bundled helper at
`/usr/local/bin/mcspeechface`. During an upgrade, it also removes the earlier
command link when that link can be verified as belonging to the older app.

## Examples

```sh
mcspeechface transcribe meeting.m4a
mcspeechface transcribe interview.m4a --diarize
mcspeechface transcribe notes.m4a --correct
mcspeechface transcribe notes.m4a --correction-model qwen-3-0.6b
mcspeechface transcribe notes.m4a --instructions "Format as Markdown with short paragraphs"
mcspeechface diarize interview.m4a --json
mcspeechface transcribe meeting.m4a --copy --json
mcspeechface record --correct --copy
session="$(mcspeechface record start --correction-model codex)"
mcspeechface record stop "$session" --copy
mcspeechface status --json
mcspeechface models
mcspeechface correction-models
```

Speaker identification requires its separate local model from **Settings >
Models** and a speech model that supplies timestamps. Apple Speech cannot be
used for speaker identification.

Interactive `mcspeechface record` records until Control-D, then transcribes. Control-C
cancels and discards the recording. McSpeechface also cancels if the terminal process
exits unexpectedly.

Correction is opt-in for command-line requests. `--correct` uses the correction
model currently selected in Settings. `--correction-model KEY` selects a model
for that invocation without changing Settings, and `--instructions TEXT` adds
one-off instructions; either option implies `--correct`. Run
`mcspeechface correction-models` to see stable model keys and availability. Correction
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

Run `mcspeechface help` for the complete syntax summary.

After replacing McSpeechface with a newer build, quit and reopen the app before
using its bundled helper. The app and helper intentionally reject mismatched
command-protocol versions instead of silently ignoring newer options.
