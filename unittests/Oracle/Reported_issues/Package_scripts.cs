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
    public async Task Creates_and_executes_the_package_from_issue_642(bool useSqlPlusSeparator)
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

        // Only the schema is changed from the reported reproduction, so every test owns its objects.
        var sql = OriginalPackage.Replace("ARGUS_DBA.", database + ".", StringComparison.Ordinal);
        if (useSqlPlusSeparator)
        {
            sql = sql.Replace("\n;", "\n/", StringComparison.Ordinal);
        }
        TestConfig.WriteContent(TestConfig.Wrap(directory, "sprocs"), "0014_ARGUS_ANALYTICS_COMMONUTILITY_PACKAGE.sql", sql);

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
                WHERE object_name = 'ANALYTICSCOMMONUTILITY' AND status = 'VALID'
                ORDER BY object_type
                """)).ToArray();
            Assert.Equal(["PACKAGE", "PACKAGE BODY"], objectTypes);

            var compilationErrors = await connection.QueryAsync<string>(
                "SELECT text FROM user_errors WHERE name = 'ANALYTICSCOMMONUTILITY' AND attribute = 'ERROR' ORDER BY sequence");
            Assert.Empty(compilationErrors);

            Assert.Equal(20m, await connection.ExecuteScalarAsync<decimal>(
                "SELECT AnalyticsCommonUtility.CalculateCPM(100, 5000) FROM dual"));
            Assert.Equal(25m, await connection.ExecuteScalarAsync<decimal>(
                "SELECT AnalyticsCommonUtility.CalculateCPP(100, 4) FROM dual"));
            Assert.Equal(50m, await connection.ExecuteScalarAsync<decimal>(
                "SELECT AnalyticsCommonUtility.CalculateIndex(50, 100) FROM dual"));
            Assert.Equal(0m, await connection.ExecuteScalarAsync<decimal>(
                "SELECT AnalyticsCommonUtility.CalculateCPM(100, 0) FROM dual"));
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    // https://github.com/grate-devs/grate/issues/642, including Roundhouse's standalone semicolons.
    private const string OriginalPackage = """
        CREATE OR REPLACE PACKAGE ARGUS_DBA.AnalyticsCommonUtility IS
        cMAX_CPP          NUMBER(16,2) DEFAULT 10000000;
        
        FUNCTION CalculateCPM(
          Rate    IN  NUMBER,
          Imps    IN  NUMBER
        ) RETURN NUMBER;
        
        
        FUNCTION CalculateCPP(
          Rate    IN  NUMBER,
          Rating  IN  NUMBER
        ) RETURN NUMBER;
        
        
        FUNCTION CalculateIndex(
          Imps    IN  NUMBER,
          Gtee    IN  NUMBER
        ) RETURN NUMBER;
        
        
        END AnalyticsCommonUtility;
        ;
        
        
        CREATE OR REPLACE PACKAGE BODY ARGUS_DBA.AnalyticsCommonUtility IS
        
        FUNCTION CalculateCPM(
          Rate    IN  NUMBER,
          Imps    IN  NUMBER
        )
          RETURN NUMBER
        IS
          CPM NUMBER;
        BEGIN
        
          IF (Imps IS NULL OR Imps = 0) THEN
            RETURN 0;
          END IF;
        
          CPM := ROUND((Rate * 1000) / Imps, 2);
        
          IF CPM >= 10000 THEN
            RETURN 10000;
          ELSE
            RETURN CPM;
          END IF;
        END CalculateCPM;
        
        
        FUNCTION CalculateCPP(
          Rate    IN  NUMBER,
          Rating  IN  NUMBER
        )
          RETURN NUMBER
        IS
          CPP NUMBER;
        BEGIN
        
          IF (Rating IS NULL  OR Rating = 0) THEN
            RETURN 0;
          END IF;
        
          CPP := ROUND(Rate / Rating, 2);
        
          IF CPP > cMAX_CPP THEN
            RETURN cMAX_CPP;
          ELSE
            RETURN CPP;
          END IF;
        END CalculateCPP;
        
        
        FUNCTION CalculateIndex(
          Imps    IN  NUMBER,
          Gtee    IN  NUMBER
        )
          RETURN NUMBER
        IS
          Idx NUMBER;
        BEGIN
        
          IF (Gtee = 0) THEN
            RETURN 0;
          END IF;
        
          Idx := (Imps * 1.0 / Gtee * 1.0) * 100;
        
          Idx := Round(Idx,2);
          
          IF Idx >= 1000 THEN
            Idx := 999.99;
          END IF;
        
          RETURN Idx;
        END CalculateIndex;
        
        
        END;
        ;
        """;
}
