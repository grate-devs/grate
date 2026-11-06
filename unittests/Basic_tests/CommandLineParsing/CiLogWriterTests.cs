using grate.Configuration;
using grate.Infrastructure;
using Microsoft.Extensions.Logging;

namespace Basic_tests.CommandLineParsing;

public sealed class CiLogWriterTests
{
    [Theory]
    [InlineData("GitHub", "::error::Critical diagnostic")]
    [InlineData("AzureDevOps", "##vso[task.logissue type=error;]Critical diagnostic")]
    [InlineData("TeamCity", "##teamcity[message text='Critical diagnostic' status='ERROR']")]
    public void Native_formats_report_critical_logs_as_errors(string format, string annotation)
    {
        using var output = new StringWriter();
        using var provider = new CiMigrationLoggerProvider(Enum.Parse<MigrationLogFormat>(format), output);

        provider.CreateLogger("Migration").LogCritical("Critical diagnostic");

        Assert.Equal(annotation + Environment.NewLine, output.ToString());
    }
}
