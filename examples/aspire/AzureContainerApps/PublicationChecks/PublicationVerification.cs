using System.Diagnostics;
using System.Text.RegularExpressions;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Grate.Aspire.Hosting;
using Microsoft.Data.Sqlite;

namespace Grate.Aspire.Example.AzureContainerApps;

internal static partial class PublicationVerification
{
    internal static async Task VerifyImage(IServiceProvider services, DistributedApplicationExecutionContext execution,
        GrateMigrationResource migration, string output)
    {
        var build = migration.Annotations.OfType<DockerfileBuildAnnotation>().Single();
        await build.EmitDockerfileArtifactsAsync(new DockerfileFactoryContext { Resource = migration, Services = services });
        var identifier = Guid.NewGuid().ToString("N");
        var image = $"grate-aca-check:{identifier}";
        var container = $"grate-aca-check-{identifier}";
        var data = Directory.CreateDirectory(Path.Combine(output, "image-data")).FullName;
        try
        {
            await Run("docker", ["build", "--tag", image, "--file", build.DockerfilePath, build.ContextPath], output, "image-build");
            var arguments = new List<object>();
            var context = new CommandLineArgsCallbackContext(arguments, migration) { ExecutionContext = execution };
            foreach (var callback in migration.Annotations.OfType<CommandLineArgsCallbackAnnotation>())
            {
                await callback.Callback(context);
            }
            // The SQL fixture is portable. Execute the actual packaged image and launcher
            // against a local SQLite file, independently of any Azure account or DB server.
            var command = new List<string>
            {
                "run", "--rm", "--name", container, "--mount", $"type=bind,source={data},target=/verification",
                "--env", "APP_CONNSTRING=Data Source=/verification/demo.db", "--env", "DATABASE_TYPE=sqlite",
                "--env", "CREATE_DATABASE=false", "--env", "ENVIRONMENT=PRODUCTION",
                "--env", "GRATE_OUTPUT_PATH=/tmp/grate-output", "--env", "DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp/dotnet-bundle",
                "--entrypoint", migration.Entrypoint ?? "/bin/sh"
            };
            if (!OperatingSystem.IsWindows())
            {
                var user = (await Run("id", ["-u"], output, "user")).Trim();
                var group = (await Run("id", ["-g"], output, "group")).Trim();
                command.AddRange(["--user", $"{user}:{group}"]);
            }
            command.Add(image);
            command.AddRange(arguments.Select(value => value as string
                ?? throw new InvalidOperationException("The image check requires the actual literal migration arguments.")));
            await Run("docker", command, output, "image-migration");
            await using var connection = new SqliteConnection($"Data Source={Path.Combine(data, "demo.db")};Pooling=False");
            await connection.OpenAsync();
            await using var query = connection.CreateCommand();
            query.CommandText = "SELECT message FROM aspire_demo WHERE id = 2";
            Require((string?)await query.ExecuteScalarAsync() == "PRODUCTION", "The packaged image must select the explicit PRODUCTION SQL.");
            query.CommandText = "SELECT COUNT(*) FROM aspire_demo";
            Require((long)(await query.ExecuteScalarAsync() ?? 0L) == 2, "Both packaged migration scripts must execute exactly once.");
            query.CommandText = "SELECT COUNT(*) FROM grate_ScriptsRun WHERE script_name LIKE '%ENV.LOCAL%'";
            Require((long)(await query.ExecuteScalarAsync() ?? 0L) == 0, "LOCAL SQL must not run in the deployment environment.");
            Console.WriteLine("PASS: derived grate 2.3.0 image executed its packaged SQL and selected PRODUCTION scripts.");
        }
        finally
        {
            await Run("docker", ["rm", "--force", container], output, "container-cleanup", allowFailure: true);
            await Run("docker", ["image", "rm", "--force", image], output, "image-cleanup", allowFailure: true);
        }
    }

    internal static void VerifyArtifacts(string output)
    {
        var files = Directory.GetFiles(output, "*.bicep", SearchOption.AllDirectories);
        var applications = files.Select(File.ReadAllText).Where(text => text.Contains("'Microsoft.App/containerApps@", StringComparison.Ordinal)).ToArray();
        Require(applications.Length == 1, "The migration must not create a separate ACA application.");
        Require(!files.Select(File.ReadAllText).Any(text => text.Contains("Microsoft.App/jobs@", StringComparison.Ordinal)),
            "The init-container publisher must not create a separate ACA job.");
        var template = applications[0];
        Require(SecureConnectionParameter().IsMatch(template), "The database connection parameter must be secure.");
        var initStart = template.IndexOf("initContainers:", StringComparison.Ordinal);
        var primaryStart = template.IndexOf("      containers:", initStart, StringComparison.Ordinal);
        Require(initStart >= 0 && primaryStart > initStart, "The ACA template must contain an init container before its primary container.");
        var init = template[initStart..primaryStart];
        var primary = template[primaryStart..];
        Require(init.Contains("image: appdb_grate_containerimage", StringComparison.Ordinal), "The init container must use the built migration image.");
        Require(init.Contains("name: 'APP_CONNSTRING'\n              secretRef:", StringComparison.Ordinal), "The init connection must use a native secret reference.");
        Require(init.Contains("name: 'ENVIRONMENT'\n              value: 'PRODUCTION'", StringComparison.Ordinal), "The init container must use the explicit deployment environment.");
        Require(init.Contains("'/bin/sh'", StringComparison.Ordinal) && init.Contains("exec /app/grate", StringComparison.Ordinal), "The published init container must keep the finite launcher.");
        Require(!primary.Contains("GRATE_INIT_", StringComparison.Ordinal) && !primary.Contains("name: 'APP_CONNSTRING'", StringComparison.Ordinal),
            "Init staging variables must not leak into the primary container.");
        Require(template.Contains("registries:", StringComparison.Ordinal) && template.Contains("userAssignedIdentities:", StringComparison.Ordinal),
            "The application must retain access to its native registry and pull identity.");
    }

    internal static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static async Task<string> Run(string executable, IEnumerable<string> arguments, string output, string logName, bool allowFailure = false)
    {
        var start = new ProcessStartInfo(executable) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }
        using var process = Process.Start(start) ?? throw new InvalidOperationException($"Could not start {executable}.");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(4));
        try
        {
            await process.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            throw new TimeoutException($"{executable} exceeded the publication-check timeout.");
        }
        var standardOutput = await stdout;
        await File.WriteAllTextAsync(Path.Combine(output, $"{logName}.log"), standardOutput + await stderr);
        if (process.ExitCode != 0 && !allowFailure)
        {
            throw new InvalidOperationException($"{executable} failed during {logName}; see the local verification output.");
        }
        return standardOutput;
    }

    [GeneratedRegex(@"@secure\(\)\s+param appdb_connectionstring string")]
    private static partial Regex SecureConnectionParameter();
}
