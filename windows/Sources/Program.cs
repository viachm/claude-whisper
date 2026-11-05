namespace ClaudeWhisper;

static class Program
{
    [STAThread]
    static void Main()
    {
        // A second copy would fight over the hook and the hidden session.
        using var single = new Mutex(true, @"Local\ClaudeWhisper", out bool first);
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
