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

    private sealed class LicenseDeclaration
    {
        public string Type;
        public string Text;
        public bool Missing;
    }

    private sealed class LicenseEvidence
    {
        public string Kind = "package";
        public JArray Sources = new JArray();
    }

    private sealed class ProjectAssets
    {
        public JObject Assets;
        public string Name;
        public string Scope;
        public string[] PackageRoots;
        public HashSet<string> DirectPackages;
        public Dictionary<string, JObject> Packages;
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

    private void Export()
    {
        var packages = new SortedDictionary<string, Package>(StringComparer.OrdinalIgnoreCase);
        var cache = ReadSourceCache();
        foreach (var item in AssetsFiles)
        {
            var project = ReadProjectAssets(item.ItemSpec);
            AddProjectPackages(packages, project, cache);
        }
        WriteOutput(packages);
    }

    private JObject ReadSourceCache()
    {
        var path = Path.Combine(SourceDirectory, "sources.json");
        return File.Exists(path) ? JObject.Parse(File.ReadAllText(path)) : new JObject();
    }

    private ProjectAssets ReadProjectAssets(string path)
    {
        var assets = JObject.Parse(File.ReadAllText(path));
        var name = (string)assets.SelectToken("project.restore.projectName");
        if (string.IsNullOrEmpty(name) || !(assets["targets"] is JObject) || !(assets["libraries"] is JObject))
        {
            throw new InvalidOperationException("Not a restored NuGet assets file: " + path);
        }
        var projectPath = ((string)assets.SelectToken("project.restore.projectPath") ?? "").Replace('\\', '/');
        return new ProjectAssets
        {
            Assets = assets,
            Name = name,
            Scope = ProjectScope(projectPath),
            PackageRoots = PackageRoots.Select(root => root.ItemSpec)
                .Concat(((JObject)assets["packageFolders"]).Properties().Select(folder => folder.Name)).ToArray(),
            DirectPackages = FindDirectPackages(assets),
            Packages = FindPackageEntries(assets)
        };
    }

    private static string ProjectScope(string path)
    {
        if (path.IndexOf("/unittests/", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return "test";
        }
        return path.IndexOf("/examples/", StringComparison.OrdinalIgnoreCase) >= 0 ? "example" : "product";
    }

    private static HashSet<string> FindDirectPackages(JObject assets)
    {
        var direct = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var framework in ((JObject)assets.SelectToken("project.frameworks")).Properties())
        {
            var dependencies = framework.Value["dependencies"] as JObject;
            if (dependencies == null)
            {
                continue;
            }
            foreach (var dependency in dependencies.Properties())
            {
                direct.Add(dependency.Name);
            }
        }
        return direct;
    }

    private static Dictionary<string, JObject> FindPackageEntries(JObject assets)
    {
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
            AddDownloadDependencies(entries, framework.Value["downloadDependencies"] as JArray);
        }
        return entries;
    }

    private static void AddDownloadDependencies(Dictionary<string, JObject> entries, JArray downloads)
    {
        foreach (var download in downloads ?? new JArray())
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

    private void AddProjectPackages(SortedDictionary<string, Package> packages, ProjectAssets project, JObject cache)
    {
        foreach (var entry in project.Packages)
        {
            if (!packages.ContainsKey(entry.Key))
            {
                packages[entry.Key] = ReadPackage(entry.Key, entry.Value, project.PackageRoots, cache);
            }
            RecordProjectUsage(packages[entry.Key], project, entry.Key, entry.Value);
        }
    }

    private static void RecordProjectUsage(Package package, ProjectAssets project, string key, JObject entry)
    {
        var relationship = project.DirectPackages.Contains((string)package.Metadata["id"]) ? "direct" : "transitive/download";
        package.Projects.Add(project.Name);
        package.Contexts.Add(project.Scope + "/" + project.Name + "/" + relationship);
        foreach (var kind in FindAssetKinds(project.Assets, key, entry))
        {
            package.AssetKinds.Add(kind);
        }
    }

    private static IEnumerable<string> FindAssetKinds(JObject assets, string key, JObject entry)
    {
        foreach (var target in ((JObject)assets["targets"]).Properties())
        {
            var reference = target.Value[key] as JObject;
            if (reference == null)
            {
                continue;
            }
            foreach (var kind in new[] { "compile", "runtime", "runtimeTargets", "native", "build", "buildTransitive", "contentFiles" })
            {
                if (reference[kind] != null)
                {
                    yield return kind;
                }
            }
        }
        if (entry["type"] == null)
        {
            yield return "sdk-download";
        }
        if ((entry["files"] as JArray ?? new JArray()).Values<string>().Any(file => file.StartsWith("analyzers/", StringComparison.Ordinal)))
        {
            yield return "analyzer";
        }
    }

    private Package ReadPackage(string key, JObject entry, IEnumerable<string> roots, JObject cache)
    {
        var directory = FindRestoredPackageDirectory(key, entry, roots);
        var metadata = ReadNuspecMetadata(key, directory);
        var license = ReadLicenseDeclaration(key, metadata);
        var package = new Package { Texts = ReadPackageLegalTexts(directory, entry, license) };
        var evidence = ResolveLicenseEvidence(key, metadata, license, package.Texts, cache);
        package.Metadata = CreatePackageRecord(entry, metadata, license, evidence);
        return package;
    }

    private static string FindRestoredPackageDirectory(string key, JObject entry, IEnumerable<string> roots)
    {
        var directory = roots.Where(root => !string.IsNullOrEmpty(root))
            .Select(root => Path.Combine(root, (string)entry["path"]))
            .FirstOrDefault(Directory.Exists);
        if (directory == null)
        {
            throw new InvalidOperationException("Restored package unavailable: " + key + ". Restore first or pass -PackageRoot.");
        }
        return directory;
    }

    private static XElement ReadNuspecMetadata(string key, string directory)
    {
        var specifications = Directory.GetFiles(directory, "*.nuspec");
        if (specifications.Length != 1)
        {
            throw new InvalidOperationException("Expected one nuspec for " + key);
        }
        return XDocument.Load(specifications[0]).Descendants().First(element => element.Name.LocalName == "metadata");
    }

    private LicenseDeclaration ReadLicenseDeclaration(string key, XElement metadata)
    {
        var node = metadata.Elements().FirstOrDefault(element => element.Name.LocalName == "license");
        var missing = node == null || string.IsNullOrWhiteSpace(node.Value);
        if (missing && !AllowMissingLicenseEvidence)
        {
            throw new InvalidOperationException("No declared license for " + key + "; inspect the exact package before distributing it.");
        }
        var type = missing ? "" : (string)node.Attribute("type") ?? "";
        if (!missing && type != "file" && type != "expression")
        {
            throw new InvalidOperationException("Unknown license declaration type for " + key + ": " + type);
        }
        return new LicenseDeclaration { Type = type, Text = missing ? "" : node.Value.Trim(), Missing = missing };
    }

    private static SortedDictionary<string, string> ReadPackageLegalTexts(string directory, JObject entry, LicenseDeclaration license)
    {
        var texts = new SortedDictionary<string, string>(StringComparer.Ordinal);
        if (license.Type == "file")
        {
            texts[license.Text] = File.ReadAllText(PackageFile(directory, license.Text));
        }
        foreach (var relative in PackageFiles(directory, entry))
        {
            if (Regex.IsMatch(Path.GetFileName(relative), @"^(licen[cs]e|copying|copyright|notice|third[-_. ]?party[-_. ]?notices?)([._-].*)?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            {
                texts[relative] = File.ReadAllText(PackageFile(directory, relative));
            }
        }
        return texts;
    }

    private static IEnumerable<string> PackageFiles(string directory, JObject entry)
    {
        var files = entry["files"] == null ? Array.Empty<string>() : entry["files"].Values<string>().ToArray();
        return files.Length > 0 ? files : Directory.GetFiles(directory, "*", SearchOption.AllDirectories)
            .Select(file => file.Substring(directory.TrimEnd(Path.DirectorySeparatorChar).Length + 1));
    }

    private LicenseEvidence ResolveLicenseEvidence(string key, XElement metadata, LicenseDeclaration license,
        SortedDictionary<string, string> texts, JObject cache)
    {
        var evidence = new LicenseEvidence();
        if (license.Missing)
        {
            evidence.Kind = "missing-license-declaration";
            Log.LogWarning("No declared license for " + key + "; inspect its legacy license URL and exact package.");
        }
        else if (license.Type == "expression" && !texts.Keys.Any(IsLicense))
        {
            var source = cache.GetValue(key, StringComparison.OrdinalIgnoreCase) as JObject;
            if (source != null)
            {
                AddCachedLicenseTexts(key, RepositoryAttribute(metadata, "commit"), source, texts, evidence);
            }
            else
            {
                RecordMissingSource(key, evidence);
            }
        }
        return evidence;
    }

    private void AddCachedLicenseTexts(string key, string commit, JObject source,
        SortedDictionary<string, string> packageTexts, LicenseEvidence evidence)
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
            packageTexts[(string)text["url"]] = File.ReadAllText(path);
            evidence.Sources.Add(text.DeepClone());
        }
        evidence.Kind = "source-cache";
    }

    private void RecordMissingSource(string key, LicenseEvidence evidence)
    {
        if (!AllowMissingLicenseEvidence)
        {
            throw new InvalidOperationException("Original license text unavailable for " + key + ". Populate scripts/licenses/sources.json from its exact upstream source.");
        }
        evidence.Kind = "missing-source";
        Log.LogWarning("Original license text unavailable for " + key);
    }

    private static JObject CreatePackageRecord(JObject entry, XElement metadata, LicenseDeclaration license, LicenseEvidence evidence)
    {
        var id = XmlValue(metadata, "id");
        var version = XmlValue(metadata, "version");
        var licenseUrl = license.Missing ? XmlValue(metadata, "licenseUrl")
            : license.Type == "expression" ? "https://licenses.nuget.org/" + license.Text
            : "https://www.nuget.org/packages/" + id + "/" + version + "/License";
        return new JObject
        {
            ["id"] = id,
            ["version"] = version,
            ["licenseType"] = license.Type,
            ["license"] = license.Text,
            ["licenseUrl"] = licenseUrl,
            ["authors"] = XmlValue(metadata, "authors"),
            ["copyright"] = XmlValue(metadata, "copyright"),
            ["repository"] = RepositoryAttribute(metadata, "url"),
            ["repositoryCommit"] = RepositoryAttribute(metadata, "commit"),
            ["packageSha512"] = (string)entry["sha512"] ?? "",
            ["evidence"] = evidence.Kind,
            ["sources"] = evidence.Sources
        };
    }

    private void WriteOutput(SortedDictionary<string, Package> packages)
    {
        var notice = CreateNoticeHeader();
        var inventory = new JArray();
        var texts = new SortedDictionary<string, Tuple<string, SortedSet<string>>>(StringComparer.Ordinal);
        foreach (var package in packages.Values)
        {
            var references = AppendPackageNotice(notice, package, texts);
            inventory.Add(AddUsageToRecord(package, references));
        }
        AppendSharedLicenseTexts(notice, texts);
        SaveDocuments(notice, inventory);
        Log.LogMessage(MessageImportance.High, "Exported licenses and original notices for " + packages.Count + " packages to " + OutputDirectory + ".");
    }

    private StringBuilder CreateNoticeHeader()
    {
        var notice = new StringBuilder();
        notice.AppendLine("grate — third-party licenses and notices\n");
        notice.AppendLine("grate source is MIT-licensed. Dependencies retain their own licenses below.");
        notice.AppendLine("This inventory includes restored build/runtime dependencies across the selected frameworks.");
        notice.AppendLine("A reference does not mean every package asset is shipped on every platform.");
        notice.AppendLine("These metadata and texts do not certify legal compliance.\n");
        notice.AppendLine(File.ReadAllText(Path.Combine(RepositoryRoot, "LICENSE")));
        return notice;
    }

    private static JArray AppendPackageNotice(StringBuilder notice, Package package,
        SortedDictionary<string, Tuple<string, SortedSet<string>>> texts)
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
            var hash = RegisterLicenseText(texts, package, text);
            notice.AppendLine("Full text: SHA256 " + hash + " (" + text.Key + ")");
            references.Add(new JObject { ["file"] = text.Key, ["sha256"] = hash });
        }
        notice.AppendLine();
        return references;
    }

    private static string RegisterLicenseText(SortedDictionary<string, Tuple<string, SortedSet<string>>> texts,
        Package package, KeyValuePair<string, string> text)
    {
        var content = text.Value.Replace("\r\n", "\n").Trim();
        var hash = Hash(Encoding.UTF8.GetBytes(content));
        if (!texts.ContainsKey(hash))
        {
            texts[hash] = Tuple.Create(content, new SortedSet<string>(StringComparer.Ordinal));
        }
        texts[hash].Item2.Add((string)package.Metadata["id"] + "/" + (string)package.Metadata["version"] + ": " + text.Key);
        return hash;
    }

    private static JObject AddUsageToRecord(Package package, JArray references)
    {
        package.Metadata["projects"] = new JArray(package.Projects);
        package.Metadata["contexts"] = new JArray(package.Contexts);
        package.Metadata["assetKinds"] = new JArray(package.AssetKinds);
        package.Metadata["texts"] = references;
        return package.Metadata;
    }

    private static void AppendSharedLicenseTexts(StringBuilder notice, SortedDictionary<string, Tuple<string, SortedSet<string>>> texts)
    {
        foreach (var text in texts)
        {
            notice.AppendLine("=== Full text SHA256 " + text.Key + " ===");
            notice.AppendLine(string.Join("\n", text.Value.Item2));
            notice.AppendLine();
            notice.AppendLine(text.Value.Item1);
            notice.AppendLine();
        }
    }

    private void SaveDocuments(StringBuilder notice, JArray inventory)
    {
        Directory.CreateDirectory(OutputDirectory);
        File.WriteAllText(Path.Combine(OutputDirectory, "THIRD-PARTY-NOTICES.txt"), notice.ToString().Replace("\r\n", "\n"), new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(OutputDirectory, "dependency-licenses.json"), inventory.ToString(Formatting.Indented).Replace("\r\n", "\n") + "\n", new UTF8Encoding(false));
    }

    private static string XmlValue(XElement parent, string name)
    {
        return (string)parent.Elements().FirstOrDefault(element => element.Name.LocalName == name) ?? "";
    }

    private static string RepositoryAttribute(XElement metadata, string name)
    {
        var repository = metadata.Elements().FirstOrDefault(element => element.Name.LocalName == "repository");
        return repository == null ? "" : (string)repository.Attribute(name) ?? "";
    }

    private static bool IsLicense(string name)
    {
        return Regex.IsMatch(Path.GetFileName(name), @"^(licen[cs]e|copying)([._-].*)?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
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

    private static string Hash(byte[] bytes)
    {
        using (var algorithm = SHA256.Create())
        {
            return BitConverter.ToString(algorithm.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }
    }
}
