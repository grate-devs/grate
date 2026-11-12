using System.Data.Common;
using grate.Configuration;
using grate.Exceptions;
using grate.Infrastructure;
using grate.Infrastructure.Npgsql;
using grate.Migration;
using grate.postgresql.Infrastructure;
using grate.PostgreSql.Infrastructure;
using Microsoft.Extensions.Logging;
using Npgsql;
namespace grate.PostgreSql.Migration;

public record PostgreSqlDatabase : AnsiSqlDatabase
{
    public override string MasterDatabaseName => "postgres";
    public override string DatabaseType => Type;
    public PostgreSqlDatabase(ILogger<PostgreSqlDatabase> logger)
        : base(logger, Syntax)
    { }

    public static string Type => "postgresql";
    public static ISyntax Syntax { get; } = new PostgreSqlSyntax();

    public override bool SupportsDdlTransactions => true;
    public override bool SupportsSchemas => true;
    protected override DbConnection GetSqlConnection(string? connectionString) => new NpgsqlConnection(connectionString);

    public override Task RestoreDatabase(string backupPath)
    {
        throw new NotImplementedException("Restoring a database from file is not currently supported for  Postgresql.");
    }

    public override IEnumerable<string> GetStatements(string sql)
        => ReflectionNpgsqlQueryParser.Split(sql);


    public override void ThrowScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception exception)
    {
        throw new PostgreSqlScriptFailed(folder, file, scriptText, exception);
    }
}
