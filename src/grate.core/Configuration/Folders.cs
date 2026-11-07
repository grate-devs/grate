namespace grate.Configuration;

/// <summary>
/// Factory class for creating <see cref="IFoldersConfiguration"/> instances.
/// </summary>
public static class Folders
{
    /// <summary>
    /// The default <see cref="IFoldersConfiguration"/>.
    /// </summary>
    public static IFoldersConfiguration Default => FoldersConfiguration.Default();

    /// <summary>
    /// An empty <see cref="IFoldersConfiguration"/>.
    /// </summary>
    public static IFoldersConfiguration Empty => FoldersConfiguration.Empty;

    /// <summary>
    /// Folder configuration with the specified folders.
    /// </summary>
    /// <param name="folders">A list of migration folders</param>
    /// <returns>An IFoldersConfiguration with the supplied folders</returns>
    public static IFoldersConfiguration Create(params MigrationsFolder[] folders)
        => new FoldersConfiguration(folders);

    /// <summary>
    /// Folder configuration with the specified folders.
    /// </summary>
    /// <param name="folders">A list of migration folders</param>
    /// <returns>An IFoldersConfiguration with the supplied folders</returns>
    public static IFoldersConfiguration Create(IEnumerable<MigrationsFolder> folders)
        => new FoldersConfiguration(folders);

    /// <summary>
    /// Folder configuration with the specified Dictionary of folder names and folders.
    /// </summary>
    /// <param name="folders">A Dictionary of folder names and migration folders</param>
    /// <returns>An IFoldersConfiguration with the supplied folders</returns>
    public static IFoldersConfiguration Create(IDictionary<string, MigrationsFolder> folders)
        => new FoldersConfiguration(folders);

    /// <summary>
    /// Folder configuration from strings, where each string is a folder configuration, as
    /// you can specify on the command line.
    ///
    /// For convenience, you can specify each folder in a separate string, instead of all in one string, separated by a semicolon.
    ///
    /// For example:
    ///
    /// <code>
    /// Create("structure=relativePath:myCustomFolder,type:Once,connectionType:Admin",
    ///        "randomstuff=type:Once;procedures=type:Once;security=type:Once")
    /// </code>
    /// 
    /// </summary>
    /// <param name="folders">Separate strings with folder configurations</param>
    /// <returns>An IFoldersConfiguration with the supplied folders</returns>
    public static IFoldersConfiguration Create(params string[] folders)
        => FoldersCommand.Parse(string.Join(";", folders));

    /// <summary>
    /// Folder configuration from strings, where each string is a folder configuration, as
    /// you can specify on the command line.
    /// 
    /// You specify multiple folders in one string, separated by a semicolon.
    ///
    /// For example: "structure=relativePath:myCustomFolder,type:Once,connectionType:Admin;randomstuff=type:Once;procedures=type:Once;security=type:Once"
    /// </summary>
    /// <param name="folders">A semicolon separated string with all the folder configurations, as specified on the command line</param>
    /// <returns>An IFoldersConfiguration with the supplied folders</returns>
    public static IFoldersConfiguration Create(string folders)
        => FoldersCommand.Parse(folders);
}
