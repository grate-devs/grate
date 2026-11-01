using grate.Configuration;
using grate.Exceptions;
using grate.Infrastructure;
using grate.Migration;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;

namespace Basic_tests;

public class DbMigrator_Roundhouse_hashes
{
    private const string ScriptName = "001.sql";
    private const string NormalizedHash = "V80d+mQUUMs/JoNH3rkeMg==";
    private readonly IDatabase _database = Substitute.For<IDatabase>();

    // Frozen RoundhousE hashes of SELECT 'æ';<EOL>SELECT 2;<EOL>, including
    // apostrophe escaping and UTF-8. LF is also the current normalized format.
    public static TheoryData<string> StoredHashes => new()
    {
        NormalizedHash,
        "y/UjYUSSI4HWQbpoD1vcqw==", // CRLF
        "t7GiNq4DJu9ePpOPw1bHCA=="  // CR
    };

    public static TheoryData<string, string, MigrationType> UnchangedScripts
    {
        get
        {
            var cases = new TheoryData<string, string, MigrationType>();
            foreach (var hash in StoredHashes)
            foreach (var lineEnding in new[] { "\n", "\r\n", "\r" })
            foreach (var type in new[] { MigrationType.Once, MigrationType.AnyTime })
            {
                cases.Add(hash.Data, $"SELECT 'æ';{lineEnding}SELECT 2;{lineEnding}", type);
            }

            return cases;
        }
    }

    [Theory]
    [MemberData(nameof(UnchangedScripts))]
    public async Task Unchanged_scripts_with_Roundhouse_hashes_are_skipped_without_rewriting_history(
        string storedHash, string sql, MigrationType type)
    {
        await using var migrator = CreateMigrator(storedHash);

        Assert.False(await RunScript(migrator, sql, type));

        await _database.DidNotReceiveWithAnyArgs().RunSql(default!, default, default);
        await _database.DidNotReceiveWithAnyArgs().InsertScriptRun(default!, default, default!, default, default, default);
        await _database.DidNotReceiveWithAnyArgs().InsertScriptRunError(default!, default, default!, default!, default);
    }

    [Theory]
    [MemberData(nameof(StoredHashes))]
    public async Task Changed_one_time_scripts_with_Roundhouse_hashes_are_still_rejected(string storedHash)
    {
        await using var migrator = CreateMigrator(storedHash);

        await Assert.ThrowsAsync<OneTimeScriptChanged>(() =>
            RunScript(migrator, "SELECT 'æ';\nSELECT 3;\n", MigrationType.Once));

        await _database.DidNotReceiveWithAnyArgs().RunSql(default!, default, default);
        await _database.DidNotReceiveWithAnyArgs().InsertScriptRun(default!, default, default!, default, default, default);
    }

    [Theory]
    [MemberData(nameof(StoredHashes))]
    public async Task Changed_anytime_scripts_with_Roundhouse_hashes_are_executed(string storedHash)
    {
        const string sql = "SELECT 'æ';\nSELECT 3;\n";
        await using var migrator = CreateMigrator(storedHash);

        Assert.True(await RunScript(migrator, sql, MigrationType.AnyTime));

        await _database.Received(1).RunSql(sql, ConnectionType.Default, TransactionHandling.Default);
        await _database.Received(1).InsertScriptRun(ScriptName, sql, "laDe53L9r7FaHjMSgjBOyw==", false, 1, TransactionHandling.Default);
    }

    [Theory]
    [MemberData(nameof(StoredHashes))]
    public async Task Everytime_scripts_still_run_and_record_normalized_hashes(string storedHash)
    {
        const string sql = "SELECT 'æ';\r\nSELECT 2;\r\n";
        await using var migrator = CreateMigrator(storedHash);

        Assert.True(await RunScript(migrator, sql, MigrationType.EveryTime));

        await _database.Received(1).RunSql(sql, ConnectionType.Default, TransactionHandling.Default);
        await _database.Received(1).InsertScriptRun(ScriptName, sql, NormalizedHash, false, 1, TransactionHandling.Default);
    }

    [Theory]
    [MemberData(nameof(StoredHashes))]
    public async Task Legacy_hashes_are_compared_after_token_replacement(string storedHash)
    {
        await using var migrator = CreateMigrator(storedHash);
        migrator.Configuration = migrator.Configuration with
        {
            DisableTokenReplacement = false,
            UserTokens = ["Value=æ"]
        };

        Assert.False(await RunScript(migrator, "SELECT '{{Value}}';\nSELECT 2;\n", MigrationType.Once));

        await _database.DidNotReceiveWithAnyArgs().RunSql(default!, default, default);
        await _database.DidNotReceiveWithAnyArgs().InsertScriptRun(default!, default, default!, default, default, default);
    }

    private DbMigrator CreateMigrator(string storedHash)
    {
        _database.HasRun(ScriptName, TransactionHandling.Default).Returns(true);
        _database.GetCurrentHash(ScriptName).Returns(storedHash);
        _database.GetStatements(Arg.Any<string>()).Returns(call => new[] { call.Arg<string>() });

        return new DbMigrator(_database, NullLogger<DbMigrator>.Instance, new HashGenerator(),
            new GrateConfiguration { DisableTokenReplacement = true });
    }

    private static async Task<bool> RunScript(DbMigrator migrator, string sql, MigrationType type) =>
        (await migrator.RunSql(sql, ScriptName, new MigrationsFolder("scripts", type), 1, null,
            ConnectionType.Default, TransactionHandling.Default)).SqlRun;
}
