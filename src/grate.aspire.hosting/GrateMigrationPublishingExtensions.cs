using System.Text.Json;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;

namespace Grate.Aspire.Hosting;

/// <summary>Packages declared SQL scripts as a portable migration image.</summary>
public static class GrateMigrationPublishingExtensions
{
    /// <summary>In publish mode, builds a derived grate image containing the declared SQL tree.</summary>
    /// <remarks>
    /// Local runs retain their read-only bind mount. Publishing snapshots only .sql files,
    /// preserving relative paths and bytes, into an Aspire-owned temporary build context.
    /// No source files are written or runtime connection values copied into that context.
    /// Configure the scripts and base image before calling this method. Shared-file SQLite
    /// migrations and additional runtime mounts need a separate storage contract.
    /// </remarks>
    public static IResourceBuilder<GrateMigrationResource> PublishAsGrateMigrationImage(
        this IResourceBuilder<GrateMigrationResource> migration)
    {
        ArgumentNullException.ThrowIfNull(migration);
        if (!migration.ApplicationBuilder.ExecutionContext.IsPublishMode)
        {
            return migration;
        }

        var resource = migration.Resource;
        if (resource.ScriptsArePackaged)
        {
            ValidateMounts(resource, allowedScriptsMount: null);
            return migration;
        }
        if (resource.UsesSharedDatabaseFile)
        {
            throw new NotSupportedException("Publishing SQLite migrations requires an explicit shared-file storage contract.");
        }
        if (resource.Annotations.OfType<DockerfileBuildAnnotation>().Any())
        {
            throw new InvalidOperationException("The migration already has a Dockerfile build. Configure only one migration image build.");
        }

        var scripts = resource.ScriptsMount ?? throw new InvalidOperationException(
            "Configure WithScriptsFolder before publishing the migration image.");
        var source = scripts.Source ?? throw new InvalidOperationException("A migration scripts bind mount must have a source directory.");
        ValidateMounts(resource, scripts);
        ValidateSource(source);
        GetBaseImage(resource);
        if (scripts.Target.Contains('$'))
        {
            throw new NotSupportedException("Published scripts targets cannot contain Dockerfile environment substitutions.");
        }

        var contextPath = CreateSqlBuildContext(migration, source);
        migration.WithDockerfileFactory(contextPath, _ =>
        {
            ValidateMounts(resource, allowedScriptsMount: null);
            var copy = JsonSerializer.Serialize(new[] { ".", scripts.Target.TrimEnd('/') + "/" });
            return $"FROM {GetBaseImage(resource)}\nCOPY {copy}\n";
        });
        resource.Annotations.Remove(scripts);
        resource.ScriptsArePackaged = true;
        return migration;
    }

    private static void ValidateMounts(GrateMigrationResource resource, ContainerMountAnnotation? allowedScriptsMount)
    {
        if (resource.Annotations.OfType<ContainerMountAnnotation>().Any(mount => !ReferenceEquals(mount, allowedScriptsMount)))
        {
            throw new InvalidOperationException("Published migration images cannot retain runtime mounts. Package SQL scripts and configure cloud storage separately.");
        }
    }

    private static void ValidateSource(string? source)
    {
        if (source is null || !Directory.Exists(source))
        {
            throw new DirectoryNotFoundException("The declared grate scripts directory no longer exists.");
        }
        if ((File.GetAttributes(source) & FileAttributes.ReparsePoint) != 0)
        {
            throw new NotSupportedException("Published scripts must use regular directories and files instead of symbolic links.");
        }
    }

    private static string GetBaseImage(GrateMigrationResource resource)
    {
        if (!resource.TryGetContainerImageName(useBuiltImage: false, out var image) ||
            string.IsNullOrWhiteSpace(image) || image.Any(char.IsWhiteSpace) || image.Any(char.IsControl))
        {
            throw new InvalidOperationException("Configure a valid grate base image before publishing its scripts.");
        }
        return image;
    }

    // The pinned Aspire 13.6.5 file-system service owns temporary-context cleanup.
    // Scope this experimental API dependency to the staging boundary, not project-wide warnings.
#pragma warning disable ASPIREFILESYSTEM001
    private static string CreateSqlBuildContext(IResourceBuilder<GrateMigrationResource> migration, string source)
    {
        var context = migration.ApplicationBuilder.FileSystemService.TempDirectory.CreateTempSubdirectory("grate-sql-");
        try
        {
            CopySqlTree(new DirectoryInfo(source), context.Path);
            return context.Path;
        }
        catch
        {
            context.Dispose();
            throw;
        }
    }
#pragma warning restore ASPIREFILESYSTEM001

    private static void CopySqlTree(DirectoryInfo source, string destination)
    {
        foreach (var entry in source.GetFileSystemInfos().OrderBy(entry => entry.Name, StringComparer.Ordinal))
        {
            if ((entry.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new NotSupportedException("Published scripts must use regular directories and files instead of symbolic links.");
            }
            if (entry is DirectoryInfo directory)
            {
                var target = Path.Combine(destination, directory.Name);
                Directory.CreateDirectory(target);
                CopySqlTree(directory, target);
            }
            else if (entry is FileInfo file && string.Equals(file.Extension, ".sql", StringComparison.OrdinalIgnoreCase))
            {
                file.CopyTo(Path.Combine(destination, file.Name));
            }
        }
    }
}
