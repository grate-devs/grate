using Aspire.Hosting.ApplicationModel;

namespace Grate.Aspire.Hosting;

/// <summary>A finite grate migration container that consumers can wait for.</summary>
public sealed class GrateMigrationResource(string name) : ContainerResource(name)
{
    internal ContainerMountAnnotation? ScriptsMount { get; set; }

    internal ContainerMountAnnotation? DataMount { get; set; }

    internal bool ScriptsArePackaged { get; set; }

    /// <summary>Whether this migration requires a database file directory shared with its consumers.</summary>
    public bool UsesSharedDatabaseFile => DataMount is not null;
}
