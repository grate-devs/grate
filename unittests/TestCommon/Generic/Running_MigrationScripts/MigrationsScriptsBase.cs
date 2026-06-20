using System.Text;
using grate.Configuration;
using TestCommon.TestInfrastructure;

namespace TestCommon.Generic.Running_MigrationScripts;

public abstract class MigrationsScriptsBase(IGrateTestContext context, ITestOutputHelper testOutput)
{
    public static DirectoryInfo CreateRandomTempDirectory() => TestConfig.CreateRandomTempDirectory();

    protected void CreateDummySql(DirectoryInfo root, MigrationsFolder? folder, string filename = "1_jalla.sql")
        => CreateDummySql(Wrap(root, folder?.Path), filename);

    protected void WriteSomeOtherSql(DirectoryInfo root, MigrationsFolder? folder, string filename = "1_jalla.sql")
        => WriteSomeOtherSql(Wrap(root, folder?.Path), filename);

    protected void CreateDummySql(DirectoryInfo? path, string filename = "1_jalla.sql")
    {
        var dummySql = Context.Sql.SelectVersion;
        WriteSql(path, filename, dummySql);
    }

    protected void CreateLargeDummySql(DirectoryInfo? path, int size = 8192, string filename = "1_very_large_file.sql")
    {
        var longComment = CreateLongComment(size);

        var dummySql = longComment + Environment.NewLine + Context.Sql.SelectVersion;
        WriteSql(path, filename, dummySql);
    }

    protected string CreateLongComment(int size)
    {
        // Line comment plus blank, plus new line, plus text should be 80 together.
        int lineLen = 80 - Context.Sql.LineComment.Length - 1 - Environment.NewLine.Length;
        var numLines = size / lineLen;
        var rest = size - (lineLen * numLines);

        var filler = new string('Æ', Math.Min(lineLen, size));

        var builder = new StringBuilder(lineLen * numLines + rest);
        for (var i = 0; i < numLines; i++)
        {
            builder.Append(Context.Sql.LineComment);
            builder.Append(' ');
            builder.AppendLine(filler);
        }
        if (rest > 0)
        {
            builder.Append(Context.Sql.LineComment);
            builder.Append(' ');
            builder.AppendLine(new string('Ø', rest));
        }

        return builder.ToString();
    }

    protected void WriteSomeOtherSql(DirectoryInfo? path, string filename = "1_jalla.sql")
    {
        var dummySql = Context.Syntax.CurrentDatabase;
        WriteSql(path, filename, dummySql);
    }

    public static void WriteSql(DirectoryInfo root, string path, string filename, string? sql) =>
        TestConfig.WriteContent(Wrap(root, path), filename, sql);

    public static void WriteSql(DirectoryInfo? path, string filename, string? sql) =>
        TestConfig.WriteContent(path, filename, sql);

    protected static DirectoryInfo MakeSurePathExists(DirectoryInfo root, MigrationsFolder? folder)
        => TestConfig.MakeSurePathExists(Wrap(root, folder?.Path));

    protected IGrateTestContext Context { get; set; } = context;
    protected ITestOutputHelper TestOutput { get; set; } = testOutput;

    public static DirectoryInfo Wrap(DirectoryInfo root, string? subFolder) => TestConfig.Wrap(root, subFolder);

}
