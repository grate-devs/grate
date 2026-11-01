using System.Data.Common;
using System.Transactions;
using Basic_tests.Infrastructure;
using grate.Configuration;
using grate.Infrastructure;
using grate.Migration;
using grate.SqlServer.Migration;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;

namespace Basic_tests;

public sealed class DatabaseReadiness_ : IDisposable
{
    private readonly DirectoryInfo _directory = Directory.CreateTempSubdirectory();
    private readonly List<DirectoryInfo> _internalDirectories = [];

    [Fact]
    public async Task Custom_creation_waits_for_target_connection_before_bootstrapping_and_after_create_scripts()
    {
        WriteScript("createDatabase/create.sql", "-- create database");
        WriteScript("runAfterCreateDatabase/after.sql", "-- after creation");
        var database = CreateDatabase();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var ready = new TaskCompletionSource<IDisposable>(TaskCreationOptions.RunContinuationsAsynchronously);
        var connection = Substitute.For<IDisposable>();
        database.OpenNewActiveConnection().Returns(_ =>
        {
            entered.SetResult();
            return ready.Task;
        });
        await using var migrator = CreateMigrator(database);

        var migration = migrator.Migrate();
        await Task.WhenAny(entered.Task, migration).WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);

        Assert.False(migration.IsCompleted);
        await database.Received(1).RunSql("-- create database", ConnectionType.Admin, TransactionHandling.Autonomous);
        await database.DidNotReceive().VersionTableExists();
        await database.DidNotReceive().RunSql("-- after creation", Arg.Any<ConnectionType>(), Arg.Any<TransactionHandling>());

        ready.SetResult(connection);
        await migration;

        connection.Received(1).Dispose();
        await database.Received().VersionTableExists();
        await database.Received(1).RunSql("-- after creation", ConnectionType.Default, TransactionHandling.Default);
    }

    [Theory]
    [InlineData(true, false, "create.sql")]
    [InlineData(false, true, "create.sql")]
    [InlineData(false, false, null)]
    [InlineData(false, false, "create.PROD.ENV.sql")]
    public async Task Skipped_or_previewed_custom_creation_does_not_probe_readiness(
        bool dryRun, bool alreadyExists, string? scriptName)
    {
        Directory.CreateDirectory(Path.Combine(_directory.FullName, "createDatabase"));
        if (scriptName is not null) WriteScript($"createDatabase/{scriptName}", "-- create database");
        var database = CreateDatabase();
        database.DatabaseExists().Returns(alreadyExists);
        await using var migrator = CreateMigrator(database, dryRun);

        await migrator.Migrate();

        await database.DidNotReceive().OpenNewActiveConnection();
        await database.DidNotReceive().RunSql("-- create database", Arg.Any<ConnectionType>(), Arg.Any<TransactionHandling>());
    }

    [Fact]
    public async Task Readiness_retries_only_connection_failures_and_suppresses_the_ambient_transaction()
    {
        var database = Substitute.For<IDatabase>();
        var connection = Substitute.For<IDisposable>();
        var attempts = 0;
        database.OpenNewActiveConnection().Returns(_ =>
        {
            Assert.Null(Transaction.Current);
            if (++attempts == 1) throw new DatabaseUnavailable();
            return Task.FromResult(connection);
        });
        using var scope = new TransactionScope(TransactionScopeAsyncFlowOption.Enabled);
        var transaction = Transaction.Current;

        await DatabaseReadiness.Wait(database);

        Assert.Equal(2, attempts);
        Assert.Same(transaction, Transaction.Current);
        connection.Received(1).Dispose();
        scope.Complete();
    }

    [Fact]
    public async Task Readiness_rethrows_the_final_database_error_when_all_attempts_fail()
    {
        var database = Substitute.For<IDatabase>();
        var attempts = 0;
        var error = new DatabaseUnavailable();
        database.OpenNewActiveConnection().Returns<Task<IDisposable>>(_ =>
        {
            attempts++;
            throw error;
        });

        var actual = await Assert.ThrowsAsync<DatabaseUnavailable>(() => DatabaseReadiness.Wait(database));

        Assert.Same(error, actual);
        Assert.Equal(10, attempts);
    }

    [Fact]
    public async Task Readiness_does_not_retry_non_database_errors()
    {
        var database = Substitute.For<IDatabase>();
        var error = new InvalidOperationException("Invalid connection configuration");
        database.OpenNewActiveConnection().Returns<Task<IDisposable>>(_ => throw error);

        var actual = await Assert.ThrowsAsync<InvalidOperationException>(() => DatabaseReadiness.Wait(database));

        Assert.Same(error, actual);
        await database.Received(1).OpenNewActiveConnection();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Failed_fresh_connection_is_disposed_and_keeps_the_default_connection_active(bool databaseError)
    {
        var original = Substitute.For<DbConnection>();
        var candidate = Substitute.For<DbConnection>();
        Exception error = databaseError ? new DatabaseUnavailable() : new InvalidOperationException();
        await using var database = new ProbeDatabase(new Queue<DbConnection>([original, candidate]), _ => Task.FromException(error));
        database.SetDefaultConnectionActive();

        var actual = await Assert.ThrowsAnyAsync<Exception>(() => database.OpenNewActiveConnection());

        Assert.Same(error, actual);
        await candidate.Received(1).DisposeAsync();
        Assert.Same(original, database.CurrentConnection);
    }

    [Fact]
    public async Task Successful_probe_disposes_its_connection_and_restores_the_default()
    {
        var original = Substitute.For<DbConnection>();
        var candidate = Substitute.For<DbConnection>();
        await using var database = new ProbeDatabase(new Queue<DbConnection>([original, candidate]), _ => Task.CompletedTask);
        database.SetDefaultConnectionActive();

        await DatabaseReadiness.Wait(database);

        candidate.Received(1).Dispose();
        Assert.Same(original, database.CurrentConnection);
    }

    private IDatabase CreateDatabase()
    {
        var database = Substitute.For<IDatabase>();
        database.Clone().Returns(_ => CreateDatabase());
        database.GetStatements(Arg.Any<string>()).Returns(call => [call.Arg<string>()]);
        database.InitializeConnections(Arg.Any<GrateConfiguration>()).Returns(call =>
        {
            var configuration = call.Arg<GrateConfiguration>();
            if (configuration.Environment == GrateEnvironment.Internal || configuration.Environment == GrateEnvironment.InternalBootstrap)
                _internalDirectories.Add(configuration.SqlFilesDirectory);
            return Task.CompletedTask;
        });
        return database;
    }

    private GrateMigrator CreateMigrator(IDatabase database, bool dryRun = false)
    {
        var defaults = FoldersConfiguration.Default();
        var folders = new FoldersConfiguration(defaults[KnownFolderKeys.RunAfterCreateDatabase]!)
        {
            CreateDatabase = defaults.CreateDatabase
        };
        var configuration = new GrateConfiguration
        {
            Folders = folders,
            SqlFilesDirectory = _directory,
            OutputPath = new DirectoryInfo(Path.Combine(_directory.FullName, "output")),
            NonInteractive = true,
            Environment = new GrateEnvironment("DEV"),
            DryRun = dryRun
        };
        return new GrateMigrator(new MockGrateLoggerFactory(),
            new DbMigrator(database, NullLogger<DbMigrator>.Instance, new HashGenerator(), configuration));
    }

    private void WriteScript(string path, string sql)
    {
        var fullPath = Path.Combine(_directory.FullName, path);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        File.WriteAllText(fullPath, sql);
    }

    public void Dispose()
    {
        _directory.Delete(true);
        foreach (var directory in _internalDirectories.DistinctBy(directory => directory.FullName))
            if (directory.Exists) directory.Delete(true);
    }

    private sealed class DatabaseUnavailable : DbException;

    private sealed record ProbeDatabase(Queue<DbConnection> Connections, Func<DbConnection, Task> OpenAttempt)
        : SqlServerDatabase(NullLogger<SqlServerDatabase>.Instance)
    {
        public DbConnection CurrentConnection => ActiveConnection;
        protected override DbConnection GetSqlConnection(string? connectionString) => Connections.Dequeue();
        protected override Task Open(DbConnection? connection) => OpenAttempt(connection!);
    }
}
