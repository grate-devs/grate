using System.Collections;
using System.Data.Common;
using grate.Configuration;

namespace grate.Exceptions;

/// <summary>
/// One script failed due to errors
/// </summary>
public abstract class ScriptFailed: MigrationException
{
    public ScriptFailed(MigrationsFolder folder, string file, string? scriptText, Exception cause)
        : base(folder, file, null, cause)
    {
        this.Folder = folder;
        this.File = file;
        ScriptText = scriptText;
        if (cause is DbException dbException)
        {
            this.DbException = dbException;
        }
    }

    public string? ScriptText { get; }
    public DbException? DbException { get; set; }
    
    private static string GetErrorMessage(MigrationsFolder folder, string file, Exception cause)
    {
        return
            $"Error in folder {folder.Path}: Script '{file}' failed due to error: {cause.Message}";
    }
    
    private string GetShortErrorMessage() => 
        $"{File}: {InnerExceptionMessage}" +
        (ErrorSnippet is { } ? $"\n{ErrorSnippet}" : ""); 

    public override string Message => GetShortErrorMessage();

    protected virtual string? InnerExceptionMessage => InnerException?.Message;
        
    public override string ToString() =>
            GetErrorMessage(Folder, File, this.InnerException!) + "\n" 
         + string.Join("\n", ScriptErrors.Select(item => $" * {item.Key}: {item.Value}"));

    public override IDictionary Data => ScriptErrors.ToDictionary(item => item.Key, item => item.Value);

    public IDictionary<string, object?> ScriptErrors
        => DbException is { } 
            ? GetDbScriptErrors() 
            : GetGenericErrorDetails();

    protected virtual int Position => 0;
    
    protected virtual (int? line, int position) LineAndPosition
    {
        get
        {
            var line = 0;
            var pos = 0;
            
            if (ScriptText is { })
            {
                for (var i = 0; i < Position && i < ScriptText.Length; i++)
                {
                    if (ScriptText[i] == '\n')
                    {
                        line++;
                        pos = 0;
                    }
                    else
                    {
                        pos++;
                    }
                }
            }
            
            return (line, pos);
        }
    }
    
    protected virtual string? LineWithError
    {
        get
        {
            if (ScriptText is { })
            {
                var lines = ScriptText.Split('\n');
                var (line, _) = LineAndPosition;
                if (line.HasValue && line.Value < lines.Length)
                {
                    return lines[line.Value];
                }
            }
            return "";
        }
    }

    protected virtual string? ErrorSnippet
    {
        get
        {
            var (line, pos) = LineAndPosition;
            var textPrefix = $"({line},{pos}): ";
            
            var prefix = new String(' ', pos + textPrefix.Length - 1);
            return $"({line},{pos}): " + LineWithError + "\n" +
                prefix + "^ " + InnerExceptionMessage;
        }
    }

    private Dictionary<string, object?> GetGenericErrorDetails() =>
        (InnerException?.Data ?? new Dictionary<string, object?>())
        .Cast<DictionaryEntry>()
        .ToDictionary(entry => entry.Key.ToString()!, entry => (object?)entry.Value);

    protected abstract IDictionary<string, object?> GetDbScriptErrors();


    public bool IsTransient => DbException?.IsTransientError() ?? false;

}
