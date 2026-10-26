using grate.Infrastructure;
using grate.SqlServer.Infrastructure;
using SqlServerCaseSensitive.TestInfrastructure;

// ReSharper disable InconsistentNaming

namespace SqlServerCaseSensitive.Basic_tests;

public class SqlServerStatementSplitter_
{
    private const string Symbols_to_check = "`~!@#$%^&*()-_+=,.;:'\"[]\\/?<>";
    private const string Words_to_check = "abcdefghijklmnopqrstuvwzyz0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    public class should_replace_on
    {
        private ITestOutputHelper _testOutput;
        private SqlServerStatementSplitter _splitter;

        public should_replace_on(ITestOutputHelper testOutput)
        {
            _testOutput = testOutput;
            _splitter = new SqlServerStatementSplitter();
        }

        [Fact]
        public void full_statement_without_issue()
        {
            string sql_to_match = SqlServerSplitterContext.FullSplitter.tsql_statement;
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.NotEmpty(result);
            Assert.True(result.Count > 1, "Should split into multiple statements");
            Assert.Equal(result, SqlServerSplitterContext.FullSplitter.tsql_statement_scrubbed);
        }

        [Fact]
        public void go_with_space()
        {
            const string sql_to_match = @" GO ";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Empty(result);
        }

        [Fact]
        public void go_with_tab()
        {
            string sql_to_match = @" GO" + "\t";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Empty(result);
        }

        [Fact]
        public void go_by_itself()
        {
            const string sql_to_match = @"GO";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Empty(result);
        }

        [Fact]
        public void go_starting_file()
        {
            const string sql_to_match = @"GO
whatever";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Contains("whatever", result[0]);
        }

        [Fact]
        public void go_with_new_line()
        {
            const string sql_to_match = @" GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Empty(result);
        }

        
        [Theory]
        [InlineData("\r\n", "CRLF")]
        [InlineData("\n", "LF")]
        public void go_with_on_new_line_after_double_dash_comments(string line_ending, string _)
        {
            string sql_to_match = $"--{line_ending}GO{line_ending}";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Equal(["--" + line_ending], result);
        }

        [Fact]
        public void go_with_on_new_line_after_double_dash_comments_and_words()
        {
            string sql_to_match = @"-- " + Words_to_check + @"
GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void go_with_new_line_after_double_dash_comments_and_symbols()
        {
            string sql_to_match = @"-- " + Symbols_to_check + @"
GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void go_on_its_own_line()
        {
            const string sql_to_match = @" 
GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Empty(result);
        }

        [Fact]
        public void go_with_no_line_terminator()
        {
            const string sql_to_match = @" GO ";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Empty(result);
        }

        [Fact]
        public void go_with_words_before()
        {
            string sql_to_match = Words_to_check + @" GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(Words_to_check.Trim(), result[0].Trim());
        }

        [Fact]
        public void go_with_symbols_and_words_before()
        {
            string sql_to_match = Symbols_to_check + Words_to_check + @" GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void go_with_words_and_symbols_before()
        {
            string sql_to_match = Words_to_check + Symbols_to_check + @" GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void go_with_words_after_on_the_same_line()
        {
            string sql_to_match = @" GO " + Words_to_check;
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Contains(Words_to_check.Substring(0, 5), result[0]);
        }

        [Fact]
        public void go_with_words_after_on_the_same_line_including_symbols()
        {
            string sql_to_match = @" GO " + Words_to_check + Symbols_to_check;
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
        }

        [Fact]
        public void go_with_words_before_and_after_on_the_same_line()
        {
            string sql_to_match = Words_to_check + @" GO " + Words_to_check;
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Equal([Words_to_check + " ", " " + Words_to_check], result);
        }

        [Fact]
        public void go_with_words_before_and_after_on_the_same_line_including_symbols()
        {
            string sql_to_match = Words_to_check + Symbols_to_check.Replace("'", "").Replace("\"", "") +
                                  " GO BOB" + Symbols_to_check;
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Equal(2, result.Count);
        }

        [Fact]
        public void go_after_double_dash_comment_with_single_quote_and_single_quote_after_go()
        {
            string sql_to_match = Words_to_check + @" -- '
GO
select ''
go";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Equal(2, result.Count);
        }

        [Fact]
        public void go_with_comment_after()
        {
            string sql_to_match = " GO -- comment";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Equal([" -- comment"], result);
        }

        [Fact]
        public void go_with_semicolon_directly_after()
        {
            string sql_to_match = "jalla GO;";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Equal(["jalla ", ";" ], result);
        }

    }

    public class should_not_replace_on
    {
        private readonly ITestOutputHelper _testOutput;
        private readonly SqlServerStatementSplitter _splitter;

        public should_not_replace_on(ITestOutputHelper testOutput)
        {
            _testOutput = testOutput;
            _splitter = new SqlServerStatementSplitter();
        }

        [Fact]
        public void g()
        {
            const string sql_to_match = @" G
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Contains("G", result[0]);
        }

        [Fact]
        public void o()
        {
            const string sql_to_match = @" O
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Contains("O", result[0]);
        }

        [Fact]
        public void go_when_go_is_the_last_part_of_the_last_word_on_a_line()
        {
            string sql_to_match = Words_to_check + @"GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Contains(Words_to_check.Substring(0, 5), result[0]);
        }

        [Fact]
        public void go_with_double_dash_comment_starting_line()
        {
            string sql_to_match = @"--GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_with_double_dash_comment_and_space_starting_line()
        {
            string sql_to_match = @"-- GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_with_double_dash_comment_and_space_starting_line_and_words_after_go()
        {
            string sql_to_match = @"-- GO " + Words_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_with_double_dash_comment_and_space_starting_line_and_symbols_after_go()
        {
            string sql_to_match = @"-- GO " + Symbols_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_with_double_dash_comment_and_tab_starting_line()
        {
            string sql_to_match = "--" + "\t" + @"GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_with_double_dash_comment_and_tab_starting_line_and_words_after_go()
        {
            string sql_to_match = @"--" + "\t" + @"GO " + Words_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_with_double_dash_comment_and_tab_starting_line_and_symbols_after_go()
        {
            string sql_to_match = @"--" + "\t" + @"GO " + Symbols_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_with_double_dash_comment_starting_line_with_words_before_go()
        {
            string sql_to_match = @"-- " + Words_to_check + @" GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_when_between_tick_marks()
        {
            const string sql_to_match = @"' GO
            '";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void
            go_when_between_tick_marks_with_symbols_and_words_before_ending_on_same_line()
        {
            string sql_to_match = @"' " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @" GO'";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_when_between_tick_marks_with_symbols_and_words_before()
        {
            string sql_to_match = @"' " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @" GO
            '";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_when_between_tick_marks_with_symbols_and_words_after()
        {
            string sql_to_match = @"' GO
            " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @"'";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_with_double_dash_comment_starting_line_with_symbols_before_go()
        {
            string sql_to_match = @"--" + Symbols_to_check + @" GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void
            go_with_double_dash_comment_starting_line_with_words_and_symbols_before_go()
        {
            string sql_to_match = @"--" + Symbols_to_check + Words_to_check + @" GO
";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_inside_of_comments()
        {
            string sql_to_match = @"/* GO */";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_inside_of_comments_with_a_line_break()
        {
            string sql_to_match = @"/* GO 
*/";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_inside_of_comments_with_words_before()
        {
            string sql_to_match =
                @"/* 
" + Words_to_check + @" GO

*/";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_inside_of_comments_with_words_before_on_a_different_line()
        {
            string sql_to_match =
                @"/* 
" + Words_to_check + @" 
GO

*/";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_inside_of_comments_with_words_before_and_after_on_different_lines()
        {
            string sql_to_match =
                @"/* 
" + Words_to_check + @" 
GO

" + Words_to_check + @"
*/";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }

        [Fact]
        public void go_inside_of_comments_with_symbols_after_on_different_lines()
        {
            string sql_to_match =
                @"/* 
GO

" + Symbols_to_check + @" 
*/";
            _testOutput.WriteLine(sql_to_match);
            var result = _splitter.Split(sql_to_match).ToList();
            Assert.Single(result);
            Assert.Equal(sql_to_match, result.Single());
        }
    }

    public class Split
    {
        private readonly SqlServerStatementSplitter _splitter = new();

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
}
