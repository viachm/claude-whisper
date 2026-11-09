using System.Media;
using System.Reflection;
using System.Text;
using Microsoft.Win32;

namespace ClaudeWhisper;

/// Where the app keeps its files: settings and history roam with the profile, the log, the
/// workspace and the outbox stay on this machine.
static class Paths
{
    public const string AppName = "Claude Whisper";

    public static readonly string Roaming =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), AppName);
    public static readonly string Local =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName);
    public static readonly string Settings = Path.Combine(Roaming, "settings.json");
    public static readonly string History = Path.Combine(Roaming, "history.json");
    public static readonly string LogFile = Path.Combine(Local, AppName + ".log");
    public static readonly string Workspace = Path.Combine(Local, "workspace");
    public static readonly string Outbox = Path.Combine(Local, "outbox.txt");
    /// The capture script is written here and the folder is put on the hidden session's PATH.
    public static readonly string Bin = Path.Combine(Local, "bin");

    public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
}

static class Log
{
    private static readonly object Gate = new();

    public static void Write(string line)
    {
        var entry = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {line}{Environment.NewLine}";
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Paths.Local);
                File.AppendAllText(Paths.LogFile, entry, Encoding.UTF8);
            }
            catch (IOException) { }
        }
    }
}

/// The start and stop cues come from the chosen sound set (`<set>-start.wav`, `<set>-stop.wav`,
/// made by macos/tools/make-sounds.py and embedded here). SoundPlayer has no volume, so the
/// 16-bit samples are scaled before they are played.
static class Sound
{
    private static readonly Dictionary<string, byte[]> Cache = new();

    public static void Play(string name)
    {
        var prefs = Preferences.Shared;
        if (!prefs.PlaySounds) return;
        PlayFile($"{prefs.SoundSet}-{name}", prefs.SoundVolume);
    }

    /// Plays a set's start cue, for trying sets in Settings.
    public static void Preview(string set) => PlayFile($"{set}-start", Preferences.Shared.SoundVolume);

    public static readonly string[] Sets = { "chime", "soft", "click", "bubble", "glass" };

    private static void PlayFile(string file, double volume)
    {
        byte[]? wav = Load(file);
        if (wav == null)
        {
            Log.Write($"missing sound {file}");
            return;
        }
        // Loudness is heard logarithmically, so the slider is curved: its lower half gets very quiet.
        var gain = Math.Pow(Math.Clamp(volume, 0, 1), 2.5);
        var scaled = (byte[])wav.Clone();
        // Format chunk is at 12, data chunk follows at 36 for the plain PCM files make-sounds.py writes.
        var data = FindChunk(scaled, "data");
        if (data >= 0)
        {
            int length = BitConverter.ToInt32(scaled, data + 4);
            for (int i = data + 8; i + 1 < Math.Min(scaled.Length, data + 8 + length); i += 2)
            {
                short sample = (short)(scaled[i] | (scaled[i + 1] << 8));
                sample = (short)Math.Clamp(sample * gain, short.MinValue, short.MaxValue);
                scaled[i] = (byte)sample;
                scaled[i + 1] = (byte)(sample >> 8);
            }
        }
        try
        {
            // Load() reads the whole stream first, so a stream that lives only for this call is fine.
            using var player = new SoundPlayer(new MemoryStream(scaled));
            player.Load();
            player.Play();
        }
        catch (Exception e)
        {
            Log.Write($"could not play {file}: {e.Message}");
        }
    }

    private static int FindChunk(byte[] wav, string id)
    {
        int pos = 12;
        while (pos + 8 <= wav.Length)
        {
            if (Encoding.ASCII.GetString(wav, pos, 4) == id) return pos;
            pos += 8 + BitConverter.ToInt32(wav, pos + 4);
        }
        return -1;
    }

    private static byte[]? Load(string file)
    {
        lock (Cache)
        {
            if (Cache.TryGetValue(file, out var cached)) return cached;
            var bytes = Resources.Read($"sounds/{file}.wav");
            if (bytes != null) Cache[file] = bytes;
            return bytes;
        }
    }
}

/// Files embedded in the executable (the sounds and the capture script).
static class Resources
{
    public static byte[]? Read(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name);
        if (stream == null) return null;
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return buffer.ToArray();
    }
}

/// Open at login through the per-user Run key; no admin rights, no scheduled task.
static class Startup
{
    private const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "Claude Whisper";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(Key);
            return key?.GetValue(Name) is string value && value.Contains(Environment.ProcessPath ?? "", StringComparison.OrdinalIgnoreCase);
        }
    }

    public static void Set(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(Key);
            if (on) key.SetValue(Name, $"\"{Environment.ProcessPath}\"");
            else key.DeleteValue(Name, throwOnMissingValue: false);
        }
        catch (Exception e)
        {
            Log.Write($"could not change open at login: {e.Message}");
        }
    }
}
