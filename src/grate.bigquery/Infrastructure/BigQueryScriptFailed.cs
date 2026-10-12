using grate.Configuration;
using grate.Exceptions;

namespace grate.BigQuery.Infrastructure;

/// <summary>
/// A migration script BigQuery refused, with BigQuery's own errors for grate to print.
/// </summary>
public class BigQueryScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception cause)
    : ScriptFailed(folder, file, scriptText, cause)
{
    protected override IDictionary<string, object?> GetDbScriptErrors() =>
        ((DbException as BigQueryDbException)?.Errors ?? [])
            .Select((error, index) => (Key: $"Error {index + 1}", Value: (object?)error))
            .ToDictionary(x => x.Key, x => x.Value);
}
