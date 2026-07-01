using System.Collections.Immutable;
using grate.Configuration;
using grate.Migration;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;
using static grate.Configuration.MigrationType;
using static grate.Migration.ConnectionType;
using static TestCommon.TestInfrastructure.DescriptiveTestObjects;

namespace Basic_tests.Infrastructure.FolderConfiguration;

// ReSharper disable once InconsistentNaming
public class KnownFolders_CustomNames
{
    private static readonly Random Random = Random.Shared;

    [Fact]
    public void Returns_folders_in_same_order_as_default()
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
        string name,
        MigrationType type,
        ConnectionType conn,
        TransactionHandling tran
    )
    {
        var root = Root.ToString();

        Assert.Multiple(() =>
        {
            Assert.Equal(name, folder.Path);
            Assert.Equal(type, folder.Type);
            Assert.Equal(conn, folder.ConnectionType);
            Assert.Equal(tran, folder.TransactionHandling);
        });
    }

    private static readonly IKnownFolderNames OverriddenFolderNames = new KnownFolderNames()
    {
        BeforeMigration = "beforeMigration" + Random.GetString(8),
        CreateDatabase = "createDatabase" + Random.GetString(8),
        AlterDatabase = "alterDatabase" + Random.GetString(8),
        RunAfterCreateDatabase = "runAfterCreateDatabase" + Random.GetString(8),
        RunBeforeUp = "runBeforeUp" + Random.GetString(8),
        Up = "up" + Random.GetString(8),
        RunFirstAfterUp = "runFirstAfterUp" + Random.GetString(8),
        Functions = "functions" + Random.GetString(8),
        Views = "views" + Random.GetString(8),
        Sprocs = "sprocs" + Random.GetString(8),
        Triggers = "triggers" + Random.GetString(8),
        Indexes = "indexes" + Random.GetString(8),
        RunAfterOtherAnyTimeScripts = "runAfterOtherAnyTimeScripts" + Random.GetString(8),
        Permissions = "permissions" + Random.GetString(8),
        AfterMigration = "afterMigration" + Random.GetString(8),
    };

    private static readonly DirectoryInfo Root = TestConfig.CreateRandomTempDirectory();
    private static readonly IFoldersConfiguration Folders = FoldersConfiguration.Default(OverriddenFolderNames);

    public static TheoryData<MigrationsFolderWithDescription, string, MigrationType, ConnectionType, TransactionHandling> ExpectedKnownFolderNames()
    {
        var data = new TheoryData<MigrationsFolderWithDescription, string, MigrationType, ConnectionType, TransactionHandling>
        {
            { Describe(Folders[BeforeMigration])!, OverriddenFolderNames.BeforeMigration, EveryTime, Default, TransactionHandling.Autonomous },
            { Describe(Folders[AlterDatabase])!, OverriddenFolderNames.AlterDatabase, AnyTime, Admin, TransactionHandling.Autonomous },
            { Describe(Folders[RunAfterCreateDatabase])!, OverriddenFolderNames.RunAfterCreateDatabase, AnyTime, Default, TransactionHandling.Default },
            { Describe(Folders[RunBeforeUp])!, OverriddenFolderNames.RunBeforeUp, AnyTime, Default, TransactionHandling.Default },
            { Describe(Folders[Up])!, OverriddenFolderNames.Up, Once, Default, TransactionHandling.Default },
            { Describe(Folders[RunFirstAfterUp])!, OverriddenFolderNames.RunFirstAfterUp, AnyTime, Default, TransactionHandling.Default },
            { Describe(Folders[Functions])!, OverriddenFolderNames.Functions, AnyTime, Default, TransactionHandling.Default },
            { Describe(Folders[Views])!, OverriddenFolderNames.Views, AnyTime, Default, TransactionHandling.Default },
            { Describe(Folders[Sprocs])!, OverriddenFolderNames.Sprocs, AnyTime, Default, TransactionHandling.Default },
            { Describe(Folders[Triggers])!, OverriddenFolderNames.Triggers, AnyTime, Default, TransactionHandling.Default },
            { Describe(Folders[Indexes])!, OverriddenFolderNames.Indexes, AnyTime, Default, TransactionHandling.Default },
            { Describe(Folders[RunAfterOtherAnyTimeScripts])!, OverriddenFolderNames.RunAfterOtherAnyTimeScripts, AnyTime, Default, TransactionHandling.Default },
            { Describe(Folders[Permissions])!, OverriddenFolderNames.Permissions, EveryTime, Default, TransactionHandling.Autonomous },
            { Describe(Folders[AfterMigration])!, OverriddenFolderNames.AfterMigration, EveryTime, Default, TransactionHandling.Autonomous }
       };
        return data;
    }
}
