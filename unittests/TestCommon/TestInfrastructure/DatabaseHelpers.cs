using System.Data.Common;
using System.Transactions;
using Dapper;
using Microsoft.Data.Sqlite;
using Xunit.Sdk;

#if NET6_0
using Dir = TestCommon.TestInfrastructure.Net6PolyFills.Directory;
#else
using Dir = System.IO.Directory;
#endif

namespace TestCommon.TestInfrastructure;

public static class DatabaseHelpers
{
    internal static async Task CreateDatabaseFromConnectionString(this IGrateTestContext context, string db, string connectionString, ITestOutputHelper output)
    {
        var uid = TestConfig.Username(connectionString);
        var pwd = TestConfig.Password(connectionString);

        using (new TransactionScope(TransactionScopeOption.Suppress, TransactionScopeAsyncFlowOption.Enabled))
        {
            for (var i = 0; i < 5; i++)
            {
                try
                {
                    using var conn = context.CreateAdminDbConnection();

                    string? commandText = null;
                    try
                    {
                        commandText = context.Syntax.CreateDatabase(db, pwd);
                        await conn.ExecuteAsync(commandText);
                    }
                    catch (DbException dbe)
                    {
                        output.WriteLine("Got error when creating database: " + dbe.Message);
                        output.WriteLine("database: " + db);
                        output.WriteLine("admin connection string: " + conn.ConnectionString);
                        output.WriteLine("user connection string: " + connectionString);
                        output.WriteLine("commandText: " + commandText);
                    }

                    string? createUserSql = null;
                    try
                    {
                        createUserSql = context.Sql.CreateUser(db, uid, pwd);
                        if (createUserSql is not null)
                        {
                            await conn.ExecuteAsync(createUserSql);
                        }
                    }
                    catch (DbException dbe)
                    {
                        output.WriteLine("Got error when creating user: " + dbe.Message);
                        output.WriteLine("Error creating user: " + uid + " for database: " + db);
                        output.WriteLine("admin connection string: " + conn.ConnectionString);
                        output.WriteLine("user connection string: " + connectionString);
                        output.WriteLine("createUserSql: " + createUserSql);
                    }

                    var grantAccessSql = context.Sql.GrantAccess(db, uid);
                    if (grantAccessSql is not null)
                    {
                        await conn.ExecuteAsync(grantAccessSql);
                    }

                    break;
                }
                catch (DbException dbe)
                {
                    output.WriteLine($"Got error in loop, iteration: {i}: {dbe.Message}");
                }

                await Task.Delay(1000);
            }
        }
    }

    internal static async Task<IEnumerable<string>> GetDatabases(this IGrateTestContext context, ITestOutputHelper output)
    {
        IEnumerable<string> databases = Enumerable.Empty<string>();
        string sql = context.Syntax.ListDatabases;

        using (new TransactionScope(TransactionScopeOption.Suppress, TransactionScopeAsyncFlowOption.Enabled))
        {
            for (var i = 0; i < 5; i++)
            {
                using var conn = context.CreateAdminDbConnection();
                try
                {
                    databases = (await conn.QueryAsync<string>(sql)).ToArray();
                    break;
                }
                catch (DbException dbe)
                {
                    output.WriteLine("Got error when listing databases: " + dbe.Message);
                    output.WriteLine("admin connection string: " + conn.ConnectionString);
                }
            }
        }
        return databases.ToArray();
    }
    
    public static async Task CreateSqliteDatabaseFromConnectionString(string connectionString)
    {
        await using var conn = new SqliteConnection(connectionString);
        conn.Open();
        await using var cmd = conn.CreateCommand();

        // Create a table to actually create the .sqlite file
        var sql = "CREATE TABLE dummy(name VARCHAR(1))";
        cmd.CommandText = sql;
        await cmd.ExecuteNonQueryAsync();

        // Remove the table to avoid polluting the database with dummy tables :)
        sql = "DROP TABLE dummy";
        cmd.CommandText = sql;
        await cmd.ExecuteNonQueryAsync();
    }

    public static async Task<IEnumerable<string>> GetSqliteDatabases(this IGrateTestContext context)
    {
        var builder = new SqliteConnectionStringBuilder(context.AdminConnectionString);
        var root = Path.GetDirectoryName(builder.DataSource) ?? Dir.CreateTempSubdirectory().ToString() ;
        var dbFiles = Directory.EnumerateFiles(root, "*.db");
        IEnumerable<string> dbNames = dbFiles
            .Select(Path.GetFileNameWithoutExtension)
            .Where(name => name is not null)
            .Cast<string>();

        return await ValueTask.FromResult(dbNames);
    }

    
}
