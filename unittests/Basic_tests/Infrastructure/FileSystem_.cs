using System.Collections.Concurrent;
using grate.Configuration;
using grate.Migration;
using TestCommon.TestInfrastructure;

namespace Basic_tests.Infrastructure;


public class FileSystem_
{
    [Fact]
    public void A_temporary_directory_is_created_empty_and_writable_under_the_temp_root()
    {
        var directory = FileSystem.CreateRandomTempDirectory();
        try
        {
            Assert.True(directory.Exists);
            Assert.False(File.Exists(directory.FullName));
            Assert.Empty(directory.EnumerateFileSystemInfos());
            Assert.Equal(directory.Name, Path.GetRelativePath(Path.GetTempPath(), directory.FullName));

            var script = Path.Combine(directory.FullName, "bootstrap.sql");
            File.WriteAllText(script, "SELECT 1;");

            Assert.Equal("SELECT 1;", File.ReadAllText(script));
        }
        finally
        {
            if (Directory.Exists(directory.FullName))
            {
                directory.Delete(recursive: true);
            }
        }
    }

    [Fact]
    public void Deleting_one_temporary_directory_preserves_another_callers_files()
    {
        var first = FileSystem.CreateRandomTempDirectory();
        DirectoryInfo? second = null;
        try
        {
            var firstScript = Path.Combine(first.FullName, "bootstrap.sql");
            File.WriteAllText(firstScript, "SELECT 1;");

            second = FileSystem.CreateRandomTempDirectory();
            var secondScript = Path.Combine(second.FullName, "bootstrap.sql");
            File.WriteAllText(secondScript, "SELECT 2;");

            Assert.NotEqual(first.FullName, second.FullName);
            Assert.Equal("SELECT 1;", File.ReadAllText(firstScript));
            first.Delete(recursive: true);

            Assert.Equal("SELECT 2;", File.ReadAllText(secondScript));
        }
        finally
        {
            if (Directory.Exists(first.FullName))
            {
                first.Delete(recursive: true);
            }
            if (second is not null && Directory.Exists(second.FullName))
            {
                second.Delete(recursive: true);
            }
        }
    }

    [Fact]
    public void Concurrent_callers_receive_separate_writable_temporary_directories()
    {
        var directories = new ConcurrentBag<(DirectoryInfo Directory, string Owner)>();
        try
        {
            Parallel.For(0, 16, index =>
            {
                var directory = FileSystem.CreateRandomTempDirectory();
                var owner = $"caller-{index}";
                directories.Add((directory, owner));
                File.WriteAllText(Path.Combine(directory.FullName, "owner.txt"), owner);
            });

            Assert.Equal(16, directories.Count);
            Assert.Equal(16, directories.Select(item => item.Directory.FullName).Distinct().Count());
            foreach (var (directory, owner) in directories)
            {
                Assert.Equal(owner, File.ReadAllText(Path.Combine(directory.FullName, "owner.txt")));
            }
        }
        finally
        {
            foreach (var (directory, _) in directories)
            {
                if (Directory.Exists(directory.FullName))
                {
                    directory.Delete(recursive: true);
                }
            }
        }
    }

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
