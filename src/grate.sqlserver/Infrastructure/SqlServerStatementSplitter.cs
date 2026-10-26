using System.Diagnostics;
using System.Text.RegularExpressions;
using grate.Infrastructure;

namespace grate.SqlServer.Infrastructure;

/// <summary>
/// Splits SQL Server batches on GO separators using a tokenizer rather than a single regex,
/// so nested comments, string literals and batch separators can be mixed in any combination.
/// </summary>
public partial class SqlServerStatementSplitter : IStatementSplitter
{
    private enum TokenType
    {
        BatchSeparator,
        StringDelimiter,
        MultiLineCommentStart,
        MultiLineCommentEnd,
        SingleLineCommentStart,
        NewLine
    }

    private readonly record struct Token(TokenType Type, int Index, int Length);

    [GeneratedRegex(
        """
        \bGO\b|'|/\*|\*/|--|$
        """,
        RegexOptions.Multiline | RegexOptions.IgnoreCase)]
    private static partial Regex TokenPattern();

    [GeneratedRegex(@"\S")]
    private static partial Regex SignificantTextPattern();

    public IEnumerable<string> Split(string statement) =>
        BreakIntoBatches(statement).Where(batch => SignificantTextPattern().IsMatch(batch));

    private static IEnumerable<Token> Tokenize(string sql)
    {
        for (var match = TokenPattern().Match(sql); match.Success; match = match.NextMatch())
        {
            // Each alternative in TokenPattern yields distinct literal text, so the matched
            // value alone identifies the token type - anything else is the (case-insensitive) GO.
            var type = match.Value switch
            {
                "'" => TokenType.StringDelimiter,
                "/*" => TokenType.MultiLineCommentStart,
                "*/" => TokenType.MultiLineCommentEnd,
                "--" => TokenType.SingleLineCommentStart,
                "" => TokenType.NewLine,
                _ => TokenType.BatchSeparator
            };
            yield return new Token(type, match.Index, match.Length);
        }
    }

    /// <summary>
    /// Cuts the sql into batches wherever a GO batch separator token is found outside
    /// of any string literal or comment, tracking nested multi-line comments.
    /// </summary>
    private static IEnumerable<string> BreakIntoBatches(string sql)
    {
        using var tokens = Tokenize(sql).GetEnumerator();
        var cutIndex = 0;
        var token = default(Token);

        bool NextToken()
        {
            if (!tokens.MoveNext())
            {
                return false;
            }
            token = tokens.Current;
            return true;
        }

        while (NextToken())
        {
            switch (token.Type)
            {
                case TokenType.BatchSeparator:
                    // great! we have a batch of SQL. 
                    yield return sql[cutIndex..token.Index];
                    cutIndex = token.Index + token.Length;
                    break;

                case TokenType.StringDelimiter:
                    // Consume until we exit the string
                    while (NextToken() && token.Type != TokenType.StringDelimiter)
                    {
                    }
                    break;

                case TokenType.MultiLineCommentStart:
                    // Consume until we exit the top-most comment, 
                    // accounting for nesting
                    var depth = 1;
                    while (depth > 0 && NextToken())
                    {
                        depth += token.Type switch
                        {
                            TokenType.MultiLineCommentStart => 1,
                            TokenType.MultiLineCommentEnd => -1,
                            _ => 0
                        };
                    }
                    break;

                case TokenType.SingleLineCommentStart:
                    while (NextToken() && token.Type != TokenType.NewLine)
                    {
                    }
                    break;

                case TokenType.NewLine:
                    break;

                default:
                    throw new UnreachableException($"Unexpected token type: {token.Type}");
            }
        }

        // And the final sql batch
        yield return sql[cutIndex..];
    }
}
