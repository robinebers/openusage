using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DrawingColor = System.Drawing.Color;
using DrawingIcon = System.Drawing.Icon;
using WpfBrushes = System.Windows.Media.Brushes;
using IOPath = System.IO.Path;

namespace OpenUsageShell;

/// <summary>
/// Renders the OpenUsage brand mark as a Windows tray icon (macOS menu-bar logo equivalent).
/// </summary>
internal static class TrayIconRenderer
{
    private static DrawingIcon? _logo;

    public static DrawingIcon CreateLogo()
    {
        if (_logo is not null)
        {
            return (DrawingIcon)_logo.Clone();
        }

        const int size = 32;
        using var bmp = RenderBrandBitmap(size) ?? FallbackBitmap(size);
        var hIcon = bmp.GetHicon();
        using var temp = DrawingIcon.FromHandle(hIcon);
        _logo = (DrawingIcon)temp.Clone();
        DestroyIcon(hIcon);
        return (DrawingIcon)_logo.Clone();
    }

    /// <summary>PNG-friendly brand bitmap for toast app-logo override.</summary>
    public static Bitmap? RenderBrandBitmapForToast(int size) => RenderBrandBitmap(size);

    /// <summary>Dark plate + white gauge — used for .ico / Start Menu / toast header.</summary>
    public static Bitmap RenderAppIconBitmap(int size)
    {
        var canvas = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(canvas);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(DrawingColor.Transparent);

        var margin = Math.Max(1, size / 32);
        using (var plate = new SolidBrush(DrawingColor.FromArgb(0xFF, 0x1C, 0x1C, 0x1E)))
        {
            g.FillEllipse(plate, margin, margin, size - margin * 2 - 1, size - margin * 2 - 1);
        }

        using var brand = RenderBrandBitmap(size) ?? FallbackBitmap(size);
        var inset = size / 7;
        g.DrawImage(brand, new Rectangle(inset, inset, size - inset * 2, size - inset * 2));
        return canvas;
    }

    private static Bitmap? RenderBrandBitmap(int size)
    {
        var pathData = LoadOpenUsagePath();
        if (pathData is null)
        {
            return null;
        }

        // SVG viewBox is 0 0 24 24 — scale into the icon with a small inset.
        var geo = Geometry.Parse(pathData);
        var bounds = geo.Bounds;
        if (bounds.IsEmpty || bounds.Width <= 0 || bounds.Height <= 0)
        {
            return null;
        }

        const double inset = 0.08;
        var target = size * (1 - 2 * inset);
        var scale = Math.Min(target / bounds.Width, target / bounds.Height);
        var transform = new TransformGroup();
        transform.Children.Add(new TranslateTransform(-bounds.X, -bounds.Y));
        transform.Children.Add(new ScaleTransform(scale, scale));
        transform.Children.Add(new TranslateTransform(
            (size - bounds.Width * scale) / 2,
            (size - bounds.Height * scale) / 2));

        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawRectangle(WpfBrushes.Transparent, null, new Rect(0, 0, size, size));
            dc.PushTransform(transform);
            dc.DrawGeometry(WpfBrushes.White, null, geo);
            dc.Pop();
        }

        var rtb = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(visual);

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(rtb));
        using var ms = new MemoryStream();
        encoder.Save(ms);
        ms.Position = 0;
        return new Bitmap(ms);
    }

    private static Bitmap FallbackBitmap(int size)
    {
        var bmp = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(DrawingColor.Transparent);
        using var pen = new System.Drawing.Pen(DrawingColor.White, 2.2f);
        g.DrawEllipse(pen, 4, 4, size - 9, size - 9);
        g.FillEllipse(System.Drawing.Brushes.White, size / 2f - 2.5f, size / 2f - 2.5f, 5, 5);
        return bmp;
    }

    private static string? LoadOpenUsagePath()
    {
        var file = IOPath.Combine(AppContext.BaseDirectory, "Assets", "Providers", "openusage.svg");
        if (!File.Exists(file))
        {
            return null;
        }

        var svg = File.ReadAllText(file);
        var match = System.Text.RegularExpressions.Regex.Match(svg, """d="([^"]+)""");
        return match.Success ? match.Groups[1].Value : null;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
    private static extern bool DestroyIcon(IntPtr handle);
}
