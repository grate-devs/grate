namespace TestCommon.TestInfrastructure;

public record GrateTestConfig
{
    public string? AdminConnectionString { get; set; } = null!;
    public string? DockerImage { get; set; } = null!;
    public string? ApplicationDockerImage { get; set; }
    public string? DefaultApplicationDockerImage { get; set; }
    public bool ConnectToDockerInternal { get; set; }
}
