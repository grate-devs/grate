namespace grate.Infrastructure;

// Relates the script-level diagnostic to the failure that may later be wrapped
// by the migrator. The message, event ID and exception passed to ILogger stay the same.
internal sealed class ScriptFailureDiagnostic(Exception failure)
{
    public Exception Failure { get; } = failure;
}
