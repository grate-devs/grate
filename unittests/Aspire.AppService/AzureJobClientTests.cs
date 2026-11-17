using System.Net;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Azure.Core.Pipeline;
using Azure.ResourceManager;
using Xunit;

namespace Grate.Aspire.AppService.Tests;

public sealed class AzureJobClientTests
{
    private const string ResponseCanary = "private-arm-error-body";
    private const string OperationPath = "/providers/Microsoft.App/locations/valid/operationResults/this-start";

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Azure_start_returns_the_exact_run_for_both_synchronous_and_location_responses(bool asynchronous)
    {
        using var transport = new FakeArmTransport(request =>
        {
            if (request.Method == HttpMethod.Post)
            {
                Assert.Equal(JobRunnerTests.JobPath + "/start", request.RequestUri!.AbsolutePath);
                if (!asynchronous)
                {
                    return StartResponse();
                }
                var accepted = Response(HttpStatusCode.Accepted, new { });
                accepted.Headers.Location = new Uri("https://management.azure.com" + OperationPath);
                accepted.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.Zero);
                return accepted;
            }
            Assert.Equal(HttpMethod.Get, request.Method);
            var path = request.RequestUri!.AbsolutePath;
            if (path == OperationPath)
            {
                Assert.True(asynchronous);
                return StartResponse();
            }
            Assert.Equal(JobRunnerTests.ExecutionPath, path);
            return ExecutionResponse(path);
        });
        var client = transport.CreateClient();
        var token = TestContext.Current.CancellationToken;

        var execution = await client.Start(JobRunnerTests.JobId, token);
        var status = await client.GetStatus(execution, token);

        Assert.Equal(JobRunnerTests.ExecutionId, execution);
        Assert.Equal("Succeeded", status);
        Assert.Single(transport.Requests, request => request.Method == HttpMethod.Post);
        Assert.Equal(asynchronous ? 3 : 2, transport.Requests.Count);
    }

    [Theory]
    [InlineData(408)]
    [InlineData(429)]
    [InlineData(503)]
    public async Task An_ambiguous_start_failure_never_replays_the_POST_or_exposes_the_response(int status)
    {
        using var transport = new FakeArmTransport(_ => ErrorResponse(status));
        var client = transport.CreateClient();

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => client.Start(JobRunnerTests.JobId, TestContext.Current.CancellationToken));

        Assert.Equal(HttpMethod.Post, Assert.Single(transport.Requests).Method);
        Assert.Contains($"HTTP {status}", error.Message);
        Assert.DoesNotContain(ResponseCanary, error.ToString());
    }

    [Theory]
    [InlineData(404)]
    [InlineData(408)]
    [InlineData(429)]
    [InlineData(503)]
    public async Task A_transient_execution_read_can_be_polled_without_restarting_the_job(int status)
    {
        using var transport = new FakeArmTransport(_ => ErrorResponse(status));

        var result = await transport.CreateClient().GetStatus(JobRunnerTests.ExecutionId, TestContext.Current.CancellationToken);

        Assert.Equal("Pending", result);
        Assert.Equal((HttpMethod.Get, JobRunnerTests.ExecutionPath), Assert.Single(transport.Requests));
    }

    [Fact]
    public async Task Missing_read_permission_fails_closed_without_exposing_the_response()
    {
        using var transport = new FakeArmTransport(_ => ErrorResponse(403));

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            transport.CreateClient().GetStatus(JobRunnerTests.ExecutionId, TestContext.Current.CancellationToken));

        Assert.Contains("HTTP 403", error.Message);
        Assert.DoesNotContain(ResponseCanary, error.ToString());
        Assert.Equal((HttpMethod.Get, JobRunnerTests.ExecutionPath), Assert.Single(transport.Requests));
    }

    [Fact]
    public async Task Azure_cannot_unlock_a_different_successful_execution()
    {
        using var transport = new FakeArmTransport(_ => ExecutionResponse(JobRunnerTests.JobPath + "/executions/other-run"));

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            transport.CreateClient().GetStatus(JobRunnerTests.ExecutionId, TestContext.Current.CancellationToken));

        Assert.Contains("different migration execution", error.Message);
        Assert.Equal((HttpMethod.Get, JobRunnerTests.ExecutionPath), Assert.Single(transport.Requests));
    }

    [Fact]
    public async Task A_start_without_an_execution_ID_fails_instead_of_selecting_an_existing_run()
    {
        using var transport = new FakeArmTransport(_ => Response(HttpStatusCode.OK, new { name = "not-enough" }));

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            transport.CreateClient().Start(JobRunnerTests.JobId, TestContext.Current.CancellationToken));

        Assert.Contains("execution ID", error.Message);
        Assert.Equal(HttpMethod.Post, Assert.Single(transport.Requests).Method);
    }

    private static HttpResponseMessage Response(HttpStatusCode status, object body) => new(status)
    {
        Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json")
    };

    private static HttpResponseMessage StartResponse() => Response(HttpStatusCode.OK, new { id = JobRunnerTests.ExecutionPath, name = "appdb-grate-exact" });

    private static HttpResponseMessage ExecutionResponse(string path) => Response(HttpStatusCode.OK, new
    {
        id = path,
        name = path[(path.LastIndexOf('/') + 1)..],
        type = "Microsoft.App/jobs/executions",
        properties = new { status = "Succeeded" }
    });

    private static HttpResponseMessage ErrorResponse(int status) => Response((HttpStatusCode)status,
        new { error = new { code = "TestError", message = ResponseCanary } });

    private sealed class FakeArmTransport : IDisposable
    {
        private readonly HttpClient _client;
        internal List<(HttpMethod Method, string Path)> Requests { get; } = [];

        internal FakeArmTransport(Func<HttpRequestMessage, HttpResponseMessage> respond)
        {
            _client = new HttpClient(new FakeHandler(request =>
            {
                Requests.Add((request.Method, request.RequestUri!.AbsolutePath));
                return respond(request);
            }));
        }

        internal AzureGrateJobClient CreateClient() => new(new FakeCredential(), new ArmClientOptions { Transport = new HttpClientTransport(_client) });
        public void Dispose() => _client.Dispose();
    }

    private sealed class FakeHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(respond(request));
    }

    private sealed class FakeCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            new("fake-offline-credential", DateTimeOffset.UtcNow.AddHours(1));

        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }
}
