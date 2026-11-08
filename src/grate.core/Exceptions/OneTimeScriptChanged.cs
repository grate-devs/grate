using grate.Configuration;

namespace grate.Exceptions;

public class OneTimeScriptChanged : MigrationException
{
    public OneTimeScriptChanged(MigrationsFolder folder, string file, string errorMessage)
        : base(folder, file, errorMessage)
    {
    }
}
