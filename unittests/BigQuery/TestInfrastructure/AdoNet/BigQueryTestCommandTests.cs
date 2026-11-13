namespace BigQuery.TestInfrastructure.AdoNet;

public class BigQueryTestCommandTests
{
    [Theory]
    [InlineData("SELECT id FROM t JOIN u ON TRUE", "SELECT id FROM `ds`.t JOIN `ds`.u ON TRUE")]
    [InlineData("SELECT id FROM `ds`.t", "SELECT id FROM `ds`.t")]
    [InlineData("SELECT table_name FROM INFORMATION_SCHEMA.TABLES", "SELECT table_name FROM `ds`.INFORMATION_SCHEMA.TABLES")]
    // the rewrite reads the SQL as text, so it also changes a string literal that looks like a table
    [InlineData("SELECT 'FROM t' AS x", "SELECT 'FROM `ds`.t' AS x")]
    public void Names_the_dataset_of_unqualified_tables_for_the_emulator(string sql, string expected)
    {
        Assert.Equal(expected, BigQueryTestCommand.Qualified(sql, "ds"));
    }
}
