# Claude Whisper

Hold a key anywhere on your Mac, speak, let go, and the text is typed where your cursor is.

Claude Whisper is a small menu bar wrapper around [Claude Code](https://code.claude.com). It does
no speech recognition of its own: it runs a hidden Claude Code session and drives Claude Code's
built-in voice dictation, so it uses the Claude account you are already signed in with and needs no
extra keys or downloads.

> Unofficial. Claude Whisper is a personal project and is not made by, affiliated with or endorsed
> by Anthropic. "Claude" and "Claude Code" are Anthropic's names, used here only to say what the app
> works with.

## What it does

- **Dictate anywhere.** Hold **Right Command**, speak, let go: the text is pasted at the cursor in
  any app, followed by a space. Your clipboard is put back afterwards.
- **Auto-send into Claude.** When the text goes into the Claude desktop app, or a Ghostty, Terminal
  or iTerm2 tab running Claude Code, Return is pressed for you, so the message is sent straight away.
- **Lock for longer dictation.** While holding Right Command, press **Right Option**, or
  **double-tap Right Command**: it keeps listening without holding anything (a lock shows on
  screen). Tap Right Command to stop; the text is inserted without sending, so you can read it
  first.
- **Esc** cancels and discards.
- **History** of the last 30 dictations, in the menu bar menu and in Settings.
- A small capsule near the bottom of the screen shows when it is listening (bars follow your voice)
  and when Claude is transcribing. The start sound only plays once the microphone is really on.

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel).
- [Claude Code](https://code.claude.com) installed and signed in. Voice dictation has to work in
  your Claude Code: run `claude`, then `/voice`, and hold Space to try it.

Claude Whisper finds `claude` in the usual install locations (`~/.local/bin`, Homebrew, npm). A
different location can be set in Settings › Claude.

## Install

### Download

1. Download `Claude-Whisper.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move **Claude Whisper.app** to your Applications folder.
3. Open it. The build is not notarized by Apple, so macOS blocks the first launch: open
   System Settings › Privacy & Security, scroll down and click **Open Anyway** next to Claude
   Whisper. Or, in Terminal:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Claude Whisper.app"
   ```

Every push to `main` also builds the app; the zip is attached to that workflow run under
**Actions** as an artifact.

### Build from source

Needs the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/viachm/claude-whisper.git
cd claude-whisper
./build.sh --install
```

This builds the app, copies it to `~/Applications` and starts it. With an Apple Development
certificate in your keychain the app is signed with it, so macOS keeps its permissions across
rebuilds.

### Permissions

On first start macOS asks for three permissions. All three are needed:

| Permission | Why |
|---|---|
| **Accessibility** | to paste the text into the app you are in |
| **Input Monitoring** | to see the dictation key |
| **Microphone** | for the hidden Claude Code session to hear you |

While any is missing, Settings opens on launch with a banner; **Manage…** lists what is left, each
with a button to the right System Settings pane, and offers to relaunch once everything is allowed. The first time it
auto-sends into a terminal, macOS also asks to let Claude Whisper control that terminal (it asks the
terminal which tab is in front).

An ad-hoc signed build (the downloaded one, or a build without a certificate) gets a new identity
with every update, so macOS asks for the permissions again after updating.

## Using it

| Do this | What happens |
|---|---|
| Hold Right Command, speak, let go | text is pasted; in Claude it is also sent |
| While holding, press Right Option | locked: keeps listening after you let go |
| Double-tap Right Command | locked from the start |
| Tap Right Command while locked | stops; text is pasted unsent |
| Tap Shift (the improve key) while dictating | Claude cleans this dictation up (a sparkle shows) |
| Tap Right Option again while locked | the same as the improve key |
| Esc | cancels and discards |
| Right Command with another key (Cmd+C…) | a normal shortcut; dictation is dropped |

Right Command and Right Option still reach the app you are in; on their own they do nothing there.

The menu bar icon has the **History** (click an entry to copy it), **Settings…**, **Restart Claude
Session** and **Quit**. Quitting also stops the hidden Claude Code session.

## Settings

- **Key**: Right Command (default), Right Option, Left Option, Right Control, Fn, or a recorded
  shortcut such as ⌃⌥Space. A picture of the keyboard shows which key dictates and which locks.
- **Mode**: hold to talk (default), or tap to start and tap to stop.
- **Cancel key**: Esc by default.
- **After dictating**: paste at the cursor, paste and always press Return, or only copy.
- **Improve**: Claude cleans a dictation up before it is pasted: filler words and self-corrections
  go ("option 2, no, option 1" becomes "option 1"), punctuation is fixed, your words and language
  stay; product names and technical terms that recognition spelled out phonetically get their
  original spelling. With a Dictation language set (Settings › Claude), the prompt names it, and
  for Ukrainian adds Ukrainian examples. By default only when you tap the **improve key** (Shift,
  or any modifier key you record in Settings) on its own while dictating: a sparkle shows on the
  capsule, and tapping it again takes it back. Shift held for a capital letter while you type
  elsewhere during a locked dictation doesn't count. It can also be Never, or Always (then the
  improve key skips it). Keys that can't work are refused with the reason: non-modifier keys, the
  dictation and lock keys, and keys another app rewrites (such as a Hyper key in Raycast).
  Haiku (fastest) or Sonnet. It uses your Claude subscription and adds about a second; if Claude
  doesn't answer within 10 seconds, the transcript is pasted as it was.
- **Auto-send into Claude**: on after a hold; optionally also after a locked dictation. Other apps
  can be added to always get Return.
- **Sounds**: on or off, one of five sound sets (Click by default; Chime, Soft, Bubble, Glass) with a
  play button to try them, and a volume slider. Each set has a start, a stop and an improve cue,
  synthesised by `tools/make-sounds.py`.
- The on-screen **capsule**, and **Open at login**.
- **Claude** tab:
  - **Faster start**: makes Option+K Claude Code's voice key (in `~/.claude/keybindings.json`).
    Claude Code starts listening on the first press of a key combination but waits for several
    repeats of a plain Space, so this starts about 0.2 s sooner. Space then no longer starts
    dictation inside Claude Code itself.
  - **Dictation language**: passed to the hidden session only.
  - The `claude` path and extra arguments; session status and restart.
- **History** tab: the last 30 dictations in full, with Copy buttons and Clear History.

## How it works

1. On start, Claude Whisper launches `claude` in its own pseudo-terminal, in
   `~/Library/Application Support/Claude Whisper/workspace`, with voice mode switched on through
   `--settings` (hold mode, no auto-submit), whatever your own settings say. Not tap mode: there
   the stopping press sends the transcript to Claude as a message, whatever auto-submit says.
2. While you hold the key, it types Claude Code's voice key into that terminal every 50 ms, which is
   what Claude Code sees from a held key. The key is read from `~/.claude/keybindings.json` (the last
   Chat binding for `voice:pushToTalk`), Space by default.
3. When you let go, Claude Code transcribes into its prompt. Claude Whisper presses Ctrl+G; Claude
   Code opens the prompt in `$EDITOR`, which is a small script (`claude-whisper-capture`) that writes
   the text out and empties the prompt. Nothing is ever sent to Claude as a message.
4. With Improve on, the text goes to a separate `claude -p` process (stream-json, no tools, MCP
   servers or settings files) together with the name of the app in front. Starting `claude` takes
   longer than the model call, so the process is started ahead of time: when the improve key is pressed (the
   rest of the dictation covers the start-up), or all the time when cleanup is always on. Each one
   handles a single dictation, so nothing carries over between dictations.
5. The text is pasted into the app you were in, and your clipboard is restored.

The start sound and capsule wait until the microphone is actually running, so a press Claude Code
ignored never looks as if it worked.

## Troubleshooting

- **Nothing happens on the key**: check Settings › Permissions, then quit and reopen the app. Other
  dictation apps on the same key (Wispr Flow, superwhisper, Karabiner rules) must be quit or moved.
- **"Claude didn't start listening"**: make sure voice works in `claude` itself (`/voice`), then
  menu › Restart Claude Session.
- **Log**: `~/Library/Logs/Claude Whisper.log` (Settings › Claude › Open Log).

## Development

```text
Sources/
  main.swift            app delegate: menu bar, dictation flow, pasting
  ClaudeSession.swift   the hidden Claude Code session in a pseudo-terminal
  Hotkey.swift          the dictation key: event tap, hold / lock / tap gestures
  VoiceKey.swift        which key Claude Code listens to; Faster start
  Overlay.swift         the on-screen capsule
  AutoSend.swift        whether the target is Claude (desktop app, terminal tab running claude)
  SettingsWindow.swift  the Settings window (SwiftUI)
  Preferences.swift     settings, kept in UserDefaults
  History.swift         the last 30 dictations
  ImproveKey.swift      the improve key: which modifier keys count, and checking a recorded one
  Refiner.swift         cleanup with Claude: the pre-started claude -p processes
  RefinerProtocol.swift its arguments, system prompt, message and result parsing
  Support.swift         log, sounds, microphone state, paste, permissions
Resources/              Info.plist, sounds, icon, the $EDITOR capture script
tools/make-icon.sh      renders the app icon (Assets.car needs Xcode's actool)
Tests/main.swift        tests for RefinerProtocol, CleanupMode, ImproveKey and SessionSettings
build.sh                builds the app: --install, --universal
test.sh                 builds and runs the tests
```

Plain `swiftc`, no Xcode project and no dependencies. Changes go in through pull requests, which
GitHub Actions builds and tests. Every merge to `main` is released automatically: the last number
of the version goes up by one (v0.1.2 → v0.1.3) and the release gets the zip.
