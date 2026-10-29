using grate.Infrastructure;

namespace Basic_tests.Infrastructure;


// ReSharper disable once InconsistentNaming
public class HashGenerator_
{
    [Fact]
    public void Generates_the_correct_hash()
    {
        string text_to_hash = "I want to see what the freak is going on here";
        string expected_hash = "TMGPZJmBhSO5uYbf/TBqNA==";

        var hashGen = new HashGenerator();
        Assert.Equal(expected_hash, hashGen.Hash(text_to_hash));
    }

    [Theory]
    [InlineData("\n")]
    [InlineData("\r\n")]
    [InlineData("\r")]
    public void New_hashes_keep_the_normalized_Roundhouse_format(string lineEnding)
    {
        var sql = $"SELECT 'æ';{lineEnding}SELECT 2;{lineEnding}";

        Assert.Equal("V80d+mQUUMs/JoNH3rkeMg==", new HashGenerator().Hash(sql));
    }

    [Fact]
    public void An_unchanged_legacy_script_with_mixed_line_endings_matches()
    {
        Assert.True(new HashGenerator().Matches("SELECT 'æ';\r\nSELECT 2;\n", "i+nOxpXSrxHI68zFCwjXAw=="));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not a hash")]
    [InlineData("v80d+mQUUMs/JoNH3rkeMg==")]
    public void Missing_invalid_or_case_changed_hashes_do_not_match(string? storedHash)
    {
        Assert.False(new HashGenerator().Matches("SELECT 'æ';\nSELECT 2;\n", storedHash));
    }

    [Theory]
    [InlineData("SELECT 'æ';\nSELECT 3;\n")]
    [InlineData("SELECT 'a';\nSELECT 2;\n")]
    [InlineData("SELECT 'æ';\nSELECT  2;\n")]
    [InlineData("SELECT 'æ';\n\nSELECT 2;\n")]
    [InlineData("SELECT 'æ';\nSELECT 2;")]
    public void Content_whitespace_and_trailing_newline_changes_do_not_match_legacy_hashes(string sql)
    {
        var hashGenerator = new HashGenerator();

        Assert.False(hashGenerator.Matches(sql, "y/UjYUSSI4HWQbpoD1vcqw=="));
        Assert.False(hashGenerator.Matches(sql, "t7GiNq4DJu9ePpOPw1bHCA=="));
    }

    [Fact]
    public void A_CRLF_pair_cannot_match_two_legacy_CR_line_breaks()
    {
        // RoundhousE hash of SELECT 'æ';\r\rSELECT 2;\r (an extra blank line).
        Assert.False(new HashGenerator().Matches("SELECT 'æ';\r\nSELECT 2;\r", "85i2v/Lw7KkR2LRgX5LRYQ=="));
    }
}
