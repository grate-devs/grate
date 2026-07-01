using System.Collections.Immutable;
using grate.Configuration;
using grate.Migration;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;
using static grate.Configuration.MigrationType;
using static grate.Migration.ConnectionType;

namespace Basic_tests.Infrastructure.FolderConfiguration;


// ReSharper disable once InconsistentNaming
public class KnownFolders_Default
{
    [Fact]
    public void Returns_folders_in_current_order()
    {
        var items = Folders.Values.ToImmutableArray();

        Assert.Multiple(() =>
        {
            Assert.Equal(Folders[BeforeMigration], items[0]);
            Assert.Equal(Folders[AlterDatabase], items[1]);
            Assert.Equal(Folders[RunAfterCreateDatabase], items[2]);
            Assert.Equal(Folders[RunBeforeUp], items[3]);
            Assert.Equal(Folders[Up], items[4]);
            Assert.Equal(Folders[RunFirstAfterUp], items[5]);
            Assert.Equal(Folders[Functions], items[6]);
            Assert.Equal(Folders[Views], items[7]);
            Assert.Equal(Folders[Sprocs], items[8]);
            Assert.Equal(Folders[Triggers], items[9]);
            Assert.Equal(Folders[Indexes], items[10]);
            Assert.Equal(Folders[RunAfterOtherAnyTimeScripts], items[11]);
            Assert.Equal(Folders[Permissions], items[12]);
            Assert.Equal(Folders[AfterMigration], items[13]);
        });
    }

    [Theory]
    [MemberData(nameof(ExpectedKnownFolderNames))]
    public void Has_expected_folder_configuration(
        MigrationsFolder folder,
        string expectedName,
        MigrationType expectedType,
        ConnectionType expectedConnectionType,
        TransactionHandling transactionHandling
    )
    {
        var root = Root.ToString();

        Assert.Multiple(() =>
        {
            Assert.Equal(expectedName, folder.Path);
            Assert.Equal(expectedType, folder.Type);
            Assert.Equal(expectedConnectionType, folder.ConnectionType);
            Assert.Equal(transactionHandling, folder.TransactionHandling);
        });
    }

    private static readonly DirectoryInfo Root = TestConfig.CreateRandomTempDirectory();
    private static readonly IFoldersConfiguration Folders = global::grate.Configuration.Folders.Default;

    public static IEnumerable<object?[]> ExpectedKnownFolderNames()
    {
        yield return new object?[] { Folders[BeforeMigration], "beforeMigration", EveryTime, Default, TransactionHandling.Autonomous };
        yield return new object?[] { Folders[AlterDatabase], "alterDatabase", AnyTime, Admin, TransactionHandling.Autonomous };
        yield return new object?[] { Folders[RunAfterCreateDatabase], "runAfterCreateDatabase", AnyTime, Default, TransactionHandling.Default };
        yield return new object?[] { Folders[RunBeforeUp], "runBeforeUp", AnyTime, Default, TransactionHandling.Default };
        yield return new object?[] { Folders[Up], "up", Once, Default, TransactionHandling.Default };
        yield return new object?[] { Folders[RunFirstAfterUp], "runFirstAfterUp", AnyTime, Default, TransactionHandling.Default };
        yield return new object?[] { Folders[Functions], "functions", AnyTime, Default, TransactionHandling.Default };
        yield return new object?[] { Folders[Views], "views", AnyTime, Default, TransactionHandling.Default };
        yield return new object?[] { Folders[Sprocs], "sprocs", AnyTime, Default, TransactionHandling.Default };
        yield return new object?[] { Folders[Triggers], "triggers", AnyTime, Default, TransactionHandling.Default };
        yield return new object?[] { Folders[Indexes], "indexes", AnyTime, Default, TransactionHandling.Default };
        yield return new object?[] { Folders[RunAfterOtherAnyTimeScripts], "runAfterOtherAnyTimeScripts", AnyTime, Default, TransactionHandling.Default };
        yield return new object?[] { Folders[Permissions], "permissions", EveryTime, Default, TransactionHandling.Autonomous };
        yield return new object?[] { Folders[AfterMigration], "afterMigration", EveryTime, Default, TransactionHandling.Autonomous };
    }
}
