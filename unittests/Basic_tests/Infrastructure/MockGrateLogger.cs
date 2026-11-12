using grate.Migration;
using Microsoft.Extensions.Logging;

namespace Basic_tests.Infrastructure;

/// <summary>
/// Cannot Substitute ILogger&lt;GrateMigrator&gt;, since GrateMigrator is internal, so we need to create a mock logger.
/// </summary>
public record MockGrateLogger : ILogger<GrateMigrator>
{
    public virtual void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        var message = formatter(state, exception);
        LoggedMessages.Add(message);
    }

    public bool IsEnabled(LogLevel logLevel) => logLevel != LogLevel.None;

    public IDisposable? BeginScope<TState>(TState state) where TState : notnull
    {
        return null;
    }

    public IList<string> LoggedMessages { get; } = new List<string>();
}

public record MockGrateLoggerFactory : ILoggerFactory
{
    private readonly MockGrateLogger _logger;

    public MockGrateLoggerFactory(MockGrateLogger? logger = null)
    {
        _logger = logger ?? new MockGrateLogger();
    }

    public void Dispose()
    {
    }

    public ILogger CreateLogger(string categoryName)
    {
        return _logger;
    }

    public void AddProvider(ILoggerProvider provider)
    {
        throw new NotImplementedException();
    }
}
