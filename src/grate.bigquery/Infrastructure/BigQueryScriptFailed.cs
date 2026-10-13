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
        DbException is BigQueryDbException ex
            ? new Dictionary<string, object?>
            {
                { nameof(BigQueryDbException.Message), ex.Message },
                { nameof(BigQueryDbException.HttpStatusCode), (int)ex.HttpStatusCode },
                { nameof(BigQueryDbException.Reason), ex.Reason },
                { nameof(BigQueryDbException.Location), ex.Location },
                { nameof(BigQueryDbException.Errors), string.Join("; ", ex.Errors) },
            }
            : new Dictionary<string, object?>();
}
