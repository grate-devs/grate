using System.Data;
using System.Data.Common;
using System.Diagnostics.CodeAnalysis;
using Google.Cloud.BigQuery.V2;

namespace BigQuery.TestInfrastructure.AdoNet;

public sealed class BigQueryTestParameter : DbParameter
{
    public override DbType DbType { get; set; } = DbType.String;
    public override ParameterDirection Direction { get; set; } = ParameterDirection.Input;
    public override bool IsNullable { get; set; } = true;

    [AllowNull]
    public override string ParameterName { get; set; } = string.Empty;

    public override int Size { get; set; }

    [AllowNull]
    public override string SourceColumn { get; set; } = string.Empty;

    public override bool SourceColumnNullMapping { get; set; }
    public override object? Value { get; set; }

    public override void ResetDbType() => DbType = DbType.String;

    public BigQueryParameter ToBigQueryParameter()
    {
        var name = ParameterName.TrimStart('@');
        var value = Value is DBNull ? null : Value;

        var type = value switch
        {
            bool => BigQueryDbType.Bool,
            short or int or long => BigQueryDbType.Int64,
            float or double => BigQueryDbType.Float64,
            decimal => BigQueryDbType.Numeric,
            DateTime or DateTimeOffset => BigQueryDbType.Timestamp,
            _ => BigQueryDbType.String,
        };

        return new BigQueryParameter(name, type, value is short or int ? Convert.ToInt64(value) : value);
    }
}
