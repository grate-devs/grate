using System.Data.Common;
using grate.MariaDb.Migration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace MariaDB.TestInfrastructure;

public record InspectableMariaDbDatabase : MariaDbDatabase
{
    public InspectableMariaDbDatabase(IServiceProvider serviceProvider)
        : base(serviceProvider.GetRequiredService<ILogger<InspectableMariaDbDatabase>>())
    {
    }

    public DbConnection GetConnection() => base.Connection;
}
