using Dapper;
using grate.Configuration;
using Oracle.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace Oracle.Reported_issues;

[Collection(nameof(OracleGrateTestContext))]
public sealed class Package_scripts(OracleGrateTestContext testContext)
{
    private readonly IGrateTestContext _context = testContext;

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Creates_and_executes_a_package_with_division(bool useSqlPlusSeparator)
    {
        var database = TestConfig.RandomDatabase();
        var directory = TestConfig.CreateRandomTempDirectory();
        var configuration = new GrateConfiguration
        {
            CreateDatabase = true,
            AdminConnectionString = _context.AdminConnectionString,
            ConnectionString = _context.ConnectionString(database),
            NonInteractive = true,
            SqlFilesDirectory = directory,
            OutputPath = new DirectoryInfo(Path.Combine(directory.FullName, "output")),
            Folders = Folders.Default
        };

        // Map the synthetic schema to this test's isolated database.
        var sql = SamplePackage.Replace("EXAMPLE_SCHEMA.", database + ".", StringComparison.Ordinal);
        if (useSqlPlusSeparator)
        {
            sql = sql.Replace("\n;", "\n/", StringComparison.Ordinal);
        }
        TestConfig.WriteContent(TestConfig.Wrap(directory, "sprocs"), "001_calculation_helpers.sql", sql);

        try
        {
            await using (var migrator = _context.Migrator.WithConfiguration(configuration))
            {
                await migrator.Migrate();
            }

            using var connection = _context.CreateDbConnection(database);
            var objectTypes = (await connection.QueryAsync<string>(
                """
                SELECT object_type FROM user_objects
                WHERE object_name = 'CALCULATIONHELPERS' AND status = 'VALID'
                ORDER BY object_type
                """)).ToArray();
            Assert.Equal(["PACKAGE", "PACKAGE BODY"], objectTypes);

            var compilationErrors = await connection.QueryAsync<string>(
                "SELECT text FROM user_errors WHERE name = 'CALCULATIONHELPERS' AND attribute = 'ERROR' ORDER BY sequence");
            Assert.Empty(compilationErrors);

            Assert.Equal(20m, await connection.ExecuteScalarAsync<decimal>(
                "SELECT CalculationHelpers.CalculateScaledRatio(100, 5000) FROM dual"));
            Assert.Equal(25m, await connection.ExecuteScalarAsync<decimal>(
                "SELECT CalculationHelpers.CalculateRatio(100, 4) FROM dual"));
            Assert.Equal(50m, await connection.ExecuteScalarAsync<decimal>(
                "SELECT CalculationHelpers.CalculatePercentage(50, 100) FROM dual"));
            Assert.Equal(0m, await connection.ExecuteScalarAsync<decimal>(
                "SELECT CalculationHelpers.CalculateScaledRatio(100, 0) FROM dual"));
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    // Based on #642 with synthetic identifiers and Roundhouse's standalone semicolons.
    private const string SamplePackage = """
        CREATE OR REPLACE PACKAGE EXAMPLE_SCHEMA.CalculationHelpers IS
        cMAX_RESULT          NUMBER(16,2) DEFAULT 10000000;

        FUNCTION CalculateScaledRatio(
          Amount    IN  NUMBER,
          Quantity  IN  NUMBER
        ) RETURN NUMBER;


        FUNCTION CalculateRatio(
          Amount    IN  NUMBER,
          Divisor   IN  NUMBER
        ) RETURN NUMBER;


        FUNCTION CalculatePercentage(
          Quantity  IN  NUMBER,
          Total     IN  NUMBER
        ) RETURN NUMBER;


        END CalculationHelpers;
        ;


        CREATE OR REPLACE PACKAGE BODY EXAMPLE_SCHEMA.CalculationHelpers IS

        FUNCTION CalculateScaledRatio(
          Amount    IN  NUMBER,
          Quantity  IN  NUMBER
        )
          RETURN NUMBER
        IS
          ResultValue NUMBER;
        BEGIN

          IF (Quantity IS NULL OR Quantity = 0) THEN
            RETURN 0;
          END IF;

          ResultValue := ROUND((Amount * 1000) / Quantity, 2);

          IF ResultValue >= 10000 THEN
            RETURN 10000;
          ELSE
            RETURN ResultValue;
          END IF;
        END CalculateScaledRatio;


        FUNCTION CalculateRatio(
          Amount    IN  NUMBER,
          Divisor   IN  NUMBER
        )
          RETURN NUMBER
        IS
          ResultValue NUMBER;
        BEGIN

          IF (Divisor IS NULL  OR Divisor = 0) THEN
            RETURN 0;
          END IF;

          ResultValue := ROUND(Amount / Divisor, 2);

          IF ResultValue > cMAX_RESULT THEN
            RETURN cMAX_RESULT;
          ELSE
            RETURN ResultValue;
          END IF;
        END CalculateRatio;


        FUNCTION CalculatePercentage(
          Quantity  IN  NUMBER,
          Total     IN  NUMBER
        )
          RETURN NUMBER
        IS
          ResultValue NUMBER;
        BEGIN

          IF (Total = 0) THEN
            RETURN 0;
          END IF;

          ResultValue := (Quantity * 1.0 / Total * 1.0) * 100;

          ResultValue := Round(ResultValue,2);

          IF ResultValue >= 1000 THEN
            ResultValue := 999.99;
          END IF;

          RETURN ResultValue;
        END CalculatePercentage;


        END;
        ;
        """;
}
