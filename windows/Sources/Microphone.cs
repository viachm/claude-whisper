using System.Runtime.InteropServices;

namespace ClaudeWhisper;

/// Whether the default microphone is recording, read from WASAPI's capture sessions: Claude Code
/// opens the microphone once it is really listening, so this tells a successful start from a
/// press Claude ignored. The endpoint's meter gives the level for the capsule's bars without
/// opening a capture stream of our own.
static class Microphone
{
    private static IMMDeviceEnumerator? enumerator;
    private static bool unavailable;

    /// True while a capture session is active; null when WASAPI cannot be asked (then the
    /// console output has to do).
    public static bool? IsRunning()
    {
        try
        {
            bool any = false;
            foreach (var device in DefaultCaptureDevices())
            {
                var iid = typeof(IAudioSessionManager2).GUID;
                device.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out var managerObject);
                var manager = (IAudioSessionManager2)managerObject;
                manager.GetSessionEnumerator(out var sessions);
                sessions.GetCount(out int count);
                for (int i = 0; i < count && !any; i++)
                {
                    sessions.GetSession(i, out var session);
                    session.GetState(out int state);
                    any = state == AudioSessionStateActive;
                    Marshal.ReleaseComObject(session);
                }
                Marshal.ReleaseComObject(sessions);
                Marshal.ReleaseComObject(manager);
                Marshal.ReleaseComObject(device);
                if (any) break;
            }
            return any;
        }
        catch (Exception e)
        {
            if (!unavailable) Log.Write($"microphone state unavailable, using Claude's output instead: {e.Message}");
            unavailable = true;
            return null;
        }
    }

    /// The default microphone's peak level, 0…1, or 0 when it cannot be read.
    public static float Peak()
    {
        try
        {
            float peak = 0;
            foreach (var device in DefaultCaptureDevices())
            {
                var iid = typeof(IAudioMeterInformation).GUID;
                device.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out var meterObject);
                var meter = (IAudioMeterInformation)meterObject;
                meter.GetPeakValue(out float value);
                peak = Math.Max(peak, value);
                Marshal.ReleaseComObject(meter);
                Marshal.ReleaseComObject(device);
            }
            return peak;
        }
        catch (Exception)
        {
            return 0;
        }
    }

    /// The default device for calls and the one for everything else, once each when they are the same.
    private static IEnumerable<IMMDevice> DefaultCaptureDevices()
    {
        enumerator ??= (IMMDeviceEnumerator)new MMDeviceEnumerator();
        var seen = new HashSet<string>();
        foreach (var role in new[] { eConsole, eCommunications })
        {
            IMMDevice device;
            try { enumerator.GetDefaultAudioEndpoint(eCapture, role, out device); }
            catch (COMException) { continue; } // no microphone for this role
            device.GetId(out var id);
            if (seen.Add(id)) yield return device;
            else Marshal.ReleaseComObject(device);
        }
    }

    // MARK: COM

    private const int eCapture = 1, eConsole = 0, eCommunications = 2;
    private const int CLSCTX_ALL = 23;
    private const int AudioSessionStateActive = 1;

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumerator { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        void GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        int RegisterEndpointNotificationCallback(IntPtr client);
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        void Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        int OpenPropertyStore(int access, out IntPtr properties);
        void GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionManager2
    {
        // IAudioSessionManager
        int GetAudioSessionControl(IntPtr sessionGuid, int streamFlags, out IntPtr control);
        int GetSimpleAudioVolume(IntPtr sessionGuid, int streamFlags, out IntPtr volume);
        // IAudioSessionManager2
        void GetSessionEnumerator(out IAudioSessionEnumerator sessions);
        int RegisterSessionNotification(IntPtr notification);
        int UnregisterSessionNotification(IntPtr notification);
        int RegisterDuckNotification([MarshalAs(UnmanagedType.LPWStr)] string sessionId, IntPtr notification);
        int UnregisterDuckNotification(IntPtr notification);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionEnumerator
    {
        void GetCount(out int count);
        void GetSession(int index, out IAudioSessionControl session);
    }

    [ComImport, Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl
    {
        void GetState(out int state);
        // The rest of the interface is not needed.
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioMeterInformation
    {
        void GetPeakValue(out float peak);
    }
}
