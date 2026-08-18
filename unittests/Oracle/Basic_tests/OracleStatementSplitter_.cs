using grate.Infrastructure;
using grate.Oracle.Infrastructure;
using Oracle.TestInfrastructure;

// ReSharper disable InconsistentNaming

namespace Oracle.Basic_tests;


public class OracleStatementSplitter_
{
    private const string Symbols_to_check = "`~!@#$%^&*()-_+=,.;:'\"[]\\/?<>";
    private const string Words_to_check = "abcdefghijklmnopqrstuvwzyz0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    // ReSharper disable once InconsistentNaming
    public class should_replace_on
    {
        private ITestOutputHelper _testOutput;
        private OracleStatementSplitter _splitter;

        public should_replace_on(ITestOutputHelper testOutput)
        {
            _testOutput = testOutput;
            _splitter = new OracleStatementSplitter();
        }

        [Fact]
        public void full_statement_without_issue()
        {
            string sql_to_match = OracleSplitterContext.FullSplitter.PLSqlStatement;
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.NotEmpty(result);
            Assert.True(result.Count > 1, "Should split into multiple statements");
            Assert.Equal(result, OracleSplitterContext.FullSplitter.PLSqlStatementScrubbed);
        }

        [Fact]
        public void slash_with_space()
        {
            const string sql_to_match = @" / ";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Empty(result);
        }

        [Fact]
        public void slash_with_tab()
        {
            string sql_to_match = @" /" + "\t";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Equal(["\t"],result);
        }

        [Fact]
        public void slash_by_itself()
        {
            const string sql_to_match = @"/";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Empty(result);
        }

        [Fact]
        public void slash_starting_file()
        {
            const string sql_to_match = @"/
whatever";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_new_line()
        {
            const string sql_to_match = @" /
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Empty(result);
        }

        [Theory]
        [InlineData("\n", "LF")]
        public void slash_with_one_new_line_after_double_dash_comments_lf(string line_ending, string _)
        {
            string sql_to_match = $"--{line_ending}/{line_ending}";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Equal(["--" + line_ending], result);
        }

        [Theory]
        [InlineData("\r\n", "CRLF")]
        public void slash_with_one_new_line_after_double_dash_comments_crlf(string line_ending, string _)
        {
            string sql_to_match = $"--{line_ending}/{line_ending}";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Equal(["--" + line_ending, line_ending], result);
        }

        [Fact]
        public void slash_with_one_new_line_after_double_dash_comments_and_words()
        {
            string sql_to_match = @"-- " + Words_to_check + @"
/
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_new_line_after_double_dash_comments_and_symbols()
        {
            string sql_to_match = @"-- " + Symbols_to_check + @"
/
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_on_its_own_line()
        {
            const string sql_to_match = @" 
/
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Empty(result);
        }

        [Fact]
        public void slash_with_no_line_terminator()
        {
            const string sql_to_match = @" / ";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Empty(result);
        }

        [Fact]
        public void slash_with_words_before()
        {
            string sql_to_match = Words_to_check + @" /
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_symbols_and_words_before()
        {
            string sql_to_match = Symbols_to_check + Words_to_check + @" /
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_words_and_symbols_before()
        {
            string sql_to_match = Words_to_check + Symbols_to_check + @" /
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_words_after_on_the_same_line()
        {
            string sql_to_match = @" / " + Words_to_check;
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_words_after_on_the_same_line_including_symbols()
        {
            string sql_to_match = @" / " + Words_to_check + Symbols_to_check;
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_words_before_and_after_on_the_same_line()
        {
            string sql_to_match = Words_to_check + @" / " + Words_to_check;
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Equal([Words_to_check + " "," " + Words_to_check], result);
        }

        [Fact]
        public void slash_with_words_before_and_after_on_the_same_line_including_symbols()
        {
            string sql_to_match = Words_to_check + Symbols_to_check.Replace("'", "").Replace("\"", "") +
                                  " / BOB" + Symbols_to_check;
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Equal([ Words_to_check + Symbols_to_check.Replace("'", "").Replace("\"", "") +
                                  " ", " BOB" + Symbols_to_check], result);
        }

        [Fact]
        public void slash_after_double_dash_comment_with_single_quote_and_single_quote_after_slash()
        {
            string sql_to_match = Words_to_check + @" -- '
/
select ''
/";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Equal([Words_to_check + " -- '\n", "\nselect ''\n"], result);
        }

        [Fact]
        public void slash_with_comment_after()
        {
            string sql_to_match = " / -- comment";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_semicolon_directly_after()
        {
            string sql_to_match = "jalla /;";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Equal(["jalla ", ";"], result);
        }

        [Fact]
        public void slash_in_a_single_quoted_literal_with_an_escaped_quote_is_not_a_separator()
        {
            const string sql_to_match = "select 'can''t / here' from dual";

            var result = _splitter.Split(sql_to_match).ToList();

            Assert.Equal([sql_to_match], result);
        }

        [Theory]
        [InlineData("q'[/]'", "slash in bracket quoted literal")]
        [InlineData("q'{ / }'", "slash in brace quoted literal")]
        [InlineData("q'< / >'", "slash in angle quoted literal")]
        [InlineData("q'! / !'", "slash in delimiter quoted literal")]
        public void slash_in_an_oracle_alternative_quoted_literal_is_not_a_separator(
            string literal,
            string _)
        {
            var sql_to_match = $"select {literal} from dual";

            var result = _splitter.Split(sql_to_match).ToList();

            Assert.Equal([sql_to_match], result);
        }

        [Fact]
        public void slash_only_with_crlf_is_not_a_batch()
        {
            const string sql_to_match = " \r\n/\r\n";

            var result = _splitter.Split(sql_to_match).ToList();

            Assert.Empty(result);
        }

    }

    public class should_not_replace_on
    {
        private ITestOutputHelper _testOutput;
        private OracleStatementSplitter _splitter;

        public should_not_replace_on(ITestOutputHelper testOutput)
        {
            _testOutput = testOutput;
            _splitter = new OracleStatementSplitter();
        }
        
        [Fact]
        public void slash_when_slash_is_the_last_part_of_the_last_word_on_a_line()
        {
            string sql_to_match = Words_to_check + @"/
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_double_dash_comment_starting_line()
        {
            string sql_to_match = @"--/
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_double_dash_comment_and_space_starting_line()
        {
            string sql_to_match = @"-- /
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_double_dash_comment_and_space_starting_line_and_words_after_slash()
        {
            string sql_to_match = @"-- / " + Words_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_double_dash_comment_and_space_starting_line_and_symbols_after_slash()
        {
            string sql_to_match = @"-- / " + Symbols_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_double_dash_comment_and_tab_starting_line()
        {
            string sql_to_match = "--" + "\t" + @"/
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_double_dash_comment_and_tab_starting_line_and_words_after_slash()
        {
            string sql_to_match = @"--" + "\t" + @"/ " + Words_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_double_dash_comment_and_tab_starting_line_and_symbols_after_slash()
        {
            string sql_to_match = @"--" + "\t" + @"/ " + Symbols_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_double_dash_comment_starting_line_with_words_before_slash()
        {
            string sql_to_match = @"-- " + Words_to_check + @" /
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_when_between_tick_marks()
        {
            const string sql_to_match = @"' /
            '";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void
            slash_when_between_tick_marks_with_symbols_and_words_before_ending_on_same_line()
        {
            string sql_to_match = @"' " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @" /'";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_when_between_tick_marks_with_symbols_and_words_before()
        {
            string sql_to_match = @"' " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @" /
            '";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_when_between_tick_marks_with_symbols_and_words_after()
        {
            string sql_to_match = @"' /
            " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @"'";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_with_double_dash_comment_starting_line_with_symbols_before_slash()
        {
            string sql_to_match = @"--" + Symbols_to_check + @" /
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void
            slash_with_double_dash_comment_starting_line_with_words_and_symbols_before_slash()
        {
            string sql_to_match = @"--" + Symbols_to_check + Words_to_check + @" /
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_inside_of_comments()
        {
            string sql_to_match = @"/* / */";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_inside_of_comments_with_a_line_break()
        {
            string sql_to_match = @"/* / 
*/";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_inside_of_comments_with_words_before()
        {
            string sql_to_match =
                @"/* 
" + Words_to_check + @" /

*/";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_inside_of_comments_with_words_before_on_a_different_line()
        {
            string sql_to_match =
                @"/* 
" + Words_to_check + @" 
/

*/";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_inside_of_comments_with_words_before_and_after_on_different_lines()
        {
            string sql_to_match =
                @"/* 
" + Words_to_check + @" 
/

" + Words_to_check + @"
*/";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void slash_inside_of_comments_with_symbols_after_on_different_lines()
        {
            string sql_to_match =
                @"/* 
/

" + Symbols_to_check + @" 
*/";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }
    }

    public class sqlplus_compatibility
    {
        private readonly OracleStatementSplitter _splitter = new();

        [Fact]
        public void standalone_slash_executes_a_plsql_buffer()
        {
            const string sql = "BEGIN\n    NULL;\nEND;\n/\n";

            var result = _splitter.Split(sql).ToList();

            Assert.Equal(["BEGIN\n    NULL;\nEND;\n"], result);
        }

        [Fact]
        public void semicolons_inside_a_plsql_buffer_do_not_split_the_buffer()
        {
            const string sql = "BEGIN\n    NULL;\n    NULL;\nEND;\n/\n";

            var result = _splitter.Split(sql).ToList();

            Assert.Single(result);
            Assert.Equal(sql[..^2], result[0]);
        }

        [Fact]
        public void slash_in_a_division_expression_is_not_a_batch_separator()
        {
            const string sql = "SELECT 10 / 2 FROM dual;";

            var result = _splitter.Split(sql).ToList();

            Assert.Equal([sql], result);
        }

        [Fact]
        public void inline_slash_is_not_a_batch_separator()
        {
            const string sql = "SELECT 1 / 2 FROM dual; SELECT 3 FROM dual;";

            var result = _splitter.Split(sql).ToList();

            Assert.Equal([sql], result);
        }

        [Fact]
        public void blank_lines_do_not_execute_or_split_the_sqlplus_buffer()
        {
            const string sql = "SELECT 1 FROM dual;\n\nSELECT 2 FROM dual;";

            var result = _splitter.Split(sql).ToList();

            Assert.Equal([sql], result);
        }

        [Fact]
        public void standalone_slash_with_trailing_spaces_executes_at_eof()
        {
            const string sql = "BEGIN\n    NULL;\nEND;\n/   ";

            var result = _splitter.Split(sql).ToList();

            Assert.Equal(["BEGIN\n    NULL;\nEND;\n"], result);
        }

        [Fact]
        public void repeated_standalone_slashes_do_not_create_empty_batches()
        {
            const string sql = "BEGIN\n    NULL;\nEND;\n/\n/\n";

            var result = _splitter.Split(sql).ToList();

            Assert.Single(result);
        }

        [Fact]
        public void standalone_slash_works_with_crlf_line_endings()
        {
            const string sql = "BEGIN\r\n    NULL;\r\nEND;\r\n/\r\n";

            var result = _splitter.Split(sql).ToList();

            Assert.Equal(["BEGIN\r\n    NULL;\r\nEND;\r\n"], result);
        }
    }

    public class Split
    {
        private readonly OracleStatementSplitter _splitter = new();

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
}
