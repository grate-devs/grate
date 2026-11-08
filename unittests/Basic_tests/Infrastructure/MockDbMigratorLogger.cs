using grate.Migration;
using Microsoft.Extensions.Logging;

namespace Basic_tests.Infrastructure;

public class MockDbMigratorLogger : ILogger<DbMigrator>
{
    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
    }

    public bool IsEnabled(LogLevel logLevel) => false;

    public IDisposable? BeginScope<TState>(TState state) where TState : notnull
    {
        return null;
    }
}
