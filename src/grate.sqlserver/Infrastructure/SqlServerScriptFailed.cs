using System.Collections;
using grate.Configuration;
using grate.Exceptions;
using Microsoft.Data.SqlClient;

namespace grate.sqlserver.Infrastructure;

public class SqlServerScriptFailed: ScriptFailed
{
    public SqlServerScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception cause) 
        : base(folder, file, scriptText, cause)
    {
    }
    
    protected override IDictionary<string, object?> GetDbScriptErrors()
        => GatherDetails(SqlException);

    private SqlException? SqlException => DbException as SqlException;

    //protected override int Position => this.SqlException!.LineNumber

    protected override (int? line, int position) LineAndPosition => (
        SqlException!.LineNumber > 0 ? SqlException.LineNumber - 1 : 0, 0);


    private IDictionary<string, object?> GatherDetails(SqlException? ex)
    {
        return DbException is null 
            ? new Dictionary<string, object?>()
            : new Dictionary<string, object?>()
            {
                { nameof(SqlException.Message), ex!.Message },
                { nameof(SqlException.LineNumber), ex.LineNumber },
                { nameof(SqlException.Number), ex.Number },
                { nameof(SqlException.Procedure), ex.Procedure },
                { nameof(SqlException.Server), ex.Server },
                { nameof(SqlException.Source), ex.Source },
                { nameof(SqlException.State), ex.State },
                { nameof(SqlException.ClientConnectionId), ex.ClientConnectionId },
                { nameof(SqlException.Class), ex.Class },
                { nameof(SqlException.ErrorCode), ex.ErrorCode },
#if !NETSTANDARD2_0
                // SqlState and IsTransient are not exposed on the netstandard2.0 build of Microsoft.Data.SqlClient.
                { nameof(SqlException.SqlState), ex.State },
                { nameof(SqlException.IsTransient), ex.IsTransient },
#endif
                { nameof(SqlException.HelpLink), ex.HelpLink },
                { nameof(SqlException.HResult), ex.HResult },
                { nameof(SqlException.StackTrace), ex.StackTrace } 
            };
    }
    
}
