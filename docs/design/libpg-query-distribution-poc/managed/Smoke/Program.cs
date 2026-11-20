using System.Runtime.InteropServices;
using System.Text.Json;
using Grate.Poc.LibPgQuery;

try
{
    for (var iteration = 0; iteration < 64; iteration++)
    {
        using var parsed = PgQuery.Parse(
            "CREATE OR REPLACE VIEW public.v_orders AS SELECT public.fn_order_totals() AS total;");
        var root = parsed.RootElement;
        Require(root.GetProperty("version").GetInt32() == 180006, "Unexpected PostgreSQL parser version.");
        var statements = root.GetProperty("stmts");
        Require(statements.GetArrayLength() == 1, "Expected one parsed statement.");
        var definition = statements[0].GetProperty("stmt").GetProperty("ViewStmt");
        var view = definition.GetProperty("view");
        Require(view.GetProperty("schemaname").GetString() == "public", "View schema was lost.");
        Require(view.GetProperty("relname").GetString() == "v_orders", "View name was lost.");
        var function = definition.GetProperty("query").GetProperty("SelectStmt")
            .GetProperty("targetList")[0].GetProperty("ResTarget").GetProperty("val")
            .GetProperty("FuncCall").GetProperty("funcname");
        Require(function.GetArrayLength() == 2
                && function[0].GetProperty("String").GetProperty("sval").GetString() == "public"
                && function[1].GetProperty("String").GetProperty("sval").GetString() == "fn_order_totals",
            "Function reference was lost.");

        using var unicode = PgQuery.Parse("SELECT 'Æøå東京' AS \"verdi_ø\";");
        var target = unicode.RootElement.GetProperty("stmts")[0].GetProperty("stmt")
            .GetProperty("SelectStmt").GetProperty("targetList")[0].GetProperty("ResTarget");
        Require(target.GetProperty("name").GetString() == "verdi_ø", "UTF-8 identifier changed.");
        var literal = target.GetProperty("val").GetProperty("A_Const").GetProperty("sval")
            .GetProperty("sval").GetString();
        Require(literal == "Æøå東京", "UTF-8 literal changed.");

        try
        {
            using var invalid = PgQuery.Parse("SELECT FROM;");
            throw new InvalidOperationException("Malformed SQL unexpectedly parsed.");
        }
        catch (PgQueryParseException error)
        {
            Require(error.Message.Contains("syntax error", StringComparison.Ordinal), "Native error message changed.");
            Require(error.CursorPosition == 12, "Native SQL error cursor changed.");
            Require(error.NativeSourceLine > 0, "Native source line was lost.");
        }
    }

    try
    {
        using var nul = PgQuery.Parse("SELECT 1;\0SELECT 2;");
        throw new InvalidOperationException("NUL-truncated input was accepted.");
    }
    catch (ArgumentException)
    {
        // A managed guard prevents native C-string truncation.
    }

    Console.WriteLine($"PASS {RuntimeInformation.RuntimeIdentifier} {RuntimeInformation.ProcessArchitecture}: "
                      + "64 definition/reference, UTF-8 and native-error round trips; NUL guard.");
    return 0;
}
catch (Exception error)
{
    Console.Error.WriteLine(error);
    return 1;
}

static void Require(bool condition, string message)
{
    if (!condition)
        throw new InvalidOperationException(message);
}
