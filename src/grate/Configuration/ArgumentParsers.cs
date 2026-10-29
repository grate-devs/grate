using System.CommandLine.Parsing;

namespace grate.Configuration;

internal static class ArgumentParsers
{
    private static readonly char[] Delimiters = [',', ';'];

    // Accept both multiple arguments and comma/semicolon-separated environment names.
    public static CommandLineGrateEnvironment? ParseEnvironment(ArgumentResult result)
    {
        return result.Tokens.Any() 
            ? new CommandLineGrateEnvironment(result.Tokens.SelectMany(GetEnvironments)) 
            : null;
    }

    private static IEnumerable<string> GetEnvironments(Token token)
    {
        return token.Value.Split(Delimiters, StringSplitOptions.RemoveEmptyEntries);
    }
}
