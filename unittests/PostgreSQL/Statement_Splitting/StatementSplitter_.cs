using grate.Infrastructure;
using grate.Migration;
using grate.PostgreSql.Infrastructure;

namespace Basic_tests.Infrastructure.PostgreSQL.Statement_Splitting;


// ReSharper disable once InconsistentNaming
public class StatementSplitter_
{
    private readonly StatementSplitter _statementSplitter;

    public StatementSplitter_()
    {
        _statementSplitter =  new StatementSplitter(new PostgreSqlSyntax());
    }

    [Fact]
    public void Splits_and_removes_semicolons()
    {
        var original = @"
DROP INDEX IF EXISTS IX_column1 CASCADE;
CREATE INDEX CONCURRENTLY IX_column1 ON public.table1
	USING btree
	(
	  column1
	);

DROP INDEX IF EXISTS IX_column2 CASCADE;
CREATE INDEX CONCURRENTLY IX_column2 ON public.table1
	USING btree
	(
	  column2
	);
";
        var batches = _statementSplitter.Split(original);

        Assert.Equal(4, batches.Count());
    }

    [Fact]
    public void Ignores_semicolons_in_backslash_escaped_strings()
    {
        var original = @"
DO E'
BEGIN
    IF NOT EXISTS(
        SELECT schema_name
        FROM information_schema.schemata
        WHERE schema_name = \'random\'
    )
    THEN
        EXECUTE \'CREATE SCHEMA random\';
    END IF;
END
';
";
        var batches = _statementSplitter.Split(original);

        Assert.Single(batches);
    }

    [Theory]
    [InlineData("$$")]
    [InlineData("$sometag$")]
    public void Ignores_semicolons_in_dollar_quoted_strings(string tag)
    {
        var original = @$"
DO 
{tag}
BEGIN
    IF NOT EXISTS(
        SELECT schema_name
        FROM information_schema.schemata
        WHERE schema_name = 'random'
    )
    THEN
        EXECUTE 'CREATE SCHEMA random';
    END IF;
END
{tag};
";
        var batches = _statementSplitter.Split(original);
        Assert.Single(batches);
    }

    [Fact]
    public void Splits_on_semicolon_after_single_quotes_when_there_is_another_semicolon_in_the_quote()
    {
        var original = @"SELECT 1 WHERE whatnot = '; ' ; MOO";
        var batches = _statementSplitter.Split(original).ToList();
        Assert.Equal(2, batches.Count);

        Assert.Equal("SELECT 1 WHERE whatnot = '; ' ", batches.First());
        Assert.Equal(" MOO", batches.Last());
    }

    [Fact]
    public void Ignores_semicolon_in_single_quotes_when_there_is_no_other_semicolon()
    {
        var original = @"SELECT 1 WHERE whatnot = '; '";
        var batches = _statementSplitter.Split(original);
        Assert.Single(batches);
    }

    [Fact]
    public void Ignores_semicolons_in_strings()
    {
        var original = @"
DO '
BEGIN
    IF NOT EXISTS(
        SELECT schema_name
        FROM information_schema.schemata
        WHERE schema_name = ''random''
    )
    THEN
        EXECUTE ''CREATE SCHEMA random'';
    END IF;
END
';
";
        var batches = _statementSplitter.Split(original);

        Assert.Single(batches);
    }
}
