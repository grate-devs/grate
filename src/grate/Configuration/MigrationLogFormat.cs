namespace grate.Configuration;

internal enum MigrationLogFormat
{
    Auto,
    Console,
    Ci,
    GitHub,
    AzureDevOps,
    TeamCity
}

internal static class MigrationLogFormatSelection
{
    public static MigrationLogFormat Resolve(MigrationLogFormat configured)
    {
        if (configured != MigrationLogFormat.Auto)
        {
            return configured;
        }

        // Jenkins uses plain CI output, whether or not another provider is detected.
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("JENKINS_URL"))
            || Environment.GetEnvironmentVariable("BUILD_TAG")?.StartsWith("jenkins-", StringComparison.Ordinal) == true)
        {
            return MigrationLogFormat.Ci;
        }

        var nativeFormats = new List<MigrationLogFormat>(3);
        if (IsTrue("GITHUB_ACTIONS"))
        {
            nativeFormats.Add(MigrationLogFormat.GitHub);
        }
        if (IsTrue("TF_BUILD"))
        {
            nativeFormats.Add(MigrationLogFormat.AzureDevOps);
        }
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("TEAMCITY_VERSION")))
        {
            nativeFormats.Add(MigrationLogFormat.TeamCity);
        }

        if (nativeFormats.Count == 1)
        {
            return nativeFormats[0];
        }

        return nativeFormats.Count > 1 || IsTrue("CI") ? MigrationLogFormat.Ci : MigrationLogFormat.Console;
    }

    private static bool IsTrue(string name) =>
        string.Equals(Environment.GetEnvironmentVariable(name), "true", StringComparison.OrdinalIgnoreCase);
}
