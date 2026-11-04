using grate.Oracle.Infrastructure;

namespace Oracle.Basic_tests;

public sealed class OracleCaseStatementSplitter_
{
    private readonly OracleStatementSplitter _splitter = new();

    [Theory]
    [InlineData("END;", "\n")]
    [InlineData("END;", "\r\n")]
    [InlineData("END ;", "\n")]
    [InlineData("END\n;", "\n")]
    public void case_expression_does_not_end_anonymous_block(string expressionEnd, string newline)
    {
        var block = $"""
            DECLARE
                value NUMBER;
            BEGIN
                value := CASE WHEN 1 = 1 THEN 1 ELSE 0 {expressionEnd}
                NULL;
            END;
            """.ReplaceLineEndings(newline);
        const string followingSql = "SELECT 2 FROM dual";

        Assert.Equal([block, followingSql],
            _splitter.Split($"{block}{newline}/{newline}{followingSql};").Select(batch => batch.Trim()));
    }

    [Theory]
    [InlineData("CASE WHEN 1 = 1 THEN CASE WHEN 2 = 2 THEN 3 ELSE 4 END ELSE 5 END")]
    [InlineData("CASE 1 WHEN 1 THEN 3 ELSE 4 END")]
    public void case_initializer_preserves_declarations_and_the_outer_begin(string expression)
    {
        var block = $"""
            DECLARE
                value NUMBER := {expression};
            BEGIN
                NULL;
            END;
            """;

        Assert.Equal([block, "BEGIN NULL; END;"],
            _splitter.Split($"{block}\n/\nBEGIN NULL; END;\n/").Select(batch => batch.Trim()));
    }

    [Fact]
    public void case_statement_with_an_inner_block_keeps_both_endings()
    {
        const string block = """
            BEGIN
                CASE
                    WHEN 1 = 1 THEN
                        BEGIN
                            NULL;
                        END;
                    ELSE
                        NULL;
                END CASE;
                NULL;
            END;
            """;

        Assert.Equal([block, "SELECT 2 FROM dual"],
            _splitter.Split($"{block}\n/\nSELECT 2 FROM dual;").Select(batch => batch.Trim()));
    }

    [Fact]
    public void case_expressions_inside_a_case_statement_do_not_close_the_outer_block()
    {
        const string block = """
            DECLARE
                value NUMBER;
            BEGIN
                CASE 1
                    WHEN 1 THEN value := CASE WHEN 2 = 2 THEN 3 ELSE 4 END;
                    ELSE value := 5;
                END /* statement */ CASE;
                NULL;
            END;
            """;

        Assert.Equal([block], _splitter.Split($"{block}\n/").Select(batch => batch.Trim()));
    }

    [Theory]
    [InlineData("IF 2 = 2 THEN NULL; END IF;")]
    [InlineData("LOOP EXIT; END LOOP;")]
    public void other_control_flow_endings_do_not_close_case_scope(string statement)
    {
        var block = $"""
            BEGIN
                CASE WHEN 1 = 1 THEN {statement} END CASE;
                NULL;
            END;
            """;

        Assert.Equal([block, "SELECT 2 FROM dual"],
            _splitter.Split($"{block}\nSELECT 2 FROM dual;").Select(batch => batch.Trim()));
    }

    [Theory]
    [InlineData("CASE WHEN 1 = 1 THEN 2 ELSE 3 END AS result")]
    [InlineData("(CASE WHEN 1 = 1 THEN 2 ELSE 3 END)")]
    [InlineData("CASE WHEN 1 = 1 THEN CASE WHEN 2 = 2 THEN 3 ELSE 4 END ELSE 5 END result")]
    public void sql_case_end_before_an_alias_or_parenthesis_does_not_leak_into_the_next_block(string expression)
    {
        var sql = $"SELECT {expression} FROM dual";
        const string block = "BEGIN NULL; END;";

        Assert.Equal([sql, block],
            _splitter.Split($"{sql};\n{block}\n/").Select(batch => batch.Trim()));
    }

    [Theory]
    [InlineData("case$")]
    [InlineData("case#")]
    [InlineData("\"CASE\"")]
    public void case_identifiers_do_not_create_case_scope(string identifier)
    {
        var block = $"DECLARE {identifier} NUMBER; BEGIN {identifier} := 1; END;";

        Assert.Equal([block, "SELECT 2 FROM dual"],
            _splitter.Split($"{block}\nSELECT 2 FROM dual;").Select(batch => batch.Trim()));
    }

    [Fact]
    public void case_keywords_in_literals_and_comments_do_not_change_scope()
    {
        const string block = """
            DECLARE
                text VARCHAR2(100) := q'[CASE END;]';
            BEGIN
                text := 'CASE END;';
                -- CASE END;
                /* CASE END; */
                NULL;
            END;
            """;

        Assert.Equal([block, "SELECT 2 FROM dual"],
            _splitter.Split($"{block}\nSELECT 2 FROM dual;").Select(batch => batch.Trim()));
    }
}
