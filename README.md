<p align="center">
  <img src=".github/assets/icon.png" width="128" height="128" alt="Claude Whisper icon">
</p>

<h1 align="center">Claude Whisper</h1>

<p align="center">
  <b>Hold a key, speak, let go: the text is typed where your cursor is.</b><br>
  System-wide voice typing for macOS and Windows, on the Claude Code you already have.
</p>

<p align="center">
  <a href="https://github.com/viachm/claude-whisper/releases/latest/download/Claude-Whisper-macOS.zip"><img alt="Download for macOS" src="https://img.shields.io/badge/Download-macOS-000?style=for-the-badge&logo=apple&logoColor=white"></a>
  <a href="https://github.com/viachm/claude-whisper/releases/latest/download/Claude-Whisper-Windows.zip"><img alt="Download for Windows" src="https://img.shields.io/badge/Download-Windows-0078D4?style=for-the-badge&logo=data:image/svg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxNiAxNiIgZmlsbD0id2hpdGUiPjxyZWN0IHdpZHRoPSI3LjUiIGhlaWdodD0iNy41Ii8%2BPHJlY3QgeD0iOC41IiB3aWR0aD0iNy41IiBoZWlnaHQ9IjcuNSIvPjxyZWN0IHk9IjguNSIgd2lkdGg9IjcuNSIgaGVpZ2h0PSI3LjUiLz48cmVjdCB4PSI4LjUiIHk9IjguNSIgd2lkdGg9IjcuNSIgaGVpZ2h0PSI3LjUiLz48L3N2Zz4="></a>
</p>

<p align="center">
  <a href="https://github.com/viachm/claude-whisper/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/viachm/claude-whisper?label=release&color=2b7489"></a>
  <a href="https://github.com/viachm/claude-whisper/actions/workflows/build.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/viachm/claude-whisper/build.yml?branch=main&label=build"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000?logo=apple&logoColor=white">
  <img alt="Windows 10 and 11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/github/license/viachm/claude-whisper?color=yellow"></a>
</p>

<p align="center">
  <a href="https://viachm.github.io/claude-whisper/">Website</a> ·
  <a href="#see-it-work">See it work</a> ·
  <a href="#install">Install</a> ·
  <a href="#keys">Keys</a> ·
  <a href="docs/GUIDE.md">Full guide</a>
</p>

---

Claude Whisper is a small menu bar (macOS) and tray (Windows) app around
[Claude Code](https://code.claude.com). It does no speech recognition of its own: it drives Claude
Code's built-in voice dictation in a hidden session, so it runs on the Claude account you already
use. Free and open source, with no extra subscription or API key.

## See it work

### Dictate into any app

Hold **Right Command**, speak, let go. A small capsule shows it is listening, and the text is typed
where your cursor is: here, at the Claude Code prompt.

<p align="center">
  <img src=".github/assets/demo.gif" width="760" alt="Holding Right Command in Claude Code: a small capsule with voice bars appears, and on release the spoken sentence is typed at the prompt">
</p>

### Find a dictation again

The menu bar icon keeps your last 30 dictations. Click one to copy it.

<p align="center">
  <img src=".github/assets/history.gif" width="620" alt="The menu bar icon's History submenu lists the latest dictations; clicking one copies it">
</p>

### Make it yours

Settings: the dictation key and mode, Improve, how the text is delivered, sounds and the capsule.

<p align="center">
  <img src=".github/assets/settings.gif" width="620" alt="Scrolling through Settings › General: dictation key, Improve, Text and Feedback">
</p>

## Install

You need [Claude Code](https://code.claude.com) installed and signed in, with voice dictation
working: run `claude`, type `/voice` and hold Space.

### macOS 14 or later

1. Download [Claude-Whisper-macOS.zip](https://github.com/viachm/claude-whisper/releases/latest/download/Claude-Whisper-macOS.zip),
   unzip it and move **Claude Whisper.app** to Applications.
2. The app is not notarized, so macOS blocks the first launch: click **Open Anyway** in System
   Settings › Privacy & Security, or run
   `xattr -dr com.apple.quarantine "/Applications/Claude Whisper.app"`.
3. Allow **Accessibility** (to paste), **Input Monitoring** (to see the key) and **Microphone**.
   Settings opens with a banner that links to each one.

### Windows 10 or 11

1. Download [Claude-Whisper-Windows.zip](https://github.com/viachm/claude-whisper/releases/latest/download/Claude-Whisper-Windows.zip)
   (the [release](https://github.com/viachm/claude-whisper/releases/latest) also has an `-arm64`
   zip for ARM PCs), unzip it anywhere and run **ClaudeWhisper.exe**.
2. The app is not signed, so SmartScreen stops the first launch: click **More info**, then
   **Run anyway**.
3. Windows Settings › Privacy & security › Microphone must let desktop apps use the microphone.

To build either app yourself, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Keys

| Do this | macOS | Windows |
|---|---|---|
| Talk: hold, speak, let go | **Right Command** | **Right Ctrl** |
| Lock it hands-free | **Right Option** while holding, or double-tap | **Right Alt** while holding, or double-tap |
| Stop when locked | tap the dictation key | tap the dictation key |
| Improve this dictation with Claude | tap **Shift** while talking | not yet |
| Cancel | **Esc** | **Esc** |

- Every key can be changed in Settings.
- The dictation key with another key (Cmd+C, Ctrl+C…) is a normal shortcut: nothing is pasted, and
  what you said is kept in History.
- **Improve** removes fillers and self-corrections ("option 2, no, option 1" → "option 1") and fixes
  punctuation, keeping your words and language. It adds about a second.
- With **Paste and press Return** in Settings (**Auto-send** on Windows), a dictation you held the
  key for is sent straight away; a locked one is only pasted.

## How it works

1. Claude Whisper runs `claude` in a hidden terminal of its own, with voice dictation on.
2. While you hold your key, it holds Claude Code's voice key in that terminal, and Claude Code
   transcribes into its prompt.
3. It takes the text out of the prompt and pastes it into the app you were in. Nothing is sent to
   Claude as a message, and the app makes no network connections of its own.

The details, every setting and troubleshooting are in the [full guide](docs/GUIDE.md).

## Contributing

Bug reports, ideas and pull requests are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md), and
[SECURITY.md](SECURITY.md) for reporting a vulnerability privately.

> Unofficial: not made by, affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are
> Anthropic's names, used only to say what the app works with.

## License

[MIT](LICENSE)
