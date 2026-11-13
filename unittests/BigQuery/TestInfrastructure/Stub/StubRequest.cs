using System.Text.Json.Nodes;
using System.Web;

namespace BigQuery.TestInfrastructure.Stub;

/// <summary>
/// A request the <see cref="BigQueryStub"/> received, with the parts of BigQuery's REST paths the tests look at.
/// </summary>
public sealed record StubRequest(string Method, string Path, string Query, JsonNode? Body)
{
    private string[] Segments => Path.Split('/', StringSplitOptions.RemoveEmptyEntries);

    // bigquery/v2/projects/{project}/...
    public string? Project => Segments.Length > 3 && Segments[2] == "projects" ? Segments[3] : null;

    // .../datasets/{dataset}
    public string? Dataset => After("datasets");

    // .../jobs/{job} or .../queries/{job}
    public string? JobId => After("jobs") ?? After("queries");

    /// <summary>
    /// Where a query runs - BigQuery's default when the client names none.
    /// </summary>
    public string? Location => IsQuery ? (string?)Body?["location"] : HttpUtility.ParseQueryString(Query)["location"];

    public string? Sql => (string?)Body?["query"];

    public string? RequestId => (string?)Body?["requestId"];

    // jobs.query - starts a query, and answers with its results if it finishes soon enough
    public bool IsQuery => Method == "POST" && Path.EndsWith("/queries", StringComparison.Ordinal);
    public bool IsJobGet => Method == "GET" && Segments.Length == 6 && Segments[4] == "jobs";
    public bool IsCancel => Method == "POST" && Path.EndsWith("/cancel", StringComparison.Ordinal);
    public bool IsQueryResults => Method == "GET" && Segments.Length == 6 && Segments[4] == "queries";

    private string? After(string segment)
    {
        var index = Array.IndexOf(Segments, segment);
        return index >= 0 && index + 1 < Segments.Length ? Segments[index + 1] : null;
    }
}

/// <summary>
/// How a job the <see cref="BigQueryStub"/> creates ends, the one row it returns if any, and how many of the stub's
/// answers about it - to the query, to a read of its results, to a read of the job - still find it running.
/// </summary>
public sealed record StubJob(string State, string? ErrorReason = null, int AnswersWhileRunning = 0, (string Column, string Value)? Row = null)
{
    public static StubJob Succeeds { get; } = new("DONE");

    public static StubJob Returns(string column, string value) => new("DONE", Row: (column, value));

    public static StubJob Running { get; } = new("RUNNING");

    public static StubJob Fails(string reason) => new("DONE", reason);

    public static StubJob FailsAfter(int answersWhileRunning, string reason) => new("DONE", reason, answersWhileRunning);
}
