using grate.Configuration;
using grate.Exceptions;
using Microsoft.Extensions.Logging;

namespace grate.Infrastructure;

internal sealed class MigrationLoggerProvider : ILoggerProvider, ISupportExternalScope
{
    private const string UpToDateCategory = "Grate.Migration.IsUpToDate";
    private readonly TextWriter _stdout;
    private readonly IMigrationLogWriter _output;
    private readonly List<ScriptError> _scriptErrors = [];
#if NET9_0_OR_GREATER
    private readonly System.Threading.Lock _gate = new();
#else
    private readonly object _gate = new();
#endif
    private IExternalScopeProvider _scopes = new LoggerExternalScopeProvider();
    private MigrationLogActivity? _activity;
    private bool _activitiesStarted;

    public MigrationLoggerProvider(MigrationLogFormat format, TextWriter stdout,
        TextWriter? stderr = null, Func<int>? getWindowWidth = null)
    {
        _stdout = stdout;
        _output = format == MigrationLogFormat.Terminal
            ? new TerminalLogWriter(stdout, stderr ?? Console.Error, getWindowWidth ?? (() => Console.WindowWidth))
            : new CiLogWriter(format, stdout);
    }

    public ILogger CreateLogger(string categoryName) => new MigrationLogger(this, categoryName);

    public void SetScopeProvider(IExternalScopeProvider scopeProvider) => _scopes = scopeProvider;

    public void Complete(ILogger logger, string message = "Migration completed.")
    {
        lock (_gate)
        {
            FinishActivity();
            FlushScriptErrors();
            if (_activitiesStarted && logger.IsEnabled(LogLevel.Information))
            {
                _output.Complete(message);
            }
        }
    }

    public void ReportFailure(ILogger logger, Exception exception)
    {
        var reportTerminalErrors = logger.IsEnabled(LogLevel.Error);
        lock (_gate)
        {
            FinishActivity();
            if (!reportTerminalErrors)
            {
                FlushScriptErrors();
                return;
            }

            // An aggregate can carry independent failures from different folders.
            // Correlate the original diagnostic by exception identity, never by its text.
            var terminalErrors = new List<string>();
            foreach (var failure in GetFailures(exception))
            {
                var index = _scriptErrors.FindIndex(item => !item.Matched && ExceptionChainContains(failure, item.Failure));
                if (index >= 0)
                {
                    var original = _scriptErrors[index];
                    _scriptErrors[index] = original with
                    {
                        Message = failure is MigrationException ? failure.Message : original.Message,
                        Matched = true
                    };
                }
                else
                {
                    terminalErrors.Add(failure.Message);
                }
            }

            FlushScriptErrors();
            foreach (var message in terminalErrors)
            {
                _output.Write(LogLevel.Error, message);
            }
            if (_activitiesStarted && logger.IsEnabled(LogLevel.Information))
            {
                _output.Write(LogLevel.Information, "❌ Migration failed.");
            }
        }
    }

    private static IEnumerable<Exception> GetFailures(Exception exception) =>
        exception is AggregateException { InnerExceptions.Count: > 0 } aggregate
            ? aggregate.InnerExceptions.SelectMany(GetFailures)
            : [exception];

    private static bool ExceptionChainContains(Exception exception, Exception original)
    {
        for (Exception? current = exception; current is not null; current = current.InnerException)
        {
            if (ReferenceEquals(current, original))
            {
                return true;
            }
        }
        return false;
    }

    private void Write(LogLevel level, string category, string message, Exception? exception, EventId eventId)
    {
        ScriptFailureDiagnostic? scriptFailure = null;
        MigrationLogActivity? activity = null;
        _scopes.ForEachScope((scope, _) =>
        {
            if (scope is MigrationLogActivity migrationActivity)
            {
                activity = migrationActivity;
            }
            else if (level == LogLevel.Error && scope is ScriptFailureDiagnostic diagnostic)
            {
                scriptFailure = diagnostic;
            }
        }, 0);

        lock (_gate)
        {
            if (_output.SupportsActivities && !ReferenceEquals(_activity, activity))
            {
                FinishActivity();
                // Warnings and errors remain visible at quiet verbosity without
                // introducing progress UI whose information logs were filtered out.
                if (activity is not null && level <= LogLevel.Information)
                {
                    _activity = activity;
                    _activitiesStarted = true;
                    _output.StartActivity(activity);
                }
            }
            if (scriptFailure is not null)
            {
                _scriptErrors.Add(new ScriptError(scriptFailure.Failure, message));
            }
            else if (category == UpToDateCategory && level == LogLevel.Information
                && message is "Up to date: True" or "Up to date: False")
            {
                // Preserve the machine-readable result emitted by GrateMigrator.
                _stdout.WriteLine(message);
            }
            else
            {
                if (exception is not null)
                {
                    if (level <= LogLevel.Debug)
                    {
                        message += Environment.NewLine + exception;
                    }
                    else if (!message.Contains(exception.Message, StringComparison.Ordinal))
                    {
                        message += Environment.NewLine + exception.Message;
                    }
                }
                _output.Write(level, message, eventId);
            }
        }
    }

    private void FlushScriptErrors()
    {
        foreach (var error in _scriptErrors)
        {
            _output.Write(LogLevel.Error, error.Message);
        }
        _scriptErrors.Clear();
    }

    private void FinishActivity()
    {
        if (_activity is not null)
        {
            _output.FinishActivity(_activity);
            _activity = null;
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            FinishActivity();
            FlushScriptErrors();
        }
    }

    private sealed record ScriptError(Exception Failure, string Message, bool Matched = false);

    private sealed class MigrationLogger(MigrationLoggerProvider provider, string categoryName) : ILogger
    {
        public IDisposable BeginScope<TState>(TState state) where TState : notnull => provider._scopes.Push(state);
        public bool IsEnabled(LogLevel logLevel) => logLevel != LogLevel.None;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            if (IsEnabled(logLevel))
            {
                provider.Write(logLevel, categoryName, formatter(state, exception), exception, eventId);
            }
        }
    }
}
