using grate.Infrastructure;
using grate.Migration;
using grate.Oracle.Infrastructure;

namespace Oracle.Basic_tests;


// ReSharper disable once InconsistentNaming
public class StatementSplitter_
{
    private readonly StatementSplitter _splitter;

    public StatementSplitter_()
    {
        _splitter =  new StatementSplitter(new OracleSyntax());
    }
    
    [Fact]
    public void Splits_and_removes_GO_statements()
    {
        var original = @"
SELECT * FROM v$version WHERE banner LIKE 'Oracle%';


/
SELECT 1
";
        var batches = _splitter.Split(original);

        Assert.Equal(2, batches.Count());
    }

}
