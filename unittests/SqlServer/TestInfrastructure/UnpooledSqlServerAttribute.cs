namespace SqlServer.TestInfrastructure;

// This marker is source-linked with the fixture. It is inert in CLI/Docker
// assemblies, which do not install the ordinary SQL Server pooling hook.
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, Inherited = true)]
public sealed class UnpooledSqlServerAttribute : Attribute;
