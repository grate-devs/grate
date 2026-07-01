using grate.Configuration;
using grate.Migration;
using TestCommon.TestInfrastructure;

namespace Basic_tests.Infrastructure;


public class FileSystem_
{
    [Fact]
    public void Sorts_enumerated_files_on_filename_when_no_subfolders()
    {
        var parent = TestConfig.CreateRandomTempDirectory();
        var knownFolders = Folders.Default;

        var path = Wrap(parent, knownFolders[KnownFolderKeys.Up]!.Path);

        string filename1 = "01_any_filename.sql";
        string filename2 = "02_any_filename.sql";

        TestConfig.WriteContent(path, filename1, "Whatever");
        TestConfig.WriteContent(path, filename2, "Whatever");

        var files = FileSystem.GetFiles(path, "*.sql").ToList();

        Assert.Equal(Path.Combine(path.ToString(), filename1), files.First().FullName);
        Assert.Equal(Path.Combine(path.ToString(), filename2), files.Last().FullName);
    }

    [Fact]
    public void Sorts_enumerated_files_on_filename_without_extension_when_no_subfolders()
    {
        var parent = TestConfig.CreateRandomTempDirectory();
        var knownFolders = Folders.Default;

        var path = Wrap(parent, knownFolders[KnownFolderKeys.Up]!.Path);

        string filename1 = "01_any_filename_and_a_bit_longer.sql";
        string filename2 = "01_any_filename.sql";

        TestConfig.WriteContent(path, filename1, "Whatever");
        TestConfig.WriteContent(path, filename2, "Whatever");

        var files = FileSystem.GetFiles(path, "*.sql").ToList();

        Assert.Equal(Path.Combine(path.ToString(), filename2), files.First().FullName);
        Assert.Equal(Path.Combine(path.ToString(), filename1), files.Last().FullName);
    }

    [Fact]
    public void Sorts_enumerated_files_on_sub_path_when_subfolders_are_used()
    {
        var parent = TestConfig.CreateRandomTempDirectory();
        var knownFolders = Folders.Default;

        var path = Wrap(parent, knownFolders[KnownFolderKeys.Up]!.Path);

        var folder1 = new DirectoryInfo(Path.Combine(path.ToString(), "01_sub", "folder", "long", "way"));
        var folder2 = new DirectoryInfo(Path.Combine(path.ToString(), "02_sub", "folder", "long", "way"));

        string filename1 = "01_any_filename.sql";
        string filename2 = "02_any_filename.sql";

        TestConfig.WriteContent(folder1, filename2, "Whatever");
        TestConfig.WriteContent(folder2, filename1, "Whatever");

        var files = FileSystem.GetFiles(path, "*.sql").ToList();

        Assert.Equal(Path.Combine(folder1.ToString(), filename2), files.First().FullName);
        Assert.Equal(Path.Combine(folder2.ToString(), filename1), files.Last().FullName);
    }

    [Fact]
    public void Sorts_enumerated_files_on_filename_when_directory_names_are_ignored()
    {
        var parent = TestConfig.CreateRandomTempDirectory();
        var knownFolders = Folders.Default;

        var path = Wrap(parent, knownFolders[KnownFolderKeys.Up]!.Path);

        var folder1 = new DirectoryInfo(Path.Combine(path.ToString(), "Init"));
        var folder2 = new DirectoryInfo(Path.Combine(path.ToString(), "1.0"));

        string filename1 = "01_Schema.sql";
        string filename2 = "02_SomeChanges.sql";

        TestConfig.WriteContent(folder1, filename1, "Whatever");
        TestConfig.WriteContent(folder2, filename2, "Whatever");

        var files = FileSystem.GetFiles(path, "*.sql", true).ToList();

        Assert.Equal(Path.Combine(folder1.ToString(), filename1), files.First().FullName);
        Assert.Equal(Path.Combine(folder2.ToString(), filename2), files.Last().FullName);
    }

    protected static DirectoryInfo Wrap(DirectoryInfo root, string? subFolder) =>
        new(Path.Combine(root.ToString(), subFolder ?? ""));

}
