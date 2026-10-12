using System.Data;
using System.Data.Common;
using System.Diagnostics.CodeAnalysis;
using System.Text.RegularExpressions;
using Google;
using Google.Cloud.BigQuery.V2;
using grate.BigQuery.Infrastructure;

namespace BigQuery.TestInfrastructure.AdoNet;

public sealed class BigQueryTestCommand(BigQueryTestConnection connection) : DbCommand
{
    [AllowNull]
    public override string CommandText { get; set; } = string.Empty;

    public override int CommandTimeout { get; set; } = 30;
    public override CommandType CommandType { get; set; } = CommandType.Text;
    public override bool DesignTimeVisible { get; set; }
    public override UpdateRowSource UpdatedRowSource { get; set; }
    protected override DbConnection? DbConnection { get; set; } = connection;
    protected override DbParameterCollection DbParameterCollection { get; } = new BigQueryTestParameterCollection();
    protected override DbTransaction? DbTransaction { get; set; }

    public override void Cancel()
    {
        // a job is not cancelled from here
    }

    public override void Prepare()
    {
        // nothing to prepare - every command is a new job
    }

    protected override DbParameter CreateDbParameter() => new BigQueryTestParameter();

    public override int ExecuteNonQuery() => (int)(Run().NumDmlAffectedRows ?? 0);

    public override object? ExecuteScalar()
    {
        var row = Run().FirstOrDefault();
        return row?[0];
    }

    protected override DbDataReader ExecuteDbDataReader(CommandBehavior behavior) => new BigQueryTestDataReader(Run());

    private BigQueryResults Run()
    {
        var conn = (BigQueryTestConnection)(DbConnection ?? throw new InvalidOperationException("The command has no connection"));

        // The emulator answers CREATE SCHEMA and DROP SCHEMA without doing anything, so the tests' datasets are
        // made and dropped through the API
        var schema = SchemaStatement.Match(CommandText);
        if (schema.Success)
        {
            var settings = conn.Settings.WithDataset(schema.Groups["dataset"].Value).ToString();
            var change = schema.Groups["verb"].Value.Equals("CREATE", StringComparison.OrdinalIgnoreCase)
                ? BigQueryDatabaseHelpers.CreateBigQueryDatabaseFromConnectionString(settings)
                : BigQueryDatabaseHelpers.DropDataset(settings);
            change.GetAwaiter().GetResult();
            return conn.Client.ExecuteQuery("SELECT 1", parameters: null);
        }
        var options = new QueryOptions
        {
            DefaultDataset = conn.Settings.Dataset is { } dataset ? conn.Client.GetDatasetReference(dataset) : null,
            UseQueryCache = false,
        };
        var parameters = DbParameterCollection
            .Cast<BigQueryTestParameter>()
            .Select(x => x.ToBigQueryParameter())
            .ToList();

        try
        {
            return conn.Client.ExecuteQuery(Qualified(CommandText, conn.Settings.Dataset), parameters, options);
        }
        catch (GoogleApiException ex)
        {
            throw new BigQueryDbException(ex);
        }
    }

    private static readonly Regex SchemaStatement = new(
        @"^\s*(?<verb>CREATE|DROP)\s+SCHEMA\s+(IF\s+(NOT\s+)?EXISTS\s+)?`?(?<dataset>[A-Za-z0-9_]+)`?(\s+CASCADE)?\s*;?\s*$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    // The emulator reads an unqualified table from the first dataset that has one by that name, whatever the
    // default dataset - so the tests' queries name the connection's dataset themselves
    private static readonly Regex UnqualifiedTable = new(
        @"\b(?<keyword>FROM|JOIN|INTO|UPDATE)\s+(?<table>(?!INFORMATION_SCHEMA\b)[A-Za-z_][A-Za-z0-9_]*)\b(?![.(])",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static readonly Regex UnqualifiedInformationSchema = new(
        @"(?<![.`\w])INFORMATION_SCHEMA\.",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static string Qualified(string sql, string? dataset)
    {
        if (dataset is null)
        {
            return sql;
        }

        var tables = UnqualifiedTable.Replace(sql, match => IsKeyword(match.Groups["table"].Value)
            ? match.Value
            : $"{match.Groups["keyword"].Value} `{dataset}`.{match.Groups["table"].Value}");
        return UnqualifiedInformationSchema.Replace(tables, $"`{dataset}`.INFORMATION_SCHEMA.");
    }

    private static bool IsKeyword(string word) =>
        word.Equals("UNNEST", StringComparison.OrdinalIgnoreCase)
        || word.Equals("SELECT", StringComparison.OrdinalIgnoreCase);
}
