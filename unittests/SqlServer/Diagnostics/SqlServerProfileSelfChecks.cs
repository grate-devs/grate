using System.Data;
using System.Reflection;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Data.SqlClient.Diagnostics;
using TestCommon.Generic.Bootstrapping;

namespace SqlServer.Diagnostics;

// Explicit unmeasured control entrypoint; no Facts and no automatic execution.
// Keep the measured provider suite's existing inventory unchanged.
internal static class SqlServerProfileSelfChecks
{
    internal static async Task Run()
    {
        await Correlates_async_open_terminals_with_the_before_scope_and_counts_reuse();
        All_typed_command_and_transaction_terminals_export_numeric_errors_only();
        Unmatched_duplicate_mismatched_unknown_and_throwing_callbacks_remain_visible();
        Batch_categories_ignore_quoted_text_and_reproducible_casings_retain_all_rows();
        await Actual_provider_async_open_duplicate_is_reported_once_per_logical_failure();
        Extra_mismatched_and_success_duplicates_remain_errors();
    }

    private static async Task Correlates_async_open_terminals_with_the_before_scope_and_counts_reuse()
    {
        var collector = new SqlServerProfileCollector();
        using var connection = new SqlConnection("Data Source=secret-source;Initial Catalog=secret-catalog;User ID=zorro;Password=secret-password");
        collector.BeginTest("secret-case-id", "ExampleClass", "FirstMethod");
        var first = Guid.NewGuid();
        Send(collector, SqlClientConnectionOpenBefore.Name, Payload<SqlClientConnectionOpenBefore>(first, "secret-operation", 0L, connection, "version"));
        collector.BeginTest("different-id", "DifferentClass", "DifferentMethod");
        var physicalId = Guid.NewGuid();
        await Task.Run(() => Send(collector, SqlClientConnectionOpenAfter.Name,
            Payload<SqlClientConnectionOpenAfter>(first, "secret-operation", 0L, physicalId, connection, "version", null)), CancellationToken.None);
        collector.EndTest();
        var second = Guid.NewGuid();
        Send(collector, SqlClientConnectionOpenBefore.Name, Payload<SqlClientConnectionOpenBefore>(second, "op", 0L, connection, "version"));
        Send(collector, SqlClientConnectionOpenAfter.Name, Payload<SqlClientConnectionOpenAfter>(second, "op", 0L, physicalId, connection, "version", null));
        var snapshot = collector.Snapshot();
        Assert.Equal(0, snapshot.Errors);
        Assert.False(snapshot.Incomplete);
        Assert.Equal(2, snapshot.SuccessfulLogicalOpens);
        Assert.Equal(1, snapshot.DistinctOpenConnectionIds);
        var test = Assert.Single(snapshot.Aggregates, row => row.Scope == "test");
        Assert.Equal("FirstMethod", test.MethodName);
        Assert.Equal("ExampleClass", test.ClassName);
        Assert.Equal("Target", test.DatabaseRole);
        Assert.Equal("TestUser", test.UserRole);
        Assert.Single(snapshot.Aggregates, row => row.Scope == "fixture-between-teardown");
        var json = JsonSerializer.Serialize(snapshot);
        foreach (var secret in new[] { "secret-case-id", "secret-source", "secret-catalog", "secret-password", "secret-operation", physicalId.ToString() })
        {
            Assert.DoesNotContain(secret, json, StringComparison.Ordinal);
        }
    }

    private static void All_typed_command_and_transaction_terminals_export_numeric_errors_only()
    {
        var collector = new SqlServerProfileCollector();
        using var connection = new SqlConnection("Data Source=secret-source;Initial Catalog=master;User ID=sa;Password=secret-password");
        using var command = new SqlCommand("/* secret-sql */ RESTORE DATABASE [secret-database] FROM DISK='secret-path'", connection);
        var exception = SqlFailure(5054, "secret-exception-message");
        var id = Guid.NewGuid();
        Send(collector, SqlClientConnectionOpenBefore.Name, Payload<SqlClientConnectionOpenBefore>(id, "op", 0L, connection, "version"));
        Send(collector, SqlClientConnectionOpenError.Name, Payload<SqlClientConnectionOpenError>(id, "op", 0L, Guid.Empty, connection, "version", exception));
        foreach (var fails in new[] { false, true })
        {
            id = Guid.NewGuid();
            Send(collector, SqlClientCommandBefore.Name, Payload<SqlClientCommandBefore>(id, "op", 0L, null, null, command));
            if (fails)
            {
                Send(collector, SqlClientCommandError.Name, Payload<SqlClientCommandError>(id, "op", 0L, null, null, command, exception));
            }
            else
            {
                Send(collector, SqlClientCommandAfter.Name, Payload<SqlClientCommandAfter>(id, "op", 0L, null, null, command, null));
            }
            id = Guid.NewGuid();
            Send(collector, SqlClientTransactionCommitBefore.Name, Payload<SqlClientTransactionCommitBefore>(id, "op", 0L, IsolationLevel.ReadCommitted, connection, 1L));
            if (fails)
            {
                Send(collector, SqlClientTransactionCommitError.Name, Payload<SqlClientTransactionCommitError>(id, "op", 0L, IsolationLevel.ReadCommitted, connection, 1L, exception));
            }
            else
            {
                Send(collector, SqlClientTransactionCommitAfter.Name, Payload<SqlClientTransactionCommitAfter>(id, "op", 0L, IsolationLevel.ReadCommitted, connection, 1L));
            }
            id = Guid.NewGuid();
            Send(collector, SqlClientTransactionRollbackBefore.Name, Payload<SqlClientTransactionRollbackBefore>(id, "op", 0L, IsolationLevel.ReadCommitted, connection, 1L, "secret-transaction"));
            if (fails)
            {
                Send(collector, SqlClientTransactionRollbackError.Name, Payload<SqlClientTransactionRollbackError>(id, "op", 0L, IsolationLevel.ReadCommitted, connection, 1L, "secret-transaction", exception));
            }
            else
            {
                Send(collector, SqlClientTransactionRollbackAfter.Name, Payload<SqlClientTransactionRollbackAfter>(id, "op", 0L, IsolationLevel.ReadCommitted, connection, 1L, "secret-transaction"));
            }
        }
        var snapshot = collector.Snapshot();
        Assert.Equal(0, snapshot.Errors);
        Assert.False(snapshot.Incomplete);
        Assert.Equal(4, snapshot.Aggregates.Length);
        foreach (var row in snapshot.Aggregates)
        {
            Assert.Equal(1, row.Failed);
            Assert.Equal(1, row.SqlErrorNumbers[5054]);
            Assert.Equal("Master", row.DatabaseRole);
            Assert.Equal("Sa", row.UserRole);
        }
        Assert.Equal("Restore", Assert.Single(snapshot.Aggregates, row => row.Operation == "Command").BatchCategory);
        var json = JsonSerializer.Serialize(snapshot);
        foreach (var secret in new[] { "secret-source", "secret-password", "secret-sql", "secret-database", "secret-path", "secret-exception-message", "secret-transaction" })
        {
            Assert.DoesNotContain(secret, json, StringComparison.Ordinal);
        }
    }

    private static void Unmatched_duplicate_mismatched_unknown_and_throwing_callbacks_remain_visible()
    {
        var collector = new SqlServerProfileCollector();
        using var connection = new SqlConnection();
        var id = Guid.NewGuid();
        var before = Payload<SqlClientConnectionOpenBefore>(id, "op", 0L, connection, "version");
        Send(collector, SqlClientConnectionOpenBefore.Name, before);
        Send(collector, SqlClientConnectionOpenBefore.Name, before);
        Send(collector, SqlClientConnectionOpenAfter.Name, Payload<SqlClientConnectionOpenAfter>(Guid.NewGuid(), "op", 0L, Guid.NewGuid(), connection, "version", null));
        Send(collector, SqlClientTransactionCommitAfter.Name, Payload<SqlClientTransactionCommitAfter>(id, "op", 0L, IsolationLevel.ReadCommitted, connection, 1L));
        Send(collector, SqlClientCommandBefore.Name, new object());
        Send(collector, SqlClientCommandBefore.Name, Payload<SqlClientCommandBefore>(Guid.NewGuid(), "op", 0L, null, null, null));
        collector.OnError(new InvalidOperationException("secret-error"));
        var snapshot = collector.Snapshot();
        Assert.Equal(6, snapshot.Errors);
        Assert.Equal(2, snapshot.ObserverErrors);
        Assert.Equal(1, snapshot.DuplicateBefore);
        Assert.Equal(1, snapshot.UnmatchedTerminal);
        Assert.Equal(1, snapshot.MismatchedOperation);
        Assert.Equal(1, snapshot.UnknownPayload);
        Assert.True(snapshot.Incomplete);
        Assert.Equal(1, snapshot.PendingOperations);
        Assert.DoesNotContain("secret-error", JsonSerializer.Serialize(snapshot));
    }

    private static void Batch_categories_ignore_quoted_text_and_reproducible_casings_retain_all_rows()
    {
        Assert.Equal(ProfileBatch.Other, SqlServerProfileCollector.Classify("SELECT 'RESTORE', [DROP], \"CREATE\"; -- ALTER\n /* DROP /* RESTORE */ CREATE */"));
        Assert.Equal(ProfileBatch.Other, SqlServerProfileCollector.Classify("SELECT @DROP, @RESTORE, #CREATE, $ALTER"));
        Assert.Equal(ProfileBatch.Alter, SqlServerProfileCollector.Classify("ALTER DATABASE [x] SET SINGLE_USER"));
        Assert.Equal(ProfileBatch.Create, SqlServerProfileCollector.Classify("CREATE DATABASE [x]"));
        Assert.Equal(ProfileBatch.Drop, SqlServerProfileCollector.Classify("IF 1=1 BEGIN ALTER DATABASE [x] SET SINGLE_USER; DROP DATABASE [x]; END"));
        Assert.Equal(ProfileBatch.Restore, SqlServerProfileCollector.Classify("DROP DATABASE [x]; RESTORE DATABASE [x]"));
        var original = Environment.GetEnvironmentVariable("GRATE_REPRODUCIBLE_TABLE_CASINGS");
        try
        {
            Environment.SetEnvironmentVariable("GRATE_REPRODUCIBLE_TABLE_CASINGS", "true");
            var rows = When_Grate_structure_is_not_latest_version.TablesWithDifferentCasings();
            Assert.Equal(27, rows.Count);
            Assert.Equal(27, rows.Select(row => string.Join("|", row.Data)).Distinct(StringComparer.Ordinal).Count());
            var versions = When_Grate_structure_is_not_latest_version.VersionTableWithDifferentCasings();
            Assert.Equal(3, versions.Select(row => string.Join("|", row.Data)).Distinct(StringComparer.Ordinal).Count());
        }
        finally
        {
            Environment.SetEnvironmentVariable("GRATE_REPRODUCIBLE_TABLE_CASINGS", original);
        }
    }

    private static async Task Actual_provider_async_open_duplicate_is_reported_once_per_logical_failure()
    {
        var output = Path.Combine(Path.GetTempPath(), "grate-sql-profile-control-" + Guid.NewGuid().ToString("N") + ".json");
        var session = new SqlServerProfileSession(output);
        session.Start();
        try
        {
            using var connection = new SqlConnection();
            await Assert.ThrowsAsync<InvalidOperationException>(() => connection.OpenAsync(CancellationToken.None)
                .WaitAsync(TimeSpan.FromSeconds(3), CancellationToken.None));
            var snapshot = session.Collector.Snapshot();
            Assert.Equal(0, snapshot.Errors);
            Assert.False(snapshot.Incomplete);
            Assert.Equal(1, snapshot.KnownDuplicateAsyncOpenErrors);
            Assert.Equal(1, snapshot.BeforeCallbacks);
            Assert.Equal(2, snapshot.TerminalCallbacks);
            var row = Assert.Single(snapshot.Aggregates);
            Assert.Equal(1, row.Started);
            Assert.Equal(1, row.Failed);
            Assert.Equal(1, row.ProviderDuplicateErrors);
        }
        finally
        {
            session.Export();
            File.Delete(output);
        }
    }

    private static void Extra_mismatched_and_success_duplicates_remain_errors()
    {
        foreach (var fault in new[] { "DifferentException", "WrongApi", "WrongOperation", "Success" })
        {
            var control = new SqlServerProfileCollector();
            using var controlConnection = new SqlConnection();
            using var controlCommand = new SqlCommand("SELECT 1", controlConnection);
            var controlId = Guid.NewGuid();
            var controlError = SqlFailure(18456, "secret-original");
            Send(control, SqlClientConnectionOpenBefore.Name, Payload<SqlClientConnectionOpenBefore>(controlId, "InternalOpenAsync", 0L, controlConnection, "version"));
            Send(control, SqlClientConnectionOpenError.Name, Payload<SqlClientConnectionOpenError>(controlId, "InternalOpenAsync", 0L, Guid.Empty, controlConnection, "version", controlError));
            if (fault == "Success")
            {
                Send(control, SqlClientConnectionOpenAfter.Name, Payload<SqlClientConnectionOpenAfter>(controlId, "OpenAsyncComplete", 0L, Guid.NewGuid(), controlConnection, "version", null));
            }
            else if (fault == "WrongOperation")
            {
                Send(control, SqlClientCommandError.Name, Payload<SqlClientCommandError>(controlId, "OpenAsyncComplete", 0L, null, null, controlCommand, new AggregateException(controlError)));
            }
            else
            {
                var error = fault == "DifferentException" ? SqlFailure(18456, "secret-other") : controlError;
                var api = fault == "WrongApi" ? "unexpected" : "OpenAsyncComplete";
                Send(control, SqlClientConnectionOpenError.Name, Payload<SqlClientConnectionOpenError>(controlId, api, 0L, Guid.Empty, controlConnection, "version", new AggregateException(error)));
            }
            Assert.Equal(1, control.Snapshot().Errors);
            Assert.Equal(0, control.Snapshot().KnownDuplicateAsyncOpenErrors);
        }
        var collector = new SqlServerProfileCollector();
        using var connection = new SqlConnection();
        using var command = new SqlCommand("SELECT 1", connection);
        var id = Guid.NewGuid();
        var original = SqlFailure(18456, "secret-original");
        collector.BeginTest("first-case", "OriginalClass", "OriginalMethod");
        Send(collector, SqlClientConnectionOpenBefore.Name, Payload<SqlClientConnectionOpenBefore>(id, "InternalOpenAsync", 0L, connection, "version"));
        Send(collector, SqlClientConnectionOpenError.Name, Payload<SqlClientConnectionOpenError>(id, "InternalOpenAsync", 0L, Guid.Empty, connection, "version", original));
        collector.EndTest();
        collector.BeginTest("next-case", "NextClass", "NextMethod");
        var duplicate = Payload<SqlClientConnectionOpenError>(id, "OpenAsyncComplete", 0L, Guid.Empty, connection, "version", new AggregateException(original));
        Send(collector, SqlClientConnectionOpenError.Name, duplicate);
        var valid = collector.Snapshot();
        Assert.Equal(0, valid.Errors);
        Assert.Equal(1, valid.KnownDuplicateAsyncOpenErrors);
        Assert.Equal(1, Assert.Single(valid.Aggregates).SqlErrorNumbers[18456]);
        Assert.Equal("OriginalMethod", Assert.Single(valid.Aggregates).MethodName);
        Send(collector, SqlClientConnectionOpenError.Name, duplicate);
        Send(collector, SqlClientConnectionOpenError.Name, Payload<SqlClientConnectionOpenError>(id, "OpenAsyncComplete", 0L, Guid.Empty, connection, "version", new AggregateException(SqlFailure(18456, "secret-different"))));
        Send(collector, SqlClientConnectionOpenAfter.Name, Payload<SqlClientConnectionOpenAfter>(id, "op", 0L, Guid.NewGuid(), connection, "version", null));
        Send(collector, SqlClientCommandError.Name, Payload<SqlClientCommandError>(id, "op", 0L, null, null, command, original));
        Send(collector, SqlClientConnectionOpenError.Name, Payload<SqlClientConnectionOpenError>(Guid.Empty, "OpenAsyncComplete", 0L, Guid.Empty, connection, "version", new AggregateException(original)));
        Send(collector, SqlClientConnectionOpenError.Name, Payload<SqlClientConnectionOpenError>(id, "unrecognized-operation", 0L, Guid.Empty, connection, "version", new AggregateException(original)));
        var invalid = collector.Snapshot();
        Assert.Equal(6, invalid.Errors);
        Assert.Equal(6, invalid.UnmatchedTerminal);
        Assert.Equal(1, invalid.KnownDuplicateAsyncOpenErrors);
        Assert.Equal(1, invalid.UnmatchedEmptyOperationIds);
        Assert.Equal(5, invalid.UnmatchedTerminalByOperation["Open"]);
        Assert.Equal(1, invalid.UnmatchedTerminalByOperation["Command"]);
        Assert.DoesNotContain("secret-", JsonSerializer.Serialize(invalid));
    }

    private static void Send(SqlServerProfileCollector collector, string name, object payload) => collector.OnNext(new(name, payload));

    // The pinned 7.1.1 payload constructors are internal; exercise the real typed
    // contract without opening a database or publishing synthetic provider events.
    private static T Payload<T>(params object?[] arguments) where T : class => Assert.IsType<T>(Activator.CreateInstance(
        typeof(T), BindingFlags.NonPublic | BindingFlags.Instance, null, arguments, null));

    private static SqlException SqlFailure(int number, string message)
    {
        var errors = (SqlErrorCollection)Activator.CreateInstance(typeof(SqlErrorCollection), true)!;
        var error = (SqlError)typeof(SqlError).GetConstructors(BindingFlags.NonPublic | BindingFlags.Instance)
            .Single(ctor => ctor.GetParameters().Length == 8).Invoke([number, (byte)1, (byte)16, "secret-server", message, "secret-procedure", 1, null]);
        typeof(SqlErrorCollection).GetMethod("Add", BindingFlags.NonPublic | BindingFlags.Instance)!.Invoke(errors, [error]);
        return (SqlException)typeof(SqlException).GetMethod("CreateException", BindingFlags.NonPublic | BindingFlags.Static,
            null, [typeof(SqlErrorCollection), typeof(string)], null)!.Invoke(null, [errors, "version"])!;
    }
}
