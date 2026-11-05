using System.Text.Json;

namespace ClaudeWhisper;

record Transcript(DateTime Date, string Text);

/// The last 30 dictations, newest first, in %APPDATA%\Claude Whisper\history.json. Pasting
/// into a window that had no text field loses the text, and the clipboard is put back right
/// after, so this is where it can still be found.
sealed class History
{
    public const int Limit = 30;

    public IReadOnlyList<Transcript> Entries => entries;
    public event Action? Changed;

    private List<Transcript> entries = new();
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public History()
    {
        try
        {
            if (File.Exists(Paths.History))
                entries = JsonSerializer.Deserialize<List<Transcript>>(File.ReadAllText(Paths.History), JsonOptions) ?? new();
        }
        catch (Exception e)
        {
            Log.Write($"could not read {Paths.History}: {e.Message}");
        }
    }

    public void Add(string text)
    {
        entries.Insert(0, new Transcript(DateTime.Now, text));
        if (entries.Count > Limit) entries.RemoveRange(Limit, entries.Count - Limit);
        Save();
    }

    public void Clear()
    {
        entries.Clear();
        Save();
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Paths.Roaming);
            File.WriteAllText(Paths.History, JsonSerializer.Serialize(entries, JsonOptions));
        }
        catch (Exception e)
        {
            Log.Write($"could not write {Paths.History}: {e.Message}");
        }
        Changed?.Invoke();
    }
}
