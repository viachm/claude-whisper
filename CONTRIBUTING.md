# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an [issue](../../issues/new/choose) with what you did, what you expected and what happened.
The log helps most: `~/Library/Logs/Claude Whisper.log` on macOS (Settings › Claude › Open Log),
or Settings › Claude › Open Log on Windows. Say which app version (menu › Settings) and which
Claude Code version (`claude --version`) you are on.

## Building

**macOS** (`macos/`): plain `swiftc`, no Xcode project or dependencies; needs the Xcode command
line tools (`xcode-select --install`).

```sh
macos/build.sh              # builds macos/build/Claude Whisper.app
macos/build.sh --install    # also copies it to ~/Applications and starts it
macos/build.sh --universal  # Apple silicon + Intel, as the release is built
macos/test.sh               # runs the tests
```

A build signed with your Apple Development certificate keeps the Accessibility and Microphone
permissions across rebuilds; an ad-hoc signed one asks again each time.

**Windows** (`windows/`): C# / .NET 8, WinForms, no packages; needs the
[.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0). It compiles on any OS:

```sh
dotnet build windows/ClaudeWhisper.csproj -r win-x64
dotnet publish windows/ClaudeWhisper.csproj -c Release -r win-x64   # one self-contained .exe
```

## Pull requests

- Branch from `main` and keep a pull request to one topic.
- Run `macos/test.sh` (and build the Windows app if you touched `windows/`).
- Describe what changes for the person using the app, and how you tried it.
- GitHub Actions builds and tests both apps on every pull request; `main` only takes changes
  through pull requests with green checks.
- Every merge to `main` that touches the apps is released automatically with the next version
  number, both apps in one release. Changes to documentation only are not released.

## Style

Match the code around you: small files by topic, comments that say why, user-facing text in plain
words. The app must not depend on anyone's own Claude Code setup: it passes its own `--settings` to
the hidden session and only reads `~/.claude/keybindings.json` for the voice key.
