using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

namespace ClaudeWhisper;

/// Checks GitHub for a newer release and installs it when asked: downloads the Windows zip for
/// this architecture, checks its SHA-256, puts the new .exe in place of this one (a running .exe
/// can be renamed, not overwritten) and starts it. These are the only network requests the app
/// makes itself, all to GitHub, and only when "Check for Updates…" is clicked.
sealed class Updater
{
    private const string LatestUrl = "https://api.github.com/repos/viachm/claude-whisper/releases/latest";
    private const string ReleasesPage = "https://github.com/viachm/claude-whisper/releases/latest";
    private static readonly HttpClient Http = CreateClient();

    public sealed record Release(Version Version, string Page, string AssetUrl, string? Sha256);

    /// Shown in the menu: "Update to 0.1.10…" once a check found one.
    public Release? Available { get; private set; }
    public event Action? Changed;
    /// How the app quits for the restart; set to the tray app's own exit so it cleans up.
    public Action Quit = Application.Exit;
    private bool busy;

    public static Version Current
    {
        get
        {
            var v = Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0, 0);
            return new Version(v.Major, v.Minor, Math.Max(0, v.Build));
        }
    }

    public static string AssetName => RuntimeInformation.ProcessArchitecture == Architecture.Arm64
        ? "Claude-Whisper-Windows-arm64.zip" : "Claude-Whisper-Windows.zip";

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"Claude-Whisper/{Current}");
        return client;
    }

    /// A leftover from the last update: the old .exe, renamed out of the way while it was running.
    public static void CleanUp()
    {
        try { File.Delete(Environment.ProcessPath + ".old"); } catch { }
    }

    /// From the menu: says so when there is nothing new or the check failed.
    public async Task Check()
    {
        if (busy) return;
        busy = true;
        Release? release = null;
        string? problem = null;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, LatestUrl);
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            using var response = await Http.SendAsync(request);
            if (!response.IsSuccessStatusCode) problem = $"HTTP {(int)response.StatusCode}";
            else release = Parse(await response.Content.ReadAsStringAsync(), AssetName);
            if (release == null) problem ??= "no usable release";
        }
        catch (Exception e) { problem = e.Message; }
        finally { busy = false; }

        if (release == null)
        {
            Log.Write($"update check failed: {problem}");
            Tell("Couldn't check for updates", "GitHub didn't answer. Try again later, or see the releases page.", ReleasesPage);
            return;
        }
        Log.Write($"update check: latest {release.Version}, running {Current}");
        Available = release.Version > Current ? release : null;
        Changed?.Invoke();
        Offer();
    }

    /// The parts of GitHub's "latest release" answer the updater needs, or null.
    public static Release? Parse(string json, string assetName)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var tag = root.GetProperty("tag_name").GetString() ?? "";
        if (!Version.TryParse(tag.TrimStart('v', 'V').Split('-')[0], out var version)) return null;
        var page = root.TryGetProperty("html_url", out var p) ? p.GetString() ?? ReleasesPage : ReleasesPage;
        foreach (var asset in root.GetProperty("assets").EnumerateArray())
        {
            if (asset.GetProperty("name").GetString() != assetName) continue;
            var url = asset.GetProperty("browser_download_url").GetString();
            if (url == null) return null;
            string? sha = null;
            if (asset.TryGetProperty("digest", out var d) && d.ValueKind == JsonValueKind.String
                && d.GetString()!.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
                sha = d.GetString()!["sha256:".Length..].ToLowerInvariant();
            return new Release(new Version(version.Major, version.Minor, Math.Max(0, version.Build)), page, url, sha);
        }
        return null;
    }

    /// The menu item while an update is known: asks, then installs.
    public void Offer()
    {
        if (Available is not { } release)
        {
            MessageBox.Show($"Version {Current} is the latest.", "Claude Whisper is up to date", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        var answer = MessageBox.Show(
            $"Claude Whisper {release.Version} is available (you have {Current}).\n\n" +
            "Yes: download it from GitHub, quit and open the new version.\nNo: open the release notes.",
            "Update available", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Information);
        if (answer == DialogResult.Yes) _ = Install(release);
        else if (answer == DialogResult.No) Open(release.Page);
    }

    private async Task Install(Release release)
    {
        if (busy) return;
        busy = true;
        var exe = Environment.ProcessPath!;
        var folder = Path.Combine(Path.GetTempPath(), "claude-whisper-update-" + Guid.NewGuid().ToString("N"));
        string newExe;
        try
        {
            Directory.CreateDirectory(folder);
            var zip = Path.Combine(folder, AssetName);
            Log.Write($"downloading {release.AssetUrl}");
            var bytes = await Http.GetByteArrayAsync(release.AssetUrl);
            if (release.Sha256 != null && Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() != release.Sha256)
                throw new InvalidDataException("The download is damaged (its SHA-256 doesn't match GitHub's).");
            await File.WriteAllBytesAsync(zip, bytes);
            ZipFile.ExtractToDirectory(zip, folder);
            newExe = Path.Combine(folder, Path.GetFileName(exe));
            if (!File.Exists(newExe)) throw new InvalidDataException("The zip didn't contain the app.");

            // The running .exe can be renamed but not overwritten; the old one is deleted at the next start.
            var old = exe + ".old";
            File.Delete(old);
            File.Move(exe, old);
            try { File.Copy(newExe, exe); }
            catch { File.Move(old, exe); throw; }
        }
        catch (Exception e)
        {
            busy = false;
            Log.Write($"update failed: {e.Message}");
            Tell("The update wasn't installed", e.Message + " You can download it from GitHub instead.", release.Page);
            return;
        }
        Log.Write("installed the update; restarting");
        // The new copy waits for this one's single-instance lock to be released.
        Process.Start(new ProcessStartInfo(exe, "--after-update") { UseShellExecute = false });
        Quit();
    }

    private static void Tell(string title, string text, string page)
    {
        if (MessageBox.Show(text + "\n\nOpen the releases page?", title, MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
            Open(page);
    }

    private static void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write($"could not open {url}: {e.Message}"); }
    }
}
