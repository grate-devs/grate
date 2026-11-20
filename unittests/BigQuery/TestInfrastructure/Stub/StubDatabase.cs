using grate.BigQuery.Migration;
using grate.Configuration;
using Microsoft.Extensions.Logging.Abstractions;

namespace BigQuery.TestInfrastructure.Stub;

/// <summary>
/// A <see cref="BigQueryDatabase"/> whose jobs go to a <see cref="BigQueryStub"/>.
/// </summary>
public static class StubDatabase
{
    public const string Dataset = "probe_dataset";

    public static async Task<BigQueryDatabase> Initialize(
        BigQueryStub stub, string project = "project-a", string? location = null, int commandTimeout = 0)
    {
        var database = new BigQueryDatabase(NullLogger<BigQueryDatabase>.Instance);
        await database.InitializeConnections(Configuration(stub, project, location, commandTimeout));
        return database;
    }

    public static GrateConfiguration Configuration(
        BigQueryStub stub, string project = "project-a", string? location = null, int commandTimeout = 0) =>
        GrateConfiguration.Default with
        {
            ConnectionString = $"ProjectId={project};Dataset={Dataset};Endpoint={stub.Endpoint}"
                               + (location is null ? "" : $";Location={location}"),
            CommandTimeout = commandTimeout,
            AdminCommandTimeout = commandTimeout,
        };
}
