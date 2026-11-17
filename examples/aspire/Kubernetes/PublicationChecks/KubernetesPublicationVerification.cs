using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Aspire.Hosting.ApplicationModel;
using YamlDotNet.RepresentationModel;

namespace Grate.Aspire.Example.Kubernetes;

internal static class KubernetesPublicationVerification
{
    internal const string DummyConnection = "Host=example.invalid;Database=appdb;Username=offline;Password=\"publication;check\\quoted\nvalue\";";
    private const string RenderedMigrationImage = "registry.example/grate/migration:publication-check";

    internal static async Task VerifyArtifacts(string output, KubernetesExampleResources resources)
    {
        var charts = Directory.GetFiles(output, "Chart.yaml", SearchOption.AllDirectories);
        Require(charts.Length == 1, "The native publisher must create exactly one Helm chart.");
        var chart = Path.GetDirectoryName(charts[0]) ?? throw new InvalidOperationException("The chart directory is missing.");
        var valuesFile = Path.Combine(chart, "values.yaml");
        var values = LoadSingle(await File.ReadAllTextAsync(valuesFile));
        var leaves = GetLeaves(values).ToArray();
        var modelEnvironment = new Dictionary<string, object>();
        var environmentContext = new EnvironmentCallbackContext(resources.Api.ApplicationBuilder.ExecutionContext,
            resources.Api.Resource, modelEnvironment, CancellationToken.None);
        foreach (var callback in resources.Api.Resource.Annotations.OfType<EnvironmentCallbackAnnotation>())
        {
            await callback.Callback(environmentContext);
        }
        var imageReference = modelEnvironment.Single(pair => pair.Value is ContainerImageReference image &&
            ReferenceEquals(image.Resource, resources.Migration.Resource));
        var migrationImage = leaves.SingleOrDefault(leaf => leaf.Path == $"config.api.{imageReference.Key.Replace('-', '_')}")
            ?? throw new InvalidOperationException("The chart must expose the native built-image reference as a deferred Helm value.");
        var apiImage = leaves.SingleOrDefault(leaf => leaf.Value.Value == resources.Api.Resource.Name + ":latest")
            ?? throw new InvalidOperationException("The chart must expose the native application image as a Helm value.");
        migrationImage.Value.Value = RenderedMigrationImage;
        foreach (var leaf in leaves.Where(leaf => leaf.Path.StartsWith("secrets.", StringComparison.Ordinal)))
        {
            leaf.Value.Value = DummyConnection;
        }
        var overridePath = Path.Combine(output, "verification-values.yaml");
        using (var writer = new StringWriter())
        {
            new YamlStream(new YamlDocument(values)).Save(writer, assignAnchors: false);
            await File.WriteAllTextAsync(overridePath, writer.ToString());
        }
        var helm = Environment.GetEnvironmentVariable("GRATE_HELM_PATH") ?? "helm";
        var version = await Run(helm, ["version", "--short"], output, "helm-version", TimeSpan.FromSeconds(30));
        var parsed = Regex.Match(version, @"v(\d+)\.(\d+)\.");
        Require(parsed.Success && (int.Parse(parsed.Groups[1].Value) > 4 ||
            int.Parse(parsed.Groups[1].Value) == 4 && int.Parse(parsed.Groups[2].Value) >= 2),
            "The pinned native Kubernetes deployment engine requires Helm 4.2 or newer.");
        await Run(helm, ["lint", chart, "--strict", "--values", overridePath], output, "helm-lint", TimeSpan.FromSeconds(60));
        var rendered = await Run(helm, ["template", "grate-publication", chart, "--values", overridePath],
            output, "helm-template", TimeSpan.FromSeconds(60));
        await File.WriteAllTextAsync(Path.Combine(output, "rendered.yaml"), rendered);
        var documents = LoadDocuments(rendered);
        await File.WriteAllTextAsync(Path.Combine(output, "rendered.json"), JsonSerializer.Serialize(
            documents.Select(ToObject), new JsonSerializerOptions { WriteIndented = true }));
        Require(!documents.Any(document => IsStandaloneMigration(document, resources.Migration.Resource.Name)),
            "The migration must not create a standalone workload or Service.");
        var deployment = documents.Single(document => Text(Get(document, "kind")) == "Deployment" &&
            Items(Get(document, "spec", "template", "spec", "containers")).Any(item => Text(Get(item, "name")) == "api"));
        var pod = Get(deployment, "spec", "template", "spec");
        var primary = Items(Get(pod, "containers")).Single(container => Text(Get(container, "name")) == "api");
        var init = Items(Get(pod, "initContainers")).Single(container => Text(Get(container, "name")) == resources.Migration.Resource.Name);
        Require(Text(Get(init, "image")) == RenderedMigrationImage, "The init container must use the native built-image Helm value.");
        Require(Scalars(Get(init, "command")).SequenceEqual(["/bin/sh"]), "The init container must retain the finite shell entrypoint.");
        var arguments = Scalars(Get(init, "args")).ToArray();
        Require(arguments.Length >= 4 && arguments[0] == "-c" && arguments[1].Contains("exec /app/grate", StringComparison.Ordinal),
            "The init container must retain the actual finite migration launcher and arguments.");
        var initEnvironment = ResolveEnvironment(init, documents);
        Require(initEnvironment["ENVIRONMENT"] == "PRODUCTION" && initEnvironment["DATABASE_TYPE"] == "postgresql",
            "The init environment must explicitly select PostgreSQL and PRODUCTION scripts.");
        var initConnection = Items(Get(init, "env")).Single(variable => Text(Get(variable, "name")) == "APP_CONNSTRING");
        var initSecretRef = Get(initConnection, "valueFrom", "secretKeyRef");
        Require(initEnvironment["APP_CONNSTRING"] == DummyConnection, "The native init secret reference must resolve through Helm values.");
        var primaryEnvironment = ResolveEnvironment(primary, documents);
        Require(primaryEnvironment["EXAMPLE_SETTING"] == "preserved", "Application configuration must survive init customization.");
        Require(Text(Get(primary, "readinessProbe", "httpGet", "path")) == "/health" &&
            Text(Get(primary, "readinessProbe", "httpGet", "scheme")) == "HTTP",
            "The native readiness probe must wait for the application listener before rollout readiness.");
        Require(primaryEnvironment["ConnectionStrings__appdb"] == DummyConnection,
            "The primary and init connection values must preserve quotes, backslashes and newlines exactly.");
        Require(!primaryEnvironment.Keys.Any(name => name.StartsWith("GRATE_INIT_", StringComparison.Ordinal)) &&
            !primaryEnvironment.ContainsKey("APP_CONNSTRING"), "Init staging variables must not leak through the primary env or envFrom maps.");
        Require(Text(Get(pod, "serviceAccountName")) == "grate-example" &&
            Text(Get(pod, "terminationGracePeriodSeconds")) == "17", "Application pod settings must remain intact.");
        Require(Items(Get(pod, "imagePullSecrets")).Any(secret => Text(Get(secret, "name")) == "registry-pull"),
            "The application must retain its image pull secret.");
        Require(Text(Get(deployment, "metadata", "labels", "grate-example")) == "preserved", "Application metadata must remain intact.");
        var primaryConnection = Items(Child(primary, "env")).FirstOrDefault(variable => Text(Get(variable, "name")) == "ConnectionStrings__appdb");
        var primarySecretRef = (primaryConnection is null ? FindEnvFromKey(primary, documents, "ConnectionStrings__appdb") :
            Get(primaryConnection, "valueFrom", "secretKeyRef"))
            ?? throw new InvalidOperationException("The API database connection must retain its own native secret reference.");
        var templates = Directory.GetFiles(Path.Combine(chart, "templates"), "*.yaml", SearchOption.AllDirectories);
        var connectionValue = GetSecretValuePath(templates, initSecretRef);
        var apiConnectionValue = GetSecretValuePath(templates, primarySecretRef);
        var podLabels = Get(deployment, "spec", "template", "metadata", "labels");
        var service = documents.Single(document => Text(Get(document, "kind")) == "Service" &&
            SelectorMatches(Child(Get(document, "spec"), "selector"), podLabels));
        var contract = new
        {
            ChartDirectory = chart,
            ApiImageValue = apiImage.Path,
            MigrationImageValue = migrationImage.Path,
            ConnectionValue = connectionValue,
            ApiConnectionValue = apiConnectionValue,
            ServiceAccountName = "grate-example",
            ImagePullSecretName = "registry-pull",
            DeploymentName = Text(Get(deployment, "metadata", "name")),
            ServiceName = Text(Get(service, "metadata", "name")),
            InitContainerName = resources.Migration.Resource.Name,
            Environment = "PRODUCTION"
        };
        await File.WriteAllTextAsync(Path.Combine(output, "runtime-contract.json"), JsonSerializer.Serialize(contract,
            new JsonSerializerOptions { WriteIndented = true }));
    }

    private static bool IsStandaloneMigration(YamlMappingNode document, string name) =>
        Text(Get(document, "kind")) is "Deployment" or "StatefulSet" or "Service" &&
        Text(Get(document, "metadata", "name")).Contains(name, StringComparison.Ordinal);

    private static bool SelectorMatches(YamlNode? selector, YamlNode labels) => selector is YamlMappingNode { Children.Count: > 0 } mapping &&
        mapping.Children.All(pair => Text(Child(labels, Text(pair.Key))) == Text(pair.Value));

    private static Dictionary<string, string> ResolveEnvironment(YamlNode container, IReadOnlyList<YamlMappingNode> documents)
    {
        var environment = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var source in Items(Child(container, "envFrom")))
        {
            var secret = Child(source, "secretRef");
            var reference = secret ?? Get(source, "configMapRef");
            var resource = documents.Single(document => Text(Get(document, "kind")) == (secret is null ? "ConfigMap" : "Secret") &&
                Text(Get(document, "metadata", "name")) == Text(Get(reference, "name")));
            foreach (var pair in ResourceData(resource).Children)
            {
                environment[Text(Child(source, "prefix")) + Text(pair.Key)] = ResourceValue(resource, pair.Value, secret is not null);
            }
        }
        foreach (var variable in Items(Child(container, "env")))
        {
            var literal = Child(variable, "value");
            if (literal is not null)
            {
                environment[Text(Get(variable, "name"))] = Text(literal);
                continue;
            }
            var valueFrom = Get(variable, "valueFrom");
            var secret = Child(valueFrom, "secretKeyRef");
            var reference = secret ?? Get(valueFrom, "configMapKeyRef");
            var resource = documents.Single(document => Text(Get(document, "kind")) == (secret is null ? "ConfigMap" : "Secret") &&
                Text(Get(document, "metadata", "name")) == Text(Get(reference, "name")));
            var data = Get(ResourceData(resource), Text(Get(reference, "key")));
            environment[Text(Get(variable, "name"))] = ResourceValue(resource, data, secret is not null);
        }
        return environment;
    }

    private static YamlNode? FindEnvFromKey(YamlNode container, IReadOnlyList<YamlMappingNode> documents, string key)
    {
        foreach (var source in Items(Child(container, "envFrom")))
        {
            if (Child(source, "secretRef") is not { } reference)
            {
                continue;
            }
            var name = Text(Get(reference, "name"));
            var secret = documents.Single(document => Text(Get(document, "kind")) == "Secret" && Text(Get(document, "metadata", "name")) == name);
            if (Child(ResourceData(secret), key) is not null)
            {
                return new YamlMappingNode { { "name", name }, { "key", key } };
            }
        }
        return null;
    }

    private static string GetSecretValuePath(IEnumerable<string> templates, YamlNode reference)
    {
        foreach (var template in templates)
        {
            var expressions = new List<string>();
            var normalized = NeutralizeHelm(File.ReadAllText(template), expressions);
            foreach (var document in LoadDocuments(normalized))
            {
                if (Text(Get(document, "kind")) != "Secret" || Text(Get(document, "metadata", "name")) != Text(Get(reference, "name")))
                {
                    continue;
                }
                var value = Text(Get(ResourceData(document), Text(Get(reference, "key"))));
                var token = Regex.Match(value, @"HELM_EXPRESSION_(\d+)");
                Require(token.Success, "The native secret must remain bound to a Helm parameter expression.");
                var expression = expressions[int.Parse(token.Groups[1].Value)];
                var path = Regex.Match(expression, @"\.Values\.([A-Za-z0-9_.]+)");
                Require(path.Success, "The native secret must use a structured Helm value path.");
                return path.Groups[1].Value;
            }
        }
        throw new InvalidOperationException("Could not locate the referenced native secret template.");
    }

    private static string NeutralizeHelm(string text, List<string> expressions)
    {
        var output = new StringBuilder();
        var position = 0;
        while (text.IndexOf("{{", position, StringComparison.Ordinal) is var start && start >= 0)
        {
            output.Append(text[position..start]);
            char? quote = null;
            var end = start + 2;
            for (; end < text.Length - 1; end++)
            {
                var current = text[end];
                if (quote is not null)
                {
                    if (quote == '"' && current == '\\')
                    {
                        end++;
                    }
                    else if (current == quote)
                    {
                        quote = null;
                    }
                }
                else if (current is '"' or '`')
                {
                    quote = current;
                }
                else if (current == '}' && text[end + 1] == '}')
                {
                    break;
                }
            }
            Require(end < text.Length - 1, "The native chart contains an unterminated Helm expression.");
            expressions.Add(text[start..(end + 2)]);
            output.Append($"HELM_EXPRESSION_{expressions.Count - 1}");
            position = end + 2;
        }
        output.Append(text[position..]);
        return output.ToString();
    }

    internal static async Task<string> Run(string executable, IEnumerable<string> arguments, string output, string logName, TimeSpan limit)
    {
        var start = new ProcessStartInfo(executable) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }
        using var process = Process.Start(start) ?? throw new InvalidOperationException($"Could not start {executable}.");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(limit);
        try
        {
            await process.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
            await process.WaitForExitAsync();
            await File.WriteAllTextAsync(Path.Combine(output, logName + ".log"), await stdout + await stderr);
            throw new TimeoutException($"{logName} exceeded the publication-check timeout.");
        }
        var text = await stdout;
        await File.WriteAllTextAsync(Path.Combine(output, logName + ".log"), text + await stderr);
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"{logName} failed; inspect the local publication-check diagnostics.");
        }
        return text;
    }

    internal static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static YamlMappingNode LoadSingle(string text) => LoadDocuments(text).Single();

    private static IReadOnlyList<YamlMappingNode> LoadDocuments(string text)
    {
        var yaml = new YamlStream();
        yaml.Load(new StringReader(text));
        return yaml.Documents.Select(document => document.RootNode).OfType<YamlMappingNode>().ToArray();
    }

    private static YamlMappingNode Mapping(YamlNode node) => node as YamlMappingNode
        ?? throw new InvalidOperationException("The native chart has an unexpected mapping structure.");

    private static YamlNode Get(YamlNode node, params string[] path)
    {
        foreach (var key in path)
        {
            node = Child(node, key) ?? throw new InvalidOperationException($"The native chart is missing '{key}'.");
        }
        return node;
    }

    private static YamlNode? Child(YamlNode? node, string key) => node is YamlMappingNode mapping &&
        mapping.Children.TryGetValue(new YamlScalarNode(key), out var child) ? child : null;

    private static string Text(YamlNode? node) => node is YamlScalarNode scalar ? scalar.Value ?? "" : "";

    private static IEnumerable<YamlNode> Items(YamlNode? node) => node is YamlSequenceNode sequence ? sequence.Children : [];

    private static IEnumerable<string> Scalars(YamlNode node) => Items(node).Select(Text);

    private static string Decode(YamlNode node) => Encoding.UTF8.GetString(Convert.FromBase64String(Text(node)));

    private static YamlMappingNode ResourceData(YamlNode resource) => Mapping(Child(resource, "stringData") ?? Get(resource, "data"));

    private static string ResourceValue(YamlNode resource, YamlNode value, bool secret) =>
        secret && Child(resource, "stringData") is null ? Decode(value) : Text(value);

    private static IEnumerable<YamlLeaf> GetLeaves(YamlMappingNode mapping, string prefix = "")
    {
        foreach (var pair in mapping.Children)
        {
            var path = prefix + Text(pair.Key);
            if (pair.Value is YamlMappingNode nested)
            {
                foreach (var leaf in GetLeaves(nested, path + "."))
                {
                    yield return leaf;
                }
            }
            else if (pair.Value is YamlScalarNode scalar)
            {
                yield return new YamlLeaf(path, scalar);
            }
        }
    }

    private static object? ToObject(YamlNode node) => node switch
    {
        YamlMappingNode mapping => mapping.Children.ToDictionary(pair => Text(pair.Key), pair => ToObject(pair.Value)),
        YamlSequenceNode sequence => sequence.Children.Select(ToObject).ToArray(),
        YamlScalarNode scalar => scalar.Value,
        _ => null
    };

    private sealed record YamlLeaf(string Path, YamlScalarNode Value);
}
