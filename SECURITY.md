# Security

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](../../security/advisories/new), not in a public issue.
You should get an answer within a few days; a fix goes out as a new release.

## What the app can reach

Claude Whisper needs broad permissions to do its job, so it is worth knowing what it does with them:

- **Accessibility** (macOS) or a low-level keyboard hook (Windows): to see the
  dictation key and to paste. It reacts only to its own keys; it does not record what you type.
- **Microphone**: used by the hidden Claude Code session for its voice dictation. Claude Whisper
  itself only reads the input level, to animate the capsule.
  Note Taker (macOS 26) reads it while a note is recording, to transcribe what you say.
- **System audio recording** (macOS, Note Taker only): while a note is recording, to transcribe the
  other people on a call. Note Taker transcribes on your Mac with Apple's speech recogniser; the
  audio is never sent anywhere; it is saved with the note (to listen to later) unless you turn that off in Settings › Notes, and deleting the note deletes it (macOS may download a speech model for the language once).
- **Network**: your speech goes to Anthropic through Claude Code's dictation, and with Improve on
  the transcribed text goes to Claude through `claude -p`, both under your own Claude account. Note Taker sends a note's transcript to Claude the same way when it stops, to title and summarize it, and when you ask a question about the call. The
  app's only connections of its own are to GitHub, to look for a newer release and download it:
  only when you click **Check for Updates…** in the menu; it never checks by itself. An update is installed only after you confirm it, and only if its SHA-256
  matches the one GitHub lists for the release and its code signature is valid (from a Developer
  ID-signed version on, it must be signed by the same developer).
- **Files**: settings, the last 30 dictations and Note Taker's notes stay on your computer; the log is in
  `~/Library/Logs/Claude Whisper.log` (macOS).

Only the latest release gets fixes.
