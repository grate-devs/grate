using grate.Oracle.Infrastructure;

namespace Oracle.Basic_tests;

public sealed class OracleAnonymousStatementSplitter_
{
    private readonly OracleStatementSplitter _splitter = new();

    [Theory]
    [InlineData("FUNCTION twice(n NUMBER) RETURN NUMBER IS", "RETURN n * 2;", "value := twice(2);")]
    [InlineData("PROCEDURE assign_value IS", "value := 2;", "assign_value;")]
    public void unnamed_local_routine_end_does_not_end_the_anonymous_unit(
        string declaration, string body, string invocation)
    {
        var block = $"""
            DECLARE
                value NUMBER;
                {declaration}
                BEGIN
                    {body}
                END;
            BEGIN
                {invocation}
            END;
            """;

        Assert.Equal([block, "SELECT 2 FROM dual"],
            _splitter.Split($"{block}\n/\nSELECT 2 FROM dual;").Select(batch => batch.Trim()));
    }

    [Fact]
    public void forward_declarations_and_nested_routines_remain_in_one_anonymous_unit()
    {
        const string block = """
            DECLARE
                value NUMBER;
                PROCEDURE assign_value;
                PROCEDURE assign_value IS
                    FUNCTION twice(n NUMBER) RETURN NUMBER IS
                    BEGIN
                        RETURN n * 2;
                    END;
                BEGIN
                    value := twice(2);
                END assign_value;
            BEGIN
                assign_value;
            END;
            """;

        Assert.Equal([block, "BEGIN NULL; END;"],
            _splitter.Split($"{block}\n/\nBEGIN NULL; END;\n/").Select(batch => batch.Trim()));
    }

    [Theory]
    [InlineData("amount$END")]
    [InlineData("amount#END")]
    [InlineData("amount$BEGIN")]
    [InlineData("amount#BEGIN")]
    [InlineData("amount$DECLARE")]
    [InlineData("amount#DECLARE")]
    [InlineData("END$amount")]
    [InlineData("DECLARE#amount")]
    [InlineData("amount$FUNCTION")]
    [InlineData("amount#PROCEDURE")]
    [InlineData("\"amount$END\"")]
    public void oracle_identifier_characters_do_not_create_keyword_boundaries(string identifier)
    {
        var block = $"""
            DECLARE
                {identifier} NUMBER := 1;
                value NUMBER;
            BEGIN
                value := {identifier};
                NULL;
            END;
            """;

        Assert.Equal([block, "SELECT 2 FROM dual"],
            _splitter.Split($"{block}\nSELECT 2 FROM dual;").Select(batch => batch.Trim()));
    }
}
