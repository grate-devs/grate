namespace grate.Configuration;

public partial class GrateConfigurationBuilder
{

    /// <summary>
    /// Create the grate configuration builder from an existing service collection and grate configuration.
    /// </summary>
    /// <param name="grateConfiguration">GrateConfiguration</param>
    /// <returns>GrateConfigurationBuilder</returns>
    public static GrateConfigurationBuilder Create(GrateConfiguration grateConfiguration)
    {
        return new GrateConfigurationBuilder(grateConfiguration);
    }

    /// <summary>
    /// Create the default grate configuration builder with existing service collection.
    /// </summary>
    /// <returns>GrateConfigurationBuilder</returns>
    public static GrateConfigurationBuilder Create()
    {
        return new GrateConfigurationBuilder(GrateConfiguration.Default with { NonInteractive = true });
    }

}

