using System.Collections;
using System.Data.Common;
using grate.Configuration;
using grate.Exceptions;
using Microsoft.Data.Sqlite;

namespace grate.sqlite.Infrastructure;

public class SqliteScriptFailed: ScriptFailed
{
    public SqliteScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception cause) 
        : base(folder, file, scriptText, cause)
    {
    }

    protected override IDictionary<string, object?> GetDbScriptErrors()
        => GatherDetails(DbException as SqliteException);
    
    protected override int Position => this.DbException is SqliteException sqliteException
        ? sqliteException.ErrorCode
        : 0;

    protected override string? ErrorSnippet => null;


    private IDictionary<string, object?> GatherDetails(SqliteException? ex)
    {
        return ex is null  
            ? new Dictionary<string, object?>()
            : new Dictionary<string, object?>()
            {
                { nameof(SqliteException.Message), ex.Message },
                { nameof(SqliteException.Source), ex.Source },
                { nameof(SqliteException.SqliteErrorCode), ex.SqliteErrorCode },
                { nameof(SqliteException.SqliteExtendedErrorCode), ex.SqliteExtendedErrorCode },
#if !NETSTANDARD2_0
                // IsTransient is not exposed on the netstandard2.0 build of Microsoft.Data.Sqlite.
                { nameof(SqliteException.IsTransient), ex.IsTransient },
#endif
                { nameof(SqliteException.HelpLink), ex.HelpLink },
                { nameof(SqliteException.HResult), ex.HResult },
                { nameof(SqliteException.StackTrace), ex.StackTrace }
            };
    }
}
