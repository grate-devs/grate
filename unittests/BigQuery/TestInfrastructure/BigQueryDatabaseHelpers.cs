using System.Net;
using Google;
using Google.Apis.Bigquery.v2.Data;
using Google.Cloud.BigQuery.V2;
using grate.BigQuery.Infrastructure;
using TestCommon.TestInfrastructure;

namespace BigQuery.TestInfrastructure;

/// <summary>
/// Datasets - BigQuery's databases - made, listed and dropped through the API, for the tests.
/// </summary>
public static class BigQueryDatabaseHelpers
{
    public static async Task CreateBigQueryDatabaseFromConnectionString(string connectionString)
    {
        var settings = BigQueryConnectionSettings.Parse(connectionString);
        using var client = await BigQueryClientFactory.CreateAsync(settings);
        await client.GetOrCreateDatasetAsync(settings.Dataset, new Dataset { Location = settings.Location });
    }

    public static async Task<IEnumerable<string>> GetBigQueryDatabases(this IGrateTestContext context)
    {
        var settings = BigQueryConnectionSettings.Parse(context.AdminConnectionString);
        using var client = await BigQueryClientFactory.CreateAsync(settings);

        var datasets = new List<string>();
        await foreach (var dataset in client.ListDatasetsAsync())
        {
            datasets.Add(dataset.Reference.DatasetId);
        }

        return datasets;
    }

    public static async Task DropDataset(string connectionString)
    {
        var settings = BigQueryConnectionSettings.Parse(connectionString);
        using var client = await BigQueryClientFactory.CreateAsync(settings);

        try
        {
            await client.DeleteDatasetAsync(settings.Dataset, new DeleteDatasetOptions { DeleteContents = true });
        }
        catch (GoogleApiException ex) when (ex.HttpStatusCode == HttpStatusCode.NotFound)
        {
            // nothing to drop
        }
    }
}
