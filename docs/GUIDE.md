# Claude Whisper guide

Everything the [README](../README.md) leaves out: every gesture, permissions, settings, how it
works and troubleshooting.

## Using it

The dictation key is **Right Command** on macOS and **Right Ctrl** on Windows; the lock key is
**Right Option** / **Right Alt**. Both can be changed in Settings.

| Do this | What happens |
|---|---|
| Hold the dictation key, speak, let go | the text is pasted at the cursor |
| While holding, press the lock key | 🔒 locked: keeps listening after you let go |
| Double-tap the dictation key | 🔒 locked from the start |
| Tap the dictation key while locked | stops; the text is pasted |
| Tap **Shift** while dictating (macOS only) | ✨ improve: Claude cleans this dictation up |
| Tap the lock key again while locked (macOS only) | ✨ the same as Shift |
| Esc | cancels and discards |
| The dictation key with another key (Cmd+C, Ctrl+C…) | a normal shortcut; nothing is pasted, what you said is kept in History |
| Typing while locked (macOS) | goes to the app as usual; the dictation goes on |

- **Paste and press Return** (macOS: Settings › Text) or **Auto-send** (Windows: into the Claude
  app, optionally a console running Claude Code) presses Return after a held dictation, so it is
  sent straight away; a locked one is only pasted. Off by default on both.
- **Improve** (macOS) removes fillers and self-corrections ("option 2, no, option 1" → "option 1"),
  fixes punctuation and restores the spelling of product names and technical terms, keeping your
  words and language. It runs a separate `claude -p` (Haiku by default), adds about a second and
  uses your Claude subscription; if Claude doesn't answer within 10 s, the text is pasted as transcribed.
- A small capsule near the bottom of the screen shows the state: bars while listening (🔒 when
  locked, ✨ when improving), a wave while transcribing. The start sound plays only once the
  microphone is really on.
- Text is pasted followed by a space, and your clipboard is put back.
- The menu bar / tray icon has **History** (the last 30 dictations; click one to copy it),
  **Settings…**, **Restart Claude Session** and **Quit**, which also stops the hidden session.


## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel), or Windows 10/11 (x64 or ARM64).
- [Claude Code](https://code.claude.com) installed and signed in with a Claude.ai account, with
  voice dictation working: run `claude`, then `/voice`, and hold Space. Claude Whisper finds
  `claude` in `~/.local/bin`, Homebrew or npm (macOS) and in `%USERPROFILE%\.local\bin`, npm's
  global folder or PATH (Windows); another path can be set in Settings › Claude.

## Install

### macOS

**Download** `Claude-Whisper-macOS.zip` from the [latest release](https://github.com/viachm/claude-whisper/releases/latest), unzip it and
move **Claude Whisper.app** to Applications, then open it. Releases from 0.1.11 on are signed with
a Developer ID and notarized by Apple, so it opens like any other downloaded app.

**Or build it** (needs the Xcode command line tools, `xcode-select --install`):

```sh
git clone https://github.com/viachm/claude-whisper.git
cd claude-whisper
macos/build.sh --install      # builds, copies to ~/Applications and starts it
```

**Permissions.** Both are needed; while one is missing, Settings opens with a banner whose
**Manage…** button lists them, links to each System Settings pane and offers a relaunch.

| Permission | Why |
|---|---|
| Accessibility | seeing the dictation key and pasting into the app you are in (it also covers Input Monitoring, which is not asked for) |
| Microphone | letting the hidden Claude Code session hear you |

Because releases are signed with the same Developer ID, macOS keeps the permissions across
updates. Coming from 0.1.10 or earlier (ad-hoc signed), it asks for them once more.

**Updating.** **Check for Updates…** in the menu asks GitHub for the latest release and, once you
confirm, downloads it, checks it, replaces the app and opens the new version. It never checks by
itself. The same works on Windows from the tray menu.

### Windows

**Download** `Claude-Whisper-Windows.zip` (`-arm64` for ARM PCs) from the
[latest release](https://github.com/viachm/claude-whisper/releases/latest), unzip it anywhere and run **ClaudeWhisper.exe**; it is one
self-contained file, nothing else to install. The app is not signed, so SmartScreen stops the first
launch: click **More info**, then **Run anyway**. Windows Settings › Privacy & security › Microphone
must allow desktop apps to use the microphone. Turn on **Open at login** in Settings to keep it.

**Or build it** (needs the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)):

```sh
dotnet publish windows/ClaudeWhisper.csproj -c Release -r win-x64
# → windows/bin/Release/net8.0-windows/win-x64/publish/ClaudeWhisper.exe
```

The Windows app is the first version: it has no Improve, no keyboard picture in Settings, no
capsule position and no Faster start yet.

## Settings


- **General**
  - **Dictation key**: Right Command, Right Option, Left Option, Right Control, Fn or a recorded
    shortcut (macOS); Right Ctrl, Right Alt or a recorded shortcut (Windows). Hold to talk or tap
    to start and stop; the cancel key (Esc on Windows). On macOS a keyboard picture shows which key
    dictates and which locks (point at a key for what it does).
  - **Pasting**: paste (default), paste and press Return, or copy only (macOS); restore the
    clipboard. Windows has **Auto-send** into the Claude app and, optionally, consoles running
    Claude Code (both off by default).
  - **Sound and capsule**: sounds (five sets, with a volume slider), the capsule (macOS: and where
    it shows: bottom, top, left or right).
  - **Improve** (macOS): never, when you tap the improve key (default), or always (then the key
    skips it); the improve key (any single modifier, Shift by default); Haiku or Sonnet.
  - **Startup**: open at login.
- **Claude**: dictation language, `claude` path, session status, the log. macOS also has extra
  arguments and **Faster start** (makes Option+K Claude Code's voice key in
  `~/.claude/keybindings.json`, so listening starts about 0.2 s sooner; Space then stops dictating
  inside Claude Code itself).
- **History** (all 30 dictations in full) and, on macOS, **Permissions**.
- **About**: the version with **Check for Updates…**, and links to the website, the source code,
  issues and the license.

## How it works

1. Claude Whisper runs `claude` in its own pseudo-terminal (a pty on macOS, a ConPTY pseudo console
   on Windows), in a workspace of its own, with voice on in hold mode and no auto-submit through
   `--settings`, whatever your own settings say.
2. While you hold the key, it types Claude Code's voice key into that terminal every 50 ms, as a held
   key would. The key comes from `~/.claude/keybindings.json` (last Chat binding for
   `voice:pushToTalk`), Space by default.
3. When you let go, Claude Code transcribes into its prompt. Claude Whisper presses Ctrl+G, and
   Claude Code hands the prompt to `$EDITOR`, a small script that writes the text out and empties
   the prompt. Nothing is sent to Claude as a message.
4. With Improve on (macOS), the text goes to a `claude -p` process with no tools, MCP servers or
   settings, started ahead of time so its start-up is hidden. Only the answer's `<text>` block is used.
5. The text is pasted into the app you were in.

On Windows the dictation key is seen through a low-level keyboard hook, "listening" is read from
WASAPI's capture sessions (falling back to Claude Code's own "listening" in the console), and the
end of transcription is taken from the console going quiet, since ConPTY only sends the cells
that changed.

## Troubleshooting

- **The key does nothing**: macOS: check the permissions, then quit and reopen the app. Other apps
  on the same key (other dictation apps, Karabiner rules, PowerToys) have to be quit or moved.
- **"Claude didn't start listening"**: check that `/voice` works in `claude` itself, then menu ›
  Restart Claude Session.
- **Log**: `~/Library/Logs/Claude Whisper.log` (macOS), `%LOCALAPPDATA%\Claude Whisper\Claude
  Whisper.log` (Windows); Settings › Claude › Open Log.
