using System.Text.Json;
using System.Text.Json.Serialization;

namespace ClaudeWhisper;

/// The key that starts dictation. A modifier key counts when pressed on its own, so it keeps
/// working as a modifier; a recorded shortcut is swallowed before the focused app sees it.
enum TriggerKey { RightControl, RightAlt, Shortcut }

enum HotkeyMode
{
    /// Hold to talk, release to type. Right Alt while holding keeps it listening after the key is let go.
    Hold,
    /// Tap to start, tap again to type.
    Toggle,
}

/// A key plus the modifiers held with it, as recorded in Settings.
record struct KeyCombo(int KeyCode, Modifiers Modifiers, string KeyName)
{
    public static readonly KeyCombo ControlAltSpace = new((int)Keys.Space, Modifiers.Control | Modifiers.Alt, "Space");

    public string Display
    {
        get
        {
            var s = "";
            if (Modifiers.HasFlag(Modifiers.Control)) s += "Ctrl+";
            if (Modifiers.HasFlag(Modifiers.Alt)) s += "Alt+";
            if (Modifiers.HasFlag(Modifiers.Shift)) s += "Shift+";
            if (Modifiers.HasFlag(Modifiers.Windows)) s += "Win+";
            return s + KeyName;
        }
    }

    public static string NameOf(Keys key) => key switch
    {
        Keys.Space => "Space",
        Keys.Return => "Enter",
        Keys.Escape => "Esc",
        Keys.Back => "Backspace",
        Keys.Delete => "Delete",
        Keys.Tab => "Tab",
        Keys.PageUp => "Page Up",
        Keys.PageDown => "Page Down",
        Keys.Oemtilde => "`",
        Keys.OemMinus => "-",
        Keys.Oemplus => "=",
        Keys.OemOpenBrackets => "[",
        Keys.OemCloseBrackets => "]",
        Keys.OemPipe => "\\",
        Keys.OemSemicolon => ";",
        Keys.OemQuotes => "'",
        Keys.Oemcomma => ",",
        Keys.OemPeriod => ".",
        Keys.OemQuestion => "/",
        >= Keys.D0 and <= Keys.D9 => ((char)('0' + (key - Keys.D0))).ToString(),
        _ => key.ToString(),
    };
}

[Flags]
enum Modifiers { None = 0, Control = 1, Alt = 2, Shift = 4, Windows = 8 }

/// Everything the user can change in Settings, kept in %APPDATA%\Claude Whisper\settings.json.
/// Each property writes the file back on change and tells the app what changed, so it can re-arm
/// the hotkey or restart the Claude session.
sealed class Preferences
{
    public static readonly Preferences Shared = Load();

    /// Dictation languages Claude Code's voice mode accepts; anything else falls back to English.
    public static readonly string[] Languages =
    {
        "english", "ukrainian", "spanish", "french", "german", "portuguese", "italian", "dutch",
        "polish", "czech", "russian", "greek", "turkish", "danish", "swedish", "norwegian",
        "japanese", "korean", "hindi", "indonesian",
    };

    public event Action<string>? Changed;

    private TriggerKey trigger = TriggerKey.RightControl;
    private KeyCombo shortcut = KeyCombo.ControlAltSpace;
    private HotkeyMode mode = HotkeyMode.Hold;
    private bool autoSend = true;
    private bool autoSendTerminals = false;
    private bool restoreClipboard = true;
    private bool playSounds = true;
    private string soundSet = "click";
    private double soundVolume = 0.6;
    private bool showOverlay = true;
    private string claudePath = "";
    private string language = "";

    public TriggerKey Trigger { get => trigger; set => Set(ref trigger, value); }
    public KeyCombo Shortcut { get => shortcut; set => Set(ref shortcut, value); }
    public HotkeyMode Mode { get => mode; set => Set(ref mode, value); }
    /// Press Return after pasting a held dictation into the Claude desktop app.
    public bool AutoSend { get => autoSend; set => Set(ref autoSend, value); }
    /// Also into a console window whose process tree runs Claude Code. Off by default: a
    /// terminal with several tabs cannot tell which tab is in front, and Return in a shell runs
    /// whatever was dictated.
    public bool AutoSendTerminals { get => autoSendTerminals; set => Set(ref autoSendTerminals, value); }
    public bool RestoreClipboard { get => restoreClipboard; set => Set(ref restoreClipboard, value); }
    public bool PlaySounds { get => playSounds; set => Set(ref playSounds, value); }
    public string SoundSet { get => soundSet; set => Set(ref soundSet, value); }
    /// The slider position, 0…1; Sound curves it into the playback volume.
    public double SoundVolume { get => soundVolume; set => Set(ref soundVolume, value); }
    public bool ShowOverlay { get => showOverlay; set => Set(ref showOverlay, value); }
    /// Empty means the first install found (`DefaultClaudePath`).
    public string ClaudePath { get => claudePath; set => Set(ref claudePath, value); }
    /// Claude Code's `language` setting for this session only; empty leaves Claude's own setting.
    public string Language { get => language; set => Set(ref language, value); }

    /// True while a shortcut field is recording, so the live hotkey does not fire meanwhile.
    [JsonIgnore]
    public bool IsRecordingShortcut { get => isRecordingShortcut; set => Set(ref isRecordingShortcut, value, save: false); }
    private bool isRecordingShortcut;

    /// The first Claude Code install found in the usual places: the native installer, npm's
    /// global folder, then PATH.
    public static string DefaultClaudePath
    {
        get
        {
            var npm = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm");
            var candidates = new List<string>
            {
                Path.Combine(Paths.Home, ".local", "bin", "claude.exe"),
                // npm's postinstall puts the native binary here; the claude.cmd shim next to it only runs it.
                Path.Combine(npm, "node_modules", "@anthropic-ai", "claude-code", "bin", "claude.exe"),
                Path.Combine(npm, "claude.cmd"),
            };
            foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
            {
                candidates.Add(Path.Combine(dir.Trim(), "claude.exe"));
                candidates.Add(Path.Combine(dir.Trim(), "claude.cmd"));
            }
            return candidates.FirstOrDefault(File.Exists) ?? candidates[0];
        }
    }

    public string ResolvedClaudePath
    {
        get
        {
            var path = ClaudePath.Trim().Trim('"');
            return path.Length == 0 ? DefaultClaudePath : Environment.ExpandEnvironmentVariables(path);
        }
    }

    private void Set<T>(ref T field, T value, bool save = true, [System.Runtime.CompilerServices.CallerMemberName] string name = "")
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        if (save) Save();
        Changed?.Invoke(name);
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
        IncludeFields = false,
    };

    private static Preferences Load()
    {
        try
        {
            if (File.Exists(Paths.Settings))
                return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(Paths.Settings), JsonOptions) ?? new Preferences();
        }
        catch (Exception e)
        {
            Log.Write($"could not read {Paths.Settings}: {e.Message}");
        }
        return new Preferences();
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Paths.Roaming);
            File.WriteAllText(Paths.Settings, JsonSerializer.Serialize(this, JsonOptions));
        }
        catch (Exception e)
        {
            Log.Write($"could not write {Paths.Settings}: {e.Message}");
        }
    }
}
