using System.Diagnostics;
using System.Runtime.InteropServices;

namespace ClaudeWhisper;

/// Decides whether a dictation meant to be sent (a hold) gets Return after it is pasted: in the
/// Claude desktop app, and optionally in a console window whose process tree runs Claude Code.
/// Hands-free dictations never ask, so they are only inserted.
static class AutoSend
{
    /// The console hosts whose window can be in front; the shell and `claude` are their children.
    private static readonly HashSet<string> Consoles = new(StringComparer.OrdinalIgnoreCase)
    {
        "WindowsTerminal", "wt", "conhost", "OpenConsole", "cmd", "powershell", "pwsh", "mintty", "alacritty", "wezterm-gui", "Code",
    };

    public static IntPtr ForegroundWindow() => GetForegroundWindow();

    public static int ProcessIdOf(IntPtr window)
    {
        GetWindowThreadProcessId(window, out var pid);
        return (int)pid;
    }

    public static bool ShouldSend(IntPtr window)
    {
        var prefs = Preferences.Shared;
        if (!prefs.AutoSend || window == IntPtr.Zero) return false;
        int pid = ProcessIdOf(window);
        string name;
        try { name = Process.GetProcessById(pid).ProcessName; }
        catch (Exception) { return false; }
        // The Claude desktop app is Claude.exe.
        if (name.Equals("Claude", StringComparison.OrdinalIgnoreCase)) return true;
        if (!prefs.AutoSendTerminals || !Consoles.Contains(name)) return false;
        bool runs = TreeRunsClaude(pid);
        if (!runs) Log.Write($"auto-send: {name} is in front but no claude under it");
        return runs;
    }

    /// Whether a `claude` process descends from `root`. A terminal with several tabs cannot say
    /// which one is in front, so any tab counts; that is why this is off by default.
    private static bool TreeRunsClaude(int root)
    {
        var parents = new Dictionary<int, int>();
        var claudes = new List<int>();
        var snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == IntPtr.Zero || snapshot == (IntPtr)(-1)) return false;
        try
        {
            var entry = new PROCESSENTRY32 { dwSize = (uint)Marshal.SizeOf<PROCESSENTRY32>() };
            if (!Process32First(snapshot, ref entry)) return false;
            do
            {
                parents[(int)entry.th32ProcessID] = (int)entry.th32ParentProcessID;
                if (entry.szExeFile.Equals("claude.exe", StringComparison.OrdinalIgnoreCase)) claudes.Add((int)entry.th32ProcessID);
            } while (Process32Next(snapshot, ref entry));
        }
        finally { CloseHandle(snapshot); }

        foreach (var claude in claudes)
        {
            int pid = claude;
            for (int depth = 0; depth < 20 && parents.TryGetValue(pid, out var parent) && parent != 0; depth++)
            {
                if (parent == root) return true;
                pid = parent;
            }
        }
        return false;
    }

    private const uint TH32CS_SNAPPROCESS = 0x2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PROCESSENTRY32
    {
        public uint dwSize, cntUsage, th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "Process32FirstW")]
    private static extern bool Process32First(IntPtr snapshot, ref PROCESSENTRY32 entry);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "Process32NextW")]
    private static extern bool Process32Next(IntPtr snapshot, ref PROCESSENTRY32 entry);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}
