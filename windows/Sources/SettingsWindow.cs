namespace ClaudeWhisper;

/// Settings: the dictation key and mode, auto-send, feedback, open at login, the Claude Code path
/// and language, and the full History. Plain WinForms controls bound by hand to Preferences.
sealed class SettingsWindow : Form
{
    public enum Tab { General, Claude, History }

    private readonly Preferences prefs = Preferences.Shared;
    private readonly History history;
    private readonly TabControl tabs = new() { Dock = DockStyle.Fill };
    private readonly ComboBox trigger = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 160 };
    private readonly TextBox shortcut = new() { ReadOnly = true, Width = 160, Cursor = Cursors.Hand };
    private readonly Label lockHint = new() { AutoSize = true, ForeColor = SystemColors.GrayText };
    private readonly RadioButton hold = new() { Text = "Hold to talk", AutoSize = true };
    private readonly RadioButton tap = new() { Text = "Tap to start, tap to stop", AutoSize = true };
    private readonly CheckBox autoSend = new() { Text = "Press Enter after a held dictation into the Claude app", AutoSize = true };
    private readonly CheckBox autoSendTerminals = new() { Text = "Also into a console running Claude Code (any tab counts)", AutoSize = true };
    private readonly CheckBox restoreClipboard = new() { Text = "Put the clipboard back after pasting", AutoSize = true };
    private readonly CheckBox sounds = new() { Text = "Sounds", AutoSize = true };
    private readonly ComboBox soundSet = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 100 };
    private readonly TrackBar volume = new() { Minimum = 0, Maximum = 100, TickFrequency = 25, Width = 160, AutoSize = false, Height = 28 };
    private readonly CheckBox overlay = new() { Text = "Show the capsule while dictating", AutoSize = true };
    private readonly CheckBox login = new() { Text = "Open at login", AutoSize = true };
    private readonly TextBox claudePath = new() { Width = 360 };
    private readonly ComboBox language = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 160 };
    private readonly Label sessionState = new() { AutoSize = true };
    private readonly ListBox historyList = new() { Dock = DockStyle.Fill, HorizontalScrollbar = true };
    private bool loading;

    public SettingsWindow(History history, Action restartSession, Action openLog)
    {
        this.history = history;
        Text = "Claude Whisper Settings";
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ClientSize = new Size(520, 440);
        Font = new Font("Segoe UI", 9.5f);
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? Icon;
        AutoScaleMode = AutoScaleMode.Dpi;

        tabs.TabPages.Add(GeneralPage());
        tabs.TabPages.Add(ClaudePage(restartSession, openLog));
        tabs.TabPages.Add(HistoryPage());
        Controls.Add(tabs);

        history.Changed += FillHistory;
        Load += (_, _) => Fill();
        // Closing hides, so the window and its state survive; Quit is in the tray menu.
        FormClosing += (_, e) =>
        {
            if (e.CloseReason != CloseReason.UserClosing) return;
            e.Cancel = true;
            Hide();
        };
    }

    public void Open(Tab tab)
    {
        tabs.SelectedIndex = (int)tab;
        if (!Visible) Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
    }

    public void ShowSessionState(ClaudeSession.State state) => sessionState.Text = state switch
    {
        ClaudeSession.State.Ready => "Claude session: ready",
        ClaudeSession.State.Starting => "Claude session: starting…",
        _ => File.Exists(prefs.ResolvedClaudePath) ? "Claude session: stopped" : "Claude session: claude not found at the path above",
    };

    // MARK: Pages

    private static TableLayoutPanel Grid()
    {
        var grid = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, AutoScroll = true, Padding = new Padding(12, 10, 12, 10) };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 120));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        return grid;
    }

    private static void Row(TableLayoutPanel grid, string title, Control control)
    {
        int row = grid.RowCount++;
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        grid.Controls.Add(new Label { Text = title, AutoSize = true, Margin = new Padding(0, 6, 8, 6), ForeColor = SystemColors.ControlText }, 0, row);
        control.Margin = new Padding(0, 3, 0, 3);
        grid.Controls.Add(control, 1, row);
    }

    private static FlowLayoutPanel Flow(params Control[] controls)
    {
        var flow = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = true, Margin = Padding.Empty };
        foreach (var c in controls)
        {
            c.Margin = new Padding(0, 3, 8, 3);
            flow.Controls.Add(c);
        }
        return flow;
    }

    private static FlowLayoutPanel Column(params Control[] controls)
    {
        var flow = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Margin = Padding.Empty };
        foreach (var c in controls)
        {
            c.Margin = new Padding(0, 3, 0, 3);
            flow.Controls.Add(c);
        }
        return flow;
    }

    private TabPage GeneralPage()
    {
        var page = new TabPage("General");
        var grid = Grid();

        trigger.Items.AddRange(new object[] { "Right Ctrl", "Right Alt", "Shortcut…" });
        trigger.SelectedIndexChanged += (_, _) => { if (!loading) prefs.Trigger = (TriggerKey)trigger.SelectedIndex; Fill(); };
        shortcut.GotFocus += (_, _) => { prefs.IsRecordingShortcut = true; shortcut.Text = "Press a shortcut (Esc cancels)"; };
        shortcut.LostFocus += (_, _) => { prefs.IsRecordingShortcut = false; Fill(); };
        shortcut.KeyDown += RecordShortcut;
        shortcut.PreviewKeyDown += (_, e) => e.IsInputKey = true;
        Row(grid, "Dictation key", Flow(trigger, shortcut));
        Row(grid, "", lockHint);
        hold.CheckedChanged += (_, _) => { if (!loading && hold.Checked) prefs.Mode = HotkeyMode.Hold; Fill(); };
        tap.CheckedChanged += (_, _) => { if (!loading && tap.Checked) prefs.Mode = HotkeyMode.Toggle; };
        Row(grid, "Mode", Column(hold, tap));

        autoSend.CheckedChanged += (_, _) => { if (!loading) prefs.AutoSend = autoSend.Checked; autoSendTerminals.Enabled = autoSend.Checked; };
        autoSendTerminals.CheckedChanged += (_, _) => { if (!loading) prefs.AutoSendTerminals = autoSendTerminals.Checked; };
        Row(grid, "Auto-send", Column(autoSend, autoSendTerminals));
        restoreClipboard.CheckedChanged += (_, _) => { if (!loading) prefs.RestoreClipboard = restoreClipboard.Checked; };
        Row(grid, "Text", restoreClipboard);

        sounds.CheckedChanged += (_, _) => { if (!loading) prefs.PlaySounds = sounds.Checked; soundSet.Enabled = volume.Enabled = sounds.Checked; };
        soundSet.Items.AddRange(Sound.Sets.Select(s => (object)Capitalise(s)).ToArray());
        soundSet.SelectedIndexChanged += (_, _) =>
        {
            if (loading) return;
            prefs.SoundSet = Sound.Sets[soundSet.SelectedIndex];
            Sound.Preview(prefs.SoundSet);
        };
        volume.ValueChanged += (_, _) => { if (!loading) prefs.SoundVolume = volume.Value / 100.0; };
        volume.MouseUp += (_, _) => Sound.Preview(prefs.SoundSet);
        overlay.CheckedChanged += (_, _) => { if (!loading) prefs.ShowOverlay = overlay.Checked; };
        Row(grid, "Feedback", Column(Flow(sounds, soundSet, volume), overlay));
        login.CheckedChanged += (_, _) => { if (!loading) Startup.Set(login.Checked); };
        Row(grid, "Startup", login);

        page.Controls.Add(grid);
        return page;
    }

    private TabPage ClaudePage(Action restartSession, Action openLog)
    {
        var page = new TabPage("Claude");
        var grid = Grid();

        claudePath.PlaceholderText = Preferences.DefaultClaudePath;
        claudePath.Leave += (_, _) => { if (!loading) prefs.ClaudePath = claudePath.Text.Trim(); Fill(); };
        var browse = new Button { Text = "Browse…", AutoSize = true };
        browse.Click += (_, _) =>
        {
            using var dialog = new OpenFileDialog { Filter = "claude|claude.exe;claude.cmd|All files|*.*", Title = "Where is Claude Code?" };
            if (dialog.ShowDialog(this) == DialogResult.OK) prefs.ClaudePath = dialog.FileName;
            Fill();
        };
        Row(grid, "claude", Column(Flow(claudePath, browse),
            new Label { Text = "Empty: the first install found (~\\.local\\bin, npm, PATH).", AutoSize = true, ForeColor = SystemColors.GrayText }));

        language.Items.Add("Claude's own setting");
        language.Items.AddRange(Preferences.Languages.Select(l => (object)Capitalise(l)).ToArray());
        language.SelectedIndexChanged += (_, _) =>
        {
            if (loading) return;
            prefs.Language = language.SelectedIndex <= 0 ? "" : Preferences.Languages[language.SelectedIndex - 1];
        };
        Row(grid, "Dictation language", language);

        var restart = new Button { Text = "Restart Claude Session", AutoSize = true };
        restart.Click += (_, _) => restartSession();
        var log = new Button { Text = "Open Log", AutoSize = true };
        log.Click += (_, _) => openLog();
        Row(grid, "Session", Column(sessionState, Flow(restart, log)));
        Row(grid, "", new Label
        {
            Text = "The hidden session runs claude with voice on, in hold mode and without auto-submit, in\n" + Paths.Workspace,
            AutoSize = true, ForeColor = SystemColors.GrayText,
        });

        page.Controls.Add(grid);
        return page;
    }

    private TabPage HistoryPage()
    {
        var page = new TabPage("History");
        var panel = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Padding = new Padding(8) };
        panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        panel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        historyList.DoubleClick += (_, _) => CopySelected();
        panel.Controls.Add(historyList, 0, 0);
        var copy = new Button { Text = "Copy", AutoSize = true };
        copy.Click += (_, _) => CopySelected();
        var clear = new Button { Text = "Clear History", AutoSize = true };
        clear.Click += (_, _) => history.Clear();
        panel.Controls.Add(Flow(copy, clear, new Label { Text = "Double-click an entry to copy it.", AutoSize = true, ForeColor = SystemColors.GrayText, Padding = new Padding(0, 5, 0, 0) }), 0, 1);
        page.Controls.Add(panel);
        return page;
    }

    // MARK: Binding

    private void Fill()
    {
        loading = true;
        try
        {
            trigger.SelectedIndex = (int)prefs.Trigger;
            shortcut.Visible = prefs.Trigger == TriggerKey.Shortcut;
            if (!prefs.IsRecordingShortcut) shortcut.Text = prefs.Shortcut.Display;
            hold.Checked = prefs.Mode == HotkeyMode.Hold;
            tap.Checked = prefs.Mode == HotkeyMode.Toggle;
            lockHint.Text = prefs.Trigger == TriggerKey.Shortcut || prefs.Mode != HotkeyMode.Hold
                ? "Esc cancels a dictation."
                : $"While holding, {Hotkey.KeyTitle(Hotkey.PartnerVk(prefs.Trigger))} locks the dictation on; tap {Hotkey.KeyTitle(Hotkey.TriggerVk(prefs.Trigger))} to stop. Esc cancels.";
            autoSend.Checked = prefs.AutoSend;
            autoSendTerminals.Checked = prefs.AutoSendTerminals;
            autoSendTerminals.Enabled = prefs.AutoSend;
            restoreClipboard.Checked = prefs.RestoreClipboard;
            sounds.Checked = prefs.PlaySounds;
            soundSet.SelectedIndex = Math.Max(0, Array.IndexOf(Sound.Sets, prefs.SoundSet));
            volume.Value = (int)Math.Round(Math.Clamp(prefs.SoundVolume, 0, 1) * 100);
            soundSet.Enabled = volume.Enabled = prefs.PlaySounds;
            overlay.Checked = prefs.ShowOverlay;
            login.Checked = Startup.IsEnabled;
            claudePath.Text = prefs.ClaudePath;
            claudePath.PlaceholderText = Preferences.DefaultClaudePath;
            language.SelectedIndex = Math.Max(0, Array.IndexOf(Preferences.Languages, prefs.Language) + 1);
            FillHistory();
        }
        finally { loading = false; }
    }

    private void FillHistory()
    {
        historyList.BeginUpdate();
        historyList.Items.Clear();
        foreach (var entry in history.Entries)
            historyList.Items.Add($"{entry.Date:d MMM HH:mm}  {System.Text.RegularExpressions.Regex.Replace(entry.Text, "\\s+", " ")}");
        historyList.EndUpdate();
    }

    private void CopySelected()
    {
        if (historyList.SelectedIndex < 0 || historyList.SelectedIndex >= history.Entries.Count) return;
        try { Clipboard.SetText(history.Entries[historyList.SelectedIndex].Text); }
        catch (Exception e) { Log.Write($"could not copy: {e.Message}"); }
    }

    /// A key with its modifiers becomes the shortcut; a modifier on its own waits for the key.
    private void RecordShortcut(object? sender, KeyEventArgs e)
    {
        e.Handled = e.SuppressKeyPress = true;
        var key = e.KeyCode;
        if (key is Keys.ControlKey or Keys.ShiftKey or Keys.Menu or Keys.LWin or Keys.RWin or Keys.None) return;
        if (key == Keys.Escape)
        {
            tabs.Focus();
            return;
        }
        var modifiers = Modifiers.None;
        if (e.Control) modifiers |= Modifiers.Control;
        if (e.Alt) modifiers |= Modifiers.Alt;
        if (e.Shift) modifiers |= Modifiers.Shift;
        if (modifiers == Modifiers.None && key is not (>= Keys.F1 and <= Keys.F24))
        {
            shortcut.Text = "Add Ctrl, Alt or Shift (or use an F key)";
            return;
        }
        prefs.Shortcut = new KeyCombo((int)key, modifiers, KeyCombo.NameOf(key));
        tabs.Focus();
    }

    private static string Capitalise(string s) => s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..];
}
