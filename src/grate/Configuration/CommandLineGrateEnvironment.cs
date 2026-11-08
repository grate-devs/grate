using System.Collections;
using grate.Infrastructure;

namespace grate.Configuration;

internal record CommandLineGrateEnvironment : GrateEnvironment, IEnumerable<string>, IEnumerable<GrateEnvironment>
{
    public CommandLineGrateEnvironment(string value) : base(value)
    {
    }

    public CommandLineGrateEnvironment(IEnumerable<string> environments) : base(environments)
    {
    }

    IEnumerator<GrateEnvironment> IEnumerable<GrateEnvironment>.GetEnumerator() =>
        new GrateEnvironment[] { this }.AsEnumerable().GetEnumerator();

    public IEnumerator<string> GetEnumerator() => Environments.GetEnumerator();
    IEnumerator IEnumerable.GetEnumerator() => Environments.GetEnumerator();

}
