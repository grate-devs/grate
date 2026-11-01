using grate.Oracle.Infrastructure;

namespace Oracle.Basic_tests;

public sealed class OracleInlineStatementSplitter_
{
    private readonly OracleStatementSplitter _splitter = new();

    [Fact]
    public void with_function_declaration_and_query_remain_one_command()
    {
        const string sql = """
            WITH
                FUNCTION get_number RETURN NUMBER IS
                BEGIN
                    RETURN 1;
                END;
            SELECT get_number FROM dual;
            """;

        Assert.Equal([sql, "SELECT 2 FROM dual"],
            _splitter.Split($"{sql}\n/\nSELECT 2 FROM dual;").Select(batch => batch.Trim()));
    }

    [Fact]
    public void with_procedure_function_and_cte_remain_one_command()
    {
        const string sql = """
            WITH /* declarations */
                PROCEDURE assign_value(value OUT NUMBER) IS
                BEGIN
                    value := 1;
                END;
                FUNCTION get_number RETURN NUMBER IS
                    value NUMBER;
                BEGIN
                    assign_value(value);
                    RETURN value;
                END;
                numbers AS (SELECT get_number AS result FROM dual)
            SELECT result FROM numbers;
            """;

        Assert.Equal([sql, "BEGIN NULL; END;"],
            _splitter.Split($"{sql}\n/\nBEGIN NULL; END;\n/").Select(batch => batch.Trim()));
    }

    [Fact]
    public void ordinary_cte_keeps_sql_terminator_handling()
    {
        const string sql = "WITH numbers AS (SELECT 1 AS result FROM dual) SELECT result FROM numbers";

        Assert.Equal([sql, "BEGIN NULL; END;"],
            _splitter.Split($"{sql};\nBEGIN NULL; END;\n/").Select(batch => batch.Trim()));
    }
}
