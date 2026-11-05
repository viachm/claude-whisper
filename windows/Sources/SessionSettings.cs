using System.Text.Json;

namespace ClaudeWhisper;

static class SessionSettings
{
    /// Settings layered over the user's own for this session only: voice on, held key, never
    /// submit, and the dictation language when one is chosen in Claude Whisper. Not tap mode: there
    /// the stopping press sends the transcript to Claude as a message, whatever autoSubmit says.
    public static string Json(string language)
    {
        var settings = new SortedDictionary<string, object>
        {
            ["voice"] = new SortedDictionary<string, object> { ["autoSubmit"] = false, ["enabled"] = true, ["mode"] = "hold" },
        };
        if (language.Length > 0) settings["language"] = language;
        return JsonSerializer.Serialize(settings);
    }
}
