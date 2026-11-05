using System.Text;
using System.Text.RegularExpressions;

namespace ClaudeWhisper;

/// A hidden Claude Code session running in its own pseudo console. Claude Whisper drives its voice
/// mode: holding is simulated by writing Claude's voice key (see `VoiceKey`) into the console
/// every 50 ms, the transcript lands in Claude's prompt, and Ctrl+G (external editor) hands the
/// prompt text to `claude-whisper-capture.cmd`, which writes it to the outbox file and empties the prompt.
sealed class ClaudeSession
{
    public enum State { Stopped, Starting, Ready }

    public State Current
    {
        get => state;
        private set
        {
            state = value;
            OnStateChange?.Invoke(value);
        }
    }
    private State state = State.Stopped;
    public event Action<State>? OnStateChange;

    private ConPty? pty;
    private System.Threading.Timer? repeatTimer;
    private readonly object writeGate = new();

    /// Plain text (escape sequences stripped) of recent console output, and when it last changed.
    private readonly StringBuilder screen = new();
    private DateTime lastOutput = DateTime.MinValue;

    // MARK: Lifecycle

    public void Start()
    {
        if (Current != State.Stopped) return;
        Current = State.Starting;
        screen.Clear();

        var prefs = Preferences.Shared;
        var claude = prefs.ResolvedClaudePath;
        if (!File.Exists(claude))
        {
            Log.Write($"claude not found at {claude}; set the path in Settings");
            Current = State.Stopped;
            return;
        }
        try
        {
            Directory.CreateDirectory(Paths.Workspace);
            Directory.CreateDirectory(Paths.Bin);
            // `--settings` takes a file as well as JSON; a file needs no quoting tricks through cmd.exe.
            var settingsFile = Path.Combine(Paths.Local, "session-settings.json");
            File.WriteAllText(settingsFile, SessionSettings.Json(prefs.Language));
            File.WriteAllBytes(Path.Combine(Paths.Bin, "claude-whisper-capture.cmd"), Resources.Read("claude-whisper-capture.cmd")!);

            var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables())
            {
                var key = (string)entry.Key;
                if (!key.StartsWith("CLAUDE", StringComparison.OrdinalIgnoreCase)) env[key] = (string?)entry.Value ?? "";
            }
            env["TERM"] = "xterm-256color";
            // Claude Code splits $EDITOR on spaces, so the script is found through PATH rather than named by its folder.
            env["EDITOR"] = "cmd.exe /c claude-whisper-capture.cmd";
            env["VISUAL"] = env["EDITOR"];
            env["CLAUDE_WHISPER_OUTBOX"] = Paths.Outbox;
            env["PATH"] = Paths.Bin + ";" + (env.TryGetValue("PATH", out var path) ? path : "");

            var commandLine = $"{ConPty.Quote(claude)} --settings {ConPty.Quote(settingsFile)}";
            // A .cmd (npm's shim) only runs through cmd.exe; the extra outer quotes keep the inner ones intact.
            if (claude.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) || claude.EndsWith(".bat", StringComparison.OrdinalIgnoreCase))
                commandLine = $"cmd.exe /c \"{commandLine}\"";

            pty = new ConPty(commandLine, Paths.Workspace, env, columns: 120, rows: 30);
            Log.Write($"started Claude Code (pid {pty.ProcessId}) in {Paths.Workspace}: {commandLine}");
        }
        catch (Exception e)
        {
            Log.Write($"could not start {claude}: {e.Message}");
            pty = null;
            Current = State.Stopped;
            return;
        }
        var current = pty;
        new Thread(() => ReadLoop(current)) { IsBackground = true, Name = "conpty-read" }.Start();
        new Thread(() =>
        {
            int code = current.WaitForExit();
            Ui.Post(() => ChildExited(current, code));
        }) { IsBackground = true, Name = "conpty-wait" }.Start();
    }

    public void Stop()
    {
        StopRepeats();
        var current = pty;
        if (current == null) return;
        current.Kill();
    }

    public void Restart()
    {
        Stop();
        Ui.After(1.5, Start);
    }

    private void ChildExited(ConPty child, int code)
    {
        if (child != pty) return;
        Log.Write($"Claude Code exited (status {code}); last screen: {Tail(400)}");
        child.Dispose();
        pty = null;
        Current = State.Stopped;
    }

    // MARK: Console output

    private void ReadLoop(ConPty child)
    {
        var buffer = new byte[65536];
        var decoder = Encoding.UTF8.GetDecoder();
        var chars = new char[65536];
        while (true)
        {
            int n;
            try { n = child.Output.Read(buffer, 0, buffer.Length); }
            catch (Exception) { return; }
            if (n <= 0) return;
            AnswerQueries(child, buffer, n);
            int count = decoder.GetChars(buffer, 0, n, chars, 0);
            var text = Strip(new string(chars, 0, count));
            Ui.Post(() => Received(child, text));
        }
    }

    /// Claude asks the terminal where the cursor is and what it is; answer like a basic terminal.
    /// ConPTY usually answers these itself, so this only covers what it lets through.
    private void AnswerQueries(ConPty child, byte[] data, int n)
    {
        var span = data.AsSpan(0, n);
        if (span.IndexOf("\u001b[6n"u8) >= 0) Write(child, "\u001b[1;1R");
        if (span.IndexOf("\u001b[c"u8) >= 0 || span.IndexOf("\u001b[0c"u8) >= 0) Write(child, "\u001b[?62;22c");
    }

    private void Received(ConPty child, string text)
    {
        if (child != pty) return;
        lastOutput = DateTime.UtcNow;
        screen.Append(text);
        if (screen.Length > 20000) screen.Remove(0, screen.Length - 10000);
        if (Current != State.Starting) return;
        var all = screen.ToString();
        if (all.Contains("trust this folder"))
        {
            // First run in the workspace: pick "Yes, I trust this folder".
            screen.Clear();
            Write("\u001b[B");
            Ui.After(0.4, () => Write("\r"));
        }
        else if (all.Contains("shift+tab to cycle") || all.Contains("? for shortcuts") || all.Contains("Try \""))
        {
            Current = State.Ready;
            Log.Write("Claude Code is ready");
        }
    }

    private static readonly Regex Escapes = new(
        "\u001b\\[[0-9;?<>=]*[ -/]*[@-~]|\u001b\\][^\u0007\u001b]*(\u0007|\u001b\\\\)|\u001b.", RegexOptions.Compiled);

    private static string Strip(string s) => Escapes.Replace(s, " ");

    /// How much console output there is so far, to look only at what comes after it.
    public int ScreenLength => screen.Length;

    public string Since(int mark) => screen.Length > mark ? screen.ToString(mark, screen.Length - mark) : "";

    public string Tail(int n)
    {
        var all = screen.ToString();
        var tail = all.Length > n ? all[^n..] : all;
        return Regex.Replace(tail, "\\s+", " ");
    }

    // MARK: Dictation

    private void Write(string s) { if (pty is { } child) Write(child, s); }

    private void Write(ConPty child, string s)
    {
        lock (writeGate)
        {
            try
            {
                var bytes = Encoding.UTF8.GetBytes(s);
                child.Input.Write(bytes, 0, bytes.Length);
                child.Input.Flush();
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException)
            {
                // The process has just exited; the exit handler takes it from here.
            }
        }
    }

    /// Starts holding the voice key: it is sent every 50 ms, like a physically held key.
    public void StartRepeats()
    {
        StopRepeats();
        var key = VoiceKey.Bytes();
        repeatTimer = new System.Threading.Timer(_ => Write(key), null, 0, 50);
    }

    public void StopRepeats()
    {
        repeatTimer?.Dispose();
        repeatTimer = null;
    }

    /// Releases the voice key and waits for Claude to finish transcribing, then takes the prompt
    /// text out of Claude. Calls back on the UI thread with the text ("" if none).
    ///
    /// ConPTY only sends the cells that changed, so the footer's "processing…" cannot be watched
    /// going away as it is on macOS; instead the console is waited for to go quiet (the spinner
    /// next to it keeps drawing while it is there), and an empty prompt is read again a few times.
    public void Finish(Action<string> completion)
    {
        StopRepeats();
        int mark = screen.Length;
        var started = DateTime.UtcNow;
        bool sawProcessing = false;

        void Poll()
        {
            var since = screen.Length > mark ? screen.ToString(mark, screen.Length - mark) : "";
            double quiet = (DateTime.UtcNow - lastOutput).TotalSeconds;
            double elapsed = (DateTime.UtcNow - started).TotalSeconds;
            if (since.Contains("No speech detected"))
            {
                Log.Write("no speech detected");
                completion("");
                return;
            }
            if (since.Contains("processing")) sawProcessing = true;
            bool done = (sawProcessing && quiet > 0.4)
                || (!sawProcessing && elapsed > 2.5 && quiet > 0.6)
                || elapsed > 20;
            if (done) CaptureRetrying(retries: sawProcessing ? 4 : 1, completion);
            else Ui.After(0.05, Poll);
        }
        Ui.After(0.1, Poll);
    }

    /// The wait for Claude to finish is kept short, so in case the transcript has not reached the
    /// prompt yet, look again.
    private void CaptureRetrying(int retries, Action<string> completion)
    {
        Capture(text =>
        {
            if (text.Length > 0 || retries <= 0)
            {
                completion(text);
                return;
            }
            Log.Write("prompt was empty; capturing again");
            Ui.After(0.5, () => CaptureRetrying(retries - 1, completion));
        });
    }

    /// Drops whatever is being recorded: releases the key and cancels with Esc, then clears
    /// anything that still lands in the prompt.
    public void Cancel()
    {
        StopRepeats();
        Ui.After(0.1, () => Write("\u001b"));
        Ui.After(2, () => Capture(text => { if (text.Length > 0) Log.Write($"discarded: {text}"); }));
    }

    /// Ctrl+G: Claude opens the prompt in $EDITOR (claude-whisper-capture.cmd), which writes the
    /// text to the outbox and empties the prompt.
    private void Capture(Action<string> completion)
    {
        try { File.Delete(Paths.Outbox); } catch (IOException) { }
        Write("\u0007");
        var started = DateTime.UtcNow;
        void Poll()
        {
            if (File.Exists(Paths.Outbox))
            {
                try
                {
                    completion(File.ReadAllText(Paths.Outbox, Encoding.UTF8).Trim());
                    return;
                }
                catch (IOException)
                {
                    // Still being moved into place; look again.
                }
            }
            if ((DateTime.UtcNow - started).TotalSeconds > 4)
            {
                Log.Write($"capture timed out; screen: {Tail(300)}");
                completion("");
                return;
            }
            Ui.After(0.05, Poll);
        }
        Poll();
    }
}
