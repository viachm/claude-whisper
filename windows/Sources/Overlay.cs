using System.Drawing.Drawing2D;
using System.Drawing.Text;

namespace ClaudeWhisper;

/// The small dark capsule near the bottom of the screen that shows what dictation is doing: bars
/// that follow your voice while listening (with a lock while locked), a travelling wave while
/// Claude transcribes, and a short line of text for messages. It never takes focus, so text still
/// goes to the window you were typing in.
sealed class Overlay : Form
{
    public enum Mode { Waiting, Listening, Locked, Transcribing, Message }

    private Mode mode = Mode.Waiting;
    private string message = "";
    private const int BarCount = 13;
    private readonly float[] levels = new float[BarCount];
    /// Bar heights on screen, eased towards their targets each frame so the motion is smooth.
    private readonly float[] shown = new float[BarCount];
    private float pending;
    private DateTime lastShift = DateTime.MinValue;
    private float phase;
    private readonly System.Windows.Forms.Timer frames = new() { Interval = 1000 / 60 };
    private IDisposable? hideWork;

    /// A colour the capsule never uses, keyed out so only the capsule shows; it is almost the
    /// capsule's own colour, so the anti-aliased edge has no visible fringe.
    private static readonly Color Key = Color.FromArgb(1, 1, 2);
    private static readonly Color Capsule = Color.FromArgb(15, 15, 20);
    private static readonly Color Wave = Color.FromArgb(140, 255, 255, 255);
    private static readonly Color Dim = Color.FromArgb(90, 255, 255, 255);

    private const float CapsuleHeight = 30, BarsWidth = 80, BarWidth = 2, BarGap = 2.4f, IconGap = 5, LockWidth = 12;

    public Overlay()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Key;
        TransparencyKey = Key;
        DoubleBuffered = true;
        frames.Tick += (_, _) =>
        {
            phase += 0.05f;
            if (mode is Mode.Listening or Mode.Locked) Push(Level());
            Invalidate();
        };
    }

    /// The layered, non-activating tool window: shown without stealing focus, absent from Alt+Tab.
    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 /* WS_EX_NOACTIVATE */ | 0x80 /* WS_EX_TOOLWINDOW */ | 0x8 /* WS_EX_TOPMOST */ | 0x20 /* WS_EX_TRANSPARENT */;
            return cp;
        }
    }

    protected override bool ShowWithoutActivation => true;

    public void Show(Mode mode, string text = "")
    {
        hideWork?.Dispose();
        hideWork = null;
        if (this.mode != mode || text != message)
        {
            if (mode != Mode.Locked && this.mode != Mode.Listening) Array.Clear(levels);
            this.mode = mode;
            message = text;
        }
        if (mode == Mode.Message) hideWork = Ui.After(2.2, () => Hide());
        Place();
        if (!Visible) Show();
        frames.Start();
        Invalidate();
    }

    public new void Hide()
    {
        hideWork?.Dispose();
        hideWork = null;
        frames.Stop();
        base.Hide();
    }

    private float Dpi => DeviceDpi / 96f;

    /// Just above the taskbar, centred on the screen the mouse is on.
    private void Place()
    {
        var screen = Screen.FromPoint(Cursor.Position).WorkingArea;
        var size = FittingSize();
        Bounds = new Rectangle(screen.Left + (screen.Width - size.Width) / 2, screen.Bottom - (int)(14 * Dpi) - size.Height, size.Width, size.Height);
    }

    private Size FittingSize()
    {
        float width = BarsWidth;
        if (mode == Mode.Message)
        {
            using var g = CreateGraphics();
            width = g.MeasureString(message, Font).Width / Dpi + 36;
        }
        else if (mode == Mode.Locked) width += LockWidth + IconGap;
        return new Size((int)Math.Ceiling(width * Dpi), (int)Math.Ceiling(CapsuleHeight * Dpi));
    }

    private static float Level()
    {
        float peak = Microphone.Peak();
        // Peaks are linear; map -50 dB … -10 dB onto the bars, as the macOS app does.
        double db = 20 * Math.Log10(Math.Max(peak, 1e-6));
        return (float)Math.Clamp((db + 50) / 40, 0, 1);
    }

    /// The meter is read 60 times a second; shifting the bars that often makes them race, so take
    /// the loudest level of each ~120 ms and shift once.
    private void Push(float level)
    {
        pending = Math.Max(pending, level);
        if ((DateTime.UtcNow - lastShift).TotalSeconds < 0.12) return;
        lastShift = DateTime.UtcNow;
        Array.Copy(levels, 1, levels, 0, BarCount - 1);
        levels[BarCount - 1] = pending;
        pending = 0;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        g.Clear(Key);
        float s = Dpi;
        var rect = new RectangleF(0.5f * s, 0.5f * s, Width - s, CapsuleHeight * s - s);
        using (var shape = Rounded(rect, rect.Height / 2))
        using (var fill = new SolidBrush(Capsule))
            g.FillPath(fill, shape);

        if (mode == Mode.Message)
        {
            using var brush = new SolidBrush(Color.FromArgb(217, 255, 255, 255));
            using var font = new Font("Segoe UI", 9f, FontStyle.Regular);
            var size = g.MeasureString(message, font);
            g.DrawString(message, font, brush, (Width - size.Width) / 2, (rect.Height - size.Height) / 2 + rect.Top);
            return;
        }

        float span = (BarCount * BarWidth + (BarCount - 1) * BarGap) * s;
        float x = rect.Left + (BarsWidth * s - span) / 2;
        if (mode == Mode.Locked)
        {
            using var lockFont = new Font("Segoe MDL2 Assets", 9f);
            using var brush = new SolidBrush(Color.FromArgb(230, 255, 255, 255));
            var glyph = "";
            var size = g.MeasureString(glyph, lockFont);
            g.DrawString(glyph, lockFont, brush, x, rect.Top + (rect.Height - size.Height) / 2);
            x += (LockWidth + IconGap) * s;
        }
        DrawBars(g, x, rect, s);
    }

    private void DrawBars(Graphics g, float x, RectangleF rect, float s)
    {
        float maxHeight = rect.Height - 10 * s, minHeight = 2.5f * s;
        for (int i = 0; i < BarCount; i++)
        {
            float centre = 1 - Math.Abs(i - (BarCount - 1) / 2f) / BarCount; // taller in the middle
            float amount;
            Color color = Color.White;
            switch (mode)
            {
                case Mode.Listening or Mode.Locked:
                    amount = Math.Min(1, levels[i] * (0.55f + centre));
                    break;
                case Mode.Transcribing:
                    amount = 0.25f + 0.3f * ((float)Math.Sin(phase - i * 0.45f) + 1) / 2;
                    color = Wave;
                    break;
                default:
                    amount = 0;
                    color = Dim;
                    break;
            }
            shown[i] += (amount - shown[i]) * 0.3f;
            float h = minHeight + (maxHeight - minHeight) * shown[i];
            var bar = new RectangleF(x, rect.Top + (rect.Height - h) / 2, BarWidth * s, h);
            using var path = Rounded(bar, bar.Width / 2);
            using var brush = new SolidBrush(color);
            g.FillPath(brush, path);
            x += (BarWidth + BarGap) * s;
        }
    }

    private static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var path = new GraphicsPath();
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        path.AddArc(r.Left, r.Top, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}
