using System.Collections;
using grate.Configuration;
using grate.Exceptions;
using Oracle.ManagedDataAccess.Client;

namespace grate.oracle.Infrastructure;

public class OracleScriptFailed : ScriptFailed
{
    public OracleScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception cause)
        : base(folder, file, scriptText, cause)
    {
    }

    protected override IDictionary<string, object?> GetDbScriptErrors()
        => GatherDetails(this.DbException as OracleException);

    protected override int Position => this.DbException is OracleException oracleException
        ? oracleException.Errors[0]?.ParseErrorOffset ?? 0
        : 0;


    private IDictionary<string, object?> GatherDetails(OracleException? ex)
    {
        return ex is null
            ? new Dictionary<string, object?>()
            : new Dictionary<string, object?>()
            {
                { nameof(OracleException.Message), ex.Message },
                { nameof(OracleError.ParseErrorOffset), ex.Errors[0]?.ParseErrorOffset },
                { nameof(OracleException.Number), ex.Number },
                { nameof(OracleException.Procedure), ex.Procedure },
                { nameof(OracleException.DataSource), ex.DataSource },
                { nameof(OracleException.Source), ex.Source },
                { nameof(OracleException.ErrorCode), ex.ErrorCode },
                { nameof(OracleException.IsTransient), ex.IsTransient },
                { nameof(OracleException.HelpLink), ex.HelpLink },
                { nameof(OracleException.HResult), ex.HResult },
                { nameof(OracleException.StackTrace), ex.StackTrace }
            };
    }

}
