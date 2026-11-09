using Microsoft.Extensions.Logging;

namespace grate.Infrastructure;

internal static class MigrationLogEvents
{
    public static readonly EventId Separator = new(90301, nameof(Separator));
}
