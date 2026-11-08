using grate.Configuration;

namespace grate.Exceptions;

public abstract class MigrationException : Exception
{
    public MigrationException(MigrationsFolder folder, string file, string? message)
        : this(folder, file, message, null) { }

    public MigrationException(MigrationsFolder folder, string file, string? message, Exception? innerException)
        : base(message, innerException)
    {
        Folder = folder;
        File = file;
        _message = message;
    }

    public MigrationsFolder Folder { get; set; }
    public string File { get; set; }

    private readonly string? _message;

    public override string Message => $"{File}: {_message ?? InnerException?.Message}";
}
