using System.Text;
using System.Text.Json;
using SqlParser;
using SqlParser.Ast;
using SqlParser.Dialects;

if (args.Length != 1)
{
    Console.Error.WriteLine("Usage: PostgreSqlManaged <sql-file>");
    return 2;
}

try
{
    var sql = new UTF8Encoding(false, true).GetString(File.ReadAllBytes(args[0])).TrimStart('\uFEFF');
    var statements = Parse(sql);
    if (statements.Count != 1)
        throw new InvalidDataException("Expected one CREATE OR REPLACE definition.");

    var visitor = new References();
    SqlName definition;
    switch (statements[0])
    {
        case Statement.CreateView { OrReplace: true, Materialized: false, Temporary: false } view:
            definition = SqlName.Read(view.Name, "view");
            visitor.ReadQuery(view.Query.Query);
            break;
        case Statement.CreateFunction { OrReplace: true } function:
            definition = SqlName.Read(function.Name, "function");
            if (function.Args?.Count > 0)
                throw new InvalidDataException("Function input parameters and overload resolution are outside this prototype.");
            if (function.ReturnType is DataType.Custom { Name.Values.Count: 1 } tableReturn
                && SqlName.Normalize(tableReturn.Name.Values[0]) == "table")
                throw new InvalidDataException(
                    "RETURNS TABLE parses into opaque type modifiers; output-column validation is an adapter gap.");
            SqlName.ValidateType(function.ReturnType);
            if (function.Language is null || SqlName.Normalize(function.Language) != "sql")
                throw new InvalidDataException("Only LANGUAGE SQL function bodies are supported.");
            ReadBody(function.FunctionBody, visitor);
            break;
        default:
            throw new InvalidDataException("Expected CREATE OR REPLACE VIEW or FUNCTION.");
    }

    var output = new { Defines = definition, References = visitor.Names.Distinct().ToArray() };
    Console.WriteLine(JsonSerializer.Serialize(output, new JsonSerializerOptions(JsonSerializerDefaults.Web)));
    return 0;
}
catch (Exception error) when (error is ParserException or TokenizeException or InvalidDataException
                             or IOException or UnauthorizedAccessException or DecoderFallbackException)
{
    Console.Error.WriteLine($"{args[0]}: {error.Message}");
    return 1;
}

static Sequence<Statement> Parse(string sql) => new SqlQueryParser().Parse(sql, new PostgreSqlDialect());

static void ReadBody(CreateFunctionBody? body, References visitor)
{
    if (body is CreateFunctionBody.Return returned)
    {
        ((IElement)returned.Expression).Visit(visitor);
        return;
    }

    var text = body?.Expression switch
    {
        Expression.LiteralValue { Value: Value.DollarQuotedString dollar } => dollar.Value.Value,
        Expression.LiteralValue { Value: Value.SingleQuotedString single } => single.Value,
        _ => throw new InvalidDataException("Unsupported SQL function body representation."),
    };
    var statements = Parse(text);
    if (statements.Count != 1 || statements[0] is not Statement.Select query)
        throw new InvalidDataException("String SQL function bodies must contain one SELECT statement.");
    visitor.ReadQuery(query.Query);
}

sealed record SqlName(string Schema, string Name, string Kind)
{
    public static SqlName Read(ObjectName name, string kind)
    {
        if (name.Values.Count != 2)
            throw new InvalidDataException("Object names must be two-part schema-qualified names.");
        return new(Normalize(name.Values[0]), Normalize(name.Values[1]), kind);
    }

    public static void ValidateType(DataType? type)
    {
        if (type is DataType.Custom or DataType.Array)
            throw new InvalidDataException("Custom and array types are outside this prototype.");
    }

    public static string Normalize(Ident name)
    {
        if (name.QuoteStyle == '"')
            return name.Value;
        if (name.QuoteStyle is not null || name.Value.Any(character => character > 127))
            throw new InvalidDataException("Expected ASCII unquoted or double-quoted PostgreSQL identifiers.");
        return name.Value.ToLowerInvariant();
    }
}

sealed class References : Visitor
{
    private readonly Stack<HashSet<string>> _cteScopes = new();
    public List<SqlName> Names { get; } = [];

    public void ReadQuery(Query query)
    {
        if (query.With?.Recursive == true)
            throw new InvalidDataException("Recursive CTEs are outside this prototype.");
        var localNames = new HashSet<string>(StringComparer.Ordinal);
        _cteScopes.Push(localNames);
        foreach (var cte in query.With?.CteTables ?? [])
        {
            // Nonrecursive CTEs see earlier siblings and outer scopes, then expose their own alias.
            ReadQuery(cte.Query);
            localNames.Add(SqlName.Normalize(cte.Alias.Name));
        }
        ReadSetExpression(query.Body);
        foreach (var modifier in new IElement?[] { query.OrderBy, query.Limit, query.Offset, query.Fetch })
            modifier?.Visit(this);
        _cteScopes.Pop();
    }

    private void ReadSetExpression(SetExpression body)
    {
        switch (body)
        {
            case SetExpression.SelectExpression select:
                // DISTINCT is omitted from Select's decorated properties in package 0.6.5.
                ((IElement?)select.Select.Distinct)?.Visit(this);
                ((IElement)select.Select).Visit(this);
                break;
            case SetExpression.QueryExpression nested:
                ReadQuery(nested.Query);
                break;
            case SetExpression.SetOperation operation:
                ReadSetExpression(operation.Left);
                ReadSetExpression(operation.Right);
                break;
            default:
                throw new InvalidDataException("Only SELECT query bodies are supported.");
        }
    }

    public override ControlFlow PreVisitTableFactor(TableFactor tableFactor)
    {
        // SqlParserCS 0.6.5's default visitor traverses Table children only.
        // Visit the other supported FROM forms explicitly to retain nested dependencies.
        switch (tableFactor)
        {
            case TableFactor.Table table:
                if (table.Args?.Arguments.Count > 0)
                    throw new InvalidDataException("Function call arguments are outside this prototype.");
                if (table.Args is null && table.Name.Values.Count == 1
                    && _cteScopes.Any(scope => scope.Contains(SqlName.Normalize(table.Name.Values[0]))))
                    break;
                Names.Add(SqlName.Read(table.Name, table.Args is null ? "relation" : "function"));
                break;
            case TableFactor.Function function:
                if (function.Args.Count > 0)
                    throw new InvalidDataException("Function call arguments are outside this prototype.");
                Names.Add(SqlName.Read(function.Name, "function"));
                break;
            case TableFactor.Derived derived:
                ReadQuery(derived.SubQuery);
                break;
            case TableFactor.NestedJoin nested:
                if (nested.TableWithJoins is not null)
                    ((IElement)nested.TableWithJoins).Visit(this);
                break;
            default:
                throw new InvalidDataException($"Unsupported FROM source {tableFactor.GetType().Name}.");
        }
        return ControlFlow.Continue;
    }

    public override ControlFlow PreVisitExpression(Expression expression)
    {
        switch (expression)
        {
            case Expression.Cast cast:
                SqlName.ValidateType(cast.DataType);
                break;
            case Expression.TypedString typed:
                SqlName.ValidateType(typed.DataType);
                break;
            case Expression.Convert converted:
                SqlName.ValidateType(converted.DataType);
                break;
            case Expression.Function function:
                if (function.Args is not FunctionArguments.List { ArgumentList.Args: null or { Count: 0 } })
                    throw new InvalidDataException("Function call arguments are outside this prototype.");
                Names.Add(SqlName.Read(function.Name, "function"));
                break;
            case Expression.Subquery subquery:
                ReadQuery(subquery.Query);
                return ControlFlow.Break;
            case Expression.Exists exists:
                ReadQuery(exists.SubQuery);
                return ControlFlow.Break;
            case Expression.InSubquery subquery:
                ReadQuery(subquery.SubQuery);
                if (subquery.Expression is not null)
                    ((IElement)subquery.Expression).Visit(this);
                return ControlFlow.Break;
        }
        return ControlFlow.Continue;
    }
}
