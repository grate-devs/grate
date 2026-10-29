using System.Transactions;
using grate.Configuration;
using grate.Infrastructure;
using grate.Migration;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;

namespace Basic_tests;

public sealed class Migration_transactions : IDisposable
{
    private readonly DirectoryInfo _directory = Directory.CreateTempSubdirectory("grate-transactions-");

    [Fact]
    public async Task A_new_migration_transaction_uses_read_committed()
    {
        await RunMigration(transaction =>
        {
            Assert.Equal(IsolationLevel.ReadCommitted, transaction.IsolationLevel);
            Assert.Equal(TransactionStatus.Active, transaction.TransactionInformation.Status);
        });
        Assert.Null(Transaction.Current);
    }

    [Fact]
    public async Task A_migration_joins_an_existing_default_transaction_without_changing_its_isolation()
    {
        using var scope = new TransactionScope(TransactionScopeAsyncFlowOption.Enabled);
        var callerTransaction = Transaction.Current!;

        await RunMigration(transaction => Assert.Same(callerTransaction, transaction));
        Assert.Same(callerTransaction, Transaction.Current);
        Assert.Equal(IsolationLevel.Serializable, callerTransaction.IsolationLevel);
        Assert.Equal(TransactionStatus.Active, callerTransaction.TransactionInformation.Status);
        scope.Complete();
    }

    private async Task RunMigration(Action<Transaction> inspectTransaction)
    {
        var scripts = _directory.CreateSubdirectory("scripts");
        var up = scripts.CreateSubdirectory("up");
        await File.WriteAllTextAsync(Path.Combine(up.FullName, "001.sql"), "SELECT 1;", TestContext.Current.CancellationToken);
        var database = Substitute.For<IDatabase>();
        database.SupportsDdlTransactions.Returns(true);
        database.ServerName.Returns("synthetic-server");
        database.DatabaseName.Returns("synthetic-database");
        var observedTransaction = false;
        database.InsertScriptRun(Arg.Any<string>(), Arg.Any<string>(), Arg.Any<string>(), Arg.Any<bool>(), Arg.Any<long>(), Arg.Any<TransactionHandling>())
            .Returns(_ =>
            {
                inspectTransaction(Assert.IsAssignableFrom<Transaction>(Transaction.Current));
                observedTransaction = true;
                return Task.CompletedTask;
            });
        var config = new GrateConfiguration
        {
            Transaction = true,
            CreateDatabase = false,
            NonInteractive = true,
            Environment = GrateEnvironment.Internal,
            SqlFilesDirectory = scripts,
            OutputPath = new DirectoryInfo(Path.Combine(_directory.FullName, "output"))
        };
        var dbMigrator = new DbMigrator(database, NullLogger<DbMigrator>.Instance, new HashGenerator(), config);
        await using var migrator = new GrateMigrator(NullLoggerFactory.Instance, dbMigrator);

        await migrator.Migrate();

        Assert.True(observedTransaction);
    }

    public void Dispose() => _directory.Delete(true);
}
