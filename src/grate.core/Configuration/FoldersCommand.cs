using System.Diagnostics.CodeAnalysis;
using System.Reflection;
using grate.Exceptions;
#if NETSTANDARD2_0
using static grate.Compatibility.StringSplitOptionsShim;
#else
using static System.StringSplitOptions;
#endif

namespace grate.Configuration;

internal static class FoldersCommand
{
    public static IFoldersConfiguration Parse(string? arg)
    {
        if (IsFile(arg))
        {
            arg = File.Exists(arg) ? File.ReadAllText(arg) : "";

            // Makes more sense to supply an empty config than the default if you actually supply a file,
            // but that file is either non-existant or empty
            if (string.IsNullOrEmpty(arg))
            {
                return FoldersConfiguration.Empty;
            }
        }

        string? content = arg switch
        {
            { Length: 0 } => null,
            _ => arg
        };

        return content switch
        {
            { } => ParseNewCustomFoldersConfiguration(content),
            _ => FoldersConfiguration.Default()
        };
    }

    private static IFoldersConfiguration ParseNewCustomFoldersConfiguration(string s)
    {
        // Combine lines into a semicolon-separated string, if there were multiple lines
        var lines = (s.Split('\n', RemoveEmptyEntries | TrimEntries));
        var oneLine = string.Join(";", lines);
        var tokens = oneLine.Split(';', StringSplitOptions.RemoveEmptyEntries);

        IEnumerable<(string key, string config)> configs = tokens.Select(token => SplitInTwo(token, '=')).ToArray();

        // Check to see if each and every of the folders specified was one of the default ones.
        // If they were, assume that the intent is so have the default folder configuration, but just
        // adjust some of the folders.
        // 
        // If one of the folders is none of the default folders, we assume the intent is a totally
        // customised folder configuration.
        IFoldersConfiguration foldersConfiguration =
            configs.Select(c => c.key).All(key => KnownFolderKeys.Keys.Contains(key, StringComparer.InvariantCultureIgnoreCase))
                ? FoldersConfiguration.Default()
                : FoldersConfiguration.Empty;

        // Loop through all the config items, and apply them
        // 1) To the existing default folder with that name
        // 2) To a new folder, if there is no default folder with that name
        foreach ((string key, string config) in configs)
        {
            MigrationsFolder folder;
            if (foldersConfiguration.CreateDatabase != null && 
                key.Equals(KnownFolderKeys.CreateDatabase, StringComparison.InvariantCultureIgnoreCase))
            {
                folder = foldersConfiguration.CreateDatabase;
            }
            else
            {
                var existingKey =
                    foldersConfiguration.Keys.SingleOrDefault(k =>
                        key.Equals(k, StringComparison.InvariantCultureIgnoreCase));
                if (existingKey is not null)
                {
                    folder = foldersConfiguration[existingKey]!;
                }
                else
                {
                    folder = new MigrationsFolder(key);
                    foldersConfiguration[key] = folder;
                }
            }
            ApplyConfig(folder, config);
        }

        return foldersConfiguration;
    }

    /// <summary>
    /// Apply folder config from a string to an existing Migrations folder.
    /// </summary>
    /// <param name="folder">The folder to apply to</param>
    /// <param name="folderConfig">A string that describes the configuration, or short form with either
    /// only the folder name, or only the migration type</param>
    /// <exception cref="InvalidFolderConfiguration"></exception>
    /// <example>relativePath:myCustomFolder,type:Once,connectionType:Admin</example>
    /// <example>Once</example>
    /// <example>AnyTime</example>
    private static void ApplyConfig(MigrationsFolder folder, string folderConfig)
    {
        // First, handle any special 'short form' types:
        if (!folderConfig.Contains(':'))
        {
            if (Enum.TryParse(folderConfig, true, out MigrationType result))
            {
                var (setter, _) = GetProperty(nameof(MigrationsFolder.Type));
                setter!.Invoke(folder, new object?[] { result });
            }
            else
            {
                var (setter, _) = GetProperty(nameof(MigrationsFolder.Path));
                setter!.Invoke(folder, new object?[] { folderConfig });
            }

            return;
        }


        var tokens = folderConfig.Split(',');
        foreach (var token in tokens)
        {
            var keyAndValue = token.Split(':', 2);
            var (key, value) = (keyAndValue.First(), keyAndValue.Last());

            var (setter, propertyType) = GetProperty(key);

            if (setter is null)
            {
                throw new InvalidFolderConfiguration(folderConfig, key);
            }

            var parsed = (propertyType?.IsEnum ?? false)
                            ? Enum.Parse(propertyType, value, true)
                            : value;

            setter.Invoke(folder, new[] { parsed });
        }
    }

    [DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicProperties | DynamicallyAccessedMemberTypes.NonPublicProperties)]
    static readonly Type FolderType = typeof(MigrationsFolder);

    private static (MethodInfo? setter, Type? propertyType) GetProperty(string propertyName)
    {
        var property =
            FolderType.GetProperty(propertyName, BindingFlags.IgnoreCase | BindingFlags.Public | BindingFlags.Instance);

        var setter = property?.GetSetMethod(true);
        var propertyType = property?.PropertyType;

        return (setter, propertyType);
    }

    private static (string key, string value) SplitInTwo(string s, char separator)
    {
        var keyAndValue = s.Split(separator, 2);
        var (key, value) = (keyAndValue.First(), keyAndValue.Last());
        return (key, value);
    }

    private static bool IsFile(string? s)
    {
        return s is not null && (File.Exists(s) || s.StartsWith("/"));
    }
}
