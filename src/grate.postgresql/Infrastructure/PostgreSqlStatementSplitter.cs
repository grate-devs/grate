using grate.Infrastructure;

namespace grate.PostgreSql.Infrastructure;

public class PostgreSqlStatementSplitter : RegexStatementSplitter
{
    protected override string StringsRegex => @"(?<KEEP1>'([^']|\'\')*')";
    protected override string DashCommentsRegex => "(?<KEEP1>--.*$)";
    protected override string StarCommentsRegex => @"(?<KEEP1>/\*[\S\s]*?\*/)";
    protected override string SeparatorRegex => "(?<KEEP1>.*)(?<BATCHSPLITTER>(;)(?=(?:[^']|'[^']*')*$))(?<KEEP2>.*)";

    protected override IEnumerable<string> AdditionalRegexes
    {
        get
        {
            const string backslashEscapedStrings = @"(?<KEEP1>E(?<!\\)('[\S\s]*?(?<!\\)'))";
            const string dollarQuotedStrings = @"(?<KEEP1>\$(?'tag'\w*)\$[\S\s]*?\$\k'tag'\$)";
            yield return backslashEscapedStrings;
            yield return dollarQuotedStrings;
        }
    }
}
