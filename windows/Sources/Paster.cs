using System.Runtime.InteropServices;

namespace ClaudeWhisper;

/// Hands the text to whichever window has focus: puts it on the clipboard, presses Ctrl+V
/// (optionally Return after, to send a chat message) and puts the previous clipboard back.
static class Paster
{
    /// Marks the key events Claude Whisper sends, so its own hook ignores them. "CLWH".
    public static readonly UIntPtr Tag = (UIntPtr)0x434C5748;

    /// How long after the paste Return goes out, so the app has taken the text first.
    public const double ReturnDelay = 0.08;

    public static void Deliver(string text, bool restoreClipboard)
    {
        DataObject? saved = restoreClipboard ? Snapshot() : null;
        try
        {
            Clipboard.SetDataObject(new DataObject(DataFormats.UnicodeText, text), true, 10, 50);
        }
        catch (Exception e)
        {
            Log.Write($"could not set the clipboard: {e.Message}");
            return;
        }
        Press(new[] { (VK_CONTROL, true), (VK_V, true), (VK_V, false), (VK_CONTROL, false) });
        if (saved == null) return;
        Ui.After(0.8, () =>
        {
            try
            {
                if (saved.GetFormats().Length == 0) Clipboard.Clear();
                else Clipboard.SetDataObject(saved, true, 10, 50);
            }
            catch (Exception e)
            {
                Log.Write($"could not put the clipboard back: {e.Message}");
            }
        });
    }

    public static void PressReturn() => Press(new[] { (VK_RETURN, true), (VK_RETURN, false) });

    /// A key no app reacts to, pressed so that a lone Alt is not a menu-bar tap.
    public static void PressSilentKey() => Press(new[] { (VK_SILENT, true), (VK_SILENT, false) });

    /// Copies what is on the clipboard now; the data object the clipboard hands out is a live view
    /// that goes stale once the clipboard changes.
    private static DataObject? Snapshot()
    {
        try
        {
            var current = Clipboard.GetDataObject();
            var copy = new DataObject();
            if (current == null) return copy;
            foreach (var format in current.GetFormats(false))
            {
                try
                {
                    var data = current.GetData(format, false);
                    if (data != null) copy.SetData(format, false, data);
                }
                catch (Exception)
                {
                    // Formats some apps advertise but cannot deliver; they are not restored.
                }
            }
            return copy;
        }
        catch (Exception e)
        {
            Log.Write($"could not read the clipboard: {e.Message}");
            return null;
        }
    }

    private static void Press((int vk, bool down)[] keys)
    {
        var inputs = new INPUT[keys.Length];
        for (int i = 0; i < keys.Length; i++)
        {
            inputs[i].type = INPUT_KEYBOARD;
            inputs[i].u.ki.wVk = (ushort)keys[i].vk;
            inputs[i].u.ki.dwFlags = keys[i].down ? 0 : KEYEVENTF_KEYUP;
            inputs[i].u.ki.dwExtraInfo = Tag;
        }
        if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>()) != inputs.Length)
            Log.Write($"SendInput failed ({Marshal.GetLastWin32Error()})");
    }

    private const int VK_RETURN = 0x0D, VK_CONTROL = 0x11, VK_V = 0x56, VK_SILENT = 0xE8;
    private const int INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public int type;
        public INPUTUNION u;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
}
