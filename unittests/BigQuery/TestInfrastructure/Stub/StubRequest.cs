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

    public string? JobId => After("jobs") ?? After("queries") ?? (string?)Body?["jobReference"]?["jobId"];

    /// <summary>
    /// Where a new job runs - BigQuery's default when the client names none.
    /// </summary>
    public string? Location => IsJobInsert ? (string?)Body?["jobReference"]?["location"]
        : IsStatelessQuery ? (string?)Body?["location"]
        : HttpUtility.ParseQueryString(Query)["location"];

    public string? Sql => IsStatelessQuery ? (string?)Body?["query"] : (string?)Body?["configuration"]?["query"]?["query"];

    public bool CreatesJob => IsJobInsert || IsStatelessQuery;

    public bool IsJobInsert => Method == "POST" && Path.EndsWith("/jobs", StringComparison.Ordinal);

    // jobs.query - a query run in one request, its job created by BigQuery
    public bool IsStatelessQuery => Method == "POST" && Path.EndsWith("/queries", StringComparison.Ordinal);
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
/// How a job the <see cref="BigQueryStub"/> creates ends.
/// </summary>
public sealed record StubJob(string State, string? ErrorReason = null, long? NumChildJobs = null)
{
    public static StubJob Succeeds { get; } = new("DONE");

    public static StubJob Running { get; } = new("RUNNING");

    public static StubJob Fails(string reason, long? numChildJobs = null) => new("DONE", reason, numChildJobs);
}
