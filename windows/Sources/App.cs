using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Reflection;

namespace ClaudeWhisper;

/// Claude Whisper: hold Right Ctrl (or the key chosen in Settings) anywhere, speak, release, and the
/// text is typed where your cursor is. Transcription is done by Claude Code's own voice mode, in
/// a hidden Claude Code session signed in with your Claude subscription.
sealed class App : ApplicationContext
{
    private readonly Preferences prefs = Preferences.Shared;
    private readonly History history = new();
    private readonly ClaudeSession session = new();
    private readonly Hotkey hotkey = new();
    private readonly Overlay overlay = new();
    private readonly NotifyIcon tray;
    private readonly ToolStripMenuItem historyMenu = new("History");
    private readonly Updater updater = new();
    private readonly ToolStripMenuItem updateItem = new("Check for Updates…");
    private SettingsWindow? settings;
    private IDisposable? pendingRestart;
    private Icon? idleIcon, activeIcon;

    private enum Phase { Idle, WaitingForMic, Listening, Transcribing }
    private Phase phase = Phase.Idle;
    private int pressId;
    /// Locked before Claude was listening: the capsule shows the lock once it is.
    private bool locked;
    /// Whether the dictation being transcribed was held and let go (rather than locked or tapped),
    /// which decides whether it is auto-sent.
    private bool held;
    /// When the key went up, for the timings in the log.
    private DateTime releasedAt = DateTime.UtcNow;

    public App()
    {
        Log.Write("Claude Whisper launched");
        tray = new NotifyIcon { Text = Paths.AppName, Visible = true, ContextMenuStrip = BuildMenu() };
        SetIcon(active: false);
        tray.DoubleClick += (_, _) => OpenSettings();
        // Windows only opens the menu on right-click; show it on a left-click too, since that is
        // what most people try first and a menu-bar app on macOS opens on a plain click.
        tray.MouseUp += (_, e) => { if (e.Button == MouseButtons.Left) ShowTrayMenu(); };

        hotkey.OnStart += Pressed;
        hotkey.OnStop += Released;
        hotkey.OnLock += LockedOn;
        hotkey.OnCancel += Cancelled;
        hotkey.IsRecording = () => phase is Phase.WaitingForMic or Phase.Listening;
        ArmHotkey();
        prefs.Changed += PreferenceChanged;
        session.OnStateChange += SessionChanged;
        session.Start();
        Updater.CleanUp();
        updater.Quit = ExitThread;
        updater.Changed += () => updateItem.Text = updater.Available is { } r ? $"Update to {r.Version}…" : "Check for Updates…";
        if (!File.Exists(prefs.ResolvedClaudePath)) Ui.After(1, OpenSettings);
    }

    protected override void ExitThreadCore()
    {
        session.Stop();
        hotkey.Dispose();
        tray.Visible = false;
        tray.Dispose();
        Log.Write("Claude Whisper quit");
        base.ExitThreadCore();
    }

    // MARK: Tray

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        historyMenu.DropDownOpening += (_, _) => FillHistory();
        historyMenu.DropDownItems.Add("No dictations yet");
        menu.Items.Add(historyMenu);
        menu.Items.Add("Settings…", null, (_, _) => OpenSettings());
        menu.Items.Add("Restart Claude Session", null, (_, _) => RestartSession());
        // Once a check found a newer release, the item offers it straight away.
        updateItem.Click += (_, _) => CheckForUpdates();
        menu.Items.Add(updateItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit Claude Whisper", null, (_, _) => ExitThread());
        return menu;
    }

    /// Opens the tray menu at the icon, the same popup a right-click shows. NotifyIcon has no public
    /// way to do this, so its own internal method is used.
    private void ShowTrayMenu()
    {
        typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)
            ?.Invoke(tray, null);
    }

    /// Built each time it opens: the latest dictations, a click copies one.
    private void FillHistory()
    {
        var items = historyMenu.DropDownItems;
        items.Clear();
        if (history.Entries.Count == 0) items.Add(new ToolStripMenuItem("No dictations yet") { Enabled = false });
        foreach (var entry in history.Entries.Take(10))
        {
            var time = entry.Date.Date == DateTime.Today ? entry.Date.ToString("HH:mm") : entry.Date.ToString("d MMM HH:mm");
            var line = System.Text.RegularExpressions.Regex.Replace(entry.Text, "\\s+", " ");
            var snippet = line.Length > 60 ? line[..60] + "…" : line;
            var item = new ToolStripMenuItem($"{time}  {snippet}") { ToolTipText = entry.Text };
            var text = entry.Text;
            item.Click += (_, _) =>
            {
                try { Clipboard.SetText(text); } catch (Exception e) { Log.Write($"could not copy: {e.Message}"); }
                Show(Overlay.Mode.Message, "Copied to clipboard");
            };
            items.Add(item);
        }
        items.Add(new ToolStripSeparator());
        items.Add($"Show All {history.Entries.Count}…", null, (_, _) => OpenSettings(SettingsWindow.Tab.History));
        var clear = new ToolStripMenuItem("Clear History", null, (_, _) => history.Clear()) { Enabled = history.Entries.Count > 0 };
        items.Add(clear);
    }

    /// A small copy of the app icon: voice bars in a rounded square, outlined while idle and
    /// filled while listening, in white so it reads on the dark taskbar.
    private void SetIcon(bool active)
    {
        ref Icon? cached = ref active ? ref activeIcon : ref idleIcon;
        if (cached == null)
        {
            const int size = 32;
            using var bitmap = new Bitmap(size, size);
            using (var g = Graphics.FromImage(bitmap))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                var tile = new RectangleF(2.5f, 3.5f, size - 5, size - 7);
                using var path = RoundedRect(tile, 7);
                using var white = new SolidBrush(Color.White);
                using var pen = new Pen(Color.White, 2);
                if (active) g.FillPath(white, path); else g.DrawPath(pen, path);
                float[] heights = { 6, 11, 16, 11, 6 };
                float barWidth = 2.6f, gap = 2.4f;
                float x = tile.Left + (tile.Width - (heights.Length * barWidth + (heights.Length - 1) * gap)) / 2;
                // Listening: the bars are cut out of the filled square.
                g.CompositingMode = active ? CompositingMode.SourceCopy : CompositingMode.SourceOver;
                using var cut = new SolidBrush(active ? Color.Transparent : Color.White);
                foreach (var h in heights)
                {
                    using var bar = RoundedRect(new RectangleF(x, tile.Top + (tile.Height - h) / 2, barWidth, h), barWidth / 2);
                    g.FillPath(cut, bar);
                    x += barWidth + gap;
                }
            }
            cached = Icon.FromHandle(bitmap.GetHicon());
        }
        tray.Icon = cached;
    }

    private static GraphicsPath RoundedRect(RectangleF r, float radius)
    {
        var path = new GraphicsPath();
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        path.AddArc(r.Left, r.Top, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    private void SessionChanged(ClaudeSession.State state)
    {
        settings?.ShowSessionState(state);
        if (state != ClaudeSession.State.Stopped) return;
        phase = Phase.Idle;
        SetIcon(active: false);
        // Only when claude is there: otherwise the log would fill with the same failure every 3 s.
        if (File.Exists(prefs.ResolvedClaudePath)) Ui.After(3, session.Start);
    }

    private void OpenSettings() => OpenSettings(SettingsWindow.Tab.General);

    /// Once a check found a newer release, it is offered straight away.
    private void CheckForUpdates()
    {
        if (updater.Available != null) updater.Offer(); else _ = updater.Check();
    }

    private void OpenSettings(SettingsWindow.Tab tab)
    {
        settings ??= new SettingsWindow(history, RestartSession, OpenLog, CheckForUpdates);
        settings.ShowSessionState(session.Current);
        settings.Open(tab);
    }

    /// Coalesced, since applying several session settings at once would restart it once each.
    private void RestartSession()
    {
        pendingRestart?.Dispose();
        pendingRestart = Ui.After(0.2, session.Restart);
    }

    private void OpenLog()
    {
        try { Process.Start(new ProcessStartInfo(Paths.LogFile) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write($"could not open the log: {e.Message}"); }
    }

    // MARK: Hotkey

    private void ArmHotkey()
    {
        // A shortcut field is recording: the old shortcut must not fire meanwhile.
        if (prefs.IsRecordingShortcut)
        {
            hotkey.Disarm();
            return;
        }
        hotkey.Arm(new Hotkey.Config(prefs.Trigger, prefs.Shortcut, prefs.Mode));
    }

    /// Applies settings as they change: hotkey changes re-arm the hook right away; Claude reads its
    /// arguments and settings only at start.
    private void PreferenceChanged(string name)
    {
        switch (name)
        {
            case nameof(Preferences.Trigger) or nameof(Preferences.Shortcut) or nameof(Preferences.Mode) or nameof(Preferences.IsRecordingShortcut):
                ArmHotkey();
                break;
            case nameof(Preferences.ClaudePath) or nameof(Preferences.Language):
                RestartSession();
                break;
            case nameof(Preferences.ShowOverlay):
                overlay.Hide();
                break;
        }
    }

    // MARK: Dictation

    private void Pressed()
    {
        Log.Write($"dictation key pressed (session {session.Current}, phase {phase})");
        if (phase != Phase.Idle) return;
        if (session.Current != ClaudeSession.State.Ready)
        {
            Show(Overlay.Mode.Message, File.Exists(prefs.ResolvedClaudePath) ? "Claude is still starting" : "Claude Code was not found: see Settings");
            return;
        }
        pressId++;
        int id = pressId;
        phase = Phase.WaitingForMic;
        locked = false;
        Show(Overlay.Mode.Waiting);
        session.StartRepeats();
        WaitForMicrophone(id, DateTime.UtcNow, session.ScreenLength);
    }

    /// Claude only opens the microphone once it is really listening; until then, show nothing that
    /// suggests it is. Without WASAPI's answer, Claude's own "listening" in the console counts.
    private void WaitForMicrophone(int id, DateTime started, int screenMark)
    {
        if (id != pressId || phase != Phase.WaitingForMic) return;
        bool? running = Microphone.IsRunning();
        bool listening = running ?? session.Since(screenMark).Contains("listening");
        if (listening)
        {
            phase = Phase.Listening;
            SetIcon(active: true);
            Show(locked ? Overlay.Mode.Locked : Overlay.Mode.Listening);
            Sound.Play("start");
            Log.Write($"listening after {(int)(DateTime.UtcNow - started).TotalMilliseconds} ms ({(running == null ? "console" : "microphone")})");
            return;
        }
        if ((DateTime.UtcNow - started).TotalSeconds > 3)
        {
            Log.Write($"Claude did not start listening; screen: {session.Tail(300)}");
            session.Cancel();
            phase = Phase.Idle;
            Show(Overlay.Mode.Message, "Claude didn't start listening");
            System.Media.SystemSounds.Hand.Play();
            return;
        }
        Ui.After(0.03, () => WaitForMicrophone(id, started, screenMark));
    }

    /// The lock key while holding: keeps listening after the key is let go. The capsule shows a lock
    /// and the start cue confirms it (right away, or with the start cue if Claude is not listening yet).
    private void LockedOn()
    {
        if (phase is not (Phase.WaitingForMic or Phase.Listening)) return;
        Log.Write("locked");
        locked = true;
        if (phase == Phase.Listening)
        {
            Sound.Play("start");
            Show(Overlay.Mode.Locked);
        }
    }

    private void Released(bool held)
    {
        switch (phase)
        {
            case Phase.WaitingForMic:
                // Let go before Claude was listening: nothing to transcribe.
                session.Cancel();
                phase = Phase.Idle;
                overlay.Hide();
                break;
            case Phase.Listening:
                // Only here: a release while an earlier dictation is still being transcribed must
                // not change whether that one gets sent.
                this.held = held;
                Sound.Play("stop");
                phase = Phase.Transcribing;
                SetIcon(active: false);
                Show(Overlay.Mode.Transcribing);
                releasedAt = DateTime.UtcNow;
                session.Finish(Transcribed);
                break;
        }
    }

    private int MsSinceRelease() => (int)(DateTime.UtcNow - releasedAt).TotalMilliseconds;

    private void Transcribed(string text)
    {
        Log.Write($"transcript ready {MsSinceRelease()} ms after release");
        phase = Phase.Idle;
        overlay.Hide();
        if (text.Length == 0) return;
        Log.Write($"pasting {text.Length} characters, {MsSinceRelease()} ms after release");
        history.Add(text);
        var target = AutoSend.ForegroundWindow();
        // A trailing space so the next dictation or typing doesn't run into this one; a message
        // that gets sent is unaffected.
        Paster.Deliver(text + " ", prefs.RestoreClipboard);
        if (held) AutoSendTo(target, DateTime.UtcNow);
    }

    /// Return after the paste when the dictation was meant to be sent and went into Claude. Return
    /// only goes out if the same window is still in front.
    private void AutoSendTo(IntPtr target, DateTime pastedAt)
    {
        if (!AutoSend.ShouldSend(target)) return;
        double elapsed = (DateTime.UtcNow - pastedAt).TotalSeconds;
        if (elapsed > 2 || AutoSend.ForegroundWindow() != target)
        {
            Log.Write("auto-send: skipped, focus moved");
            return;
        }
        Log.Write("auto-send: Return");
        Ui.After(Math.Max(0, Paster.ReturnDelay - elapsed), Paster.PressReturn);
    }

    private void Show(Overlay.Mode mode, string text = "")
    {
        if (!prefs.ShowOverlay) return;
        overlay.Show(mode, text);
    }

    private void Cancelled(bool deliberate)
    {
        if (phase is not (Phase.WaitingForMic or Phase.Listening)) return;
        SetIcon(active: false);
        overlay.Hide();
        // The dictation key used in a shortcut: nothing is pasted, but what was said so far is kept
        // in History rather than lost.
        if (!deliberate && phase == Phase.Listening)
        {
            phase = Phase.Transcribing;
            session.Finish(text =>
            {
                phase = Phase.Idle;
                if (text.Length == 0) return;
                history.Add(text);
                Log.Write($"dictation dropped; kept {text.Length} characters in History");
            });
            return;
        }
        session.Cancel();
        phase = Phase.Idle;
        if (deliberate) Sound.Play("stop");
    }
}
