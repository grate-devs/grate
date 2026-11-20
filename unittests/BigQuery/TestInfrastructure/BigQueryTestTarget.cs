using grate.BigQuery.Infrastructure;

namespace BigQuery.TestInfrastructure;

/// <summary>
/// Whether the tests run against the emulator: they do unless <c>GrateTestConfig__AdminConnectionString</c> names a
/// BigQuery project without an <c>Endpoint</c> (see <see cref="BigQueryExternalDatabase"/>).
/// </summary>
public static class BigQueryTestTarget
{
    private static string? AdminConnectionString =>
        Environment.GetEnvironmentVariable("GrateTestConfig__AdminConnectionString");

    public static bool IsEmulator =>
        AdminConnectionString is null || BigQueryConnectionSettings.Parse(AdminConnectionString).Endpoint is not null;
}
