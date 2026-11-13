using System.Data;
using System.Data.Common;
using System.Diagnostics.CodeAnalysis;
using Google.Cloud.BigQuery.V2;
using grate.BigQuery.Infrastructure;

namespace BigQuery.TestInfrastructure.AdoNet;

/// <summary>
/// Just enough of an ADO.NET connection over the BigQuery client for Dapper to run the tests' queries: no
/// transactions, and every command is one query job in the connection string's dataset.
/// </summary>
public sealed class BigQueryTestConnection(string connectionString) : DbConnection
{
    private BigQueryClient? _client;
    private ConnectionState _state = ConnectionState.Closed;

    [AllowNull]
    public override string ConnectionString { get; set; } = connectionString;

    internal BigQueryConnectionSettings Settings => BigQueryConnectionSettings.Parse(ConnectionString);

    internal BigQueryClient Client => _client ??= BigQueryClientFactory.CreateAsync(Settings).GetAwaiter().GetResult();

    public override string Database => Settings.Dataset ?? string.Empty;
    public override string DataSource => Settings.ProjectId;
    public override string ServerVersion => "BigQuery";
    public override ConnectionState State => _state;

    public override void Open() => _state = ConnectionState.Open;
    public override void Close() => _state = ConnectionState.Closed;

    public override void ChangeDatabase(string databaseName) =>
        ConnectionString = Settings.WithDataset(databaseName).ToString();

    protected override DbTransaction BeginDbTransaction(IsolationLevel isolationLevel) =>
        throw new NotSupportedException("BigQuery runs no transactions across jobs");

    protected override DbCommand CreateDbCommand() => new BigQueryTestCommand(this);

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _client?.Dispose();
        }

        base.Dispose(disposing);
    }
}
