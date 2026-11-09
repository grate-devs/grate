using Microsoft.Extensions.Logging;

namespace grate.Infrastructure;

internal interface IMigrationLogWriter
{
    bool SupportsActivities { get; }
    void StartActivity(MigrationLogActivity activity);
    void FinishActivity(MigrationLogActivity activity);
    void Complete(string message);
    void Write(LogLevel level, string message, EventId eventId = default);
}
