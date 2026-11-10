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
  <img src=".github/assets/demo.gif" width="760" alt="Holding Right Command in Claude Code: a small capsule with voice bars appears, and on release the spoken sentence is typed at the prompt">
</p>
<p align="center">
  <img src=".github/assets/history.gif" height="280" alt="The menu bar icon's History submenu lists the latest dictations; clicking one copies it">
  <img src=".github/assets/settings.gif" height="280" alt="Scrolling through Settings › General: dictation key, Improve, Text and Feedback">
</p>

<p align="center">
  <a href="https://github.com/viachm/claude-whisper/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/viachm/claude-whisper?label=release&color=2b7489"></a>
  <a href="https://github.com/viachm/claude-whisper/actions/workflows/build.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/viachm/claude-whisper/build.yml?branch=main&label=build"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/github/license/viachm/claude-whisper?color=yellow"></a>
  <a href="https://viachm.github.io/claude-whisper/"><img alt="Website" src="https://img.shields.io/badge/website-viachm.github.io-555"></a>
</p>

Free and open source. It uses Claude Code's own voice dictation in a hidden session, on the Claude
account you already have: no extra subscription, no API key, no servers of its own.

## Keys

| | macOS | Windows |
|---|---|---|
| Talk | hold **Right Command**, let go | hold **Right Ctrl**, let go |
| Lock hands-free | **Right Option** while holding, or double-tap | **Right Alt** while holding, or double-tap |
| Improve with Claude | tap **Shift** while talking | not yet |
| Cancel | **Esc** | **Esc** |

Every key can be changed in Settings. History keeps your last 30 dictations in the menu bar
(tray) icon.

## Install

You need [Claude Code](https://code.claude.com) signed in, with `/voice` working.

**macOS 14+**: download [Claude-Whisper-macOS.zip](https://github.com/viachm/claude-whisper/releases/latest/download/Claude-Whisper-macOS.zip),
move the app to Applications, click **Open Anyway** in System Settings › Privacy & Security (it is not
notarized) and grant Accessibility, Input Monitoring and Microphone.

**Windows 10/11**: download [Claude-Whisper-Windows.zip](https://github.com/viachm/claude-whisper/releases/latest/download/Claude-Whisper-Windows.zip)
(`-arm64` for ARM PCs from the [release](https://github.com/viachm/claude-whisper/releases/latest)),
run `ClaudeWhisper.exe` and click **More info › Run anyway** (it is not signed).

## How it works

The app types Claude Code's voice key into a hidden `claude` session while you hold yours, takes
the transcript out of its prompt and pastes it where your cursor is. Nothing is sent to Claude as a
message.

## More

- [Guide](docs/GUIDE.md): every gesture, permissions, settings, internals, troubleshooting
- [Contributing](CONTRIBUTING.md) (build from source, tests) · [Security](SECURITY.md)

> Unofficial: not made by, affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are
> Anthropic's names, used only to say what the app works with.

## License

[MIT](LICENSE)
