using System.Collections;
using System.Data.Common;
using Google.Cloud.BigQuery.V2;

namespace BigQuery.TestInfrastructure.AdoNet;

/// <summary>
/// The rows of one query job, as an ADO.NET reader - each value as the BigQuery client gives it.
/// </summary>
public sealed class BigQueryTestDataReader : DbDataReader
{
    private readonly IReadOnlyList<string> _names;
    private readonly IReadOnlyList<Type> _types;
    private readonly IEnumerator<BigQueryRow> _rows;
    private readonly long _affected;
    private bool _closed;

    public BigQueryTestDataReader(BigQueryResults results)
    {
        var fields = results.Schema?.Fields ?? [];
        _names = fields.Select(x => x.Name).ToList();
        _types = fields.Select(x => FieldType(x.Type)).ToList();
        _rows = results.GetEnumerator();
        _affected = results.NumDmlAffectedRows ?? -1;
    }

    private BigQueryRow Current => _rows.Current;

    public override int FieldCount => _names.Count;
    public override bool HasRows => true;
    public override bool IsClosed => _closed;
    public override int RecordsAffected => (int)_affected;
    public override int Depth => 0;

    public override object this[int ordinal] => GetValue(ordinal);
    public override object this[string name] => GetValue(GetOrdinal(name));

    public override bool Read() => _rows.MoveNext();
    public override bool NextResult() => false;

    public override void Close()
    {
        _closed = true;
        _rows.Dispose();
    }

    public override string GetName(int ordinal) => _names[ordinal];
    public override int GetOrdinal(string name) => _names.ToList().FindIndex(x => string.Equals(x, name, StringComparison.OrdinalIgnoreCase));
    public override Type GetFieldType(int ordinal) => _types[ordinal];
    public override string GetDataTypeName(int ordinal) => _types[ordinal].Name;
    public override object GetValue(int ordinal) => Current[ordinal] ?? DBNull.Value;
    public override bool IsDBNull(int ordinal) => Current[ordinal] is null;

    public override int GetValues(object[] values)
    {
        var count = Math.Min(values.Length, FieldCount);
        for (var i = 0; i < count; i++)
        {
            values[i] = GetValue(i);
        }
        return count;
    }

    public override bool GetBoolean(int ordinal) => Convert.ToBoolean(GetValue(ordinal));
    public override byte GetByte(int ordinal) => Convert.ToByte(GetValue(ordinal));
    public override char GetChar(int ordinal) => Convert.ToChar(GetValue(ordinal));
    public override DateTime GetDateTime(int ordinal) => Convert.ToDateTime(GetValue(ordinal));
    public override decimal GetDecimal(int ordinal) => Convert.ToDecimal(GetValue(ordinal));
    public override double GetDouble(int ordinal) => Convert.ToDouble(GetValue(ordinal));
    public override float GetFloat(int ordinal) => Convert.ToSingle(GetValue(ordinal));
    public override Guid GetGuid(int ordinal) => Guid.Parse(GetString(ordinal));
    public override short GetInt16(int ordinal) => Convert.ToInt16(GetValue(ordinal));
    public override int GetInt32(int ordinal) => Convert.ToInt32(GetValue(ordinal));
    public override long GetInt64(int ordinal) => Convert.ToInt64(GetValue(ordinal));
    public override string GetString(int ordinal) => Convert.ToString(GetValue(ordinal)) ?? string.Empty;

    public override long GetBytes(int ordinal, long dataOffset, byte[]? buffer, int bufferOffset, int length) =>
        throw new NotSupportedException();

    public override long GetChars(int ordinal, long dataOffset, char[]? buffer, int bufferOffset, int length) =>
        throw new NotSupportedException();

    public override IEnumerator GetEnumerator() => new DbEnumerator(this);

    private static Type FieldType(string type) => type switch
    {
        "INTEGER" or "INT64" => typeof(long),
        "FLOAT" or "FLOAT64" => typeof(double),
        "BOOLEAN" or "BOOL" => typeof(bool),
        "TIMESTAMP" or "DATETIME" or "DATE" => typeof(DateTime),
        "NUMERIC" or "BIGNUMERIC" => typeof(decimal),
        _ => typeof(string),
    };
}
