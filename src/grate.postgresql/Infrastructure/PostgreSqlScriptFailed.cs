using System.Collections;
using grate.Configuration;
using grate.Exceptions;
using Npgsql;

namespace grate.postgresql.Infrastructure;

public class PostgreSqlScriptFailed : ScriptFailed
{
    public PostgreSqlScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception cause)
        : base(folder, file, scriptText, cause)
    {
    }

    protected override int Position => this.DbException is PostgresException postgresException
        ? postgresException.Position
        : 0;

    protected override string? InnerExceptionMessage => DbException is PostgresException postgresException
        ? $"{postgresException.SqlState}: {postgresException.MessageText}"
        : InnerException?.Message;

    protected override IDictionary<string, object?> GetDbScriptErrors()
        => InnerException!.Data
            .Cast<DictionaryEntry>()
            .ToDictionary(entry => entry.Key.ToString()!, entry => entry.Value);

}
