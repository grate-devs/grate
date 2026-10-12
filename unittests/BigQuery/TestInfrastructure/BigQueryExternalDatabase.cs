using grate.BigQuery.Infrastructure;
using TestCommon.TestInfrastructure;

namespace BigQuery.TestInfrastructure;

/// <summary>
/// A real BigQuery project, named by <c>GrateTestConfig__AdminConnectionString</c> (<c>ProjectId=...;Location=...</c>),
/// with Application Default Credentials that may create and drop datasets in it.
/// </summary>
// ReSharper disable once ClassNeverInstantiated.Global
public class BigQueryExternalDatabase(GrateTestConfig grateTestConfig) : ITestDatabase
{
    private readonly BigQueryConnectionSettings _settings = BigQueryConnectionSettings.Parse(
        grateTestConfig.AdminConnectionString ?? throw new ArgumentNullException(nameof(grateTestConfig)));

    public string AdminConnectionString => _settings.WithDataset(null).ToString();
    public string ConnectionString(string database) => _settings.WithDataset(database).ToString();
    public string UserConnectionString(string database) => ConnectionString(database);
}
