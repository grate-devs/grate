namespace TestCommon.TestInfrastructure;

public interface ITestDatabase
{
    string AdminConnectionString { get; }
    string ConnectionString(string database);
    string UserConnectionString(string database);

    /// <summary>
    /// An external representation of the database. Returns this instance by default,
    /// mostly used to be able to access Docker containers both from the outside and the internal docker network
    /// (from the inside when testing grate in a docker image, from the outside when performing assertions on the
    /// _database_ container from the unit tests afterwards)
    /// </summary>
    public ITestDatabase External => this;
}
