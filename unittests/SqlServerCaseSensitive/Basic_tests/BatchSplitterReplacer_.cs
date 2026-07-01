using grate.Infrastructure;
using grate.SqlServer.Infrastructure;
using SqlServerCaseSensitive.TestInfrastructure;

// ReSharper disable InconsistentNaming

namespace SqlServerCaseSensitive.Basic_tests;

public class BatchSplitterReplacer_
{
    private const string Batch_terminator_replacement_string = StatementSplitter.BatchTerminatorReplacementString;

    private const string Symbols_to_check = "`~!@#$%^&*()-_+=,.;:'\"[]\\/?<>";
    private const string Words_to_check = "abcdefghijklmnopqrstuvwzyz0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    public class should_replace_on
    {
        private ITestOutputHelper _testOutput;
        private BatchSplitterReplacer Replacer;

        public should_replace_on(ITestOutputHelper testOutput)
        {
            _testOutput = testOutput;
            Replacer = new BatchSplitterReplacer(new SqlServerSyntax());
        }

        [Fact]
        public void full_statement_without_issue()
        {
            string sql_to_match = SqlServerSplitterContext.FullSplitter.tsql_statement;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(SqlServerSplitterContext.FullSplitter.tsql_statement_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_space()
        {
            const string sql_to_match = @" GO ";
            string expected_scrubbed = @" " + Batch_terminator_replacement_string + @" ";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_tab()
        {
            string sql_to_match = @" GO" + "\t";
            string expected_scrubbed = @" " + Batch_terminator_replacement_string + "\t";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_by_itself()
        {
            const string sql_to_match = @"GO";
            string expected_scrubbed = Batch_terminator_replacement_string;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_starting_file()
        {
            const string sql_to_match = @"GO
whatever";
            string expected_scrubbed = Batch_terminator_replacement_string + @"
whatever";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_new_line()
        {
            const string sql_to_match = @" GO
";
            string expected_scrubbed = @" " + Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_on_new_line_after_double_dash_comments()
        {
            const string sql_to_match =
                @"--
GO
";
            string expected_scrubbed =
                @"--
" + Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_on_new_line_after_double_dash_comments_and_words()
        {
            string sql_to_match = @"-- " + Words_to_check + @"
GO
";
            string expected_scrubbed = @"-- " + Words_to_check + @"
" + Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_new_line_after_double_dash_comments_and_symbols()
        {
            string sql_to_match = @"-- " + Symbols_to_check + @"
GO
";
            string expected_scrubbed = @"-- " + Symbols_to_check + @"
" + Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_on_its_own_line()
        {
            const string sql_to_match = @" 
GO
";
            string expected_scrubbed = @" 
" + Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_no_line_terminator()
        {
            const string sql_to_match = @" GO ";
            string expected_scrubbed = @" " + Batch_terminator_replacement_string + @" ";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_words_before()
        {
            string sql_to_match = Words_to_check + @" GO
";
            string expected_scrubbed = Words_to_check + @" " + Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_symbols_and_words_before()
        {
            string sql_to_match = Symbols_to_check + Words_to_check + @" GO
";
            string expected_scrubbed = Symbols_to_check + Words_to_check + @" " +
                                       Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_words_and_symbols_before()
        {
            string sql_to_match = Words_to_check + Symbols_to_check + @" GO
";
            string expected_scrubbed = Words_to_check + Symbols_to_check + @" " +
                                       Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_words_after_on_the_same_line()
        {
            string sql_to_match = @" GO " + Words_to_check;
            string expected_scrubbed = @" " + Batch_terminator_replacement_string + @" " + Words_to_check;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_words_after_on_the_same_line_including_symbols()
        {
            string sql_to_match = @" GO " + Words_to_check + Symbols_to_check;
            string expected_scrubbed = @" " + Batch_terminator_replacement_string + @" " + Words_to_check +
                                       Symbols_to_check;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_words_before_and_after_on_the_same_line()
        {
            string sql_to_match = Words_to_check + @" GO " + Words_to_check;
            string expected_scrubbed = Words_to_check + @" " + Batch_terminator_replacement_string + @" " +
                                       Words_to_check;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_words_before_and_after_on_the_same_line_including_symbols()
        {
            string sql_to_match = Words_to_check + Symbols_to_check.Replace("'", "").Replace("\"", "") +
                                  " GO BOB" + Symbols_to_check;
            string expected_scrubbed = Words_to_check + Symbols_to_check.Replace("'", "").Replace("\"", "") +
                                       " " + Batch_terminator_replacement_string + " BOB" + Symbols_to_check;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_after_double_dash_comment_with_single_quote_and_single_quote_after_go()
        {
            string sql_to_match = Words_to_check + @" -- '
GO
select ''
go";
            string expected_scrubbed = Words_to_check + @" -- '
" + Batch_terminator_replacement_string + @"
select ''
" + Batch_terminator_replacement_string;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_comment_after()
        {
            string sql_to_match = " GO -- comment";
            string expected_scrubbed = " " + Batch_terminator_replacement_string + " -- comment";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_semicolon_directly_after()
        {
            string sql_to_match = "jalla GO;";
            string expected_scrubbed = "jalla " + Batch_terminator_replacement_string + ";";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

    }

    public class should_not_replace_on
    {
        private readonly ITestOutputHelper _testOutput;
        private readonly BatchSplitterReplacer _replacer;

        public should_not_replace_on(ITestOutputHelper testOutput)
        {
            _testOutput = testOutput;
            _replacer = new BatchSplitterReplacer(new SqlServerSyntax());
        }

        [Fact]
        public void g()
        {
            const string sql_to_match = @" G
";
            const string expected_scrubbed = @" G
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void o()
        {
            const string sql_to_match = @" O
";
            const string expected_scrubbed = @" O
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_when_go_is_the_last_part_of_the_last_word_on_a_line()
        {
            string sql_to_match = Words_to_check + @"GO
";
            string expected_scrubbed = Words_to_check + @"GO
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_double_dash_comment_starting_line()
        {
            string sql_to_match = @"--GO
";
            string expected_scrubbed = @"--GO
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_double_dash_comment_and_space_starting_line()
        {
            string sql_to_match = @"-- GO
";
            string expected_scrubbed = @"-- GO
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_double_dash_comment_and_space_starting_line_and_words_after_go()
        {
            string sql_to_match = @"-- GO " + Words_to_check + @"
";
            string expected_scrubbed = @"-- GO " + Words_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_double_dash_comment_and_space_starting_line_and_symbols_after_go()
        {
            string sql_to_match = @"-- GO " + Symbols_to_check + @"
";
            string expected_scrubbed = @"-- GO " + Symbols_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_double_dash_comment_and_tab_starting_line()
        {
            string sql_to_match = "--" + "\t" + @"GO
";
            string expected_scrubbed = @"--" + "\t" + @"GO
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_double_dash_comment_and_tab_starting_line_and_words_after_go()
        {
            string sql_to_match = @"--" + "\t" + @"GO " + Words_to_check + @"
";
            string expected_scrubbed = @"--" + "\t" + @"GO " + Words_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_double_dash_comment_and_tab_starting_line_and_symbols_after_go()
        {
            string sql_to_match = @"--" + "\t" + @"GO " + Symbols_to_check + @"
";
            string expected_scrubbed = @"--" + "\t" + @"GO " + Symbols_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_double_dash_comment_starting_line_with_words_before_go()
        {
            string sql_to_match = @"-- " + Words_to_check + @" GO
";
            string expected_scrubbed = @"-- " + Words_to_check + @" GO
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_when_between_tick_marks()
        {
            const string sql_to_match = @"' GO
            '";
            const string expected_scrubbed = @"' GO
            '";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void
            go_when_between_tick_marks_with_symbols_and_words_before_ending_on_same_line()
        {
            string sql_to_match = @"' " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @" GO'";
            string expected_scrubbed =
                @"' " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @" GO'";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_when_between_tick_marks_with_symbols_and_words_before()
        {
            string sql_to_match = @"' " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @" GO
            '";
            string expected_scrubbed = @"' " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @" GO
            '";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_when_between_tick_marks_with_symbols_and_words_after()
        {
            string sql_to_match = @"' GO
            " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @"'";
            string expected_scrubbed = @"' GO
            " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @"'";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_with_double_dash_comment_starting_line_with_symbols_before_go()
        {
            string sql_to_match = @"--" + Symbols_to_check + @" GO
";
            string expected_scrubbed = @"--" + Symbols_to_check + @" GO
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void
            go_with_double_dash_comment_starting_line_with_words_and_symbols_before_go()
        {
            string sql_to_match = @"--" + Symbols_to_check + Words_to_check + @" GO
";
            string expected_scrubbed = @"--" + Symbols_to_check + Words_to_check + @" GO
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_inside_of_comments()
        {
            string sql_to_match = @"/* GO */";
            string expected_scrubbed = @"/* GO */";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_inside_of_comments_with_a_line_break()
        {
            string sql_to_match = @"/* GO 
*/";
            string expected_scrubbed = @"/* GO 
*/";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_inside_of_comments_with_words_before()
        {
            string sql_to_match =
                @"/* 
" + Words_to_check + @" GO

*/";
            string expected_scrubbed =
                @"/* 
" + Words_to_check + @" GO

*/";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_inside_of_comments_with_words_before_on_a_different_line()
        {
            string sql_to_match =
                @"/* 
" + Words_to_check + @" 
GO

*/";
            string expected_scrubbed =
                @"/* 
" + Words_to_check + @" 
GO

*/";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
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
            string expected_scrubbed =
                @"/* 
" + Words_to_check + @" 
GO

" + Words_to_check + @"
*/";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void go_inside_of_comments_with_symbols_after_on_different_lines()
        {
            string sql_to_match =
                @"/* 
GO

" + Symbols_to_check + @" 
*/";
            string expected_scrubbed =
                @"/* 
GO

" + Symbols_to_check + @" 
*/";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = _replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }
    }

}
