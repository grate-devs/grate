using System.Data.Common;
using Google;

namespace grate.BigQuery.Infrastructure;

/// <summary>
/// A failed BigQuery job, as the <see cref="DbException"/> grate expects: grate treats a <c>DbException</c> as a failed
/// script, so a <see cref="GoogleApiException"/> is wrapped.
/// </summary>
public sealed class BigQueryDbException : DbException
{
    public BigQueryDbException(GoogleApiException exception)
        : base(exception?.Error?.Message ?? exception?.Message, exception)
    {
        ArgumentNullException.ThrowIfNull(exception);

        Errors = exception.Error?.Errors?
            .Select(x => $"{x.Reason}: {x.Message}")
            .ToArray() ?? [];
    }

    /// <summary>
    /// Every error BigQuery gave, as <c>reason: message</c> - a failed multi-statement job lists one per statement.
    /// </summary>
    public IReadOnlyList<string> Errors { get; }
}
