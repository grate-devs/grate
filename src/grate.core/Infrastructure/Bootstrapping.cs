using System.Text.RegularExpressions;

namespace grate.Infrastructure;

internal static class Bootstrapping
{
    internal static async Task WriteBootstrapScriptsToFolder(
        Type databasetype, 
        string folder,
        string resourcePrefix,
        string? sqlFolderNamePrefix)
    {
        var assembly = databasetype.Assembly;
        
        // If the resource prefix starts with a number, we need to prefix it with an underscore
        if (Regex.IsMatch(resourcePrefix, "^\\d"))
        {
            resourcePrefix = $"_{resourcePrefix}";
        }
        
        var prefix = $"{assembly.GetName().Name}.Bootstrapping.Sql.{resourcePrefix}";
        var prefixLength = prefix.Length;
        
        var resources = assembly.GetManifestResourceNames()
            .Where(x => x.StartsWith(prefix))
            .ToArray();

        foreach (var resource in resources)
        {
            var nextDot = resource.IndexOf('.', prefixLength + 1);
            var folderName = resource.Substring(prefixLength + 1, nextDot - prefixLength - 1);
            
            var fullFolder = sqlFolderNamePrefix is {} 
                ? Path.Combine(folder, folderName, sqlFolderNamePrefix)
                : Path.Combine(folder, folderName);
            if (!Directory.Exists(fullFolder))
            {
                Directory.CreateDirectory(fullFolder);
            }
            
            var resourceName = resource.Substring(prefixLength + 1 + folderName.Length + 1);
            var resourceStream = assembly.GetManifestResourceStream(resource);
            if (resourceStream is null)
            {
                throw new Exception($"Resource {resource} not found");
            }

            using var streamReader = new StreamReader(resourceStream);
            var resourceText = await streamReader.ReadToEndAsync();
            var filePath = Path.Combine(fullFolder, resourceName);
            await FileCompat.WriteAllTextAsync(filePath, resourceText);
        }
    }
    
}
