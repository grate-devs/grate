using Microsoft.Extensions.Logging;

namespace grate.Infrastructure;

internal sealed class TerminalLogWriter(TextWriter stdout, TextWriter stderr, Func<int> getWidth) : IMigrationLogWriter
{
    private const string Reset = "\u001b[0m";
    private MigrationLogActivity? _activity;
    private bool _lineVisible;

    public bool SupportsActivities => true;

    public void StartActivity(MigrationLogActivity activity)
    {
        ClearProgress();
        _activity = activity;
        stdout.WriteLine($"\u001b[1;36m{SafeText(activity.Name).ReplaceLineEndings(" ")}{Reset}");
        DrawProgress();
    }

    public void FinishActivity(MigrationLogActivity activity)
    {
        ClearProgress();
        _activity = null;
    }

    public void Complete(string message)
    {
        ClearProgress();
        _activity = null;
        Write(LogLevel.Information, "✅ " + message);
    }

    public void Write(LogLevel level, string message, EventId eventId = default)
    {
        if (eventId == MigrationLogEvents.Separator)
        {
            return;
        }
        ClearProgress();
        var writer = level >= LogLevel.Warning ? stderr : stdout;
        var color = level switch
        {
            LogLevel.Warning => "\u001b[33m",
            LogLevel.Error or LogLevel.Critical => "\u001b[31m",
            LogLevel.Debug or LogLevel.Trace => "\u001b[90m",
            _ => ""
        };
        var severity = level == LogLevel.Information ? "INFO" : level.ToString().ToUpperInvariant();
        foreach (var line in SafeText(message).Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (!string.IsNullOrWhiteSpace(line))
            {
                writer.WriteLine($"{color}[{severity}]{(color.Length == 0 ? "" : Reset)} {line}");
            }
        }
        // The streams must be flushed in order: clear stdout, persist stderr,
        // then restore stdout's live line. The provider serializes these writes.
        writer.Flush();
        DrawProgress();
    }

    private void ClearProgress()
    {
        if (_lineVisible)
        {
            stdout.Write("\r\u001b[2K");
            stdout.Flush();
            _lineVisible = false;
        }
    }

    private void DrawProgress()
    {
        if (_activity is not { } activity)
        {
            stdout.Flush();
            return;
        }

        int width;
        try
        {
            width = getWidth();
        }
        catch (IOException)
        {
            return;
        }
        catch (PlatformNotSupportedException)
        {
            return;
        }

        // Leave two cells unused so the status never reaches the last column.
        // Narrow terminals retain durable headings and logs without live output.
        if (width < 24)
        {
            return;
        }

        var completed = activity.CompletedFolders;
        var total = activity.TotalFolders;
        var percent = (int)((long)completed * 100 / ((long)total + 1));
        var filled = percent / 10;
        var bar = new string('#', filled) + new string('-', 10 - filled);
        // Only ASCII is used on the live line, whose display width must be exact.
        // Durable headings above retain the full Unicode activity name and icons.
        var name = new string(SafeText(activity.Name).ReplaceLineEndings(" ")
            .Where(character => character is >= ' ' and <= '~').ToArray()).Trim();
        var status = $"[{bar}] {percent}% {completed}/{total} folders checked | {name}";
        var budget = width - 2;
        if (status.Length > budget)
        {
            status = status[..(budget - 3)] + "...";
        }
        stdout.Write(status);
        stdout.Flush();
        _lineVisible = true;
    }

    private static string SafeText(string text) => LogText.ShowControlCharacters(text, allowTabs: false);
}
