namespace TestCommon.TestInfrastructure;

public record SqlStatements
{
    public string SelectVersion { get; init; } = default!;
    public string? SleepTwoSeconds { get; init; }
    public Func<string?, string?, string?, string?> CreateUser { get; init; } = (_, _, _) => null;
    public Func<string?, string?, string?> GrantAccess { get; init; } = (_, _) => null;
    public string LineComment { get; init; } = "--";
}
