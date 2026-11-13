using System.Collections.Concurrent;
using grate.BigQuery.Infrastructure;
using TestCommon.TestInfrastructure;

namespace BigQuery.TestInfrastructure;

/// <summary>
/// A real BigQuery project, named by <c>GrateTestConfig__AdminConnectionString</c> (<c>ProjectId=...;Location=...</c>),
/// with Application Default Credentials that may create and drop datasets in it. Every dataset the tests name is
/// dropped when they are done, as the project outlives the run - the emulator's datasets go with its container.
/// </summary>
// ReSharper disable once ClassNeverInstantiated.Global
public class BigQueryExternalDatabase(GrateTestConfig grateTestConfig) : ITestDatabase, IAsyncLifetime
{
    private readonly BigQueryConnectionSettings _settings = BigQueryConnectionSettings.Parse(
        grateTestConfig.AdminConnectionString ?? throw new ArgumentNullException(nameof(grateTestConfig)));

    private readonly ConcurrentDictionary<string, byte> _datasets = new();

    public string AdminConnectionString => _settings.WithDataset(null).ToString();

    public string ConnectionString(string database)
    {
        _datasets.TryAdd(database, 0);
        return _settings.WithDataset(database).ToString();
    }

    public string UserConnectionString(string database) => ConnectionString(database);

    public ValueTask InitializeAsync() => ValueTask.CompletedTask;

    public async ValueTask DisposeAsync()
    {
        // one dataset that cannot be dropped leaves the others to drop
        var failures = new List<Exception>();
        foreach (var dataset in _datasets.Keys)
        {
            try
            {
                await BigQueryDatabaseHelpers.DropDataset(_settings.WithDataset(dataset).ToString());
                _datasets.TryRemove(dataset, out _);
            }
            catch (Exception ex)
            {
                failures.Add(ex);
            }
        }

        GC.SuppressFinalize(this);

        if (failures.Count > 0)
        {
            throw new AggregateException("Could not drop every dataset the tests named", failures);
        }
    }
}
