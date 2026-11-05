using System.Runtime.InteropServices;

namespace ClaudeWhisper;

/// Watches the dictation key system-wide through a low-level keyboard hook and turns it into
/// start, stop and cancel, following the chosen mode. A modifier key (Right Ctrl, Right Alt) only
/// counts when pressed on its own: any other key while it is down means it is being used as a
/// modifier, so the dictation is dropped quietly. A recorded shortcut is swallowed by the hook, so
/// the keystroke does not also reach the focused app. Esc cancels in every mode.
///
/// In hold mode a modifier trigger has a lock key (Right Alt, or Right Ctrl when Right Alt is the
/// trigger): pressed while holding, it keeps the dictation listening after the trigger is let go,
/// until the trigger is tapped again. A double-tap of the trigger locks it on straight away.
sealed class Hotkey : IDisposable
{
    public record Config(TriggerKey Trigger, KeyCombo Shortcut, HotkeyMode Mode);

    public event Action? OnStart;
    /// `held` is true for a press-and-hold that was let go, false for a locked or tap-mode
    /// dictation stopped by a tap.
    public event Action<bool>? OnStop;
    public event Action<bool>? OnCancel;
    public event Action? OnLock;
    /// Whether the app is still recording. A tap or hands-free state is dropped once it is not
    /// (Claude never started listening, the session restarted), so the next press starts afresh.
    public Func<bool> IsRecording = () => false;

    private enum Gesture
    {
        Idle,
        /// Pressed from idle; dictation has started.
        Down,
        /// Hold mode: a short tap, waiting to see whether a second one follows (double-tap = lock).
        AwaitingSecondTap,
        /// The second tap of a double-tap is still down.
        SecondTapDown,
        /// Locked, or tap mode: recording until the next tap.
        HandsFree,
        /// Pressed while hands-free; a clean release stops, one with other keys in between was the
        /// key used as a modifier.
        StopDown,
    }

    /// Held at least this long, a press is a hold rather than a tap.
    private static readonly TimeSpan TapLength = TimeSpan.FromSeconds(0.3);
    private static readonly TimeSpan DoubleTapWindow = TimeSpan.FromSeconds(0.35);

    private Config? config;
    private Gesture gesture = Gesture.Idle;
    private DateTime downSince;
    private bool stopInterrupted;
    private IDisposable? secondTapTimeout;
    private bool triggerDown;
    private bool partnerDown;
    private IntPtr hook;
    private readonly LowLevelKeyboardProc callback;

    public Hotkey() => callback = Handle;

    /// (Re)arms with `config`, dropping any dictation in progress. The hook is installed once and
    /// kept; it is the config that decides what the keys mean.
    public void Arm(Config config)
    {
        if (gesture != Gesture.Idle) Cancel(deliberate: false);
        this.config = config;
        triggerDown = false;
        partnerDown = false;
        if (hook == IntPtr.Zero)
        {
            hook = SetWindowsHookEx(WH_KEYBOARD_LL, callback, GetModuleHandle(null), 0);
            if (hook == IntPtr.Zero) Log.Write($"could not install the keyboard hook ({Marshal.GetLastWin32Error()})");
        }
    }

    public void Disarm()
    {
        if (gesture != Gesture.Idle) Cancel(deliberate: false);
        config = null;
        triggerDown = false;
        partnerDown = false;
    }

    public void Dispose()
    {
        Disarm();
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
    }

    // MARK: Keys

    public static int TriggerVk(TriggerKey trigger) => trigger switch
    {
        TriggerKey.RightControl => VK_RCONTROL,
        TriggerKey.RightAlt => VK_RMENU,
        _ => 0,
    };

    /// The lock key; a shortcut has none.
    public static int PartnerVk(TriggerKey trigger) => trigger switch
    {
        TriggerKey.RightControl => VK_RMENU,
        TriggerKey.RightAlt => VK_RCONTROL,
        _ => 0,
    };

    public static string KeyTitle(int vk) => vk switch
    {
        VK_RCONTROL => "Right Ctrl",
        VK_RMENU => "Right Alt",
        _ => ((Keys)vk).ToString(),
    };

    private static readonly int[] ModifierVks =
        { VK_LCONTROL, VK_RCONTROL, VK_LMENU, VK_RMENU, VK_LSHIFT, VK_RSHIFT, VK_LWIN, VK_RWIN };

    private static bool IsModifier(int vk) => Array.IndexOf(ModifierVks, vk) >= 0;

    private static bool IsDown(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;

    /// Whether any modifier other than the ones named is held right now.
    private static bool OtherModifiersDown(params int[] except)
    {
        foreach (var vk in ModifierVks)
            if (Array.IndexOf(except, vk) < 0 && IsDown(vk)) return true;
        return false;
    }

    private static Modifiers CurrentModifiers()
    {
        var m = Modifiers.None;
        if (IsDown(VK_LCONTROL) || IsDown(VK_RCONTROL)) m |= Modifiers.Control;
        if (IsDown(VK_LMENU) || IsDown(VK_RMENU)) m |= Modifiers.Alt;
        if (IsDown(VK_LSHIFT) || IsDown(VK_RSHIFT)) m |= Modifiers.Shift;
        if (IsDown(VK_LWIN) || IsDown(VK_RWIN)) m |= Modifiers.Windows;
        return m;
    }

    private IntPtr Handle(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code != 0 || config == null) return CallNextHookEx(hook, code, wParam, lParam);
        var key = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        // Keys Claude Whisper types itself (Ctrl+V, Return, the Alt companion) are not the user's.
        if (key.dwExtraInfo == Paster.Tag) return CallNextHookEx(hook, code, wParam, lParam);
        int message = (int)wParam;
        bool down = message is WM_KEYDOWN or WM_SYSKEYDOWN;
        int vk = Normalise(key);
        bool swallow = false;
        try
        {
            swallow = Key(vk, down, key);
        }
        catch (Exception e)
        {
            Log.Write($"hook: {e}");
        }
        return swallow ? (IntPtr)1 : CallNextHookEx(hook, code, wParam, lParam);
    }

    /// The hook reports Ctrl, Alt and Shift as their left and right keys; the generic codes only
    /// show up from some remappers, where the extended flag tells the sides apart.
    private static int Normalise(KBDLLHOOKSTRUCT key)
    {
        bool extended = (key.flags & LLKHF_EXTENDED) != 0;
        return (int)key.vkCode switch
        {
            VK_CONTROL => extended ? VK_RCONTROL : VK_LCONTROL,
            VK_MENU => extended ? VK_RMENU : VK_LMENU,
            VK_SHIFT => key.scanCode == 0x36 ? VK_RSHIFT : VK_LSHIFT,
            var other => other,
        };
    }

    /// Returns true to swallow the key.
    private bool Key(int vk, bool down, KBDLLHOOKSTRUCT raw)
    {
        var cfg = config!;
        // The Ctrl that AltGr layouts send along with Right Alt is not a key the user pressed.
        if (vk == VK_LCONTROL && (raw.scanCode & 0x200) != 0) return false;

        if (cfg.Trigger == TriggerKey.Shortcut)
        {
            if (vk == cfg.Shortcut.KeyCode)
            {
                if (down)
                {
                    if (triggerDown) return true; // auto-repeat
                    if (CurrentModifiers() != cfg.Shortcut.Modifiers) return false;
                    triggerDown = true;
                    TriggerDown();
                    return true;
                }
                if (!triggerDown) return false;
                triggerDown = false;
                TriggerUp();
                return true;
            }
            if (down && !IsModifier(vk)) OtherKey(isCancel: vk == VK_ESCAPE);
            return false;
        }

        int trigger = TriggerVk(cfg.Trigger);
        int partner = cfg.Mode == HotkeyMode.Hold ? PartnerVk(cfg.Trigger) : 0;
        if (partner != 0 && vk == partner)
        {
            if (down && !partnerDown)
            {
                partnerDown = true;
                if (partner == VK_RMENU && gesture != Gesture.Idle) Paster.PressSilentKey();
                PartnerPressed();
            }
            else if (!down) partnerDown = false;
            return false;
        }
        if (vk == trigger)
        {
            if (down && !triggerDown)
            {
                // Pressed alone: with another modifier down it is part of a shortcut. While locked,
                // a tap stops it even if the lock key is still down.
                var allowed = gesture == Gesture.HandsFree && partner != 0 ? new[] { trigger, partner } : new[] { trigger };
                if (OtherModifiersDown(allowed)) return false;
                triggerDown = true;
                // A lone Alt press and release moves focus to the menu bar in many apps; a key that
                // does nothing, pressed meanwhile, keeps that from happening.
                if (trigger == VK_RMENU) Paster.PressSilentKey();
                TriggerDown();
            }
            else if (!down && triggerDown)
            {
                triggerDown = false;
                TriggerUp();
            }
            return false;
        }
        if (down && !IsModifier(vk)) OtherKey(isCancel: vk == VK_ESCAPE);
        return false;
    }

    // MARK: Gestures

    private void TriggerDown()
    {
        DropIfNotRecording();
        switch (gesture)
        {
            case Gesture.Idle:
                OnStart?.Invoke();
                gesture = Gesture.Down;
                downSince = DateTime.UtcNow;
                break;
            case Gesture.AwaitingSecondTap:
                secondTapTimeout?.Dispose();
                gesture = Gesture.SecondTapDown;
                OnLock?.Invoke();
                break;
            case Gesture.HandsFree:
                gesture = Gesture.StopDown;
                stopInterrupted = false;
                break;
        }
    }

    /// The lock key while the trigger is held: keep listening after the trigger is let go.
    private void PartnerPressed()
    {
        if (gesture != Gesture.Down) return;
        gesture = Gesture.HandsFree;
        OnLock?.Invoke();
    }

    private void TriggerUp()
    {
        DropIfNotRecording();
        if (config == null) return;
        switch (gesture)
        {
            case Gesture.Down:
                if (config.Mode != HotkeyMode.Hold)
                {
                    gesture = Gesture.HandsFree;
                    return;
                }
                if (DateTime.UtcNow - downSince >= TapLength)
                {
                    Stop(held: true);
                    return;
                }
                // Too short to be a hold: the first half of a double-tap, or a stray tap to drop.
                gesture = Gesture.AwaitingSecondTap;
                secondTapTimeout = Ui.After(DoubleTapWindow, () =>
                {
                    if (gesture == Gesture.AwaitingSecondTap) Cancel(deliberate: false);
                });
                break;
            case Gesture.SecondTapDown:
                gesture = Gesture.HandsFree;
                break;
            case Gesture.StopDown:
                if (stopInterrupted) gesture = Gesture.HandsFree;
                else Stop(held: false);
                break;
        }
    }

    private void OtherKey(bool isCancel)
    {
        DropIfNotRecording();
        switch (gesture)
        {
            case Gesture.Idle:
                break;
            case Gesture.HandsFree:
                if (isCancel) Cancel(deliberate: true);
                // A key while the trigger is still held after locking was a Ctrl+Alt shortcut, not
                // dictation. Once it is let go, typing elsewhere does not end it.
                else if (triggerDown) Cancel(deliberate: false);
                break;
            case Gesture.StopDown:
                if (isCancel) Cancel(deliberate: true);
                else stopInterrupted = true;
                break;
            default:
                Cancel(deliberate: isCancel);
                break;
        }
    }

    private void DropIfNotRecording()
    {
        if (gesture is Gesture.Idle or Gesture.Down) return;
        if (!IsRecording()) Reset();
    }

    private void Reset()
    {
        secondTapTimeout?.Dispose();
        secondTapTimeout = null;
        gesture = Gesture.Idle;
    }

    private void Stop(bool held)
    {
        Reset();
        OnStop?.Invoke(held);
    }

    private void Cancel(bool deliberate)
    {
        Reset();
        OnCancel?.Invoke(deliberate);
    }

    // MARK: Win32

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    private const int LLKHF_EXTENDED = 0x01;
    public const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_ESCAPE = 0x1B;
    public const int VK_LWIN = 0x5B, VK_RWIN = 0x5C;
    public const int VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1, VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3, VK_LMENU = 0xA4, VK_RMENU = 0xA5;

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode, scanCode, flags, time;
        public UIntPtr dwExtraInfo;
    }

    private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);
}
