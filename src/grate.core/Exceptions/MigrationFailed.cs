using System.Collections;
using System.Data.Common;
using System.Text;

namespace grate.Exceptions;

/// <summary>
/// The whole migration failed due to errors
/// </summary>
public class MigrationFailed : AggregateException
{
    private const string ErrorMessage = "Migration failed due to errors";

    public MigrationFailed(IEnumerable<Exception> exceptions)
        : base(ErrorMessage, exceptions)
    {
    }

    public MigrationFailed(params Exception[] exceptions)
        : base(ErrorMessage, exceptions)
    { }

    public override IDictionary Data => MigrationErrors.ToDictionary(item => item.Key, item => item.Value);

    public virtual IDictionary<string, object?> MigrationErrors =>
        InnerExceptions
            .SelectMany(exception => exception.Data.Cast<KeyValuePair<string, object?>>())
            .ToDictionary(entry => entry.Key, entry => entry.Value);

    public bool IsTransient => 
        InnerExceptions.OfType<DbException>().All(ex => ex.IsTransientError())
        && InnerExceptions.OfType<ScriptFailed>().All(ex => ex.IsTransient)
        ;

    public override string Message
    {
        get
        {
            if (!InnerExceptions.Any())
            {
                return base.Message;
            }

            StringBuilder sb = new StringBuilder();
            
            sb.Append("Migration failed due to the following errors");
            sb.Append(":\n\n");

            var migrationExceptions = InnerExceptions.OfType<MigrationException>().ToArray();
            
            foreach (var folderErrors in migrationExceptions.GroupBy(ex => ex.Folder))
            {
                var folder= folderErrors.Key;
                sb.AppendLine($"{folder.Name} (\"{folder.Path}\"):");
                sb.AppendLine("--------------------------------------------------------------------------------");
                foreach (var error in folderErrors)
                {
                    sb.AppendLine(error.Message);
                }
            }
            
            foreach (var t in InnerExceptions.Except(migrationExceptions))
            {
                sb.Append(" * ");
                sb.Append(t.Message);
                sb.Append('\n');
            }
            sb.Length--;
            return sb.ToString();
        }
    }
}
