using TestCommon.TestInfrastructure;

namespace BigQuery.TestInfrastructure;

[Collection(nameof(BigQueryGrateTestContext))]
public class BigQueryExternalDatabaseTests(BigQueryGrateTestContext context)
{
    [Fact]
    public async Task Drops_the_datasets_the_tests_named_when_the_tests_are_done()
    {
        // a project the tests use, as a real one would be - here the one the other tests use
        var external = new BigQueryExternalDatabase(new GrateTestConfig { AdminConnectionString = context.AdminConnectionString });
        var testContext = new BigQueryGrateTestContext(context.Migrator, external);
        var other = TestConfig.RandomDatabase();
        var named = TestConfig.RandomDatabase();
        await BigQueryDatabaseHelpers.CreateBigQueryDatabaseFromConnectionString(context.ConnectionString(other));
        await BigQueryDatabaseHelpers.CreateBigQueryDatabaseFromConnectionString(testContext.ConnectionString(named));

        await testContext.DisposeAsync();

        var datasets = (await context.GetBigQueryDatabases()).ToArray();
        Assert.DoesNotContain(named, datasets);
        Assert.Contains(other, datasets);
    }
}
