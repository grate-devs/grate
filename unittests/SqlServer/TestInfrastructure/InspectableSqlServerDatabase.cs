using System.Data.Common;
using grate.SqlServer.Migration;
using Microsoft.Extensions.Logging;

namespace SqlServer.TestInfrastructure;

// ReSharper disable once ClassNeverInstantiated.Global
public record InspectableSqlServerDatabase(ILogger<InspectableSqlServerDatabase> logger) : SqlServerDatabase(logger)
{
    public DbConnection GetConnection() => base.Connection;
}
