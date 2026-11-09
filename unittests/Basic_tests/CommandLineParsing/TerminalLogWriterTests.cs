using grate.Configuration;
using grate.Infrastructure;
using Microsoft.Extensions.Logging;

namespace Basic_tests.CommandLineParsing;

public sealed class TerminalLogWriterTests
{
    [Fact]
    public void Activity_progress_is_cleared_before_durable_logs_and_errors_keep_stderr_routing()
    {
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();
        var writer = new TerminalLogWriter(stdout, stderr, () => 80);
        var activity = new MigrationLogActivity("📂 Update (up)", completedFolders: 4, totalFolders: 9);

        writer.StartActivity(activity);
        var beforeLog = stdout.ToString().Length;
        writer.Write(LogLevel.Information, "Running 01_change.sql.");
        var beforeWarning = stdout.ToString().Length;
        writer.Write(LogLevel.Warning, "Keep this diagnostic.");
        writer.FinishActivity(activity);
        writer.Complete("Migration completed.");

        var text = stdout.ToString();
        Assert.Contains("📂 Update (up)", text);
        Assert.Contains("40%", text);
        Assert.Contains("Running 01_change.sql.", text);
        Assert.StartsWith("\r\u001b[2K", text[beforeLog..]);
        Assert.StartsWith("\r\u001b[2K", text[beforeWarning..]);
        Assert.Contains("Keep this diagnostic.", stderr.ToString());
        Assert.DoesNotContain("Keep this diagnostic.", text);
        Assert.DoesNotContain("Running 01_change.sql.", stderr.ToString());
        Assert.Contains("✅ Migration completed.", text);
        Assert.EndsWith(Environment.NewLine, text);
    }

    [Fact]
    public void Untrusted_terminal_text_cannot_move_the_cursor_or_set_a_terminal_title()
    {
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();
        var writer = new TerminalLogWriter(stdout, stderr, () => 80);
        var activity = new MigrationLogActivity("📂 folder\u001b]0;injected\u0007\r\nnext\tname");

        writer.StartActivity(activity);
        writer.Write(LogLevel.Error, "first\u001b[2J\r\nsecond\u0007\tcolumn");
        writer.FinishActivity(activity);

        Assert.DoesNotContain("\u001b]0;", stdout.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain("\u001b[2J", stderr.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain('\u0007', stdout.ToString());
        Assert.DoesNotContain('\u0007', stderr.ToString());
        Assert.Contains(@"\u001B", stdout.ToString());
        Assert.Contains(@"\u001B", stderr.ToString());
        Assert.Contains("first", stderr.ToString());
        Assert.Contains("second", stderr.ToString());
    }

    [Theory]
    [InlineData(0)]
    [InlineData(8)]
    public void A_narrow_terminal_keeps_headings_and_diagnostics_without_a_live_line(int width)
    {
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();
        var writer = new TerminalLogWriter(stdout, stderr, () => width);
        var activity = new MigrationLogActivity("📂 Update (up)");

        writer.StartActivity(activity);
        writer.Write(LogLevel.Information, "Running script.");
        writer.FinishActivity(activity);

        Assert.Contains("Update (up)", stdout.ToString());
        Assert.Contains("Running script.", stdout.ToString());
        Assert.DoesNotContain("\r\u001b[2K", stdout.ToString());
    }

    [Fact]
    public void Unavailable_terminal_width_does_not_interrupt_a_migration()
    {
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();
        var writer = new TerminalLogWriter(stdout, stderr, () => throw new IOException("No terminal size."));
        var activity = new MigrationLogActivity("Update (up)");

        writer.StartActivity(activity);
        writer.Write(LogLevel.Information, "Running script.");
        writer.FinishActivity(activity);

        Assert.Contains("Running script.", stdout.ToString());
        Assert.DoesNotContain("\r\u001b[2K", stdout.ToString());
    }

    [Theory]
    [InlineData(24)]
    [InlineData(30)]
    [InlineData(80)]
    public void Resizing_truncates_the_live_line_before_it_can_wrap(int resizedWidth)
    {
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();
        var width = 120;
        var writer = new TerminalLogWriter(stdout, stderr, () => width);
        var activity = new MigrationLogActivity("📂 資料庫 " + new string('x', 150), completedFolders: 4, totalFolders: 9);
        writer.StartActivity(activity);

        width = resizedWidth;
        writer.Write(LogLevel.Information, "Persisted log.");

        var liveLine = stdout.ToString().Split('\n')[^1];
        Assert.Contains("40%", liveLine);
        Assert.InRange(liveLine.Length, 1, resizedWidth - 2);
        Assert.EndsWith("...", liveLine);
        Assert.All(liveLine, character => Assert.InRange(character, ' ', '~'));
        writer.FinishActivity(activity);
    }

    [Fact]
    public void A_terminal_failure_clears_progress_and_keeps_one_error_on_stderr()
    {
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();
        using var provider = new MigrationLoggerProvider(MigrationLogFormat.Terminal, stdout, stderr, () => 80);
        var logger = provider.CreateLogger("Grate.Migration");
        var failure = new InvalidOperationException("01_change.sql failed.");
        using (logger.BeginScope(new MigrationLogActivity("📂 Update (up)")))
        {
            logger.LogInformation("Running script.");
            using (logger.BeginScope(new ScriptFailureDiagnostic(failure)))
            {
                logger.LogError("01_change.sql failed.");
            }
        }

        provider.ReportFailure(logger, failure);

        Assert.Single(stderr.ToString().Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries));
        Assert.Contains("01_change.sql failed.", stderr.ToString());
        Assert.DoesNotContain("01_change.sql failed.", stdout.ToString());
        Assert.DoesNotContain("✅", stdout.ToString());
        Assert.EndsWith("[INFO] ❌ Migration failed." + Environment.NewLine, stdout.ToString());
        Assert.True(stdout.ToString().LastIndexOf("\r\u001b[2K", StringComparison.Ordinal)
                    < stdout.ToString().LastIndexOf("❌", StringComparison.Ordinal));
    }

    [Fact]
    public void Typed_separators_start_the_activity_without_printing_the_old_decoration()
    {
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();
        using var provider = new MigrationLoggerProvider(MigrationLogFormat.Terminal, stdout, stderr, () => 80);
        var logger = provider.CreateLogger("Grate.Migration");
        using (logger.BeginScope(new MigrationLogActivity("🏁 Finalizing migration")))
        {
            logger.LogInformation(MigrationLogEvents.Separator, "{Separator}", new string('=', 80));

            Assert.Contains("🏁 Finalizing migration", stdout.ToString());
            Assert.DoesNotContain(new string('=', 80), stdout.ToString());
            logger.LogInformation("{Text}", new string('-', 80));
            Assert.Contains(new string('-', 80), stdout.ToString());
        }
    }

    [Fact]
    public void Quiet_terminal_logging_has_no_headings_progress_or_completion_status()
    {
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();
        using var provider = new MigrationLoggerProvider(MigrationLogFormat.Terminal, stdout, stderr, () => 80);
        using var factory = LoggerFactory.Create(builder => builder.AddProvider(provider).SetMinimumLevel(LogLevel.Warning));
        var logger = factory.CreateLogger("Grate.Migration");
        using (logger.BeginScope(new MigrationLogActivity("Hidden activity")))
        {
            logger.LogInformation("Hidden progress.");
            logger.LogWarning("Visible warning.");
        }
        provider.Complete(logger);

        Assert.Empty(stdout.ToString());
        Assert.Contains("Visible warning.", stderr.ToString());
    }
}
