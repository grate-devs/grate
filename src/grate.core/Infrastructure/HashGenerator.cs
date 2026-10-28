using System.Security.Cryptography;
using System.Text;

namespace grate.Infrastructure;

internal class HashGenerator : IHashGenerator
{
    private const string WindowsLineEnding = "\r\n";
    private const string UnixLineEnding = "\n";
    private const string MacLineEnding = "\r";

    public string Hash(string text) => HashWithoutNormalizingLineEndings(NormalizeLineEndings(text));

    public bool Matches(string text, string? storedHash)
    {
        if (string.IsNullOrEmpty(storedHash))
        {
            return false;
        }

        var normalized = NormalizeLineEndings(text);

        // Older RoundhousE records predate LF normalization. Preserve the original
        // text for unchanged mixed endings, then try historical CRLF and CR forms.
        // Expand from LF so a CRLF pair cannot accidentally become two line breaks.
        return HashWithoutNormalizingLineEndings(normalized) == storedHash ||
               HashWithoutNormalizingLineEndings(text) == storedHash ||
               HashWithoutNormalizingLineEndings(normalized.Replace(UnixLineEnding, WindowsLineEnding)) == storedHash ||
               HashWithoutNormalizingLineEndings(normalized.Replace(UnixLineEnding, MacLineEnding)) == storedHash;
    }

    private static string NormalizeLineEndings(string text) => text
        .Replace(WindowsLineEnding, UnixLineEnding)
        .Replace(MacLineEnding, UnixLineEnding);

    private static string HashWithoutNormalizingLineEndings(string text)
    {
        var input = text.Replace(@"'", @"''");
        var messageBytes = Encoding.UTF8.GetBytes(input);
        var hash = ComputeHash(messageBytes);

        return Convert.ToBase64String(hash);
    }

    private static byte[] ComputeHash(byte[] messageBytes)
    {
#pragma warning disable CA5351
        // The code that's violating the rule is on this line.
        using var alg = MD5.Create(); // consider to use SHA256
#pragma warning restore CA5351
        alg.ComputeHash(messageBytes);
        return alg.Hash!;
    }
}
