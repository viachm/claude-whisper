@echo off
rem Claude Code runs this as %EDITOR% when Claude Whisper presses Ctrl+G. It hands the prompt text to
rem Claude Whisper through the outbox file and leaves the prompt empty. Claude Code splits $EDITOR on
rem spaces, so it is started as "cmd.exe /c claude-whisper-capture.cmd" and found through PATH: the
rem folder it lives in (under the user's profile, often with a space in it) never appears in $EDITOR.
copy /y "%~1" "%CLAUDE_WHISPER_OUTBOX%.tmp" >nul
move /y "%CLAUDE_WHISPER_OUTBOX%.tmp" "%CLAUDE_WHISPER_OUTBOX%" >nul
type nul > "%~1"
