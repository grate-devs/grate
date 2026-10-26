using grate.Oracle.Infrastructure;

namespace Oracle.Basic_tests;

public class OracleStatementSplitter_sql_terminators
{
    private readonly OracleStatementSplitter _splitter = new();

    // Original CREATE TABLE statement from https://github.com/grate-devs/grate/issues/283.
    private const string CreateActorTable = """
        CREATE TABLE actor (
          actor_id numeric NOT NULL ,
          first_name VARCHAR(45) NOT NULL,
          last_name VARCHAR(45) NOT NULL,
          last_update DATE NOT NULL,
          CONSTRAINT pk_actor PRIMARY KEY  (actor_id)
        )
        """;

    [Theory]
    [InlineData("\n", ";")]
    [InlineData("\r\n", ";")]
    [InlineData("\n", ";\n/")]
    [InlineData("\r\n", ";\r\n/")]
    public void Removes_sql_terminator_from_issue_283_table(string lineEnding, string terminator)
    {
        var statement = CreateActorTable.ReplaceLineEndings(lineEnding);

        var batches = _splitter.Split(statement + terminator).ToArray();

        Assert.Equal([statement], batches);
    }

    [Theory]
    [InlineData(";")]
    [InlineData(";\n;\n/")]
    [InlineData(";\r\n/\r\n;\r\n/")]
    public void Does_not_execute_separator_only_batches(string sql)
    {
        Assert.Empty(_splitter.Split(sql));
    }

    [Fact]
    public void Removes_sql_terminators_without_removing_plsql_semicolons()
    {
        const string sql = "SELECT 1 FROM dual;\nBEGIN\n    NULL;\nEND;\n/\nSELECT 2 FROM dual;";

        var batches = _splitter.Split(sql).ToArray();

        Assert.Equal(["SELECT 1 FROM dual", "\nBEGIN\n    NULL;\nEND;", "\nSELECT 2 FROM dual"], batches);
    }

    [Theory]
    [InlineData("'a;b'")]
    [InlineData("'can''t; stop'")]
    [InlineData("q'[a;b]'")]
    public void Preserves_semicolons_inside_literals(string literal)
    {
        var statement = $"SELECT {literal} FROM dual";

        Assert.Equal([statement], _splitter.Split(statement + ";"));
    }
}
