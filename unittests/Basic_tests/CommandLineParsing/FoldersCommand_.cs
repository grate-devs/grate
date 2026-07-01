using grate.Commands;
using grate.Configuration;
using grate.Migration;

namespace Basic_tests.CommandLineParsing;

// ReSharper disable once InconsistentNaming

public class FoldersCommand_
{
    [Theory]
    [MemberData(nameof(FoldersCommandLines))]
    [MemberData(nameof(FileFoldersCommandLines))]
    public void Can_Parse(string argument, IFoldersConfiguration expected)
    {
        var actual = FoldersCommand.Parse(argument);

        Assert.NotNull(actual);

        var expectedArr = expected.ToArray();
        var actualArr = actual.ToArray();

        Assert.Equal(expectedArr.Length, actualArr.Length);

        Assert.Multiple(() =>
        {
            for (int i = 0; i < expected.Count; i++)
            {
                var act = actualArr?[i];
                var exp = expectedArr[i];

                Assert.Equal(exp.Key, act?.Key);
                AssertEquivalent(exp.Value, act?.Value);
            }
        });
    }

    private static void AssertEquivalent(MigrationsFolder? expected, MigrationsFolder? actual)
    {
        Assert.Multiple(() =>
        {
            Assert.Equal(expected?.Name, actual?.Name);
            Assert.Equal(expected?.Path, actual?.Path);
            Assert.Equal(expected?.Type, actual?.Type);
            Assert.Equal(expected?.ConnectionType, actual?.ConnectionType);
            Assert.Equal(expected?.TransactionHandling, actual?.TransactionHandling);
        });
    }

    private static readonly List<(string name, string config, IFoldersConfiguration expected)> TestCases =
        new()
        {
            ("createDatabase override",
                "createDatabase=createDb;sprocs=sp",
                FoldersConfiguration.Default(
                    KnownFolderNames.Default with{ CreateDatabase = "createDb", Sprocs = "sp"})
                ),

            ("Default, with overrides",
                "up=blup;afterMigration=æfter",
                FoldersConfiguration.Default(
                    KnownFolderNames.Default with{ Up = "blup", AfterMigration = "æfter"})
                ),

            ("Fully customised",
             "folder1=type:Once;folder2=type:EveryTime;folder3=type:AnyTime",
             new FoldersConfiguration(
                new MigrationsFolder("folder1", MigrationType.Once),
                new MigrationsFolder("folder2", MigrationType.EveryTime),
                new MigrationsFolder("folder3", MigrationType.AnyTime)
             )),

            ("Fully customised, only one folder",
                "folder1=type:Once",
                new FoldersConfiguration(
                    new MigrationsFolder("folder1", MigrationType.Once)
                )),

            ("Fully customised, one folder with standard name",
                "folder1=type:Once;up=tables",
                new FoldersConfiguration(
                    new MigrationsFolder("folder1", MigrationType.Once),
                    new MigrationsFolder("up", "tables", MigrationType.Once)
                )),

            ("Fully customised, only folder names, should have defaults",
                "folder1;up",
                new FoldersConfiguration(
                    new MigrationsFolder("folder1"),
                    new MigrationsFolder("up")
                )),

            ("Fully customised, more properties",
                "folder1=path:a/sub/folder/here,type:Once,connectionType:Admin;folder2=type:EveryTime;folder3=type:AnyTime",
                new FoldersConfiguration(
                    new MigrationsFolder("folder1", "a/sub/folder/here", MigrationType.Once, ConnectionType.Admin),
                    new MigrationsFolder("folder2", MigrationType.EveryTime),
                    new MigrationsFolder("folder3", MigrationType.AnyTime)
                )),

            ("Fully customised, with newline separators",
@"folder1=type:Once
folder2=type:EveryTime
folder3=type:AnyTime",
                new FoldersConfiguration(
                    new MigrationsFolder("folder1", MigrationType.Once),
                    new MigrationsFolder("folder2", MigrationType.EveryTime),
                    new MigrationsFolder("folder3", MigrationType.AnyTime)
                )),

            ("Fully customised - With only migration type",
                "folderA=Everytime;folderB=Once;folderC=AnyTime",
                new FoldersConfiguration(
                    new MigrationsFolder("folderA", MigrationType.EveryTime),
                    new MigrationsFolder("folderB", MigrationType.Once),
                    new MigrationsFolder("folderC", MigrationType.AnyTime)
                )),

            ("Fully customised - With only folder name",
                "folderA=hello;folderB=you;folderC=fool",
                new FoldersConfiguration(
                    new MigrationsFolder("folderA", "hello", MigrationType.Once),
                    new MigrationsFolder("folderB", "you", MigrationType.Once),
                    new MigrationsFolder("folderC", "fool", MigrationType.Once)
                )),
        };

    public static IEnumerable<object?[]> FoldersCommandLines()
    {
        return TestCases.Select(c =>
        new object?[] { c.config, c.expected }).ToArray();
    }
    public static IEnumerable<object?[]> FileFoldersCommandLines()
    {
        yield return new object?[] { "/tmp/this/does/not/exist", FoldersConfiguration.Empty };
        yield return new object?[] { CreateFile(""), FoldersConfiguration.Empty };
        foreach (var c in TestCases)
        {
            yield return new object[] { CreateFile(c.config), c.expected };
        }
    }
    private static string CreateFile(string content)
    {
        var tmpFile = Path.GetTempFileName();
        File.WriteAllText(tmpFile, content);
        return tmpFile;
    }

}
