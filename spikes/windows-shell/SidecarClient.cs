using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenUsageShell;

public sealed class SidecarRequest
{
    [JsonPropertyName("op")]
    public string Op { get; set; } = "";

    [JsonPropertyName("provider")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Provider { get; set; }
}

public sealed class SidecarResponse
{
    [JsonPropertyName("op")]
    public string Op { get; set; } = "";

    [JsonPropertyName("version")]
    public int? Version { get; set; }

    [JsonPropertyName("providers")]
    public List<SidecarProvider>? Providers { get; set; }

    [JsonPropertyName("message")]
    public string? Message { get; set; }
}

public sealed class SidecarProvider
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("displayName")]
    public string DisplayName { get; set; } = "";

    [JsonPropertyName("plan")]
    public string? Plan { get; set; }

    [JsonPropertyName("credentialsFound")]
    public bool CredentialsFound { get; set; }

    [JsonPropertyName("status")]
    public string Status { get; set; } = "";

    [JsonPropertyName("metricLines")]
    public List<SidecarMetricLine> MetricLines { get; set; } = [];

    [JsonPropertyName("error")]
    public string? Error { get; set; }
}

public sealed class SidecarMetricLine
{
    [JsonPropertyName("kind")]
    public string Kind { get; set; } = "";

    [JsonPropertyName("label")]
    public string Label { get; set; } = "";

    [JsonPropertyName("display")]
    public string Display { get; set; } = "";
}

public sealed class SidecarClient : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = null,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private NamedPipeClientStream? _pipe;
    private StreamReader? _reader;
    private StreamWriter? _writer;

    public static string PipeName => $"OpenUsageCore-{Environment.UserName}";

    public void Connect(int timeoutMs = 30_000)
    {
        Disconnect();
        _pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.None);
        _pipe.Connect(timeoutMs);
        var stream = _pipe;
        _reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true);
        _writer = new StreamWriter(stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false))
        {
            AutoFlush = true,
            NewLine = "\n"
        };
    }

    public void Disconnect()
    {
        _writer?.Dispose();
        _reader?.Dispose();
        _pipe?.Dispose();
        _writer = null;
        _reader = null;
        _pipe = null;
    }

    public SidecarResponse Send(SidecarRequest request)
    {
        if (_writer is null || _reader is null)
        {
            throw new InvalidOperationException("Not connected");
        }

        var payload = JsonSerializer.Serialize(request, JsonOptions);
        _writer.WriteLine(payload);

        var line = _reader.ReadLine();
        if (string.IsNullOrWhiteSpace(line))
        {
            throw new IOException("Sidecar closed the connection");
        }

        return JsonSerializer.Deserialize<SidecarResponse>(line, JsonOptions)
               ?? throw new InvalidDataException("Invalid JSON response");
    }

    public void Dispose() => Disconnect();
}
