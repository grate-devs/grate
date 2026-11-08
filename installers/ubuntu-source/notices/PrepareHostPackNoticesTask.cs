using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Build.Framework;
using Microsoft.Build.Utilities;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

// Ubuntu can supply runtime, reference and apphost packs directly from the SDK,
// leaving no downloadDependencies in project.assets.json. Use resolved MSBuild
// pack metadata, not assumptions about the installed SDK's default runtime.
public sealed class PrepareHostPackNoticesTask : Microsoft.Build.Utilities.Task
{
    [Required] public string ResolvedPacksFile { get; set; }
    [Required] public string SourceBuiltFeed { get; set; }
    [Required] public string OutputDirectory { get; set; }
    [Output] public ITaskItem[] PackFiles { get; set; }
    [Output] public string PackAssetsFile { get; set; }
    [Output] public string InstalledAppHost { get; set; }
    [Output] public string SourcePackAppHost { get; set; }
    [Output] public string DistributionNoticesFile { get; set; }

    private static string Run(string program, string arguments)
    {
        var start = new ProcessStartInfo(program, arguments)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        using (var process = Process.Start(start))
        {
            var output = process.StandardOutput.ReadToEnd();
            var error = process.StandardError.ReadToEnd();
            process.WaitForExit();
            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException(program + " failed: " + error);
            }
            return output;
        }
    }

    private static string HashFile(string file)
    {
        using (var stream = File.OpenRead(file))
        using (var algorithm = SHA256.Create())
        {
            return BitConverter.ToString(algorithm.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }
    }

    public override bool Execute()
    {
        try
        {
            var items = JObject.Parse(File.ReadAllText(ResolvedPacksFile))["Items"] as JObject;
            if (items == null)
            {
                throw new InvalidOperationException("Resolved MSBuild pack metadata is missing.");
            }
            var packagesRoot = Path.Combine(OutputDirectory, "installed-packs");
            var libraries = new JObject();
            var packageFiles = new List<ITaskItem>();
            var manifest = new JArray();
            var distributionPackages = new SortedSet<string>(StringComparer.Ordinal);
            var dotnetRoot = "";
            foreach (var category in new[] { "RuntimePack", "AppHostPack", "TargetingPack" })
            {
                var selected = items[category] as JArray;
                if (selected == null || selected.Count == 0)
                {
                    throw new InvalidOperationException("Resolved " + category + " metadata is missing.");
                }
                foreach (var pack in selected)
                {
                    var installedDirectory = (string)pack["PackageDirectory"];
                    if (string.IsNullOrEmpty(installedDirectory) || !Directory.Exists(installedDirectory))
                    {
                        throw new InvalidOperationException("Resolved SDK pack directory missing: " + pack);
                    }
                    var version = Path.GetFileName(installedDirectory.TrimEnd(Path.DirectorySeparatorChar));
                    var id = Path.GetFileName(Path.GetDirectoryName(installedDirectory));
                    if (category != "AppHostPack" && ((string)pack["NuGetPackageId"] != id || (string)pack["NuGetPackageVersion"] != version))
                    {
                        throw new InvalidOperationException("Resolved SDK pack identity differs from its directory: " + pack);
                    }
                    var fileName = id + "." + version + ".nupkg";
                    var matches = Directory.GetFiles(SourceBuiltFeed, "*", SearchOption.AllDirectories)
                        .Where(file => string.Equals(Path.GetFileName(file), fileName, StringComparison.OrdinalIgnoreCase)).ToArray();
                    if (matches.Length != 1)
                    {
                        throw new InvalidOperationException("Expected exact source-built SDK pack " + fileName + ", found " + matches.Length);
                    }
                    var relative = (id + "/" + version).ToLowerInvariant();
                    var destination = Path.Combine(packagesRoot, relative);
                    dotnetRoot = Path.GetDirectoryName(Path.GetDirectoryName(Path.GetDirectoryName(installedDirectory)));
                    var representative = category == "AppHostPack" ? (string)pack["Path"]
                        : Directory.GetFiles(installedDirectory, "*", SearchOption.AllDirectories).First();
                    if (representative.Any(char.IsWhiteSpace))
                    {
                        throw new InvalidOperationException("Unexpected whitespace in distribution pack path.");
                    }
                    var ownership = Run("dpkg-query", "--search " + representative).Trim();
                    var separator = ownership.IndexOf(": ", StringComparison.Ordinal);
                    if (separator < 1 || ownership.Contains("\n"))
                    {
                        throw new InvalidOperationException("Ambiguous distribution package ownership: " + ownership);
                    }
                    var owner = ownership.Substring(0, separator);
                    distributionPackages.Add(owner);
                    var item = new TaskItem(matches[0]);
                    item.SetMetadata("DestinationDirectory", destination);
                    packageFiles.Add(item);
                    libraries[id + "/" + version] = new JObject { ["type"] = "package", ["path"] = relative };
                    manifest.Add(new JObject
                    {
                        ["category"] = category,
                        ["id"] = id,
                        ["version"] = version,
                        ["distributionBinaryPackage"] = owner,
                        ["installedDirectory"] = installedDirectory,
                        ["sourceBuiltPackage"] = matches[0],
                        ["sourceBuiltPackageSha256"] = HashFile(matches[0])
                    });
                    if (category == "AppHostPack")
                    {
                        if (!string.IsNullOrEmpty(InstalledAppHost))
                        {
                            throw new InvalidOperationException("Expected exactly one selected apphost.");
                        }
                        InstalledAppHost = (string)pack["Path"];
                        SourcePackAppHost = Path.Combine(destination, (string)pack["PathInPackage"]);
                    }
                }
            }
            if (libraries.Count == 0 || string.IsNullOrEmpty(InstalledAppHost))
            {
                throw new InvalidOperationException("Selected runtime/reference/apphost pack metadata is incomplete.");
            }
            Directory.CreateDirectory(OutputDirectory);
            PackFiles = packageFiles.ToArray();
            PackAssetsFile = Path.Combine(OutputDirectory, "installed-sdk-packs.assets.json");
            var synthetic = new JObject
            {
                ["libraries"] = libraries,
                ["targets"] = new JObject(),
                ["packageFolders"] = new JObject { [packagesRoot] = new JObject() },
                ["project"] = new JObject
                {
                    ["restore"] = new JObject { ["projectName"] = "archive-resolved-sdk-packs", ["projectPath"] = PackAssetsFile },
                    ["frameworks"] = new JObject { ["net10.0"] = new JObject { ["dependencies"] = new JObject() } }
                }
            };
            File.WriteAllText(PackAssetsFile, synthetic.ToString(Formatting.Indented));
            File.WriteAllText(Path.Combine(OutputDirectory, "source-built-sdk-packs.json"), manifest.ToString(Formatting.Indented));
            var notice = new StringBuilder();
            notice.AppendLine("Ubuntu SDK distribution licenses and notices");
            notice.AppendLine("Includes source-package and build-only material; this does not imply every listed component is shipped.");
            var common = new SortedSet<string>(StringComparer.Ordinal);
            var distribution = new JArray();
            foreach (var owner in distributionPackages)
            {
                var metadata = Run("dpkg-query", "--show --showformat=${binary:Package}|${Version}|${source:Package}|${source:Version} " + owner).Trim();
                distribution.Add(metadata);
                notice.AppendLine("\n=== " + metadata + " ===");
                var packageName = owner.Split(':')[0];
                var copyright = File.ReadAllText("/usr/share/doc/" + packageName + "/copyright");
                notice.AppendLine(copyright);
                foreach (Match match in Regex.Matches(copyright, @"/usr/share/common-licenses/[A-Za-z0-9+_.-]+"))
                {
                    common.Add(match.Value.TrimEnd('.'));
                }
                var gzipNotice = "/usr/share/doc/" + packageName + "/NOTICE.txt.gz";
                if (File.Exists(gzipNotice))
                {
                    try
                    {
                        // Some SDK packages contain a dangling NOTICE symlink.
                        // Keep that provenance gap explicit; mandatory pack and
                        // dotnet-root license/TPN files are still read below.
                        using (File.OpenRead(gzipNotice))
                        {
                        }
                        notice.AppendLine(Run("gzip", "-dc " + gzipNotice));
                    }
                    catch (FileNotFoundException)
                    {
                        notice.AppendLine("Supplier NOTICE symlink has no target: " + gzipNotice);
                    }
                }
            }
            foreach (var file in new[] { Path.Combine(dotnetRoot, "LICENSE.txt"), Path.Combine(dotnetRoot, "ThirdPartyNotices.txt") }.Concat(common))
            {
                notice.AppendLine("\n=== " + file + " ===");
                notice.AppendLine(File.ReadAllText(file));
            }
            DistributionNoticesFile = Path.Combine(OutputDirectory, "ubuntu-distribution-notices.txt");
            File.WriteAllText(DistributionNoticesFile, notice.ToString());
            File.WriteAllText(Path.Combine(OutputDirectory, "ubuntu-distribution-packages.json"), distribution.ToString(Formatting.Indented));
            Log.LogMessage(MessageImportance.High, "Including notices from " + libraries.Count + " resolved SDK packs.");
            return true;
        }
        catch (Exception exception)
        {
            Log.LogErrorFromException(exception, false);
            return false;
        }
    }
}
