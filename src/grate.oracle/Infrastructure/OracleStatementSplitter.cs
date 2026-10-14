using System.Text.RegularExpressions;
using grate.Infrastructure;

namespace grate.Oracle.Infrastructure;

/// <summary>
/// Splits Oracle scripts on semicolons and SQL*Plus slash commands without treating
/// separators in comments or quoted literals as batch separators.
/// </summary>
public partial class OracleStatementSplitter : IStatementSplitter
{
    private enum TokenType
    {
        BlockStart,
        DeclareBlockStart,
        BlockEnd,
        Semicolon,
        SQLPLUSEXECUTE,
        StringLiteral,
        OpenCustomQuotedLiteral,
        MultiLineCommentStart,
        MultiLineCommentEnd,
        SingleLineComment,
        NewLine
    }

    private readonly record struct Token(
        TokenType Type,
        int Index,
        int Length,
        string CustomQuoteDelimiter = "");

    private const string OpenCustomQuotedLiteralPattern =
        "(?<OpenCustomQuotedLiteral>\\b[qQ]'(?<CustomQuoteDelimiter>[^'\\s]))";
    private const string StringLiteralPattern = "(?<StringLiteral>')";
    private const string MultiLineCommentStartPattern = "(?<MultiLineCommentStart>/\\*)";
    private const string MultiLineCommentEndPattern = "(?<MultiLineCommentEnd>\\*/)";
    private const string SingleLineCommentPattern = "(?<SingleLineComment>--)";
    private const string BlockStartPattern = "(?<BlockStart>\\bBEGIN\\b)";
    private const string DeclareBlockStartPattern = "(?<DeclareBlockStart>\\bDECLARE\\b)";

    // Note that this captures ; as well, so that we avoid capturing END IF; etc.
    private const string BlockEndPattern = "(?<BlockEnd>\\bEND;)";
    private const string SemicolonPattern = "(?<Semicolon>;)";
    private const string SqlPlusExecutePattern = "(?<SQLPLUSEXECUTE>^[ \\t]*/[ \\t]*(?=\\r?$))";
    private const string NewLinePattern = "(?<NewLine>\\r\\n|\\r|\\n)";

    [GeneratedRegex(
        OpenCustomQuotedLiteralPattern + "|" +
        StringLiteralPattern + "|" +
        MultiLineCommentStartPattern + "|" +
        MultiLineCommentEndPattern + "|" +
        SingleLineCommentPattern + "|" +
        BlockStartPattern + "|" +
        DeclareBlockStartPattern + "|" +
        BlockEndPattern + "|" +
        SemicolonPattern + "|" +
        SqlPlusExecutePattern + "|" +
        NewLinePattern,
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
            var index = match.Index;
            var tokenGroup = match.Groups
                .Cast<Group>()
                .Single(group => group.Success && group.Name is not "0" and not "CustomQuoteDelimiter");
            var tokenType = Enum.Parse<TokenType>(tokenGroup.Name);
            string CustomQuoteDelimiter = "";
            if (tokenType == TokenType.OpenCustomQuotedLiteral)
            {
                CustomQuoteDelimiter = match.Groups["CustomQuoteDelimiter"].Value;
            }
            yield return new Token(tokenType, index, match.Length, CustomQuoteDelimiter);
        }
    }

    private static IEnumerable<string> BreakIntoBatches(string sql)
    {
        using var tokens = Tokenize(sql).GetEnumerator();
        var cutIndex = 0;
        var blockDepth = 0;
        var inDeclareBlock = false;
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

        while(NextToken())
        {
            switch (token.Type)
            {
                case TokenType.DeclareBlockStart:
                    blockDepth++;
                    inDeclareBlock = true;
                    break;
                case TokenType.BlockStart:
                    // a declare block is eventually followed by a BEGIN
                    // so we need to check if we were preceded by a DECLARE
                    if (inDeclareBlock)
                    {
                        inDeclareBlock = false;
                    } else {
                        blockDepth++;
                    }
                    break;

                case TokenType.BlockEnd:
                    blockDepth--;
                    if (blockDepth == 0)
                    {
                        yield return sql[cutIndex..(token.Index + token.Length)];
                        cutIndex = token.Index + token.Length;
                    }
                    break;

                case TokenType.StringLiteral:
                    while(NextToken() && token.Type != TokenType.StringLiteral)
                    {

                    }
                    break;
                case TokenType.OpenCustomQuotedLiteral:
                    var closingDelimiter = GetClosingCustomQuoteDelimiter(token.CustomQuoteDelimiter);
                    while(NextToken()) {
                        // Custom Delimiters come just before the ' string
                        // literal so check for that.
                        if (token.Type == TokenType.StringLiteral &&
                            sql[..token.Index].EndsWith(closingDelimiter)
                        ) {
                            // end of string literal
                            break;
                        }
                    }
                    break;

                case TokenType.MultiLineCommentStart:
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

                case TokenType.SingleLineComment:
                    while (NextToken() && token.Type != TokenType.NewLine)
                    {
                    }
                    break;

                case TokenType.Semicolon:
                    // We want to include the semicolon in the batch 
                    if (blockDepth > 0)
                    {
                        break;
                    }

                    yield return sql[cutIndex..(token.Index + token.Length)];
                    cutIndex = token.Index + token.Length;
                    break;

                case TokenType.SQLPLUSEXECUTE:
                    yield return sql[cutIndex..token.Index];
                    cutIndex = token.Index + token.Length;
                    break;
            }
        }

        yield return sql[cutIndex..];
    }

    private static string GetClosingCustomQuoteDelimiter(string delimiter) => delimiter switch
    {
        "[" => "]",
        "{" => "}",
        "(" => ")",
        "<" => ">",
        _ => delimiter
    };
}
