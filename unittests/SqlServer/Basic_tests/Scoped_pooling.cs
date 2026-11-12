using System.Reflection;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using SqlServer.TestInfrastructure;

namespace SqlServer.Basic_tests;

public sealed class Scoped_pooling(IConfiguration configuration)
{
    [Fact]
    public async Task Pooling_requires_opt_in_and_case_scope_and_restores_state_after_failure()
    {
        foreach (var value in new string?[] { null, "", "false", "yes", "1" })
        {
            Assert.False(SqlServerScopedPooling.IsOptedIn(value));
        }
        Assert.True(SqlServerScopedPooling.IsOptedIn("true"));

        var original = new SqlConnectionStringBuilder
        {
            DataSource = "fixture,1433",
            InitialCatalog = "target; quoted=name",
            UserID = "sa",
            Password = "round; trip 'with\" spaces=æ",
            Encrypt = false,
            Pooling = false,
            ConnectTimeout = 5
        }.ConnectionString;
        var optedIn = bool.TryParse(Environment.GetEnvironmentVariable("GRATE_SQLSERVER_SCOPED_POOLING"), out var flagValue) && flagValue;
        Assert.Equal(configuration["GrateTestConfig:AdminConnectionString"] is null && optedIn,
            new SqlConnectionStringBuilder(SqlServerScopedPooling.TargetConnectionString(original)).Pooling);
        using var disabled = SqlServerScopedPooling.BeginCase(false, clearPools: false);
        Assert.Equal(original, SqlServerScopedPooling.TargetConnectionString(original));
        using (SqlServerScopedPooling.BeginCase(true, clearPools: false))
        {
            await Task.Yield();
            var pooled = new SqlConnectionStringBuilder(SqlServerScopedPooling.TargetConnectionString(original));
            Assert.True(pooled.Pooling);
            Assert.Equal(PoolBlockingPeriod.NeverBlock, pooled.PoolBlockingPeriod);
            Assert.Equal(0, pooled.MinPoolSize);
            Assert.Equal(4, pooled.MaxPoolSize);
            Assert.Equal("fixture,1433", pooled.DataSource);
            Assert.Equal("target; quoted=name", pooled.InitialCatalog);
            Assert.Equal("sa", pooled.UserID);
            Assert.Equal("round; trip 'with\" spaces=æ", pooled.Password);
            Assert.Equal(5, pooled.ConnectTimeout);
            Assert.Equal(SqlConnectionEncryptOption.Optional, pooled.Encrypt);
        }
        Assert.Equal(original, SqlServerScopedPooling.TargetConnectionString(original));

        Action failInScope = () =>
        {
            using var scope = SqlServerScopedPooling.BeginCase(true, clearPools: false);
            throw new InvalidOperationException("scope failure control");
        };
        Assert.Throws<InvalidOperationException>(failInScope);
        Assert.Equal(original, SqlServerScopedPooling.TargetConnectionString(original));
    }

    [Fact]
    public void System_catalogs_and_other_users_remain_unpooled()
    {
        using var scope = SqlServerScopedPooling.BeginCase(true, clearPools: false);
        foreach (var (database, user, integrated) in new[]
        {
            ("", "sa", false), ("master", "sa", false), ("mOdEl", "sa", false),
            ("msdb", "sa", false), ("tempdb", "sa", false),
            ("target", "zorro", false), ("target", "", true)
        })
        {
            var original = new SqlConnectionStringBuilder
            {
                DataSource = "fixture,1433",
                InitialCatalog = database,
                UserID = user,
                IntegratedSecurity = integrated,
                Pooling = false
            }.ConnectionString;
            Assert.Equal(original, SqlServerScopedPooling.TargetConnectionString(original));
        }
    }

    [Fact]
    public void Restore_opt_outs_and_explicit_blocking_period_are_preserved()
    {
        var restore = typeof(Running_MigrationScripts.RestoreDatabase).GetMethod("Restores_both_files_and_migrates");
        var failure = typeof(Reported_issues.RestoreFailure).GetMethod("Unknown_logical_file_leaves_existing_database_in_multi_user_mode");
        var snapshot = typeof(Reported_issues.Run_after_create_database_232).GetMethod("Bug232_Timeout_v1U002E4U002E0_Regression");
        var markedMethod = typeof(Scoped_pooling).GetMethod(nameof(Unpooled_method), BindingFlags.NonPublic | BindingFlags.Static);
        Assert.NotNull(restore);
        Assert.NotNull(failure);
        Assert.NotNull(snapshot);
        Assert.NotNull(markedMethod);
        Assert.True(SqlServerScopedPooling.IsUnpooledCase(restore));
        Assert.True(SqlServerScopedPooling.IsUnpooledCase(failure));
        Assert.True(SqlServerScopedPooling.IsUnpooledCase(snapshot));
        Assert.True(SqlServerScopedPooling.IsUnpooledCase(markedMethod));

        if (string.Equals(Environment.GetEnvironmentVariable("GRATE_REPRODUCIBLE_TABLE_CASINGS"), "true", StringComparison.OrdinalIgnoreCase))
        {
            var tables = TestCommon.Generic.Bootstrapping.When_Grate_structure_is_not_latest_version
                .TablesWithDifferentCasings().Select(row => ((ITheoryDataRow)row).GetData()).ToArray();
            var versions = TestCommon.Generic.Bootstrapping.When_Grate_structure_is_not_latest_version
                .VersionTableWithDifferentCasings().Select(row => ((ITheoryDataRow)row).GetData()).ToArray();
            Assert.Equal(27, tables.Length);
            Assert.Equal(27, tables.Select(row => string.Join("\0", row)).Distinct(StringComparer.Ordinal).Count());
            Assert.Equal(3, versions.Length);
            Assert.Equal(3, versions.Select(row => Assert.IsType<string>(Assert.Single(row))).Distinct(StringComparer.Ordinal).Count());
        }

        using var scope = SqlServerScopedPooling.BeginCase(true, clearPools: false);
        var builder = new SqlConnectionStringBuilder(SqlServerScopedPooling.TargetConnectionString(
            "Server=fixture;Database=target;User ID=sa;Pooling=false"));
        // Match the existing readiness test: its explicit override wins after
        // the fixture supplies the target string, without a connection rewrite.
        builder.Remove("Pooling");
        builder.PoolBlockingPeriod = PoolBlockingPeriod.AlwaysBlock;
        Assert.True(builder.Pooling);
        Assert.Equal(PoolBlockingPeriod.AlwaysBlock, builder.PoolBlockingPeriod);
    }

    [UnpooledSqlServer]
    private static void Unpooled_method() { }
}
