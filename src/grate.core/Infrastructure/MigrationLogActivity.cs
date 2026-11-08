namespace grate.Infrastructure;

// Optional presentation metadata for CLI log providers. Other logging providers
// continue to receive the same messages, levels and categories.
internal sealed class MigrationLogActivity(string name, int completedFolders = 0, int totalFolders = 0)
{
    public string Name { get; } = name;
    public int CompletedFolders { get; } = completedFolders;
    public int TotalFolders { get; } = totalFolders;
}
