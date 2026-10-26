namespace grate.Infrastructure;

/// <summary>
/// Splits a batch of SQL text into individual statements to be run separately.
/// </summary>
public interface IStatementSplitter
{
    IEnumerable<string> Split(string statement);
}
