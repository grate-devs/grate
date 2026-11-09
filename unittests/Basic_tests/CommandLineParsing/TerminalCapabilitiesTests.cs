using grate.Infrastructure;

namespace Basic_tests.CommandLineParsing;

public sealed class TerminalCapabilitiesTests
{
    [Theory]
    [InlineData(false, false, "xterm-256color", null, false, null, true)]
    [InlineData(true, false, "xterm-256color", null, false, null, false)]
    [InlineData(false, true, "xterm-256color", null, false, null, false)]
    [InlineData(false, false, "dumb", null, false, null, false)]
    [InlineData(false, false, "DUMB", null, true, "session", false)]
    [InlineData(false, false, null, null, false, null, false)]
    [InlineData(false, false, "", null, false, null, false)]
    [InlineData(false, false, "xterm", "1", false, null, false)]
    [InlineData(false, false, "xterm", "", false, null, true)]
    [InlineData(false, false, "xterm", null, true, null, false)]
    [InlineData(false, false, null, null, true, "session", true)]
    [InlineData(false, false, "xterm", null, true, "session", true)]
    public void Only_capable_unredirected_terminals_enable_live_output(
        bool stdoutRedirected, bool stderrRedirected, string? term, string? noColor,
        bool isWindows, string? windowsTerminalSession, bool expected)
    {
        Assert.Equal(expected, TerminalCapabilities.IsSupported(
            stdoutRedirected, stderrRedirected, term, noColor, isWindows, windowsTerminalSession));
    }
}
