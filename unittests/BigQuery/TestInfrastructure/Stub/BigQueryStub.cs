using System.Collections.Concurrent;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;

namespace BigQuery.TestInfrastructure.Stub;

/// <summary>
/// A local HTTP server in place of BigQuery's REST API, for the failures the emulator cannot make. It keeps the jobs it
/// creates - a job id, or the request id of a <c>jobs.query</c>, creates one job - answers the requests a
/// <c>BigQueryClient</c> makes for a query, and records every request. A test
/// decides how each new job ends (<see cref="NewJob"/>) and which answers get lost (<see cref="LoseAnswerTo"/>).
/// </summary>
public sealed class BigQueryStub : IAsyncDisposable
{
    private readonly HttpListener _listener = new();
    private readonly Task _serving;
    private readonly ConcurrentDictionary<string, (JsonObject Reference, JsonObject Configuration, StubJob Outcome)> _jobs = new();
    private readonly ConcurrentQueue<StubRequest> _requests = new();
    private readonly ConcurrentDictionary<string, string> _jobsByRequestId = new();

    public BigQueryStub()
    {
        Endpoint = $"http://127.0.0.1:{FreePort()}";
        _listener.Prefixes.Add(Endpoint + "/");
        _listener.Start();
        _serving = ServeAsync();
    }

    /// <summary>
    /// What a connection string names as its <c>Endpoint</c> to reach this stub.
    /// </summary>
    public string Endpoint { get; }

    /// <summary>
    /// How a new job ends. By default it succeeds at once, with no rows.
    /// </summary>
    public Func<StubRequest, StubJob> NewJob { get; set; } = _ => StubJob.Succeeds;

    /// <summary>
    /// Requests the stub carries out, but whose answer is lost on its way back: the client gets HTTP 503 with
    /// BigQuery's <c>backendError</c>.
    /// </summary>
    public Func<StubRequest, bool> LoseAnswerTo { get; set; } = _ => false;

    public IReadOnlyList<StubRequest> Requests => _requests.ToArray();

    /// <summary>
    /// The requests that create a job: <c>jobs.insert</c>, or <c>jobs.query</c>, which runs a query in one request.
    /// </summary>
    public IReadOnlyList<StubRequest> JobCreations => Requests.Where(x => x.CreatesJob).ToArray();

    public IReadOnlyList<StubRequest> Cancels => Requests.Where(x => x.IsCancel).ToArray();

    public IReadOnlyCollection<string> CreatedJobIds => _jobs.Keys.ToArray();

    public async ValueTask DisposeAsync()
    {
        _listener.Stop();
        _listener.Close();
        await _serving;
    }

    private async Task ServeAsync()
    {
        while (true)
        {
            HttpListenerContext context;
            try
            {
                context = await _listener.GetContextAsync();
            }
            catch (Exception ex) when (ex is HttpListenerException or ObjectDisposedException)
            {
                // stopped
                return;
            }

            await HandleAsync(context);
        }
    }

    private async Task HandleAsync(HttpListenerContext context)
    {
        var request = await ReadAsync(context.Request);
        _requests.Enqueue(request);

        var (status, body) = await AnswerAsync(request);
        if (LoseAnswerTo(request))
        {
            (status, body) = Error(HttpStatusCode.ServiceUnavailable, "backendError", "The answer was lost");
        }

        var bytes = Encoding.UTF8.GetBytes(body?.ToJsonString() ?? "");
        context.Response.StatusCode = (int)status;
        context.Response.ContentType = "application/json; charset=UTF-8";
        context.Response.ContentLength64 = bytes.Length;
        await context.Response.OutputStream.WriteAsync(bytes);
        context.Response.Close();
    }

    private async Task<(HttpStatusCode, JsonNode?)> AnswerAsync(StubRequest request)
    {
        if (request.IsJobInsert)
        {
            var reference = request.Body!["jobReference"]!.AsObject();
            var jobId = (string)reference["jobId"]!;
            reference["projectId"] ??= request.Project;

            // BigQuery writes a query's results to a temporary table of its own
            var configuration = (JsonObject)request.Body["configuration"]!.DeepClone();
            configuration["query"]!["destinationTable"] = new JsonObject
            {
                ["projectId"] = request.Project,
                ["datasetId"] = "_anonymous",
                ["tableId"] = $"anon_{jobId}",
            };

            if (!_jobs.TryAdd(jobId, ((JsonObject)reference.DeepClone(), configuration, NewJob(request))))
            {
                return Error(HttpStatusCode.Conflict, "duplicate", $"Already Exists: Job {request.Project}:{jobId}");
            }

            return (HttpStatusCode.OK, Job(jobId));
        }

        if (request.IsStatelessQuery)
        {
            // BigQuery answers a request id it has seen with the job it created for it
            var requestId = (string?)request.Body!["requestId"] ?? Guid.NewGuid().ToString("N");
            var created = _jobsByRequestId.GetOrAdd(requestId, _ => $"job_{Guid.NewGuid():N}");
            if (!_jobs.ContainsKey(created))
            {
                var reference = new JsonObject
                {
                    ["projectId"] = request.Project,
                    ["jobId"] = created,
                    ["location"] = request.Body["location"]?.DeepClone(),
                };
                var configuration = new JsonObject
                {
                    ["query"] = new JsonObject
                    {
                        ["query"] = request.Sql,
                        ["destinationTable"] = new JsonObject
                        {
                            ["projectId"] = request.Project,
                            ["datasetId"] = "_anonymous",
                            ["tableId"] = $"anon_{created}",
                        },
                    },
                };
                _jobs.TryAdd(created, (reference, configuration, NewJob(request)));
            }

            return Results(created, "bigquery#queryResponse");
        }

        if (request.IsCancel)
        {
            return _jobs.ContainsKey(request.JobId!)
                ? (HttpStatusCode.OK, new JsonObject { ["kind"] = "bigquery#jobCancelResponse", ["job"] = Job(request.JobId!) })
                : NotFound($"Job {request.JobId}");
        }

        if (request.IsJobGet)
        {
            return _jobs.ContainsKey(request.JobId!) ? (HttpStatusCode.OK, Job(request.JobId!)) : NotFound($"Job {request.JobId}");
        }

        if (request.IsQueryResults)
        {
            if (!_jobs.ContainsKey(request.JobId!))
            {
                return NotFound($"Job {request.JobId}");
            }

            if (_jobs[request.JobId!].Outcome.State == "RUNNING")
            {
                // BigQuery holds a read of a running job for a while before it answers
                await Task.Delay(100);
            }

            return Results(request.JobId!, "bigquery#getQueryResultsResponse");
        }

        if (request.Method == "DELETE" && request.Dataset is not null)
        {
            return (HttpStatusCode.NoContent, null);
        }

        return NotFound(request.Path);
    }

    private (HttpStatusCode, JsonNode?) Results(string jobId, string kind)
    {
        var (reference, _, outcome) = _jobs[jobId];

        if (outcome.State == "RUNNING")
        {
            return (HttpStatusCode.OK, new JsonObject
            {
                ["kind"] = kind,
                ["jobReference"] = reference.DeepClone(),
                ["jobComplete"] = false,
            });
        }

        if (outcome.ErrorReason is { } reason)
        {
            return Error(HttpStatusCode.BadRequest, reason, $"The job failed: {reason}");
        }

        return (HttpStatusCode.OK, new JsonObject
        {
            ["kind"] = kind,
            ["jobReference"] = reference.DeepClone(),
            ["jobComplete"] = true,
            ["totalRows"] = "0",
            ["schema"] = new JsonObject
            {
                ["fields"] = new JsonArray(new JsonObject { ["name"] = "value", ["type"] = "INTEGER", ["mode"] = "NULLABLE" }),
            },
            ["rows"] = new JsonArray(),
        });
    }

    private JsonObject Job(string jobId)
    {
        var (reference, configuration, outcome) = _jobs[jobId];

        var status = new JsonObject { ["state"] = outcome.State };
        if (outcome.ErrorReason is { } reason)
        {
            var error = new JsonObject { ["reason"] = reason, ["message"] = $"The job failed: {reason}" };
            status["errorResult"] = error;
            status["errors"] = new JsonArray(error.DeepClone());
        }

        var statistics = new JsonObject { ["creationTime"] = "1700000000000", ["startTime"] = "1700000000000" };
        if (outcome.NumChildJobs is { } children)
        {
            statistics["numChildJobs"] = children.ToString();
        }

        return new JsonObject
        {
            ["kind"] = "bigquery#job",
            ["id"] = $"{reference["projectId"]}:{jobId}",
            ["jobReference"] = reference.DeepClone(),
            ["configuration"] = configuration.DeepClone(),
            ["status"] = status,
            ["statistics"] = statistics,
        };
    }

    private static (HttpStatusCode, JsonNode?) NotFound(string what) =>
        Error(HttpStatusCode.NotFound, "notFound", $"Not found: {what}");

    private static (HttpStatusCode, JsonNode?) Error(HttpStatusCode status, string reason, string message) =>
        (status, new JsonObject
        {
            ["error"] = new JsonObject
            {
                ["code"] = (int)status,
                ["message"] = message,
                ["errors"] = new JsonArray(new JsonObject { ["message"] = message, ["domain"] = "global", ["reason"] = reason }),
            },
        });

    private static async Task<StubRequest> ReadAsync(HttpListenerRequest request)
    {
        var path = request.Url!.AbsolutePath;
        var query = request.Url.Query;

        JsonNode? body = null;
        if (request.HasEntityBody)
        {
            Stream stream = request.InputStream;
            if (string.Equals(request.Headers["Content-Encoding"], "gzip", StringComparison.OrdinalIgnoreCase))
            {
                stream = new GZipStream(stream, CompressionMode.Decompress);
            }

            using var reader = new StreamReader(stream, Encoding.UTF8);
            var text = await reader.ReadToEndAsync();
            body = text.Length == 0 ? null : JsonNode.Parse(text);
        }

        return new StubRequest(request.HttpMethod, path, query, body);
    }

    private static int FreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }
}
