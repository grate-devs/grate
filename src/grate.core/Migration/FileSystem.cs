using static System.IO.Path;
using static System.IO.SearchOption;
using static System.StringComparer;

namespace grate.Migration;

internal static class FileSystem
{
    public static IEnumerable<FileSystemInfo> GetFiles(DirectoryInfo folderPath, string pattern, bool ignoreDirectoryNames = false)
    {
        return ignoreDirectoryNames
            ? folderPath
                .EnumerateFileSystemInfos(pattern, AllDirectories).ToList()
                .OrderBy(f => GetFileNameWithoutExtension(f.FullName), CurrentCultureIgnoreCase)
            : folderPath
                .EnumerateFileSystemInfos(pattern, AllDirectories).ToList()
                .OrderBy(f =>
                    Combine(
                        PathCompat.GetRelativePath(folderPath.ToString(), GetDirectoryName(f.FullName)!),
                        GetFileNameWithoutExtension(f.FullName)),
                    CurrentCultureIgnoreCase);
    }
    
    public static DirectoryInfo CreateRandomTempDirectory()
    {
        var dummyFile = Path.GetTempFileName();
        File.Delete(dummyFile);

        if (Directory.Exists(dummyFile))
        {
            Directory.Delete(dummyFile, true);
        }

        var scriptsDir = Directory.CreateDirectory(dummyFile);
        return scriptsDir;
    }
}
