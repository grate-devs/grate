using System.Text;
using Microsoft.SqlServer.TransactSql.ScriptDom;

sealed record SqlName(string Schema, string Name)
{
    public override string ToString() => $"[{Schema.Replace("]", "]]")}].[{Name.Replace("]", "]]")}]";

    public static SqlName Read(IList<Identifier> parts, string path, string context)
    {
        if (parts.Count != 2 || parts.Any(part => string.IsNullOrEmpty(part.Value)))
            throw new InvalidDataException($"{path}: {context} requires a two-part schema-qualified name.");
        return new(parts[0].Value, parts[1].Value);
    }
}

sealed record SqlScript(string Path, SqlName Defines, List<SqlName> References, string[]? Declarations)
{
    public static SqlScript Read(string file, string path, bool expectView)
    {
        var fileName = System.IO.Path.GetFileName(file);
        if (fileName.Contains(".env.", StringComparison.InvariantCultureIgnoreCase)
            || fileName.StartsWith("everytime.", StringComparison.InvariantCultureIgnoreCase)
            || fileName.Contains(".everytime.", StringComparison.InvariantCultureIgnoreCase))
            throw new InvalidDataException($"{path}: environment and EveryTime scripts are outside the prototype scope.");

        string sql;
        try
        {
            sql = new UTF8Encoding(false, true).GetString(File.ReadAllBytes(file)).TrimStart('\uFEFF');
        }
        catch (DecoderFallbackException error)
        {
            throw new InvalidDataException($"{path}: expected UTF-8 SQL.", error);
        }
        if (sql.Contains("{{", StringComparison.Ordinal))
            throw new InvalidDataException($"{path}: token placeholders are outside the prototype scope.");

        using var reader = new StringReader(sql);
        var fragment = (TSqlScript)new TSql160Parser(initialQuotedIdentifiers: true).Parse(reader, out var errors);
        if (errors.Count > 0)
            throw new InvalidDataException($"{path}:{errors[0].Line}:{errors[0].Column}: {errors[0].Message}");

        var statements = fragment.Batches.SelectMany(batch => batch.Statements).ToArray();
        if (statements.Length != 1)
            throw new InvalidDataException($"{path}: expected one CREATE OR ALTER definition.");

        var definition = statements[0] switch
        {
            CreateOrAlterViewStatement view when expectView => view.SchemaObjectName,
            CreateOrAlterFunctionStatement { ReturnType: SelectFunctionReturnType } function when !expectView => function.Name,
            _ => throw new InvalidDataException(
                $"{path}: expected CREATE OR ALTER {(expectView ? "VIEW" : "FUNCTION (inline table-valued)")}."),
        };

        var references = new References(path);
        statements[0].Accept(references);
        return new(path, SqlName.Read(definition.Identifiers, path, "definition"),
            references.Names.Distinct().ToList(), ReadDeclarations(fragment, path));
    }

    private static string[]? ReadDeclarations(TSqlScript script, string path)
    {
        const string prefix = "Dependencies:";
        string[]? declarations = null;
        foreach (var token in script.ScriptTokenStream.TakeWhile(token => token.TokenType is
                     TSqlTokenType.WhiteSpace or TSqlTokenType.SingleLineComment or TSqlTokenType.MultilineComment))
        {
            if (token.TokenType != TSqlTokenType.SingleLineComment)
                continue;
            var comment = token.Text[2..].Trim();
            if (!comment.StartsWith(prefix, StringComparison.Ordinal))
                continue;
            if (declarations is not null)
                throw new InvalidDataException($"{path}: expected at most one leading Dependencies declaration.");

            var value = comment[prefix.Length..].Trim();
            declarations = value.Length == 0 ? [] : value.Split(',', StringSplitOptions.TrimEntries);
            if (declarations.Contains(string.Empty))
                throw new InvalidDataException($"{path}: empty path in Dependencies declaration.");
        }
        return declarations?.Distinct(StringComparer.Ordinal).ToArray();
    }
}

sealed class References(string path) : TSqlFragmentVisitor
{
    public List<SqlName> Names { get; } = [];

    public override void ExplicitVisit(FromClause node)
    {
        foreach (var table in node.TableReferences)
        {
            if (table is not (NamedTableReference or SchemaObjectFunctionTableReference))
                throw new InvalidDataException($"{path}:{table.StartLine}: unsupported FROM source ({table.GetType().Name}).");
        }
        base.ExplicitVisit(node);
    }

    public override void ExplicitVisit(NamedTableReference node)
    {
        Names.Add(SqlName.Read(node.SchemaObject.Identifiers, path, $"line {node.StartLine} relation"));
        base.ExplicitVisit(node);
    }

    public override void ExplicitVisit(SchemaObjectFunctionTableReference node)
    {
        Names.Add(SqlName.Read(node.SchemaObject.Identifiers, path, $"line {node.StartLine} table function"));
        base.ExplicitVisit(node);
    }

    public override void ExplicitVisit(FunctionCall node)
    {
        if (node.CallTarget is MultiPartIdentifierCallTarget target)
            Names.Add(SqlName.Read([.. target.MultiPartIdentifier.Identifiers, node.FunctionName],
                path, $"line {node.StartLine} scalar function"));
        else if (node.CallTarget is not null)
            throw new InvalidDataException($"{path}:{node.StartLine}: unsupported scalar function target.");

        base.ExplicitVisit(node);
    }
}
