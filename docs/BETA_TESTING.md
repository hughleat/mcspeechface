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

## One-time identity upgrade

1. Note the current Microphone, Accessibility, and Speech Recognition states.
2. Quit the earlier app, install McSpeechface alongside it, approve the new
   ad-hoc build in Privacy & Security, and launch McSpeechface.
3. Approve Microphone, Accessibility, and, when using Apple Speech, Speech
   Recognition for McSpeechface.
4. For the product-identity migration, confirm the old data directory is moved
   rather than copied and free disk space does not fall by the size of installed models.
5. Confirm settings, vocabulary, history, and downloaded models remain available.
6. If launch at login was enabled, enable it again for McSpeechface, remove any
   earlier entry still shown in System Settings, then confirm McSpeechface starts
   only once after logging out and back in.
7. Reinstall the command-line tool and confirm its earlier owned link is removed.
8. Recheck the shortcut, recording, transcription, and automatic paste.
9. Confirm About reports the installed release tag and no update when it is current.
10. After confirming migration, remove the earlier app from Applications.

## Later McSpeechface upgrades

1. Quit McSpeechface and replace it in Applications with the next DMG build.
2. Approve the new ad-hoc build in Privacy & Security and launch it.
3. Confirm settings, models, history, the shortcut, and automatic paste still work.
4. Confirm About reports the installed release tag and no update when it is current.

Ad-hoc community builds are not a stable Apple code identity. macOS can require
first-launch approval or permission renewal after an update. The product-identity
migration always requires permission renewal because its bundle identifier changes.
A future Developer ID build would make subsequent updates more predictable.
