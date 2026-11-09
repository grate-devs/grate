using System.Text;

namespace grate.Infrastructure;

internal static class LogText
{
    public static string ShowControlCharacters(string text, bool allowTabs = true)
    {
        StringBuilder? safe = null;
        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            if (character is '\u2028' or '\u2029' ||
                (char.IsControl(character) && character is not ('\r' or '\n') && (character != '\t' || !allowTabs)))
            {
                safe ??= new StringBuilder(text.Length).Append(text, 0, index);
                safe.Append($@"\u{(int)character:X4}");
            }
            else
            {
                safe?.Append(character);
            }
        }
        return safe?.ToString() ?? text;
    }
}
