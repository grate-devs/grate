using System.Data.Common;
using grate.Configuration;
using grate.Infrastructure;
using grate.MariaDb.Migration;
using grate.Migration;
using grate.PostgreSql.Migration;
using grate.Sqlite.Migration;
using grate.SqlServer.Migration;
using Microsoft.Data.SqlClient;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using MySqlConnector;
using Npgsql;
using Oracle.ManagedDataAccess.Client;
using OracleDatabase = grate.Oracle.Migration.OracleDatabase;

namespace Basic_tests.Infrastructure;

public class ConnectionStringExtensionTests
{
    public static TheoryData<string, string> CatalogConnectionStrings()
    {
        var cases = new TheoryData<string, string>();
        foreach (var provider in new[] { "sqlserver", "postgresql", "mariadb" })
        {
            var server = provider == "postgresql" ? "Host=demo" : "Server=demo";
            foreach (var connectionString in new[]
                     {
                         $"{server};Database=app;User ID=demo;Password=dummy",
                         $"Database=app;{server};User ID=demo;Password=dummy",
                         $"{server};database=app;User ID=demo;Password=dummy",
                         $"{server};Database = app;User ID=demo;Password=dummy",
                         $"{server};Database=app;User ID=demo;Password=\"abc;Database=not-a-db;xyz\"",
                         $"{server};Database=app;User ID=demo;Password='abc;Initial Catalog=not-a-db;xyz'",
                         $"{server};Database=\"app;name\";User ID=demo;Password=\"a\"\"b;c=d\";",
                         $"; {server}; DaTaBaSe = 'app' ; User ID = demo ; Password = '  a;=b  ' ;;",
                         $"{server};Database=app;DATABASE=other;User ID=demo;Password=dummy",
                         $"{server};Database=app;Password=first;Pwd=second;Password=third",
                         $"{server};Database=app;Pwd=second;Password=",
                         $"{server};Database=app;Password=first;Pwd=second;Password=",
                         $"{server};Database=app;Password=\"\"",
                         $"{server};Database=app;Password=''",
                         $"{server};Database=;User ID=demo;Password=dummy",
                         $"{server};Database=\"\";User ID=demo;Password=dummy"
                     })
            {
                cases.Add(provider, connectionString);
            }
            if (provider != "postgresql")
            {
                cases.Add(provider, $"Initial Catalog=app;{server};User ID=demo;Password=dummy");
                cases.Add(provider, $"{server};initial catalog = app;User ID=demo;Password=dummy");
                cases.Add(provider, $"{server};Initial Catalog=app;Database=other;User ID=demo;Password=dummy");
                cases.Add(provider, $"{server};Database=app;Initial Catalog=other;User ID=demo;Password=dummy");
                cases.Add(provider, $"{server};Initial Catalog=;User ID=demo;Password=dummy");
                cases.Add(provider, $"{server};Database=app;Initial Catalog=;User ID=demo;Password=dummy");
                cases.Add(provider, $"{server};Initial Catalog=app;Database=;User ID=demo;Password=dummy");
                cases.Add(provider, "Server=first;Data Source=second;Server=third;Database=app");
                cases.Add(provider, $"{server};Database=app;User ID=first;UID=second;User ID=third");
            }
            if (provider == "sqlserver")
            {
                cases.Add(provider, $"{server};Database=app;Application Name=");
                cases.Add(provider, $"{server};Database=app;Workstation ID=");
                cases.Add(provider, $"{server};Database=app;Application Name=\"\"");
                cases.Add(provider, $"{server};Database=app;Application Name=''");
                cases.Add(provider, $"{server};Database=app;Workstation ID=\"\"");
                cases.Add(provider, $"{server};Database=app;Workstation ID=''");
            }
            if (provider == "postgresql")
            {
                cases.Add(provider, $"{server};Database=app;Search Path=\"\"");
                cases.Add(provider, $"{server};Database=app;Search Path=''");
            }
        }
        return cases;
    }

    [Theory]
    [MemberData(nameof(CatalogConnectionStrings))]
    public async Task Uses_provider_admin_database_and_preserves_other_values(string provider, string connectionString)
    {
        await using IDatabase database = provider switch
        {
            "sqlserver" => new SqlServerDatabase(NullLogger<SqlServerDatabase>.Instance),
            "postgresql" => new PostgreSqlDatabase(NullLogger<PostgreSqlDatabase>.Instance),
            "mariadb" => new MariaDbDatabase(NullLogger<MariaDbDatabase>.Instance),
            _ => throw new ArgumentOutOfRangeException(nameof(provider))
        };
        DbConnectionStringBuilder Parse(string value) => provider switch
        {
            "sqlserver" => new SqlConnectionStringBuilder(value),
            "postgresql" => new NpgsqlConnectionStringBuilder(value),
            "mariadb" => new MySqlConnectionStringBuilder(value),
            _ => throw new ArgumentOutOfRangeException(nameof(provider))
        };
        var expected = Parse(connectionString);
        expected[provider == "sqlserver" ? "Initial Catalog" : "Database"] = provider switch
        {
            "sqlserver" => "master",
            "postgresql" => "postgres",
            "mariadb" => "mysql",
            _ => throw new ArgumentOutOfRangeException(nameof(provider))
        };

        var actual = database.GetAdminConnectionString(new GrateConfiguration { ConnectionString = connectionString });

        Assert.NotNull(actual);
        Assert.True(expected.EquivalentTo(Parse(actual)), "Only the parsed database/catalog value should change.");
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("Server=demo;Password=\"abc;Database=not-a-db;xyz\"")]
    public async Task Leaves_connections_without_a_catalog_unchanged(string? connectionString)
    {
        await using var database = new SqlServerDatabase(NullLogger<SqlServerDatabase>.Instance);
        var config = new GrateConfiguration { ConnectionString = connectionString };

        Assert.Equal(connectionString, database.GetAdminConnectionString(config));
    }

    [Theory]
    [InlineData("")]
    [InlineData("Database=explicit;Server=admin;Password='abc;Database=secret'")]
    public async Task Explicit_admin_connection_is_authoritative(string adminConnectionString)
    {
        await using var database = new SqlServerDatabase(NullLogger<SqlServerDatabase>.Instance);
        var config = new GrateConfiguration
        {
            ConnectionString = "not a valid connection string",
            AdminConnectionString = adminConnectionString
        };

        Assert.Equal(adminConnectionString, database.GetAdminConnectionString(config));
    }

    [Fact]
    public async Task Preserves_sqlite_data_source()
    {
        const string connectionString = "Data Source=\"app;Database=keep.db\";Mode=ReadWriteCreate";
        await using var database = new SqliteDatabase(NullLogger<SqliteDatabase>.Instance);

        var actual = database.GetAdminConnectionString(new GrateConfiguration { ConnectionString = connectionString });

        Assert.Equal(connectionString, actual);
        Assert.Equal("app;Database=keep.db", new SqliteConnectionStringBuilder(actual).DataSource);
    }

    [Fact]
    public async Task Preserves_oracle_data_source_and_credentials()
    {
        const string connectionString = "Data Source=demo:1521/FREEPDB1;User ID=demo;Password=\"abc;Database=keep;xyz\"";
        await using var database = new OracleDatabase(NullLogger<OracleDatabase>.Instance);

        var actual = database.GetAdminConnectionString(new GrateConfiguration { ConnectionString = connectionString });

        Assert.Equal(connectionString, actual);
        Assert.True(new OracleConnectionStringBuilder(connectionString)
            .EquivalentTo(new OracleConnectionStringBuilder(actual)));
    }
}
