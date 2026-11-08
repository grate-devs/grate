using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Microsoft.Build.Framework;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

// Publishing uses the SDK's MSBuild runtime, without an extra PowerShell install.
// The PowerShell audit entry point invokes this same engine.
public sealed class GenerateDependencyNoticesTask : Microsoft.Build.Utilities.Task
{
    [Required] public ITaskItem[] AssetsFiles { get; set; }
    [Required] public string OutputDirectory { get; set; }
    [Required] public string RepositoryRoot { get; set; }
    [Required] public string SourceDirectory { get; set; }
    public ITaskItem[] PackageRoots { get; set; } = Array.Empty<ITaskItem>();
    public bool AllowMissingLicenseEvidence { get; set; }

    private sealed class Package
    {
        public JObject Metadata;
        public SortedDictionary<string, string> Texts = new SortedDictionary<string, string>(StringComparer.Ordinal);
        public SortedSet<string> Projects = new SortedSet<string>(StringComparer.Ordinal);
        public SortedSet<string> Contexts = new SortedSet<string>(StringComparer.Ordinal);
        public SortedSet<string> AssetKinds = new SortedSet<string>(StringComparer.Ordinal);
    }

    private static string Hash(byte[] bytes)
    {
        using (var algorithm = SHA256.Create())
        {
            return BitConverter.ToString(algorithm.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }
    }

    private static string PackageFile(string directory, string relative)
    {
        var root = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var path = Path.GetFullPath(Path.Combine(directory, relative));
        var comparison = Path.DirectorySeparatorChar == '\\' ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (!path.StartsWith(root, comparison))
        {
            throw new InvalidOperationException("Package file escapes its directory: " + relative);
        }
        if (!File.Exists(path))
        {
            throw new InvalidOperationException("Required package file is missing: " + path);
        }
        return path;
    }

    private static string XmlValue(XElement parent, string name)
    {
        return (string)parent.Elements().FirstOrDefault(element => element.Name.LocalName == name) ?? "";
    }

    private static bool IsLicense(string name)
    {
        return Regex.IsMatch(Path.GetFileName(name), @"^(licen[cs]e|copying)([._-].*)?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }

    private Package ReadPackage(string key, JObject entry, IEnumerable<string> roots, JObject cache)
    {
        var directory = roots.Where(root => !string.IsNullOrEmpty(root))
            .Select(root => Path.Combine(root, (string)entry["path"]))
            .FirstOrDefault(Directory.Exists);
        if (directory == null)
        {
            throw new InvalidOperationException("Restored package unavailable: " + key + ". Restore first or pass -PackageRoot.");
        }
        var specs = Directory.GetFiles(directory, "*.nuspec");
        if (specs.Length != 1)
        {
            throw new InvalidOperationException("Expected one nuspec for " + key);
        }
        var metadata = XDocument.Load(specs[0]).Descendants().First(element => element.Name.LocalName == "metadata");
        var licenseNode = metadata.Elements().FirstOrDefault(element => element.Name.LocalName == "license");
        var missingDeclaration = licenseNode == null || string.IsNullOrWhiteSpace(licenseNode.Value);
        if (missingDeclaration && !AllowMissingLicenseEvidence)
        {
            throw new InvalidOperationException("No declared license for " + key + "; inspect the exact package before distributing it.");
        }
        var type = missingDeclaration ? "" : (string)licenseNode.Attribute("type") ?? "";
        var license = missingDeclaration ? "" : licenseNode.Value.Trim();
        var package = new Package();
        if (type == "file")
        {
            package.Texts[license] = File.ReadAllText(PackageFile(directory, license));
        }
        else if (type != "expression" && !missingDeclaration)
        {
            throw new InvalidOperationException("Unknown license declaration type for " + key + ": " + type);
        }
        var files = entry["files"] == null ? Array.Empty<string>() : entry["files"].Values<string>().ToArray();
        if (files.Length == 0)
        {
            files = Directory.GetFiles(directory, "*", SearchOption.AllDirectories)
                .Select(file => file.Substring(directory.TrimEnd(Path.DirectorySeparatorChar).Length + 1)).ToArray();
        }
        foreach (var relative in files)
        {
            if (Regex.IsMatch(Path.GetFileName(relative), @"^(licen[cs]e|copying|copyright|notice|third[-_. ]?party[-_. ]?notices?)([._-].*)?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            {
                package.Texts[relative] = File.ReadAllText(PackageFile(directory, relative));
            }
        }
        var repository = metadata.Elements().FirstOrDefault(element => element.Name.LocalName == "repository");
        var commit = repository == null ? "" : (string)repository.Attribute("commit") ?? "";
        var evidence = missingDeclaration ? "missing-license-declaration" : "package";
        if (missingDeclaration)
        {
            Log.LogWarning("No declared license for " + key + "; inspect its legacy license URL and exact package.");
        }
        var sources = new JArray();
        if (type == "expression" && !package.Texts.Keys.Any(IsLicense))
        {
            var source = cache.GetValue(key, StringComparison.OrdinalIgnoreCase) as JObject;
            if (source != null)
            {
                var texts = source["texts"] as JArray;
                if (texts == null || texts.Count == 0)
                {
                    throw new InvalidOperationException("Source license cache contains no original texts: " + key);
                }
                if ((string)source["repositoryCommit"] != commit)
                {
                    throw new InvalidOperationException("Source license cache commit differs from nuspec: " + key);
                }
                foreach (var text in texts)
                {
                    var path = PackageFile(SourceDirectory, (string)text["file"]);
                    if (Hash(File.ReadAllBytes(path)) != (string)text["sha256"])
                    {
                        throw new InvalidOperationException("Source license cache hash mismatch: " + key + " " + (string)text["file"]);
                    }
                    package.Texts[(string)text["url"]] = File.ReadAllText(path);
                    sources.Add(text.DeepClone());
                }
                evidence = "source-cache";
            }
            else if (AllowMissingLicenseEvidence)
            {
                evidence = "missing-source";
                Log.LogWarning("Original license text unavailable for " + key);
            }
            else
            {
                throw new InvalidOperationException("Original license text unavailable for " + key + ". Populate scripts/licenses/sources.json from its exact upstream source.");
            }
        }
        var id = XmlValue(metadata, "id");
        var version = XmlValue(metadata, "version");
        package.Metadata = new JObject
        {
            ["id"] = id,
            ["version"] = version,
            ["licenseType"] = type,
            ["license"] = license,
            ["licenseUrl"] = missingDeclaration ? XmlValue(metadata, "licenseUrl") : type == "expression" ? "https://licenses.nuget.org/" + license : "https://www.nuget.org/packages/" + id + "/" + version + "/License",
            ["authors"] = XmlValue(metadata, "authors"),
            ["copyright"] = XmlValue(metadata, "copyright"),
            ["repository"] = repository == null ? "" : (string)repository.Attribute("url") ?? "",
            ["repositoryCommit"] = commit,
            ["packageSha512"] = (string)entry["sha512"] ?? "",
            ["evidence"] = evidence,
            ["sources"] = sources
        };
        return package;
    }

    private void Export()
    {
        var packages = new SortedDictionary<string, Package>(StringComparer.OrdinalIgnoreCase);
        var cachePath = Path.Combine(SourceDirectory, "sources.json");
        var cache = File.Exists(cachePath) ? JObject.Parse(File.ReadAllText(cachePath)) : new JObject();
        foreach (var item in AssetsFiles)
        {
            var assets = JObject.Parse(File.ReadAllText(item.ItemSpec));
            var project = (string)assets.SelectToken("project.restore.projectName");
            if (string.IsNullOrEmpty(project) || !(assets["targets"] is JObject) || !(assets["libraries"] is JObject))
            {
                throw new InvalidOperationException("Not a restored NuGet assets file: " + item.ItemSpec);
            }
            var projectPath = ((string)assets.SelectToken("project.restore.projectPath") ?? "").Replace('\\', '/');
            var scope = projectPath.IndexOf("/unittests/", StringComparison.OrdinalIgnoreCase) >= 0 ? "test"
                : projectPath.IndexOf("/examples/", StringComparison.OrdinalIgnoreCase) >= 0 ? "example" : "product";
            var roots = PackageRoots.Select(root => root.ItemSpec)
                .Concat(((JObject)assets["packageFolders"]).Properties().Select(property => property.Name)).ToArray();
            var direct = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var entries = new Dictionary<string, JObject>(StringComparer.OrdinalIgnoreCase);
            foreach (var library in ((JObject)assets["libraries"]).Properties())
            {
                if ((string)library.Value["type"] == "package")
                {
                    entries[library.Name] = (JObject)library.Value;
                }
            }
            foreach (var framework in ((JObject)assets.SelectToken("project.frameworks")).Properties())
            {
                var dependencies = framework.Value["dependencies"] as JObject;
                if (dependencies != null)
                {
                    foreach (var dependency in dependencies.Properties())
                    {
                        direct.Add(dependency.Name);
                    }
                }
                foreach (var download in (framework.Value["downloadDependencies"] as JArray) ?? new JArray())
                {
                    var match = Regex.Match((string)download["version"], @"^\[([^,\[\]]+)(?:,\s*\1)?\]$");
                    if (!match.Success)
                    {
                        throw new InvalidOperationException("Non-exact download dependency: " + download);
                    }
                    var key = (string)download["name"] + "/" + match.Groups[1].Value;
                    if (!entries.ContainsKey(key))
                    {
                        entries[key] = new JObject { ["path"] = key.ToLowerInvariant(), ["files"] = new JArray() };
                    }
                }
            }
            foreach (var entry in entries)
            {
                if (!packages.ContainsKey(entry.Key))
                {
                    packages[entry.Key] = ReadPackage(entry.Key, entry.Value, roots, cache);
                }
                var package = packages[entry.Key];
                package.Projects.Add(project);
                package.Contexts.Add(scope + "/" + project + "/" + (direct.Contains((string)package.Metadata["id"]) ? "direct" : "transitive/download"));
                foreach (var target in ((JObject)assets["targets"]).Properties())
                {
                    var reference = target.Value[entry.Key] as JObject;
                    if (reference == null)
                    {
                        continue;
                    }
                    foreach (var kind in new[] { "compile", "runtime", "runtimeTargets", "native", "build", "buildTransitive", "contentFiles" })
                    {
                        if (reference[kind] != null)
                        {
                            package.AssetKinds.Add(kind);
                        }
                    }
                }
                if (entry.Value["type"] == null)
                {
                    package.AssetKinds.Add("sdk-download");
                }
                if ((entry.Value["files"] as JArray ?? new JArray()).Values<string>().Any(file => file.StartsWith("analyzers/", StringComparison.Ordinal)))
                {
                    package.AssetKinds.Add("analyzer");
                }
            }
        }
        WriteOutput(packages);
    }

    private void WriteOutput(SortedDictionary<string, Package> packages)
    {
        var notice = new StringBuilder();
        notice.AppendLine("grate — third-party licenses and notices\n");
        notice.AppendLine("grate source is MIT-licensed. Dependencies retain their own licenses below.");
        notice.AppendLine("This inventory includes restored build/runtime dependencies across the selected frameworks.");
        notice.AppendLine("A reference does not mean every package asset is shipped on every platform.");
        notice.AppendLine("These metadata and texts do not certify legal compliance.\n");
        notice.AppendLine(File.ReadAllText(Path.Combine(RepositoryRoot, "LICENSE")));
        var inventory = new JArray();
        var texts = new SortedDictionary<string, Tuple<string, SortedSet<string>>>(StringComparer.Ordinal);
        foreach (var package in packages.Values)
        {
            var data = package.Metadata;
            notice.AppendLine("=== " + (string)data["id"] + " " + (string)data["version"] + " ===");
            notice.AppendLine("License: " + (string)data["license"]);
            notice.AppendLine("License reference: " + (string)data["licenseUrl"]);
            notice.AppendLine("Authors: " + (string)data["authors"]);
            notice.AppendLine("Copyright: " + (string)data["copyright"]);
            notice.AppendLine("License text evidence: " + (string)data["evidence"]);
            var references = new JArray();
            foreach (var text in package.Texts)
            {
                var content = text.Value.Replace("\r\n", "\n").Trim();
                var hash = Hash(Encoding.UTF8.GetBytes(content));
                if (!texts.ContainsKey(hash))
                {
                    texts[hash] = Tuple.Create(content, new SortedSet<string>(StringComparer.Ordinal));
                }
                texts[hash].Item2.Add((string)data["id"] + "/" + (string)data["version"] + ": " + text.Key);
                notice.AppendLine("Full text: SHA256 " + hash + " (" + text.Key + ")");
                references.Add(new JObject { ["file"] = text.Key, ["sha256"] = hash });
            }
            notice.AppendLine();
            data["projects"] = new JArray(package.Projects);
            data["contexts"] = new JArray(package.Contexts);
            data["assetKinds"] = new JArray(package.AssetKinds);
            data["texts"] = references;
            inventory.Add(data);
        }
        foreach (var text in texts)
        {
            notice.AppendLine("=== Full text SHA256 " + text.Key + " ===");
            notice.AppendLine(string.Join("\n", text.Value.Item2));
            notice.AppendLine();
            notice.AppendLine(text.Value.Item1);
            notice.AppendLine();
        }
        Directory.CreateDirectory(OutputDirectory);
        File.WriteAllText(Path.Combine(OutputDirectory, "THIRD-PARTY-NOTICES.txt"), notice.ToString().Replace("\r\n", "\n"), new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(OutputDirectory, "dependency-licenses.json"), inventory.ToString(Formatting.Indented).Replace("\r\n", "\n") + "\n", new UTF8Encoding(false));
        Log.LogMessage(MessageImportance.High, "Exported licenses and original notices for " + packages.Count + " packages to " + OutputDirectory + ".");
    }

    public override bool Execute()
    {
        try
        {
            Export();
            return true;
        }
        catch (Exception exception)
        {
            Log.LogErrorFromException(exception, false);
            return false;
        }
    }
}
