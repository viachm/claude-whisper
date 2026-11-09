# Claude Whisper

Hold a key anywhere on your Mac, speak, let go, and the text is typed where your cursor is.

Claude Whisper is a menu bar wrapper around [Claude Code](https://code.claude.com). It does no
speech recognition of its own: it drives Claude Code's built-in voice dictation in a hidden session,
so it runs on the Claude account you are already signed in with.

> Unofficial: not made by, affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are
> Anthropic's names, used only to say what the app works with.

## Using it

| Do this | What happens |
|---|---|
| Hold **Right Command**, speak, let go | the text is pasted at the cursor; in Claude it is also sent |
| While holding, press **Right Option** | 🔒 locked: keeps listening after you let go |
| Double-tap Right Command | 🔒 locked from the start |
| Tap Right Command while locked | stops; the text is pasted without sending |
| Tap **Shift** while dictating | ✨ improve: Claude cleans this dictation up |
| Tap Right Option again while locked | ✨ the same as Shift |
| Esc | cancels and discards |
| Another key while holding Right Command | ignored: the dictation goes on, and the key does nothing |
| Right Command with another key at once (Cmd+C…) | a normal shortcut; the dictation is dropped |

- **Auto-send into Claude**: after a hold, Return is pressed when the text went into the Claude
  desktop app or a Ghostty, Terminal or iTerm2 tab running Claude Code.
- **Improve** removes fillers and self-corrections ("option 2, no, option 1" → "option 1"), fixes
  punctuation and restores the spelling of product names and technical terms, keeping your words
  and language. It runs a separate `claude -p` (Haiku by default), adds about a second and uses your
  Claude subscription; if Claude doesn't answer within 10 s, the text is pasted as transcribed.
- A small capsule near the bottom of the screen shows the state: bars while listening (🔒 when
  locked, ✨ when improving), a wave while transcribing. The start sound plays only once the
  microphone is really on.
- Text is pasted followed by a space, and your clipboard is put back.
- The menu bar icon has **History** (the last 30 dictations; click one to copy it), **Settings…**,
  **Restart Claude Session** and **Quit**, which also stops the hidden session.

## Requirements

- macOS 14 Sonoma or later, Apple silicon or Intel.
- [Claude Code](https://code.claude.com) installed and signed in, with voice dictation working:
  run `claude`, then `/voice`, and hold Space. Claude Whisper finds `claude` in `~/.local/bin`,
  Homebrew or npm; another path can be set in Settings › Claude.

## Install

**Download** `Claude-Whisper.zip` from the [latest release](../../releases/latest), unzip it and
move **Claude Whisper.app** to Applications. The app is not notarized, so the first launch is
blocked: click **Open Anyway** in System Settings › Privacy & Security, or run

```sh
xattr -dr com.apple.quarantine "/Applications/Claude Whisper.app"
```

**Or build it** (needs the Xcode command line tools, `xcode-select --install`):

```sh
git clone https://github.com/viachm/claude-whisper.git
cd claude-whisper
./build.sh --install      # builds, copies to ~/Applications and starts it
```

**Permissions.** All three are needed; while one is missing, Settings opens with a banner whose
**Manage…** button lists them, links to each System Settings pane and offers a relaunch.

| Permission | Why |
|---|---|
| Accessibility | pasting into the app you are in |
| Input Monitoring | seeing the dictation key |
| Microphone | letting the hidden Claude Code session hear you |

The first auto-send into a terminal also asks to let Claude Whisper control it (to see which tab is
in front). Release builds are ad-hoc signed, so macOS asks for the permissions again after each
update; a build signed with your Apple Development certificate keeps them.

## Settings

- **General**
  - **Dictation key**: Right Command, Right Option, Left Option, Right Control, Fn or a recorded
    shortcut; hold to talk or tap to start and stop; the cancel key. A keyboard picture shows which
    key dictates and which locks (point at a key for what it does).
  - **Improve**: never, when you tap the improve key (default), or always (then the key skips it);
    the improve key (any single modifier, Shift by default); Haiku or Sonnet.
  - **Auto-send into Claude**: after a hold, and optionally after a locked dictation; extra apps
    that always get Return.
  - **Text**: paste, paste and press Return, or copy only; restore the clipboard.
  - **Feedback**: sounds (five sets, with a volume slider), the capsule and where it shows (bottom,
    top, left or right), open at login.
- **Claude**: **Faster start** (makes Option+K Claude Code's voice key in
  `~/.claude/keybindings.json`, so listening starts about 0.2 s sooner; Space then stops dictating
  inside Claude Code itself), dictation language, `claude` path and extra arguments, session status.
- **Permissions** and **History** (all 30 dictations in full).

## How it works

1. Claude Whisper runs `claude` in its own pseudo-terminal
   (`~/Library/Application Support/Claude Whisper/workspace`), with voice on in hold mode and no
   auto-submit through `--settings`, whatever your own settings say.
2. While you hold the key, it types Claude Code's voice key into that terminal every 50 ms, as a held
   key would. The key comes from `~/.claude/keybindings.json` (last Chat binding for
   `voice:pushToTalk`), Space by default.
3. When you let go, Claude Code transcribes into its prompt. Claude Whisper presses Ctrl+G, and
   Claude Code hands the prompt to `$EDITOR`, a small script that writes the text out and empties
   the prompt. Nothing is sent to Claude as a message.
4. With Improve on, the text goes to a `claude -p` process with no tools, MCP servers or settings,
   started ahead of time so its start-up is hidden. Only the answer's `<text>` block is used.
5. The text is pasted into the app you were in.

## Troubleshooting

- **The key does nothing**: check the permissions, then quit and reopen the app. Other apps on the
  same key (Wispr Flow, superwhisper, Karabiner rules) have to be quit or moved.
- **"Claude didn't start listening"**: check that `/voice` works in `claude` itself, then menu ›
  Restart Claude Session.
- **Log**: `~/Library/Logs/Claude Whisper.log` (Settings › Claude › Open Log).

## Contributing

`./build.sh` builds the app (`--install` to install and start it, `--universal` for both
architectures) and `./test.sh` runs the tests; plain `swiftc`, no Xcode project or dependencies.
Changes go in through pull requests, which GitHub Actions builds and tests; every merge to `main`
is released automatically with the next version number.
