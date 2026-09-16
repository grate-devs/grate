using System.Collections;
using grate.Configuration;
using grate.Exceptions;
using MySqlConnector;

namespace grate.MariaDb.Infrastructure;

public class MariaDbScriptFailed: ScriptFailed
{
    public MariaDbScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception cause) 
        : base(folder, file, scriptText, cause)
    {
    }
    
    protected override (int? line, int position) LineAndPosition => (0, 0);
    protected override string? ErrorSnippet => null;

    protected override int Position => this.DbException is MySqlException mySqlException
        ? mySqlException.Number
        : 0;

    protected override IDictionary<string, object?>  GetDbScriptErrors()
        => InnerException!.Data 
            .Cast<DictionaryEntry>()
            .ToDictionary(entry => entry.Key.ToString()!, entry => (object?)entry.Value);
    
}
