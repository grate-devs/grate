using grate.Infrastructure;
using grate.Migration;
using grate.SqlServer.Infrastructure;

namespace SqlServer.Statement_Splitting;


// ReSharper disable once InconsistentNaming
public class StatementSplitter_
{
    private readonly StatementSplitter _splitter;

    public StatementSplitter_()
    {
        _splitter =  new StatementSplitter(new SqlServerSyntax());
    }

    [Fact]
    public void Splits_and_removes_GO_statements()
    {
        var original = @"
SELECT @@VERSION;


GO
SELECT 1
";
        var batches = _splitter.Split(original);

        Assert.Equal(2, batches.Count());
    }

}
