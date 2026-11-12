using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Data.SqlClient.Diagnostics;
using Xunit.v3;

namespace SqlServer.Diagnostics;

internal static class SqlServerProfile
{
    private static SqlServerProfileSession? session;

    internal static void StartFromEnvironment()
    {
        if (session is not null)
        {
            return;
        }
        var output = Environment.GetEnvironmentVariable("GRATE_SQLSERVER_PROFILE_OUTPUT");
        if (string.IsNullOrWhiteSpace(output))
        {
            return;
        }
        var active = new SqlServerProfileSession(Path.GetFullPath(output));
        session = active;
        active.Start();
        AppDomain.CurrentDomain.ProcessExit += (_, _) => active.Export();
    }

    internal static void Before(string id, MethodInfo method) => session?.Collector.BeginTest(
        id, method.DeclaringType?.FullName ?? "unknown", method.Name);

    internal static void After() => session?.Collector.EndTest();
}

public sealed class SqlServerProfileTestAttribute : BeforeAfterTestAttribute
{
    public override void Before(MethodInfo methodUnderTest, IXunitTest test) => SqlServerProfile.Before(test.UniqueID, methodUnderTest);
    public override void After(MethodInfo methodUnderTest, IXunitTest test) => SqlServerProfile.After();
}

internal sealed class SqlServerProfileSession(string output) : IObserver<DiagnosticListener>
{
    private readonly object gate = new();
    private readonly List<IDisposable> subscriptions = [];
    private readonly DateTime started = DateTime.UtcNow;
    private IDisposable? allListeners;
    private int listeners;
    internal SqlServerProfileCollector Collector { get; } = new();

    internal void Start()
    {
        try
        {
            allListeners = DiagnosticListener.AllListeners.Subscribe(this);
        }
        catch (Exception)
        {
            Collector.ObserverError();
        }
    }

    public void OnNext(DiagnosticListener listener)
    {
        try
        {
            if (listener.Name == "SqlClientDiagnosticListener")
            {
                lock (gate)
                {
                    subscriptions.Add(listener.Subscribe(Collector, SqlServerProfileCollector.IsEnabled));
                    listeners++;
                }
            }
        }
        catch (Exception)
        {
            Collector.ObserverError();
        }
    }

    public void OnError(Exception error) => Collector.ObserverError();
    public void OnCompleted() { }

    internal void Export()
    {
        try
        {
            allListeners?.Dispose();
            lock (gate)
            {
                foreach (var subscription in subscriptions)
                {
                    subscription.Dispose();
                }
            }
            var snapshot = Collector.Snapshot();
            var assembly = typeof(SqlServerProfile).Assembly;
            var report = new
            {
                SchemaVersion = 1,
                StartedUtc = started,
                CompletedUtc = DateTime.UtcNow,
                Runtime = RuntimeInformation.FrameworkDescription,
                RuntimeVersion = Environment.Version.ToString(),
                ProcessArchitecture = RuntimeInformation.ProcessArchitecture.ToString(),
                OSArchitecture = RuntimeInformation.OSArchitecture.ToString(),
                BuildConfiguration = assembly.GetCustomAttribute<AssemblyConfigurationAttribute>()?.Configuration,
                AssemblyModuleId = assembly.ManifestModule.ModuleVersionId,
                SqlClientVersion = typeof(SqlConnection).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion,
                StopwatchFrequency = Stopwatch.Frequency,
                ListenerCount = listeners,
                Errors = snapshot.Errors + (listeners == 0 ? 1 : 0),
                snapshot.Incomplete,
                Definitions = new
                {
                    Duration = "Monotonic elapsed time between observer callbacks; includes client work and waits, not server CPU.",
                    ConnectionReuse = "Distinct non-empty successful OpenAfter.ConnectionId values are physical-session hints, not server login counts. Per-row distinct counts are not additive.",
                    Attribution = "Scope captured at Before; case ID is SHA256(xUnit UniqueID); class is the method's declaring type. Outside the Before/After hook includes fixture/between/teardown work; no display names or theory arguments.",
                    DatabaseRole = "Configured ConnectionString.InitialCatalog at Before, not live server context after USE; a Master connection can execute in a target database.",
                    Categories = "Generic lexical batch keywords outside comments/quoted text/variable identifiers, including table/login/database DDL; priority RESTORE, DROP, CREATE, ALTER, Other."
                },
                Data = snapshot
            };
            var directory = Path.GetDirectoryName(output);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }
            File.WriteAllText(output, JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception)
        {
            // No exception text: provider errors can include SQL and credentials.
            Console.Error.WriteLine("SQL Server profiler could not export complete evidence.");
            Environment.ExitCode = 1;
        }
    }
}

internal enum ProfileOperation { Open, Command, Commit, Rollback }
internal enum ProfileBatch { None, Other, Alter, Create, Drop, Restore }
internal enum ProfileDatabase { Default, Master, Target }
internal enum ProfileUser { Sa, TestUser, Integrated, Other }
internal sealed record ProfileScope(string Kind, string? CaseId, string? ClassName, string? MethodName);
internal sealed record ProfileKey(ProfileScope Scope, ProfileOperation Operation, ProfileDatabase Database, ProfileUser User, ProfileBatch Batch);
internal sealed record ProfilePending(ProfileOperation Operation, long Started, ProfileAggregate Aggregate);

internal sealed class ProfileAggregate(ProfileKey key)
{
    internal ProfileKey Key { get; } = key;
    internal long Started;
    internal long Succeeded;
    internal long Failed;
    internal double Milliseconds;
    internal double MaximumMilliseconds;
    internal long NonSqlErrors;
    internal Dictionary<int, long> SqlErrorNumbers { get; } = [];
    internal HashSet<Guid> ConnectionIds { get; } = [];
}

internal sealed class SqlServerProfileCollector : IObserver<KeyValuePair<string, object?>>
{
    private static readonly ProfileScope Infrastructure = new("fixture-between-teardown", null, null, null);
    private static readonly HashSet<string> EventNames = new(StringComparer.Ordinal)
    {
        SqlClientConnectionOpenBefore.Name, SqlClientConnectionOpenAfter.Name, SqlClientConnectionOpenError.Name,
        SqlClientCommandBefore.Name, SqlClientCommandAfter.Name, SqlClientCommandError.Name,
        SqlClientTransactionCommitBefore.Name, SqlClientTransactionCommitAfter.Name, SqlClientTransactionCommitError.Name,
        SqlClientTransactionRollbackBefore.Name, SqlClientTransactionRollbackAfter.Name, SqlClientTransactionRollbackError.Name
    };
    private readonly object gate = new();
    private readonly Dictionary<Guid, ProfilePending> pending = [];
    private readonly Dictionary<ProfileKey, ProfileAggregate> aggregates = [];
    private readonly HashSet<Guid> openConnectionIds = [];
    private ProfileScope current = Infrastructure;
    private long observerErrors;
    private long duplicateBefore;
    private long unmatchedTerminal;
    private long mismatchedOperation;
    private long unknownPayload;
    private long emptyConnectionIds;
    private long callbacks;
    private long callbackTicks;

    internal static bool IsEnabled(string name) => EventNames.Contains(name);

    internal void BeginTest(string id, string className, string methodName)
    {
        var opaqueId = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id)));
        lock (gate)
        {
            current = new("test", opaqueId, className, methodName);
        }
    }

    internal void EndTest()
    {
        lock (gate)
        {
            current = Infrastructure;
        }
    }

    internal void ObserverError() => Interlocked.Increment(ref observerErrors);
    public void OnError(Exception error) => ObserverError();
    public void OnCompleted() { }

    public void OnNext(KeyValuePair<string, object?> item)
    {
        var timestamp = Stopwatch.GetTimestamp();
        try
        {
            lock (gate)
            {
                switch (item.Value)
                {
                    case SqlClientConnectionOpenBefore value:
                        Before(value.OperationId, ProfileOperation.Open, value.Connection, null, timestamp);
                        break;
                    case SqlClientConnectionOpenAfter value:
                        Terminal(value.OperationId, ProfileOperation.Open, null, value.ConnectionId, timestamp);
                        break;
                    case SqlClientConnectionOpenError value:
                        Terminal(value.OperationId, ProfileOperation.Open, value.Exception, null, timestamp);
                        break;
                    case SqlClientCommandBefore value:
                        Before(value.OperationId, ProfileOperation.Command, value.Command.Connection, value.Command.CommandText, timestamp);
                        break;
                    case SqlClientCommandAfter value:
                        Terminal(value.OperationId, ProfileOperation.Command, null, null, timestamp);
                        break;
                    case SqlClientCommandError value:
                        Terminal(value.OperationId, ProfileOperation.Command, value.Exception, null, timestamp);
                        break;
                    case SqlClientTransactionCommitBefore value:
                        Before(value.OperationId, ProfileOperation.Commit, value.Connection, null, timestamp);
                        break;
                    case SqlClientTransactionCommitAfter value:
                        Terminal(value.OperationId, ProfileOperation.Commit, null, null, timestamp);
                        break;
                    case SqlClientTransactionCommitError value:
                        Terminal(value.OperationId, ProfileOperation.Commit, value.Exception, null, timestamp);
                        break;
                    case SqlClientTransactionRollbackBefore value:
                        Before(value.OperationId, ProfileOperation.Rollback, value.Connection, null, timestamp);
                        break;
                    case SqlClientTransactionRollbackAfter value:
                        Terminal(value.OperationId, ProfileOperation.Rollback, null, null, timestamp);
                        break;
                    case SqlClientTransactionRollbackError value:
                        Terminal(value.OperationId, ProfileOperation.Rollback, value.Exception, null, timestamp);
                        break;
                    default:
                        unknownPayload++;
                        break;
                }
            }
        }
        catch (Exception)
        {
            ObserverError();
        }
        finally
        {
            Interlocked.Increment(ref callbacks);
            Interlocked.Add(ref callbackTicks, Stopwatch.GetTimestamp() - timestamp);
        }
    }

    private void Before(Guid id, ProfileOperation operation, SqlConnection? connection, string? sql, long timestamp)
    {
        if (id == Guid.Empty || pending.ContainsKey(id))
        {
            duplicateBefore++;
            return;
        }
        var builder = new SqlConnectionStringBuilder(connection?.ConnectionString ?? "");
        var database = string.IsNullOrEmpty(builder.InitialCatalog) ? ProfileDatabase.Default
            : string.Equals(builder.InitialCatalog, "master", StringComparison.OrdinalIgnoreCase) ? ProfileDatabase.Master
            : ProfileDatabase.Target;
        var user = builder.IntegratedSecurity ? ProfileUser.Integrated
            : string.Equals(builder.UserID, "sa", StringComparison.OrdinalIgnoreCase) ? ProfileUser.Sa
            : string.Equals(builder.UserID, "zorro", StringComparison.OrdinalIgnoreCase) ? ProfileUser.TestUser
            : ProfileUser.Other;
        var batch = operation == ProfileOperation.Command ? Classify(sql ?? "") : ProfileBatch.None;
        var key = new ProfileKey(current, operation, database, user, batch);
        if (!aggregates.TryGetValue(key, out var aggregate))
        {
            aggregate = new(key);
            aggregates.Add(key, aggregate);
        }
        aggregate.Started++;
        pending.Add(id, new(operation, timestamp, aggregate));
    }

    private void Terminal(Guid id, ProfileOperation operation, Exception? error, Guid? connectionId, long timestamp)
    {
        if (!pending.TryGetValue(id, out var entry))
        {
            unmatchedTerminal++;
            return;
        }
        if (entry.Operation != operation)
        {
            mismatchedOperation++;
            return;
        }
        pending.Remove(id);
        var aggregate = entry.Aggregate;
        var milliseconds = (timestamp - entry.Started) * 1000d / Stopwatch.Frequency;
        aggregate.Milliseconds += milliseconds;
        aggregate.MaximumMilliseconds = Math.Max(aggregate.MaximumMilliseconds, milliseconds);
        if (error is null)
        {
            aggregate.Succeeded++;
            if (operation == ProfileOperation.Open)
            {
                if (connectionId is null || connectionId == Guid.Empty)
                {
                    emptyConnectionIds++;
                }
                else
                {
                    aggregate.ConnectionIds.Add(connectionId.Value);
                    openConnectionIds.Add(connectionId.Value);
                }
            }
        }
        else
        {
            aggregate.Failed++;
            var sqlError = false;
            for (var exception = error; exception is not null; exception = exception.InnerException)
            {
                if (exception is SqlException sqlException)
                {
                    sqlError = true;
                    foreach (SqlError item in sqlException.Errors)
                    {
                        aggregate.SqlErrorNumbers.TryGetValue(item.Number, out var count);
                        aggregate.SqlErrorNumbers[item.Number] = count + 1;
                    }
                }
            }
            if (!sqlError)
            {
                aggregate.NonSqlErrors++;
            }
        }
    }

    internal ProfileSnapshot Snapshot()
    {
        lock (gate)
        {
            var observedErrors = Interlocked.Read(ref observerErrors);
            var rows = aggregates.Values.Select(value => new ProfileRow(
                value.Key.Scope.Kind, value.Key.Scope.CaseId, value.Key.Scope.ClassName, value.Key.Scope.MethodName,
                value.Key.Operation.ToString(), value.Key.Database.ToString(), value.Key.User.ToString(), value.Key.Batch.ToString(),
                value.Started, value.Succeeded, value.Failed, value.Milliseconds, value.MaximumMilliseconds,
                value.ConnectionIds.Count, value.NonSqlErrors, new Dictionary<int, long>(value.SqlErrorNumbers)))
                .OrderBy(row => row.Scope, StringComparer.Ordinal)
                .ThenBy(row => row.CaseId, StringComparer.Ordinal)
                .ThenBy(row => row.Operation, StringComparer.Ordinal)
                .ThenBy(row => row.DatabaseRole, StringComparer.Ordinal)
                .ThenBy(row => row.UserRole, StringComparer.Ordinal)
                .ThenBy(row => row.BatchCategory, StringComparer.Ordinal).ToArray();
            return new ProfileSnapshot(
                observedErrors + duplicateBefore + unmatchedTerminal + mismatchedOperation + unknownPayload + emptyConnectionIds,
                pending.Count != 0, pending.Count, observedErrors, duplicateBefore, unmatchedTerminal, mismatchedOperation,
                unknownPayload, emptyConnectionIds, Interlocked.Read(ref callbacks),
                Interlocked.Read(ref callbackTicks) * 1000d / Stopwatch.Frequency,
                rows.Where(row => row.Operation == nameof(ProfileOperation.Open)).Sum(row => row.Succeeded),
                openConnectionIds.Count, rows);
        }
    }

    internal static ProfileBatch Classify(string sql)
    {
        var result = ProfileBatch.Other;
        for (var index = 0; index < sql.Length;)
        {
            if (index + 1 < sql.Length && sql[index] == '-' && sql[index + 1] == '-')
            {
                while (index < sql.Length && sql[index] != '\n') { index++; }
            }
            else if (index + 1 < sql.Length && sql[index] == '/' && sql[index + 1] == '*')
            {
                index += 2;
                var depth = 1;
                while (index < sql.Length && depth > 0)
                {
                    if (index + 1 < sql.Length && sql[index] == '/' && sql[index + 1] == '*') { depth++; index += 2; }
                    else if (index + 1 < sql.Length && sql[index] == '*' && sql[index + 1] == '/') { depth--; index += 2; }
                    else { index++; }
                }
            }
            else if (sql[index] is '\'' or '"' or '[')
            {
                var closing = sql[index++] == '[' ? ']' : sql[index - 1];
                while (index < sql.Length)
                {
                    if (sql[index++] == closing)
                    {
                        if (index < sql.Length && sql[index] == closing) { index++; }
                        else { break; }
                    }
                }
            }
            else if (char.IsLetter(sql[index]) || sql[index] is '_' or '@' or '#' or '$')
            {
                var start = index++;
                while (index < sql.Length && (char.IsLetterOrDigit(sql[index]) || sql[index] is '_' or '@' or '#' or '$')) { index++; }
                var token = sql.AsSpan(start, index - start);
                if (token.Equals("RESTORE", StringComparison.OrdinalIgnoreCase)) { return ProfileBatch.Restore; }
                if (token.Equals("DROP", StringComparison.OrdinalIgnoreCase)) { result = ProfileBatch.Drop; }
                else if (result < ProfileBatch.Create && token.Equals("CREATE", StringComparison.OrdinalIgnoreCase)) { result = ProfileBatch.Create; }
                else if (result < ProfileBatch.Alter && token.Equals("ALTER", StringComparison.OrdinalIgnoreCase)) { result = ProfileBatch.Alter; }
            }
            else { index++; }
        }
        return result;
    }
}

internal sealed record ProfileRow(
    string Scope, string? CaseId, string? ClassName, string? MethodName,
    string Operation, string DatabaseRole, string UserRole, string BatchCategory,
    long Started, long Succeeded, long Failed, double Milliseconds, double MaximumMilliseconds,
    int DistinctConnectionIds, long NonSqlErrors, IReadOnlyDictionary<int, long> SqlErrorNumbers);

internal sealed record ProfileSnapshot(
    long Errors, bool Incomplete, int PendingOperations, long ObserverErrors, long DuplicateBefore,
    long UnmatchedTerminal, long MismatchedOperation, long UnknownPayload, long EmptyConnectionIds,
    long Callbacks, double ObserverMilliseconds, long SuccessfulLogicalOpens, int DistinctOpenConnectionIds,
    ProfileRow[] Aggregates);
