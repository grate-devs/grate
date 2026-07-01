using grate.Configuration;
using grate.Infrastructure;
using grate.Migration;
using NSubstitute;

namespace Basic_tests.Infrastructure;


public class TokenReplacerTests
{
    [Theory]
    [InlineData("")]
    [InlineData(null)]
    public void EnsureEmptyStringIsLeftEmpty(string? input)
    {
        var tokens = new Dictionary<string, string?>();
        Assert.Equal(string.Empty, TokenReplacer.ReplaceTokens(tokens, input));
    }

    [Fact]
    public void EnsureUnknownTokenIsIgnored()
    {
        var tokens = new Dictionary<string, string?>();
        var input = "This has a {{token}} in it.";
        Assert.Equal(input, TokenReplacer.ReplaceTokens(tokens, input));
    }

    [Fact]
    public void EnsureTokensAreReplaced()
    {
        var tokens = new Dictionary<string, string?> { ["EnvName"] = "Test" };
        var input = "This is a {{EnvName}}.";
        Assert.Equal("This is a Test.", TokenReplacer.ReplaceTokens(tokens, input));
    }

    [Fact]
    public void EnsureConfigMakesItToTokens()
    {
        var folders = Folders.Default;
        var config = new GrateConfiguration() { SchemaName = "Test", Folders = folders };
        var provider = new TokenProvider(config, Substitute.For<IDatabase>());
        var tokens = provider.GetTokens();

        Assert.Equal("Test", tokens["SchemaName"]);

        //RH Only uses the name of a folder, not it's full path.  Make sure we're compat
        Assert.Equal("up", tokens["UpFolderName"]);

    }

    [Fact]
    public void EnsureUserTokenParserWorks()
    {
        Assert.Equal(("token", "value"), TokenProvider.ParseUserToken("token=value   "));
        Assert.Throws<ArgumentOutOfRangeException>(() => TokenProvider.ParseUserToken("token"));

        // #641: While we initially wanted to protect migrating users from our change to use multiple `--ut` command line params, there's
        // legitimate scenarios where we want an `=` in the value.
        Assert.Equal(("token1", "value=with=equals"), TokenProvider.ParseUserToken("token1=value=with=equals"));
        Assert.Equal(("token1", "value1;token2=value2"), TokenProvider.ParseUserToken("token1=value1;token2=value2"));
    }
}
