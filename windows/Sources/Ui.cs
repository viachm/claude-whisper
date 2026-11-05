namespace ClaudeWhisper;

/// The UI thread, for code that runs on other threads (the console reader, the key hook's
/// timers) and wants to touch the app's state. Everything in App runs here.
static class Ui
{
    private static SynchronizationContext? context;

    /// Called once from the UI thread, before anything else starts.
    public static void Capture() => context = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();

    public static void Post(Action action) => context!.Post(_ => action(), null);

    /// Runs `action` on the UI thread after `delay`; the returned timer can be disposed to cancel it.
    public static IDisposable After(TimeSpan delay, Action action)
    {
        var timer = new System.Windows.Forms.Timer { Interval = Math.Max(1, (int)delay.TotalMilliseconds) };
        timer.Tick += (_, _) =>
        {
            timer.Dispose();
            action();
        };
        if (SynchronizationContext.Current == context) timer.Start();
        else Post(timer.Start);
        return timer;
    }

    public static IDisposable After(double seconds, Action action) => After(TimeSpan.FromSeconds(seconds), action);
}
