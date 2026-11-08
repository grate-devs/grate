using System.Globalization;
using System.Reflection;

namespace grate.Configuration;

internal static class ApplicationInfo
{
    public static string Name => "grate";
    public static string Version => BuildInfo().version;
    public static DateTime BuildDate => BuildInfo().buildDate;

    private static (string version, DateTime buildDate) BuildInfo()
    {
        string version = "0.0.0.1";
        DateTime buildDate = DateTime.MinValue;

        var assembly = typeof(ApplicationInfo).Assembly;

        // The version numbers can look a bit different if the SourceRevisionId is already set before building (e.g. in build servers)
        const string buildVersionMetadataPrefix = "+build";
        const string buildVersionMetadataPrefix2 = ".build";


        var attribute = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>();
        if (attribute?.InformationalVersion != null)
        {
            var informationalVersion = attribute.InformationalVersion;

            var index = informationalVersion.IndexOf(buildVersionMetadataPrefix);
            if (index < 0)
            {
                index = informationalVersion.IndexOf(buildVersionMetadataPrefix2);
            }

            if (index > 0)
            {
                var dateString = informationalVersion[(index + buildVersionMetadataPrefix.Length)..];
                DateTime.TryParseExact(dateString, "O", CultureInfo.InvariantCulture, DateTimeStyles.None, out buildDate);

                version = informationalVersion[..index];
            }
        }

        return (version, buildDate);
    }

}
