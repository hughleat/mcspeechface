# Beta testing McSpeechface

Use a normal macOS user account. Use non-sensitive test speech because
screenshots, diagnostics, or test notes may later be shared in a public issue.
Record the McSpeechface release tag, macOS version, selected model, and result for each
check.

## Fresh install

1. Download the DMG from GitHub Releases and verify its published SHA-256.
2. Drag McSpeechface to Applications and approve its first launch in Privacy & Security.
3. Complete setup, granting Microphone and Accessibility access.
4. Install one model and confirm no other model is downloaded.
5. Test tap-to-toggle, push-to-talk, Escape cancellation, clipboard copy, and automatic paste.
6. In On request mode, test Repair and Add more before and after repair. Confirm
   Add more preserves both the accumulated original and complete playback audio.
7. Enable launch at login, log out and back in, then confirm McSpeechface starts once.
8. Use About > Check for Updates and Copy Diagnostics.

## Upgrade

1. Note the current Microphone, Accessibility, and Speech Recognition states.
2. Quit McSpeechface and replace it in Applications with the next DMG build.
3. Approve the new ad-hoc build in Privacy & Security and launch it.
4. Confirm settings, vocabulary, history, and downloaded models remain available.
5. Recheck permissions, the shortcut, recording, transcription, and automatic paste.
6. Confirm About reports the installed release tag and no update when it is current.

Ad-hoc community builds are not a stable Apple code identity. macOS can require
first-launch approval or permission renewal after an update even though McSpeechface
keeps the same bundle identifier. A future Developer ID build would remove this
limitation.
