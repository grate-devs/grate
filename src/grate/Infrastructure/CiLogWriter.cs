using grate.Configuration;
using Microsoft.Extensions.Logging;

namespace grate.Infrastructure;

internal sealed class CiLogWriter(MigrationLogFormat format, TextWriter output) : IMigrationLogWriter
{
    public bool SupportsActivities => format is MigrationLogFormat.GitHub or MigrationLogFormat.AzureDevOps or MigrationLogFormat.TeamCity;

    public void StartActivity(MigrationLogActivity activity)
    {
        var name = SafeText(activity.Name);
        switch (format)
        {
            case MigrationLogFormat.GitHub:
                output.WriteLine($"::group::{EscapeGitHub(name)}");
                break;
            case MigrationLogFormat.AzureDevOps:
                // Group titles are formatting commands, without a payload decoder.
                output.WriteLine($"##[group]{name.ReplaceLineEndings(" ")}");
                var value = (int)((long)activity.CompletedFolders * 100 / ((long)activity.TotalFolders + 1));
                var progress = $"grate: {activity.CompletedFolders}/{activity.TotalFolders} configured folders checked; {name}";
                output.WriteLine($"##vso[task.setprogress value={value};]{EscapeAzureDevOps(progress)}");
                break;
            case MigrationLogFormat.TeamCity:
                var escapedName = EscapeTeamCity(name);
                output.WriteLine($"##teamcity[blockOpened name='{escapedName}']");
                output.WriteLine($"##teamcity[progressStart '{escapedName}']");
                break;
        }
        output.Flush();
    }

    public void FinishActivity(MigrationLogActivity activity)
    {
        switch (format)
        {
            case MigrationLogFormat.GitHub:
                output.WriteLine("::endgroup::");
                break;
            case MigrationLogFormat.AzureDevOps:
                output.WriteLine("##[endgroup]");
                break;
            case MigrationLogFormat.TeamCity:
                var name = EscapeTeamCity(SafeText(activity.Name));
                output.WriteLine($"##teamcity[progressFinish '{name}']");
                output.WriteLine($"##teamcity[blockClosed name='{name}']");
                break;
        }
        output.Flush();
    }

    public void Complete(string message)
    {
        if (format == MigrationLogFormat.AzureDevOps)
        {
            output.WriteLine($"##vso[task.setprogress value=100;]{EscapeAzureDevOps(SafeText(message))}");
        }
        Write(LogLevel.Information, "✅ " + message);
    }

    public void Write(LogLevel level, string message, EventId eventId = default)
    {
        var text = SafeText(message);
        if (format != MigrationLogFormat.Ci && level is LogLevel.Warning or LogLevel.Error or LogLevel.Critical)
        {
            var kind = level == LogLevel.Warning ? "warning" : "error";
            var annotation = format switch
            {
                MigrationLogFormat.GitHub => $"::{kind}::{EscapeGitHub(text)}",
                MigrationLogFormat.AzureDevOps => $"##vso[task.logissue type={kind};]{EscapeAzureDevOps(text)}",
                MigrationLogFormat.TeamCity => $"##teamcity[message text='{EscapeTeamCity(text)}' status='{kind.ToUpperInvariant()}']",
                _ => throw new InvalidOperationException($"Expected a CI log format, got {format}.")
            };
            output.WriteLine(annotation);
        }
        else
        {
            var severity = level == LogLevel.Information ? "INFO" : level.ToString().ToUpperInvariant();
            foreach (var line in text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
            {
                if (!string.IsNullOrWhiteSpace(line))
                {
                    output.WriteLine($"[{severity}] {line}");
                }
            }
        }
        output.Flush();
    }

    private static string SafeText(string text) => NeutralizeCommands(LogText.ShowControlCharacters(text));

    // These markers can be recognized even in the middle of a line. Escape them
    // in every CI format because ambiguous runners fall back to plain CI output.
    // GitHub's newer :: commands require the start of a physical line, which is
    // reserved for our severity prefix or for the annotation envelope.
    private static string NeutralizeCommands(string text) => text
        .Replace("##vso[", @"##vso\[", StringComparison.Ordinal)
        .Replace("##teamcity[", @"##teamcity\[", StringComparison.Ordinal)
        .Replace("##[", @"##\[", StringComparison.Ordinal);

    private static string EscapeGitHub(string text) => text
        .Replace("%", "%25", StringComparison.Ordinal)
        .Replace("\r", "%0D", StringComparison.Ordinal)
        .Replace("\n", "%0A", StringComparison.Ordinal);

    private static string EscapeAzureDevOps(string text) => text
        .Replace("%", "%AZP25", StringComparison.Ordinal)
        .Replace(";", "%3B", StringComparison.Ordinal)
        .Replace("]", "%5D", StringComparison.Ordinal)
        .Replace("\r", "%0D", StringComparison.Ordinal)
        .Replace("\n", "%0A", StringComparison.Ordinal);

    private static string EscapeTeamCity(string text) => text
        .Replace("|", "||", StringComparison.Ordinal)
        .Replace("'", "|'", StringComparison.Ordinal)
        .Replace("[", "|[", StringComparison.Ordinal)
        .Replace("]", "|]", StringComparison.Ordinal)
        .Replace("\r", "|r", StringComparison.Ordinal)
        .Replace("\n", "|n", StringComparison.Ordinal);

}
