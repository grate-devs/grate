using System.Data.Common;
using System.Net;
using Google;

namespace grate.BigQuery.Infrastructure;

/// <summary>
/// A failed BigQuery job, as the <see cref="DbException"/> grate expects: grate treats a <c>DbException</c> as a failed
/// script, so a <see cref="GoogleApiException"/> is wrapped.
/// </summary>
public sealed class BigQueryDbException : DbException
{
    /// <summary>
    /// The reasons BigQuery gives for a failure that passes if the job is tried again.
    /// </summary>
    public static readonly IReadOnlyList<string> TransientReasons = ["rateLimitExceeded", "backendError"];

    public BigQueryDbException(GoogleApiException exception)
        : base(exception?.Error?.Message ?? exception?.Message, exception)
    {
        ArgumentNullException.ThrowIfNull(exception);

        HttpStatusCode = exception.HttpStatusCode;
        var first = exception.Error?.Errors?.FirstOrDefault();
        Reason = first?.Reason;
        Location = first?.Location;
        Errors = exception.Error?.Errors?
            .Select(x => $"{x.Reason}: {x.Message}")
            .ToArray() ?? [];
    }

    public HttpStatusCode HttpStatusCode { get; }

    /// <summary>
    /// BigQuery's reason for the first error, e.g. <c>invalidQuery</c>.
    /// </summary>
    public string? Reason { get; }

    /// <summary>
    /// Where the first error is, as BigQuery names it, e.g. <c>query</c>.
    /// </summary>
    public string? Location { get; }

    /// <summary>
    /// Every error BigQuery gave, as <c>reason: message</c> - a failed multi-statement job lists one per statement.
    /// </summary>
    public IReadOnlyList<string> Errors { get; }

    public override bool IsTransient => Reason is not null && TransientReasons.Contains(Reason);
}
