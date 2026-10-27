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
        StoredProgramStart,
        StandaloneSemicolon,
        QuotedIdentifier,
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
    // Stored PL/SQL units include declarations before BEGIN and may contain nested routines.
    // Their script boundary is an explicit / or Roundhouse ; line, rather than an inner END.
    private const string TriviaPattern = @"(?:\s|--[^\r\n]*(?:\r?\n|$)|/\*[\s\S]*?\*/)+";
    private const string StoredProgramStartPattern =
        @"(?<StoredProgramStart>\bCREATE" + TriviaPattern +
        "(?:OR" + TriviaPattern + "REPLACE" + TriviaPattern + ")?" +
        "(?:(?:NON)?EDITIONABLE" + TriviaPattern + ")?" +
        @"(?:PACKAGE|PROCEDURE|FUNCTION|TRIGGER|TYPE)\b)";
    private const string StandaloneSemicolonPattern = @"(?<StandaloneSemicolon>^[ \t]*;[ \t]*(?=\r?$))";
    private const string QuotedIdentifierPattern = "(?<QuotedIdentifier>\")";
    private const string BlockStartPattern = "(?<BlockStart>\\bBEGIN\\b)";
    private const string DeclareBlockStartPattern = "(?<DeclareBlockStart>\\bDECLARE\\b)";

    // Named routine endings and spaced CASE expression endings do not necessarily close
    // the surrounding anonymous block. Stored programs use explicit script delimiters.
    private const string BlockEndPattern = @"(?<BlockEnd>\bEND;)";
    private const string SemicolonPattern = "(?<Semicolon>;)";
    private const string SqlPlusExecutePattern = "(?<SQLPLUSEXECUTE>^[ \\t]*/[ \\t]*(?=\\r?$))";
    private const string NewLinePattern = "(?<NewLine>\\r\\n|\\r|\\n)";

    [GeneratedRegex(
        OpenCustomQuotedLiteralPattern + "|" +
        StringLiteralPattern + "|" +
        MultiLineCommentStartPattern + "|" +
        MultiLineCommentEndPattern + "|" +
        SingleLineCommentPattern + "|" +
        StoredProgramStartPattern + "|" +
        StandaloneSemicolonPattern + "|" +
        QuotedIdentifierPattern + "|" +
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

    [GeneratedRegex(@"\A(?:\s|--[^\r\n]*(?:\r?\n|$)|/\*[\s\S]*?\*/)*\z")]
    private static partial Regex TriviaOnlyPattern();

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
        var inStoredProgram = false;
        var lastStoredTerminatorEnd = -1;
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
                case TokenType.StoredProgramStart:
                    inStoredProgram = true;
                    lastStoredTerminatorEnd = -1;
                    break;
                // Roundhouse's extra ; follows an actual terminator, not one inside a comment/literal.
                case TokenType.StandaloneSemicolon when inStoredProgram && lastStoredTerminatorEnd >= 0 &&
                                                          TriviaOnlyPattern().IsMatch(sql[lastStoredTerminatorEnd..token.Index]):
                    yield return sql[cutIndex..token.Index];
                    cutIndex = token.Index + token.Length;
                    inStoredProgram = false;
                    blockDepth = 0;
                    inDeclareBlock = false;
                    break;
                case TokenType.BlockEnd or TokenType.Semicolon or TokenType.StandaloneSemicolon when inStoredProgram:
                    lastStoredTerminatorEnd = token.Index + token.Length;
                    break;
                case TokenType.BlockStart or TokenType.DeclareBlockStart when inStoredProgram:
                    break;
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
                    if (blockDepth == 0)
                    {
                        // END can also close a SQL CASE expression. Keep END, but not its SQL terminator.
                        yield return sql[cutIndex..(token.Index + token.Length - 1)];
                        cutIndex = token.Index + token.Length;
                        break;
                    }

                    blockDepth--;
                    if (blockDepth == 0)
                    {
                        yield return sql[cutIndex..(token.Index + token.Length)];
                        cutIndex = token.Index + token.Length;
                    }
                    break;

                case TokenType.QuotedIdentifier:
                    while (NextToken() && token.Type != TokenType.QuotedIdentifier)
                    {
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

                case TokenType.StandaloneSemicolon:
                case TokenType.Semicolon:
                    // Semicolons belong to PL/SQL blocks, but only delimit ordinary SQL commands.
                    if (blockDepth > 0)
                    {
                        break;
                    }

                    yield return sql[cutIndex..token.Index];
                    cutIndex = token.Index + token.Length;
                    break;

                case TokenType.SQLPLUSEXECUTE:
                    yield return sql[cutIndex..token.Index];
                    cutIndex = token.Index + token.Length;
                    inStoredProgram = false;
                    blockDepth = 0;
                    inDeclareBlock = false;
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
