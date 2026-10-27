using grate.Oracle.Infrastructure;

namespace Oracle.Basic_tests;

public sealed class OraclePackageStatementSplitter_
{
    private readonly OracleStatementSplitter _splitter = new();

    // Original package from https://github.com/grate-devs/grate/issues/642.
    private const string PackageSpecification = """
        CREATE OR REPLACE PACKAGE ARGUS_DBA.AnalyticsCommonUtility IS
        cMAX_CPP          NUMBER(16,2) DEFAULT 10000000;
        
        FUNCTION CalculateCPM(
          Rate    IN  NUMBER,
          Imps    IN  NUMBER
        ) RETURN NUMBER;
        
        
        FUNCTION CalculateCPP(
          Rate    IN  NUMBER,
          Rating  IN  NUMBER
        ) RETURN NUMBER;
        
        
        FUNCTION CalculateIndex(
          Imps    IN  NUMBER,
          Gtee    IN  NUMBER
        ) RETURN NUMBER;
        
        
        END AnalyticsCommonUtility;
        """;

    private const string PackageBody = """
        CREATE OR REPLACE PACKAGE BODY ARGUS_DBA.AnalyticsCommonUtility IS
        
        FUNCTION CalculateCPM(
          Rate    IN  NUMBER,
          Imps    IN  NUMBER
        )
          RETURN NUMBER
        IS
          CPM NUMBER;
        BEGIN
        
          IF (Imps IS NULL OR Imps = 0) THEN
            RETURN 0;
          END IF;
        
          CPM := ROUND((Rate * 1000) / Imps, 2);
        
          IF CPM >= 10000 THEN
            RETURN 10000;
          ELSE
            RETURN CPM;
          END IF;
        END CalculateCPM;
        
        
        FUNCTION CalculateCPP(
          Rate    IN  NUMBER,
          Rating  IN  NUMBER
        )
          RETURN NUMBER
        IS
          CPP NUMBER;
        BEGIN
        
          IF (Rating IS NULL  OR Rating = 0) THEN
            RETURN 0;
          END IF;
        
          CPP := ROUND(Rate / Rating, 2);
        
          IF CPP > cMAX_CPP THEN
            RETURN cMAX_CPP;
          ELSE
            RETURN CPP;
          END IF;
        END CalculateCPP;
        
        
        FUNCTION CalculateIndex(
          Imps    IN  NUMBER,
          Gtee    IN  NUMBER
        )
          RETURN NUMBER
        IS
          Idx NUMBER;
        BEGIN
        
          IF (Gtee = 0) THEN
            RETURN 0;
          END IF;
        
          Idx := (Imps * 1.0 / Gtee * 1.0) * 100;
        
          Idx := Round(Idx,2);
          
          IF Idx >= 1000 THEN
            Idx := 999.99;
          END IF;
        
          RETURN Idx;
        END CalculateIndex;
        
        
        END;
        """;

    [Theory]
    [InlineData(";", "\n")]
    [InlineData("/", "\n")]
    [InlineData(";", "\r\n")]
    [InlineData("/", "\r\n")]
    public void original_package_and_body_remain_two_complete_commands(string delimiter, string newline)
    {
        var specification = PackageSpecification.Replace("\n", newline);
        var body = PackageBody.Replace("\n", newline);
        var sql = $"{specification}{newline}{delimiter}{newline}{body}{newline}{delimiter}{newline}";

        var batches = _splitter.Split(sql).Select(batch => batch.Trim()).ToArray();

        Assert.Equal([specification, body], batches);
    }

    [Theory]
    [InlineData("PROCEDURE p IS", "END p;")]
    [InlineData("FUNCTION f RETURN NUMBER IS", "RETURN value; END f;")]
    public void declarations_and_nested_routines_stay_inside_stored_program(string declaration, string ending)
    {
        var program = $"""
            CREATE OR REPLACE {declaration}
                value NUMBER := 10;
                PROCEDURE nested IS
                    other NUMBER := 2;
                BEGIN
                    value := value / other;
                END nested;
            BEGIN
                nested;
                DECLARE
                    copy NUMBER := value;
                BEGIN
                    value := copy;
                END;
                {ending}
            """;

        Assert.Equal([program], _splitter.Split(program));
    }

    [Theory]
    [InlineData(";")]
    [InlineData("/")]
    public void stored_program_delimiter_resets_state_for_following_sql(string delimiter)
    {
        const string program = "CREATE OR REPLACE PROCEDURE p IS value NUMBER; BEGIN NULL; END p;";
        const string firstSql = "CREATE TABLE first_table (id NUMBER)";
        const string secondSql = "CREATE TABLE second_table (id NUMBER)";
        var sql = $"{program}\n{delimiter}\n{firstSql}\n/\n{secondSql}";

        Assert.Equal([program, firstSql, secondSql], _splitter.Split(sql).Select(batch => batch.Trim()));
    }

    [Fact]
    public void comments_in_header_and_quoted_qualified_names_preserve_package()
    {
        const string program = """
            -- Before the declaration
            CREATE /* header */ OR -- replacement
            REPLACE EDITIONABLE PACKAGE "Some.Schema"."BEGIN; / package" IS
                value NUMBER;
            END "BEGIN; / package";
            """;

        Assert.Equal([program], _splitter.Split(program));
    }

    [Fact]
    public void separator_lines_in_literals_and_comments_do_not_end_package()
    {
        const string program = """
            CREATE PACKAGE p IS
                text VARCHAR2(200) := q'[CREATE PROCEDURE fake IS
            ;
            /
            END;]';
                other VARCHAR2(200) := 'it''s a
            ;
            /
            string';
                /*
            ;
            /
                */
            END p;
            """;

        Assert.Equal([program], _splitter.Split(program));
    }

    [Fact]
    public void semicolon_lines_terminating_internal_statements_remain_inside_program()
    {
        const string program = """
            CREATE OR REPLACE PROCEDURE p AS
                value NUMBER
                ;
            BEGIN
                NULL
                ;
            END p;
            """;

        Assert.Equal([program], _splitter.Split($"{program}\n;\n").Select(batch => batch.Trim()));
    }

    [Theory]
    [InlineData("-- comment ending ;")]
    [InlineData("/* comment containing ; */")]
    public void semicolons_inside_comments_do_not_turn_statement_terminator_into_separator(string comment)
    {
        var program = $"""
            CREATE OR REPLACE PROCEDURE p AS
                value NUMBER;
            BEGIN
                NULL {comment}
                ;
            END p;
            """;

        Assert.Equal([program], _splitter.Split($"{program}\n;\n").Select(batch => batch.Trim()));
    }

    [Fact]
    public void roundhouse_separator_can_follow_comments_after_completed_program()
    {
        const string program = """
            CREATE PACKAGE p IS value NUMBER; END p;
            -- retained comment
            /* retained block comment */
            """;

        Assert.Equal([program], _splitter.Split($"{program}\n;\n").Select(batch => batch.Trim()));
    }

    [Theory]
    [InlineData("named_block")]
    [InlineData("\"Named Block\"")]
    public void slash_delimits_named_anonymous_block_before_next_block(string name)
    {
        var first = $"<<{name}>> BEGIN NULL; END {name};";
        const string second = "BEGIN NULL; END;";

        Assert.Equal([first, second], _splitter.Split($"{first}\n/\n{second}").Select(batch => batch.Trim()));
    }

    [Theory]
    [InlineData("FUNCTION twice(n NUMBER) RETURN NUMBER IS", "RETURN n * 2;", "twice", "value := twice(2);")]
    [InlineData("PROCEDURE assign_value IS", "value := 2;", "assign_value", "assign_value;")]
    public void named_local_routine_does_not_end_enclosing_anonymous_block(
        string declaration, string body, string name, string invocation)
    {
        var block = $"""
            DECLARE
                value NUMBER;
                {declaration}
                BEGIN
                    {body}
                END {name};
            BEGIN
                {invocation}
            END;
            """;
        const string followingBlock = "BEGIN NULL; END;";

        Assert.Equal([block, followingBlock],
            _splitter.Split($"{block}\n/\n{followingBlock}\n/\n").Select(batch => batch.Trim()));
    }

    [Theory]
    [InlineData("END ;")]
    [InlineData("END\n;")]
    public void spaced_case_expression_end_does_not_end_anonymous_block(string expressionEnd)
    {
        var block = $"""
            DECLARE
                value NUMBER;
            BEGIN
                value := CASE WHEN 1 = 1 THEN 1 ELSE 0 {expressionEnd}
                NULL;
            END;
            """;
        const string followingBlock = "BEGIN NULL; END;";

        Assert.Equal([block, followingBlock],
            _splitter.Split($"{block}\n/\n{followingBlock}\n/\n").Select(batch => batch.Trim()));
    }

    [Theory]
    [InlineData("-- CREATE PACKAGE fake IS\n")]
    [InlineData("/* CREATE PACKAGE fake IS */\n")]
    [InlineData("SELECT 'CREATE PACKAGE fake IS' FROM dual\n/\n")]
    public void stored_program_keywords_in_comments_and_strings_do_not_change_mode(string prefix)
    {
        const string block = "BEGIN NULL; END;";
        var batches = _splitter.Split($"{prefix}{block}\n{block}").ToArray();

        Assert.EndsWith(block, batches[^2].Trim());
        Assert.Equal(block, batches[^1].Trim());
    }
}
