using grate.Configuration;
using Oracle.ManagedDataAccess.Client;
using Oracle.TestInfrastructure;
using TestCommon.TestInfrastructure;
using Microsoft.Extensions.Logging.Abstractions;

namespace Oracle;

[Collection(nameof(OracleGrateTestContext))]
public sealed class ConnectionPooling(OracleGrateTestContext context, GrateTestConfig configuration)
{
    [Fact]
    public async Task Fixture_connections_use_the_selected_pooling_policy()
    {
        var scoped = string.Equals(Environment.GetEnvironmentVariable("GRATE_ORACLE_SCOPED_POOLING"),
            "true", StringComparison.OrdinalIgnoreCase);
        var externalPooling = configuration.AdminConnectionString is { } external
                              && new OracleConnectionStringBuilder(external).Pooling;
        var expectedPooling = scoped || externalPooling;

        foreach (var value in new[]
                 {
                     context.AdminConnectionString,
                     context.ConnectionString("POOL_POLICY_PROBE"),
                     context.UserConnectionString("POOL_POLICY_PROBE")
                 })
        {
            var connection = new OracleConnectionStringBuilder(value);
            Assert.Equal(expectedPooling, connection.Pooling);
            if (scoped)
            {
                Assert.Equal(0, connection.MinPoolSize);
                Assert.Equal(4, connection.MaxPoolSize);
            }
        }

        foreach (var password in new[] { "generatedAZ012", "a;PASSWORD=b", "a=b", "a\"b", "a' b" })
        {
            var original = new OracleConnectionStringBuilder
            {
                DataSource = "localhost/FREEPDB1",
                UserID = "system",
                Password = password,
                Pooling = false
            }.ConnectionString;
            var configured = OracleTestConnectionPools.Configure(original);
            Assert.True(password == new OracleConnectionStringBuilder(configured).Password,
                "Pooling configuration must preserve the password value.");

        }

        var legacyInput = OracleTestConnectionPools.Configure(
            "Data Source=localhost/FREEPDB1;User ID=system;Password=generatedAZ012;Pooling=False");
        await using var database = new grate.Oracle.Migration.OracleDatabase(
            NullLogger<grate.Oracle.Migration.OracleDatabase>.Instance);
        await database.InitializeConnections(new GrateConfiguration { ConnectionString = legacyInput });
        Assert.Equal("system", database.DatabaseName);
        var legacyPassword = legacyInput.Split(';', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .SingleOrDefault(entry => entry.StartsWith("Password") || entry.StartsWith("Pwd"))?
            .Split('=', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Last();
        Assert.True("generatedAZ012" == legacyPassword,
            "Pooling configuration must preserve the key expected by custom bootstrap tests.");

        if (scoped)
        {
            var admin = context.AdminConnectionString;
            var actualLegacyPassword = admin.Split(';', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
                .SingleOrDefault(entry => entry.StartsWith("Password") || entry.StartsWith("Pwd"))?
                .Split('=', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
                .Last();
            Assert.True(actualLegacyPassword == new OracleConnectionStringBuilder(admin).Password,
                "The fixture's serialized admin password must remain readable by custom bootstrap tests.");
        }

        if (string.Equals(Environment.GetEnvironmentVariable("GRATE_REPRODUCIBLE_TABLE_CASINGS"),
                "true", StringComparison.OrdinalIgnoreCase))
        {
            var cases = TestCommon.Generic.Bootstrapping.When_Grate_structure_is_not_latest_version.TablesWithDifferentCasings();
            var rows = cases.Select(row => ((ITheoryDataRow)row).GetData()).ToArray();
            Assert.Equal(27, rows.Length);
            Assert.Equal(27, rows.Select(row => string.Join("\0", row.Cast<string>())).Distinct(StringComparer.Ordinal).Count());

            var defaults = GrateConfiguration.Default;
            var originals = new[] { defaults.ScriptsRunTableName, defaults.ScriptsRunErrorsTableName, defaults.VersionTableName };
            for (var index = 0; index < originals.Length; index++)
            {
                var variants = rows.Select(row => (string)row[index]!).Distinct(StringComparer.Ordinal).ToArray();
                Assert.Equal(3, variants.Length);
                Assert.Contains(originals[index], variants);
                Assert.Contains(originals[index].ToLower(), variants);
                var mixed = variants.Single(value => value != originals[index] && value != originals[index].ToLower());
                Assert.True(mixed.Any(char.IsUpper) && mixed.Any(char.IsLower));
            }
        }
    }
}
