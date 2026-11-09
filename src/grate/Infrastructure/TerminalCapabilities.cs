namespace grate.Infrastructure;

internal static class TerminalCapabilities
{
    public static bool IsSupported() => IsSupported(
        Console.IsOutputRedirected,
        Console.IsErrorRedirected,
        Environment.GetEnvironmentVariable("TERM"),
        Environment.GetEnvironmentVariable("NO_COLOR"),
        OperatingSystem.IsWindows(),
        Environment.GetEnvironmentVariable("WT_SESSION"));

    public static bool IsSupported(bool stdoutRedirected, bool stderrRedirected, string? term,
        string? noColor, bool isWindows, string? windowsTerminalSession) =>
        !stdoutRedirected && !stderrRedirected
        && !string.Equals(term, "dumb", StringComparison.OrdinalIgnoreCase)
        && string.IsNullOrEmpty(noColor)
        // Older Windows consoles can accept stdout while still treating ANSI as
        // literal text. Be conservative unless Windows Terminal identifies itself.
        && (isWindows ? !string.IsNullOrWhiteSpace(windowsTerminalSession) : !string.IsNullOrWhiteSpace(term));
}
