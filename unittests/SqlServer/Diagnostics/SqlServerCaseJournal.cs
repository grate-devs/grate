using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace SqlServer.Diagnostics;

// Only xUnit case hooks call this opt-in diagnostic sink, never SqlClient callbacks.
internal sealed class SqlServerCaseJournal(string output, Action recordError)
{
    private readonly object gate = new();
    private CaseIdentity? active;
    private long errors;

    internal long Errors => Interlocked.Read(ref errors);

    internal void Before(string id, string className, string methodName)
    {
        lock (gate)
        {
            active = new(Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id))), className, methodName);
            Append("Before", active);
        }
    }

    internal void After()
    {
        lock (gate)
        {
            if (active is null)
            {
                Failed();
                return;
            }
            Append("After", active);
            active = null;
        }
    }

    internal void EnforceExitCode()
    {
        if (Errors != 0)
        {
            Environment.ExitCode = 1;
        }
    }

    private void Append(string phase, CaseIdentity identity)
    {
        try
        {
            var directory = Path.GetDirectoryName(output);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }
            var line = JsonSerializer.Serialize(new
            {
                Utc = DateTime.UtcNow,
                Phase = phase,
                identity.CaseId,
                identity.ClassName,
                identity.MethodName
            }) + "\n";
            // Flush each completed record and close the file before running SQL.
            // A testhost kill can then leave its last Before marker readable.
            using var stream = new FileStream(output, FileMode.Append, FileAccess.Write,
                FileShare.ReadWrite, 4096, FileOptions.WriteThrough);
            stream.Write(Encoding.UTF8.GetBytes(line));
            stream.Flush(flushToDisk: true);
        }
        catch (Exception)
        {
            Failed();
        }
    }

    private void Failed()
    {
        Interlocked.Increment(ref errors);
        recordError();
        Environment.ExitCode = 1;
        // File paths and exception messages are intentionally excluded.
        Console.Error.WriteLine("SQL Server progress journal could not write a case marker.");
    }

    private sealed record CaseIdentity(string CaseId, string ClassName, string MethodName);
}
