namespace ClaudeWhisper;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        // A second copy would fight over the hook and the hidden session. Started by an update, it
        // waits for the old copy to quit.
        using var single = new Mutex(false, @"Local\ClaudeWhisper");
        bool first;
        try { first = single.WaitOne(args.Contains("--after-update") ? TimeSpan.FromSeconds(15) : TimeSpan.Zero); }
        catch (AbandonedMutexException) { first = true; }
        if (!first)
        {
            MessageBox.Show("Claude Whisper is already running: look for it in the tray.", Paths.AppName, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Ui.Capture();
        Application.ThreadException += (_, e) => Log.Write($"unhandled: {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"unhandled: {e.ExceptionObject}");
        Application.Run(new App());
    }
}
