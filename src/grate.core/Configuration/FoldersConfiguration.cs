using grate.Migration;
using static grate.Configuration.KnownFolderKeys;
using static grate.Configuration.MigrationType;

namespace grate.Configuration;

internal class FoldersConfiguration : Dictionary<string, MigrationsFolder?>, IFoldersConfiguration
{
    public FoldersConfiguration(IEnumerable<MigrationsFolder> folders) :
        base(folders.ToDictionary(folder => folder.Name, folder => (MigrationsFolder?)folder))
    {
    }

    public FoldersConfiguration(params MigrationsFolder[] folders) :
        this(folders.AsEnumerable())
    { }

    public FoldersConfiguration(IDictionary<string, MigrationsFolder> source)
        : base(source.ToDictionary(item => item.Key, item => (MigrationsFolder?)item.Value))
    { }


    public FoldersConfiguration()
    { }

    public MigrationsFolder? CreateDatabase { get; set; }
    public MigrationsFolder? DropDatabase { get; set; }

    public static FoldersConfiguration Empty => new();
    
    public override string ToString() => string.Join(";", Values);

    public static IFoldersConfiguration Default(IKnownFolderNames? folderNames = null)
    {
        folderNames ??= KnownFolderNames.Default;

        var foldersConfiguration = new FoldersConfiguration()
        {
            { BeforeMigration, new MigrationsFolder(BeforeMigration, "BeforeMigration", folderNames.BeforeMigration, EveryTime, TransactionHandling: TransactionHandling.Autonomous) },
            { AlterDatabase , new MigrationsFolder(AlterDatabase, "AlterDatabase", folderNames.AlterDatabase, AnyTime, ConnectionType.Admin, TransactionHandling.Autonomous) },
            { RunAfterCreateDatabase, new MigrationsFolder(RunAfterCreateDatabase, "Run After Create Database", folderNames.RunAfterCreateDatabase, AnyTime) },
            { RunBeforeUp,  new MigrationsFolder(RunBeforeUp, "Run Before Update", folderNames.RunBeforeUp, AnyTime) },
            { Up, new MigrationsFolder(Up, "Update", folderNames.Up, Once) },
            { RunFirstAfterUp, new MigrationsFolder(RunFirstAfterUp, "Run First After Update", folderNames.RunFirstAfterUp, AnyTime) },
            { Functions, new MigrationsFolder(Functions, "Functions", folderNames.Functions, AnyTime) },
            { Views, new MigrationsFolder(Views, "Views", folderNames.Views, AnyTime) },
            { Sprocs, new MigrationsFolder(Sprocs, "Stored Procedures", folderNames.Sprocs, AnyTime) },
            { Triggers, new MigrationsFolder(Triggers, "Triggers", folderNames.Triggers, AnyTime) },
            { Indexes, new MigrationsFolder(Indexes, "Indexes", folderNames.Indexes, AnyTime) },
            { RunAfterOtherAnyTimeScripts, new MigrationsFolder(RunAfterOtherAnyTimeScripts, "Run after Other Anytime Scripts", folderNames.RunAfterOtherAnyTimeScripts, AnyTime) },
            { Permissions, new MigrationsFolder(Permissions, "Permissions", folderNames.Permissions, EveryTime, TransactionHandling: TransactionHandling.Autonomous) },
            { AfterMigration, new MigrationsFolder(AfterMigration, "AfterMigration", folderNames.AfterMigration, EveryTime, TransactionHandling: TransactionHandling.Autonomous) },
        };
        foldersConfiguration.CreateDatabase = new MigrationsFolder(KnownFolderKeys.CreateDatabase, "CreateDatabase", folderNames.CreateDatabase, AnyTime, ConnectionType.Admin, TransactionHandling.Autonomous);
        foldersConfiguration.DropDatabase = new MigrationsFolder(KnownFolderKeys.DropDatabase, "DropDatabase", folderNames.DropDatabase, AnyTime, ConnectionType.Admin, TransactionHandling.Autonomous);

        return foldersConfiguration;
    }

}
