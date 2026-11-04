using System.Transactions;
using grate.Configuration;
using grate.Exceptions;
using grate.Infrastructure;
using grate.Migration;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;

namespace Basic_tests;

public sealed class DryRunSafety
{
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Database_lifecycle_writes_are_skipped_only_in_dryrun(bool dryRun)
    {
        var database = Substitute.For<IDatabase>();
        var configuration = new GrateConfiguration { DryRun = dryRun, Drop = true, CreateDatabase = true };
        await using var migrator = new DbMigrator(database, NullLogger<DbMigrator>.Instance, new HashGenerator(), configuration);

        Assert.Equal(!dryRun, await migrator.CreateDatabase());
        await migrator.DropDatabase();
        await migrator.RestoreDatabase("backup.bak");

        await database.Received(dryRun ? 0 : 1).CreateDatabase();
        await database.Received(dryRun ? 0 : 1).DropDatabase();
        await database.Received(dryRun ? 0 : 1).RestoreDatabase("backup.bak");
    }

    [Fact]
    public async Task Changed_one_time_script_in_dryrun_reports_error_without_writes_or_rollback()
    {
        var database = Substitute.For<IDatabase>();
        database.HasRun("001.sql", TransactionHandling.Default).Returns(true);
        database.GetCurrentHash("001.sql").Returns("old hash");
        await using var migrator = new DbMigrator(database, NullLogger<DbMigrator>.Instance, new HashGenerator(),
            new GrateConfiguration { DryRun = true });
        using var scope = new TransactionScope(TransactionScopeAsyncFlowOption.Enabled);
        var transaction = Transaction.Current!;

        await Assert.ThrowsAsync<OneTimeScriptChanged>(() => migrator.RunSql("SELECT 1;", "001.sql",
            new MigrationsFolder("Up", "Up", "up", MigrationType.Once), 42, null,
            ConnectionType.Default, TransactionHandling.Default));

        database.DidNotReceive().Rollback();
        Assert.Same(transaction, Transaction.Current);
        Assert.Equal(TransactionStatus.Active, transaction.TransactionInformation.Status);
        await database.DidNotReceiveWithAnyArgs().InsertScriptRunError(default!, default, default!, default!, default);
        await database.DidNotReceiveWithAnyArgs().ChangeVersionStatus(default!, default);
        await database.DidNotReceiveWithAnyArgs().InsertScriptRun(default!, default, default!, default, default, default);
        await database.DidNotReceiveWithAnyArgs().RunSql(default!, default, default);
        scope.Complete();
    }
}
