using grate.Infrastructure;

namespace grate.Oracle.Infrastructure;

public class OracleStatementSplitter : RegexStatementSplitter
{
    protected override string StringsRegex => @"(?<KEEP1>'[^']*')";
    protected override string DashCommentsRegex => @"(?<KEEP1>--.*$)";
    protected override string StarCommentsRegex => @"(?<KEEP1>/\*[\S\s]*?\*/)";
    protected override string SeparatorRegex => @"(?<KEEP1>^|\s)(?<BATCHSPLITTER>/)(?<KEEP2>\s|;|$)";
}
