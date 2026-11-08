using grate.Migration;

namespace grate.Configuration;

/// <summary>
/// A folder to migrate
/// </summary>
/// <param name="Name">A name you wish to give the migration folder (e.g. "The first one")</param>
/// <param name="Path">The _relative_ path of the folder (relative to the SqlFilesDirectory).
/// Defaults to <paramref name="Name"/></param>
/// <param name="Type">The migration type (decides what happens on subsequent runs of the folder</param>
/// <param name="ConnectionType">Whether you need an admin connection or not</param>
/// <param name="TransactionHandling">Whether to roll back this folder if something fails, or run these
/// scripts in a separate, autonomous transactions, which makes them run no matter if other stuff errors.</param>
public record MigrationsFolder(
        string Key,
        string Name,
        string Path,
        MigrationType Type = MigrationType.Once,
        ConnectionType ConnectionType = ConnectionType.Default,
        TransactionHandling TransactionHandling = TransactionHandling.Default)
{
    public MigrationsFolder(
        string name,
        string path,
        MigrationType type = MigrationType.Once,
        ConnectionType connectionType = ConnectionType.Default,
        TransactionHandling transactionHandling = TransactionHandling.Default)
        : this(name, name, path, type, connectionType, transactionHandling)
    { }

    public MigrationsFolder(
        string name,
        MigrationType type = MigrationType.Once,
        ConnectionType connectionType = ConnectionType.Default,
        TransactionHandling transactionHandling = TransactionHandling.Default)
        : this(name, name, name, type, connectionType, transactionHandling)
    { }

    public override string ToString() =>
        $"{Key}=name:{Name},path:{Path},type:{Type},connectionType:{ConnectionType},transactionHandling:{TransactionHandling}";
}
