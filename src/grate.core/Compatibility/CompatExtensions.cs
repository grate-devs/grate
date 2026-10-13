using System.Data.Common;

namespace grate.Compatibility;

/// <summary>
/// Cross-target compatibility helpers. On modern .NET targets these forward to the BCL;
/// on netstandard2.0 (consumed by .NET Framework 4.8) they provide a hand-written equivalent.
/// </summary>
internal static class PathCompat
{
    public static string GetRelativePath(string relativeTo, string path)
    {
#if NETSTANDARD2_0
        return NetStandardPath.GetRelativePath(relativeTo, path);
#else
        return Path.GetRelativePath(relativeTo, path);
#endif
    }
}

internal static class FileCompat
{
    public static Task<string> ReadAllTextAsync(string path, CancellationToken cancellationToken = default)
    {
#if NETSTANDARD2_0
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(File.ReadAllText(path));
#else
        return File.ReadAllTextAsync(path, cancellationToken);
#endif
    }

    public static Task WriteAllTextAsync(string path, string contents, CancellationToken cancellationToken = default)
    {
#if NETSTANDARD2_0
        cancellationToken.ThrowIfCancellationRequested();
        File.WriteAllText(path, contents);
        return Task.CompletedTask;
#else
        return File.WriteAllTextAsync(path, contents, cancellationToken);
#endif
    }
}

internal static class DbExceptionExtensions
{
    /// <summary>
    /// Whether the error is transient/retryable. <see cref="DbException.IsTransient"/> only exists from
    /// .NET 5 onward; on netstandard2.0 there is no framework-agnostic way to determine this, so we
    /// conservatively report <c>false</c> (errors are treated as non-transient and are not retried).
    /// </summary>
    public static bool IsTransientError(this DbException ex)
    {
#if NETSTANDARD2_0
        return false;
#else
        return ex.IsTransient;
#endif
    }
}

#if NETSTANDARD2_0
/// <summary>
/// Exposes <c>StringSplitOptions.TrimEntries</c> (added in .NET 5) as a compile-time constant so that
/// call sites using <c>using static</c> keep compiling on netstandard2.0. The extensions below honour it.
/// </summary>
internal static class StringSplitOptionsShim
{
    public const System.StringSplitOptions None = System.StringSplitOptions.None;
    public const System.StringSplitOptions RemoveEmptyEntries = System.StringSplitOptions.RemoveEmptyEntries;
    public const System.StringSplitOptions TrimEntries = (System.StringSplitOptions)2;
}

internal static class NetStandardStringExtensions
{
    private const System.StringSplitOptions TrimEntries = (System.StringSplitOptions)2;

    private static string[] ApplyOptions(string[] parts, System.StringSplitOptions options)
    {
        if ((options & TrimEntries) == 0)
        {
            return parts;
        }

        // netstandard2.0's String.Split does not understand TrimEntries, so trim (and re-drop empties) ourselves.
        var trimmed = new System.Collections.Generic.List<string>(parts.Length);
        foreach (var part in parts)
        {
            var t = part.Trim();
            if ((options & System.StringSplitOptions.RemoveEmptyEntries) != 0 && t.Length == 0) continue;
            trimmed.Add(t);
        }
        return trimmed.ToArray();
    }

    public static string[] Split(this string value, char separator, System.StringSplitOptions options)
        => ApplyOptions(value.Split(new[] { separator }, options & ~TrimEntries), options);

    public static string[] Split(this string value, string separator, System.StringSplitOptions options = System.StringSplitOptions.None)
        => ApplyOptions(value.Split(new[] { separator }, options & ~TrimEntries), options);

    public static string[] Split(this string value, char separator, int count, System.StringSplitOptions options = System.StringSplitOptions.None)
        => ApplyOptions(value.Split(new[] { separator }, count, options & ~TrimEntries), options);

    public static string Replace(this string value, string oldValue, string newValue, System.StringComparison comparisonType)
    {
        if (string.IsNullOrEmpty(oldValue)) return value;

        var result = new System.Text.StringBuilder();
        int previous = 0;
        int index;
        while ((index = value.IndexOf(oldValue, previous, comparisonType)) >= 0)
        {
            result.Append(value, previous, index - previous);
            result.Append(newValue);
            previous = index + oldValue.Length;
        }
        result.Append(value, previous, value.Length - previous);
        return result.ToString();
    }
}

internal static class NetStandardPath
{
    // Faithful re-implementation of .NET's Path.GetRelativePath for the file-system paths grate deals with.
    public static string GetRelativePath(string relativeTo, string path)
    {
        relativeTo = Path.GetFullPath(relativeTo);
        path = Path.GetFullPath(path);

        var relativeParts = relativeTo.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            .Split(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, System.StringSplitOptions.RemoveEmptyEntries);
        var pathParts = path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            .Split(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, System.StringSplitOptions.RemoveEmptyEntries);

        var comparison = System.StringComparison.OrdinalIgnoreCase;
        int common = 0;
        while (common < relativeParts.Length && common < pathParts.Length
               && string.Equals(relativeParts[common], pathParts[common], comparison))
        {
            common++;
        }

        if (common == 0)
        {
            // No shared root (e.g. different drives) — cannot build a relative path.
            return path;
        }

        var segments = new System.Collections.Generic.List<string>();
        for (int i = common; i < relativeParts.Length; i++)
        {
            segments.Add("..");
        }
        for (int i = common; i < pathParts.Length; i++)
        {
            segments.Add(pathParts[i]);
        }

        return segments.Count == 0 ? "." : string.Join(Path.DirectorySeparatorChar.ToString(), segments);
    }
}

internal static class DbCompatExtensions
{
    public static Task CloseAsync(this DbConnection connection)
    {
        connection.Close();
        return Task.CompletedTask;
    }
}
#endif
