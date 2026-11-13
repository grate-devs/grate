using grate.Infrastructure;

namespace grate.BigQuery.Infrastructure;

/// <summary>
/// BigQuery runs a whole script as one multi-statement job, so a script is never split - BigQuery itself has no batch
/// separator.
/// </summary>
public class BigQueryStatementSplitter : IStatementSplitter
{
    public IEnumerable<string> Split(string statement) =>
        string.IsNullOrWhiteSpace(statement) ? [] : [statement];
}
