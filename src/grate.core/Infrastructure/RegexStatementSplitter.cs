using System.Text.RegularExpressions;
using static System.Text.RegularExpressions.RegexOptions;

namespace grate.Infrastructure;

/// <summary>
/// Base class for splitting SQL batches into statements using a dialect-specific regex.
/// The regex must tag the parts to keep as KEEP1/KEEP2 groups, and the separator to remove as BATCHSPLITTER.
/// </summary>
public abstract class RegexStatementSplitter : IStatementSplitter
{
    private const string BatchTerminatorReplacementString = @" |{[_REMOVE_]}| ";

    protected abstract string StringsRegex { get; }
    protected abstract string DashCommentsRegex { get; }
    protected abstract string StarCommentsRegex { get; }
    protected abstract string SeparatorRegex { get; }

    /// <summary>
    /// Additional regex fragments to be inserted between the strings and comments patterns (e.g. for extra string forms).
    /// </summary>
    protected virtual IEnumerable<string> AdditionalRegexes => Enumerable.Empty<string>();

    private Regex? _regex;
    private Regex Regex => _regex ??= new Regex(Pattern, IgnoreCase | Multiline);

    private string Pattern =>
        string.Join("|", new[] { StringsRegex }
            .Concat(AdditionalRegexes)
            .Append(DashCommentsRegex)
            .Append(StarCommentsRegex)
            .Append(SeparatorRegex));

    public IEnumerable<string> Split(string statement)
    {
        var replaced = Replace(statement);

        var statements = replaced.Split(BatchTerminatorReplacementString);
        return statements.Where(HasScriptsToRun);
    }

    private string Replace(string text) => Regex.Replace(text, ReplaceBatchSeparator);

    private static string ReplaceBatchSeparator(Match match)
    {
        var groups = match.Groups;
        var replacement = groups["BATCHSPLITTER"].Success ? BatchTerminatorReplacementString : string.Empty;
        return groups["KEEP1"].Value + replacement + groups["KEEP2"].Value;
    }

    private static bool HasScriptsToRun(string sqlStatement)
    {
        var trimmedStatement = sqlStatement.Replace(BatchTerminatorReplacementString, string.Empty, StringComparison.InvariantCultureIgnoreCase);
        return !string.IsNullOrEmpty(trimmedStatement.ToLower()
            .Replace(Environment.NewLine, string.Empty)
            .Replace("\n", string.Empty) // This is necessary to make script with unix-style line endings work on grate on Windows
            .Replace(" ", string.Empty));
    }
}
