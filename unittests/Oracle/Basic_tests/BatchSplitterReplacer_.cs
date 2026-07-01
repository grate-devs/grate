using grate.Infrastructure;
using grate.Migration;
using grate.Oracle.Infrastructure;
using Oracle.TestInfrastructure;

// ReSharper disable InconsistentNaming

namespace Oracle.Basic_tests;


public class BatchSplitterReplacer_
{
    private const string Batch_terminator_replacement_string = StatementSplitter.BatchTerminatorReplacementString;

    private const string Symbols_to_check = "`~!@#$%^&*()-_+=,.;:'\"[]\\/?<>";
    private const string Words_to_check = "abcdefghijklmnopqrstuvwzyz0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    // private static readonly IDatabase Database = new OracleDatabase(NullLogger<OracleDatabase>.Instance);

    // private static BatchSplitterReplacer Replacer => new(Database.StatementSeparatorRegex, StatementSplitter.BatchTerminatorReplacementString);

    // ReSharper disable once InconsistentNaming
    public class should_replace_on
    {
        private ITestOutputHelper _testOutput;
        private BatchSplitterReplacer Replacer;

        public should_replace_on(ITestOutputHelper testOutput)
        {
            _testOutput = testOutput;
            Replacer = new BatchSplitterReplacer(new OracleSyntax());
        }

        [Fact]
        public void full_statement_without_issue()
        {
            string sql_to_match = OracleSplitterContext.FullSplitter.PLSqlStatement;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(OracleSplitterContext.FullSplitter.PLSqlStatementScrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_space()
        {
            const string sql_to_match = @" / ";
            string expected_scrubbed = @" " + Batch_terminator_replacement_string + @" ";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_tab()
        {
            string sql_to_match = @" /" + "\t";
            string expected_scrubbed = @" " + Batch_terminator_replacement_string + "\t";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_by_itself()
        {
            const string sql_to_match = @"/";
            string expected_scrubbed = Batch_terminator_replacement_string;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_starting_file()
        {
            const string sql_to_match = @"/
whatever";
            string expected_scrubbed = Batch_terminator_replacement_string + @"
whatever";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_new_line()
        {
            const string sql_to_match = @" /
";
            string expected_scrubbed = @" " + Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_one_new_line_after_double_dash_comments()
        {
            const string sql_to_match =
                @"--
/
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
        public void slash_with_one_new_line_after_double_dash_comments_and_words()
        {
            string sql_to_match = @"-- " + Words_to_check + @"
/
";
            string expected_scrubbed = @"-- " + Words_to_check + @"
" + Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_new_line_after_double_dash_comments_and_symbols()
        {
            string sql_to_match = @"-- " + Symbols_to_check + @"
/
";
            string expected_scrubbed = @"-- " + Symbols_to_check + @"
" + Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_on_its_own_line()
        {
            const string sql_to_match = @" 
/
";
            string expected_scrubbed = @" 
" + Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_no_line_terminator()
        {
            const string sql_to_match = @" / ";
            string expected_scrubbed = @" " + Batch_terminator_replacement_string + @" ";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_words_before()
        {
            string sql_to_match = Words_to_check + @" /
";
            string expected_scrubbed = Words_to_check + @" " + Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_symbols_and_words_before()
        {
            string sql_to_match = Symbols_to_check + Words_to_check + @" /
";
            string expected_scrubbed = Symbols_to_check + Words_to_check + @" " +
                                       Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_words_and_symbols_before()
        {
            string sql_to_match = Words_to_check + Symbols_to_check + @" /
";
            string expected_scrubbed = Words_to_check + Symbols_to_check + @" " +
                                       Batch_terminator_replacement_string + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_words_after_on_the_same_line()
        {
            string sql_to_match = @" / " + Words_to_check;
            string expected_scrubbed = @" " + Batch_terminator_replacement_string + @" " + Words_to_check;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_words_after_on_the_same_line_including_symbols()
        {
            string sql_to_match = @" / " + Words_to_check + Symbols_to_check;
            string expected_scrubbed = @" " + Batch_terminator_replacement_string + @" " + Words_to_check +
                                       Symbols_to_check;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_words_before_and_after_on_the_same_line()
        {
            string sql_to_match = Words_to_check + @" / " + Words_to_check;
            string expected_scrubbed = Words_to_check + @" " + Batch_terminator_replacement_string + @" " +
                                       Words_to_check;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_words_before_and_after_on_the_same_line_including_symbols()
        {
            string sql_to_match = Words_to_check + Symbols_to_check.Replace("'", "").Replace("\"", "") +
                                  " / BOB" + Symbols_to_check;
            string expected_scrubbed = Words_to_check + Symbols_to_check.Replace("'", "").Replace("\"", "") +
                                       " " + Batch_terminator_replacement_string + " BOB" + Symbols_to_check;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_after_double_dash_comment_with_single_quote_and_single_quote_after_slash()
        {
            string sql_to_match = Words_to_check + @" -- '
/
select ''
/";
            string expected_scrubbed = Words_to_check + @" -- '
" + Batch_terminator_replacement_string + @"
select ''
" + Batch_terminator_replacement_string;
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_comment_after()
        {
            string sql_to_match = " / -- comment";
            string expected_scrubbed = " " + Batch_terminator_replacement_string + " -- comment";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_semicolon_directly_after()
        {
            string sql_to_match = "jalla /;";
            string expected_scrubbed = "jalla " + Batch_terminator_replacement_string + ";";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

    }

    public class should_not_replace_on
    {
        private ITestOutputHelper _testOutput;
        private BatchSplitterReplacer Replacer;

        public should_not_replace_on(ITestOutputHelper testOutput)
        {
            _testOutput = testOutput;
            Replacer = new BatchSplitterReplacer(new OracleSyntax());
        }
        
        [Fact]
        public void slash_when_slash_is_the_last_part_of_the_last_word_on_a_line()
        {
            string sql_to_match = Words_to_check + @"/
";
            string expected_scrubbed = Words_to_check + @"/
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_double_dash_comment_starting_line()
        {
            string sql_to_match = @"--/
";
            string expected_scrubbed = @"--/
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_double_dash_comment_and_space_starting_line()
        {
            string sql_to_match = @"-- /
";
            string expected_scrubbed = @"-- /
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_double_dash_comment_and_space_starting_line_and_words_after_slash()
        {
            string sql_to_match = @"-- / " + Words_to_check + @"
";
            string expected_scrubbed = @"-- / " + Words_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_double_dash_comment_and_space_starting_line_and_symbols_after_slash()
        {
            string sql_to_match = @"-- / " + Symbols_to_check + @"
";
            string expected_scrubbed = @"-- / " + Symbols_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_double_dash_comment_and_tab_starting_line()
        {
            string sql_to_match = "--" + "\t" + @"/
";
            string expected_scrubbed = @"--" + "\t" + @"/
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_double_dash_comment_and_tab_starting_line_and_words_after_slash()
        {
            string sql_to_match = @"--" + "\t" + @"/ " + Words_to_check + @"
";
            string expected_scrubbed = @"--" + "\t" + @"/ " + Words_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_double_dash_comment_and_tab_starting_line_and_symbols_after_slash()
        {
            string sql_to_match = @"--" + "\t" + @"/ " + Symbols_to_check + @"
";
            string expected_scrubbed = @"--" + "\t" + @"/ " + Symbols_to_check + @"
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_double_dash_comment_starting_line_with_words_before_slash()
        {
            string sql_to_match = @"-- " + Words_to_check + @" /
";
            string expected_scrubbed = @"-- " + Words_to_check + @" /
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_when_between_tick_marks()
        {
            const string sql_to_match = @"' /
            '";
            const string expected_scrubbed = @"' /
            '";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void
            slash_when_between_tick_marks_with_symbols_and_words_before_ending_on_same_line()
        {
            string sql_to_match = @"' " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @" /'";
            string expected_scrubbed =
                @"' " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @" /'";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_when_between_tick_marks_with_symbols_and_words_before()
        {
            string sql_to_match = @"' " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @" /
            '";
            string expected_scrubbed = @"' " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @" /
            '";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_when_between_tick_marks_with_symbols_and_words_after()
        {
            string sql_to_match = @"' /
            " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @"'";
            string expected_scrubbed = @"' /
            " + Symbols_to_check.Replace("'", string.Empty) + Words_to_check + @"'";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_with_double_dash_comment_starting_line_with_symbols_before_slash()
        {
            string sql_to_match = @"--" + Symbols_to_check + @" /
";
            string expected_scrubbed = @"--" + Symbols_to_check + @" /
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void
            slash_with_double_dash_comment_starting_line_with_words_and_symbols_before_slash()
        {
            string sql_to_match = @"--" + Symbols_to_check + Words_to_check + @" /
";
            string expected_scrubbed = @"--" + Symbols_to_check + Words_to_check + @" /
";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_inside_of_comments()
        {
            string sql_to_match = @"/* / */";
            string expected_scrubbed = @"/* / */";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_inside_of_comments_with_a_line_break()
        {
            string sql_to_match = @"/* / 
*/";
            string expected_scrubbed = @"/* / 
*/";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_inside_of_comments_with_words_before()
        {
            string sql_to_match =
                @"/* 
" + Words_to_check + @" /

*/";
            string expected_scrubbed =
                @"/* 
" + Words_to_check + @" /

*/";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_inside_of_comments_with_words_before_on_a_different_line()
        {
            string sql_to_match =
                @"/* 
" + Words_to_check + @" 
/

*/";
            string expected_scrubbed =
                @"/* 
" + Words_to_check + @" 
/

*/";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
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
            string expected_scrubbed =
                @"/* 
" + Words_to_check + @" 
/

" + Words_to_check + @"
*/";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }

        [Fact]
        public void slash_inside_of_comments_with_symbols_after_on_different_lines()
        {
            string sql_to_match =
                @"/* 
/

" + Symbols_to_check + @" 
*/";
            string expected_scrubbed =
                @"/* 
/

" + Symbols_to_check + @" 
*/";
            _testOutput.WriteLine(sql_to_match);
            string sql_statement_scrubbed = Replacer.Replace(sql_to_match);
            Assert.Equal(expected_scrubbed, sql_statement_scrubbed);
        }
    }

}
