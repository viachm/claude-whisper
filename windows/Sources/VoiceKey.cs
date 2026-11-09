using System.Text.Json;

namespace ClaudeWhisper;

/// The key Claude Code listens to for hold-to-talk, as the bytes a terminal sends for it. Read
/// from the user's `~/.claude/keybindings.json` on every press, so Claude Whisper follows whatever
/// voice key this Claude Code install uses; without a custom binding it is Space, Claude Code's
/// default.
static class VoiceKey
{
    public const string Action = "voice:pushToTalk";

    public static string Bytes()
    {
        var key = ConfiguredKey();
        if (key == null) return " ";
        var encoded = Encode(key);
        if (encoded != null) return encoded;
        Log.Write($"voice key \"{key}\" can't be typed into a terminal; using Space");
        return " ";
    }

    private static string KeybindingsPath => Path.Combine(Paths.Home, ".claude", "keybindings.json");

    /// The last Chat binding for push-to-talk wins, the same rule Claude Code uses.
    public static string? ConfiguredKey()
    {
        try
        {
            if (!File.Exists(KeybindingsPath)) return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(KeybindingsPath), new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
            return ConfiguredKey(doc.RootElement);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static string? ConfiguredKey(JsonElement root)
    {
        if (!root.TryGetProperty("bindings", out var blocks) || blocks.ValueKind != JsonValueKind.Array) return null;
        string? found = null;
        foreach (var block in blocks.EnumerateArray())
        {
            if (!block.TryGetProperty("context", out var context) || context.GetString() != "Chat") continue;
            if (!block.TryGetProperty("bindings", out var bindings) || bindings.ValueKind != JsonValueKind.Object) continue;
            foreach (var binding in bindings.EnumerateObject())
                if (binding.Value.ValueKind == JsonValueKind.String && binding.Value.GetString() == Action) found = binding.Name;
        }
        return found;
    }

    /// `space`, `k`, `meta+k`/`alt+k`/`opt+k` (Esc prefix), `ctrl+k` (control character),
    /// `shift+k`. Keys a terminal sends as longer escape sequences are not supported.
    public static string? Encode(string binding)
    {
        var parts = binding.ToLowerInvariant().Split('+').ToList();
        if (parts.Count == 0) return null;
        var key = parts[^1];
        parts.RemoveAt(parts.Count - 1);
        string ch;
        if (key == "space") ch = " ";
        else if (key.Length == 1) ch = key;
        else return null;
        var prefix = "";
        foreach (var modifier in parts)
        {
            switch (modifier)
            {
                case "meta" or "alt" or "opt" or "option": prefix = "\u001b"; break;
                case "shift": ch = ch.ToUpperInvariant(); break;
                case "ctrl" or "control":
                    if (ch[0] > 127) return null;
                    ch = ((char)(ch[0] & 0x1f)).ToString();
                    break;
                default: return null;
            }
        }
        return prefix + ch;
    }
}
