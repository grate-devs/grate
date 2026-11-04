using System.Text.RegularExpressions;
using grate.Infrastructure;

namespace grate.SqlServer.Infrastructure;

/// <summary>
/// Splits SQL Server batches on GO separator lines, respecting quoted identifiers,
/// string literals and nested comments.
/// </summary>
public partial class SqlServerStatementSplitter : IStatementSplitter
{
    [GeneratedRegex(@"\S")]
    private static partial Regex SignificantTextPattern();

    public IEnumerable<string> Split(string statement) =>
        BreakIntoBatches(statement).Where(batch => SignificantTextPattern().IsMatch(batch));

    private static IEnumerable<string> BreakIntoBatches(string sql)
    {
        var cutIndex = 0;
        var commentDepth = 0;
        var inLineComment = false;
        var closingDelimiter = '\0';
        var lineHasSql = false;

        for (var index = 0; index < sql.Length; index++)
        {
            var current = sql[index];
            var next = index + 1 < sql.Length ? sql[index + 1] : '\0';

            if (current is '\r' or '\n')
            {
                inLineComment = false;
                // A multiline quoted value still occupies the new line, even if it
                // closes before a GO token on that line.
                lineHasSql = closingDelimiter != '\0';
                continue;
            }

            if (inLineComment)
            {
                continue;
            }

            if (commentDepth > 0)
            {
                if (current == '/' && next == '*')
                {
                    commentDepth++;
                    index++;
                }
                else if (current == '*' && next == '/')
                {
                    commentDepth--;
                    index++;
                }
                continue;
            }

            if (closingDelimiter != '\0')
            {
                if (current == closingDelimiter)
                {
                    if (next == closingDelimiter)
                    {
                        index++;
                    }
                    else
                    {
                        closingDelimiter = '\0';
                    }
                }
                continue;
            }

            if (current == '/' && next == '*')
            {
                commentDepth = 1;
                index++;
                continue;
            }

            if (current == '-' && next == '-')
            {
                inLineComment = true;
                index++;
                continue;
            }

            if (!lineHasSql && current is 'g' or 'G' && next is 'o' or 'O' &&
                HasOnlyCommentsAndWhitespaceOnLine(sql, index + 2))
            {
                yield return sql[cutIndex..index];
                cutIndex = index + 2;
                index++;
                continue;
            }

            if (!char.IsWhiteSpace(current))
            {
                lineHasSql = true;
                closingDelimiter = current switch
                {
                    '[' => ']',
                    '\'' => '\'',
                    '"' => '"',
                    _ => '\0'
                };
            }
        }

        yield return sql[cutIndex..];
    }

    private static bool HasOnlyCommentsAndWhitespaceOnLine(string sql, int index)
    {
        var commentDepth = 0;
        for (; index < sql.Length; index++)
        {
            var current = sql[index];
            var next = index + 1 < sql.Length ? sql[index + 1] : '\0';
            if (current is '\r' or '\n')
            {
                return true;
            }

            if (current == '/' && next == '*')
            {
                commentDepth++;
                index++;
            }
            else if (commentDepth > 0)
            {
                if (current == '*' && next == '/')
                {
                    commentDepth--;
                    index++;
                }
            }
            else if (current == '-' && next == '-')
            {
                return true;
            }
            else if (!char.IsWhiteSpace(current))
            {
                return false;
            }
        }

        return true;
    }
}
