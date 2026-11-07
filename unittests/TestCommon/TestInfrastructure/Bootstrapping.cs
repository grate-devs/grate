using System.Reflection;
using System.Text.RegularExpressions;

namespace TestCommon.TestInfrastructure;

internal static class Bootstrapping
{
    internal static IEnumerable<string> GetBootstrapScripts(
        Type databasetype,
        string resourcePrefix
    )
    {
        var assembly = databasetype.Assembly;

        // If the resource prefix starts with a number, we need to prefix it with an underscore
        if (Regex.IsMatch(resourcePrefix, "^\\d"))
        {
            resourcePrefix = $"_{resourcePrefix}";
        }

        var prefix = $"{assembly.GetName().Name}.Bootstrapping.Sql.{resourcePrefix}";

        var resources = assembly.GetManifestResourceNames()
            .Where(x => x.StartsWith(prefix))
            .ToArray();

        return resources;
    }


    internal static async Task<string> GetContent(
        Assembly assembly,
        string resource)
    {
        var resourceStream = assembly.GetManifestResourceStream(resource);
        if (resourceStream is null)
        {
            throw new Exception($"Resource {resource} not found");
        }

        using var streamReader = new StreamReader(resourceStream);
        var resourceText = await streamReader.ReadToEndAsync();

        return resourceText;
    }

    internal static async Task WriteResourceToFolder(
        string resource,
        string resourceText,
        string folder,
        string resourcePrefix,
        string? sqlFolderNamePrefix)
    {
        var prefix = $".Bootstrapping.Sql.{resourcePrefix}";
        var index = resource.IndexOf(prefix, StringComparison.Ordinal) + prefix.Length;

        var prefixLength = index;

        var nextDot = resource.IndexOf('.', prefixLength + 1);
        var folderName = resource.Substring(prefixLength + 1, nextDot - prefixLength - 1);

        var fullFolder = sqlFolderNamePrefix is { }
            ? Path.Combine(folder, folderName, sqlFolderNamePrefix)
            : Path.Combine(folder, folderName);

        if (!Directory.Exists(fullFolder))
        {
            Directory.CreateDirectory(fullFolder);
        }

        var resourceName = resource.Substring(prefixLength + 1 + folderName.Length + 1);

        var filePath = Path.Combine(fullFolder, resourceName);
        await File.WriteAllTextAsync(filePath, resourceText);
    }


}
