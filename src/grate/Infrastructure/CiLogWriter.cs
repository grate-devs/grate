using System.Text;
using grate.Configuration;
using Microsoft.Extensions.Logging;

namespace grate.Infrastructure;

internal sealed class CiLogWriter(MigrationLogFormat format, TextWriter output)
{
    public void Write(LogLevel level, string message)
    {
        var text = NeutralizeCommands(ShowControlCharacters(message));
        if (format != MigrationLogFormat.Ci && level is LogLevel.Warning or LogLevel.Error or LogLevel.Critical)
        {
            var kind = level == LogLevel.Warning ? "warning" : "error";
            var annotation = format switch
            {
                MigrationLogFormat.GitHub => $"::{kind}::{EscapeGitHub(text)}",
                MigrationLogFormat.Azure => $"##vso[task.logissue type={kind};]{EscapeAzure(text)}",
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

    private static string EscapeAzure(string text) => text
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

    private static string ShowControlCharacters(string text)
    {
        StringBuilder? safe = null;
        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            if (character is '\u2028' or '\u2029' ||
                (char.IsControl(character) && character is not ('\r' or '\n' or '\t')))
            {
                safe ??= new StringBuilder(text.Length).Append(text, 0, index);
                safe.Append($@"\u{(int)character:X4}");
            }
            else
            {
                safe?.Append(character);
            }
        }
        return safe?.ToString() ?? text;
    }
}
