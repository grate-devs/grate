using Google.Apis.Auth.OAuth2;
using Google.Cloud.BigQuery.V2;

namespace grate.BigQuery.Infrastructure;

/// <summary>
/// Creates the <see cref="BigQueryClient"/> for a set of connection settings: Application Default Credentials against
/// Google, or no credentials against an emulator.
/// </summary>
public static class BigQueryClientFactory
{
    public static async Task<BigQueryClient> CreateAsync(BigQueryConnectionSettings settings)
    {
        var builder = new BigQueryClientBuilder
        {
            ProjectId = settings.ProjectId,
            DefaultLocation = settings.Location,
        };

        if (settings.Endpoint is { } endpoint)
        {
            // an emulator serves the same REST API under its own address, and checks no credentials
            builder.BaseUri = endpoint.TrimEnd('/') + "/bigquery/v2/";
            builder.GoogleCredential = GoogleCredential.FromAccessToken("emulator");
        }

        return await builder.BuildAsync();
    }
}
