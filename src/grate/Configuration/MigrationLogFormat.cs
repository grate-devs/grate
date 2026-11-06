namespace grate.Configuration;

internal enum MigrationLogFormat
{
    Auto,
    Console,
    Ci,
    GitHub,
    Azure,
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

        var github = IsTrue("GITHUB_ACTIONS");
        var azure = IsTrue("TF_BUILD");
        var teamCity = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("TEAMCITY_VERSION"));
        var jenkins = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("JENKINS_URL"))
            || Environment.GetEnvironmentVariable("BUILD_TAG")?.StartsWith("jenkins-", StringComparison.Ordinal) == true;
        var matches = (github ? 1 : 0) + (azure ? 1 : 0) + (teamCity ? 1 : 0) + (jenkins ? 1 : 0);

        return matches switch
        {
            0 when !IsTrue("CI") => MigrationLogFormat.Console,
            1 when github => MigrationLogFormat.GitHub,
            1 when azure => MigrationLogFormat.Azure,
            1 when teamCity => MigrationLogFormat.TeamCity,
            _ => MigrationLogFormat.Ci
        };
    }

    private static bool IsTrue(string name) =>
        string.Equals(Environment.GetEnvironmentVariable(name), "true", StringComparison.OrdinalIgnoreCase);
}
