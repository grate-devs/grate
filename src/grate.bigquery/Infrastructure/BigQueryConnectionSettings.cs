using System.Data.Common;

namespace grate.BigQuery.Infrastructure;

/// <summary>
/// What a BigQuery "connection string" holds. BigQuery has no connections - every call is a job - so the connection
/// string only names where the jobs run: <c>ProjectId=my-project;Dataset=my_dataset;Location=EU</c>. The dataset is
/// grate's database. <c>Endpoint=http://localhost:9050</c> points at a BigQuery emulator instead of Google, without
/// credentials; otherwise the credentials are Application Default Credentials.
/// </summary>
public sealed record BigQueryConnectionSettings(string ProjectId, string? Dataset, string? Location, string? Endpoint)
{
    public const string ProjectIdKey = "ProjectId";
    public const string DatasetKey = "Dataset";
    public const string LocationKey = "Location";
    public const string EndpointKey = "Endpoint";

    public static BigQueryConnectionSettings Parse(string? connectionString)
    {
        var builder = new DbConnectionStringBuilder { ConnectionString = connectionString ?? string.Empty };

        var projectId = Value(builder, ProjectIdKey)
            ?? throw new ArgumentException(
                $"The BigQuery connection string has no {ProjectIdKey} - expected {ProjectIdKey}=...;{DatasetKey}=...;{LocationKey}=...",
                nameof(connectionString));

        return new BigQueryConnectionSettings(
            projectId,
            Value(builder, DatasetKey),
            Value(builder, LocationKey),
            Value(builder, EndpointKey));
    }

    /// <summary>
    /// The same settings for another dataset - how the tests and the admin connection reach a database by name.
    /// </summary>
    public BigQueryConnectionSettings WithDataset(string? dataset) => this with { Dataset = dataset };

    public override string ToString()
    {
        var builder = new DbConnectionStringBuilder { [ProjectIdKey] = ProjectId };
        if (Dataset is not null) builder[DatasetKey] = Dataset;
        if (Location is not null) builder[LocationKey] = Location;
        if (Endpoint is not null) builder[EndpointKey] = Endpoint;
        return builder.ConnectionString;
    }

    private static string? Value(DbConnectionStringBuilder builder, string key) =>
        builder.TryGetValue(key, out var value) && value is string text && !string.IsNullOrWhiteSpace(text)
            ? text
            : null;
}
