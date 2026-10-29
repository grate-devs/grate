namespace grate.Infrastructure;

internal interface IHashGenerator
{
    string Hash(string text);
    bool Matches(string text, string? storedHash);
}
