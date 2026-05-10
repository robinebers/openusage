using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using System.Globalization;
using System.Security;
using System.Text.RegularExpressions;
using ShapePath = Microsoft.UI.Xaml.Shapes.Path;

namespace UsageMeter.App;

public sealed partial class MainWindow
{
    private static readonly Regex ViewBoxRegex = new(
        "viewBox=\"(?<value>[^\"]+)\"",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex SvgPathRegex = new(
        "<path\\b[^>]*\\bd=\"(?<data>[^\"]+)\"[^>]*>",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static FrameworkElement CreateProviderIcon(string providerId)
    {
        var svgPath = Path.Combine(
            AppContext.BaseDirectory,
            "Assets",
            "Providers",
            $"{providerId}.svg");

        if (!File.Exists(svgPath))
        {
            throw new FileNotFoundException($"Provider icon is missing: {providerId}", svgPath);
        }

        var svg = File.ReadAllText(svgPath);
        var viewBox = ReadViewBox(svg, providerId);
        var canvas = new Canvas
        {
            Width = viewBox.Width,
            Height = viewBox.Height
        };

        var iconBrush = Brush(15, 23, 42);
        var matches = SvgPathRegex.Matches(svg);
        if (matches.Count == 0)
        {
            throw new InvalidOperationException($"Provider icon has no path data: {providerId}");
        }

        foreach (Match match in matches)
        {
            var shape = CreatePath(match.Groups["data"].Value);
            shape.Fill = iconBrush;
            shape.Stretch = Stretch.None;
            shape.RenderTransform = new TranslateTransform
            {
                X = -viewBox.MinX,
                Y = -viewBox.MinY
            };

            canvas.Children.Add(shape);
        }

        return new Viewbox
        {
            Width = 21,
            Height = 21,
            Child = canvas
        };
    }

    private static SvgViewBox ReadViewBox(string svg, string providerId)
    {
        var match = ViewBoxRegex.Match(svg);
        if (!match.Success)
        {
            throw new InvalidOperationException($"Provider icon has no viewBox: {providerId}");
        }

        var values = match.Groups["value"].Value
            .Split([' ', ','], StringSplitOptions.RemoveEmptyEntries)
            .Select(value => double.Parse(value, CultureInfo.InvariantCulture))
            .ToArray();

        if (values.Length != 4 || values[2] <= 0 || values[3] <= 0)
        {
            throw new InvalidOperationException($"Provider icon has an invalid viewBox: {providerId}");
        }

        return new SvgViewBox(values[0], values[1], values[2], values[3]);
    }

    private static ShapePath CreatePath(string data)
    {
        var escapedData = SecurityElement.Escape(data);
        var xaml = $"""
            <Path
                xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                Data="{escapedData}" />
            """;

        return (ShapePath)XamlReader.Load(xaml);
    }

    private readonly record struct SvgViewBox(double MinX, double MinY, double Width, double Height);
}
