using System.Collections.Immutable;
using grate.Configuration;

namespace Basic_tests.Infrastructure.FolderConfiguration;

// ReSharper disable once InconsistentNaming
public class Customized_Folders_Can_Be_Set_Programmatically
{
    [Fact]
    public void From_MigrationsFolder_list()
    {
        var folders = Folders.Create(
            new MigrationsFolder("structure"),
            new MigrationsFolder("randomstuff"),
            new MigrationsFolder("procedures"),
            new MigrationsFolder("security")
            );
        var items = folders.Values.ToImmutableArray();

        Assert.Multiple(() =>
        {
            Assert.Equal(folders["structure"], items[0]);
            Assert.Equal(folders["randomstuff"], items[1]);
            Assert.Equal(folders["procedures"], items[2]);
            Assert.Equal(folders["security"], items[3]);
        });
    }

    [Fact]
    public void From_Enumerable_of_MigrationsFolder()
    {
        var folders = Folders.Create(new List<MigrationsFolder>
            {
            new("structure"),
            new("randomstuff"),
            new("procedures"),
            new("security")}
        );
        var items = folders.Values.ToImmutableArray();

        Assert.Multiple(() =>
        {
            Assert.Equal(folders["structure"], items[0]);
            Assert.Equal(folders["randomstuff"], items[1]);
            Assert.Equal(folders["procedures"], items[2]);
            Assert.Equal(folders["security"], items[3]);
        });
    }

    [Fact]
    public void From_Dictionary_of_MigrationsFolder()
    {
        var folders = Folders.Create(new Dictionary<string, MigrationsFolder>
            {
                {"structure", new("str") },
                {"randomstuff", new("rnd") },
                {"procedures", new("procs") },
                {"security", new("sec") }
            }
        );
        var items = folders.Values.ToImmutableArray();

        Assert.Multiple(() =>
        {
            Assert.Equal(folders["structure"], items[0]);
            Assert.Equal(folders["randomstuff"], items[1]);
            Assert.Equal(folders["procedures"], items[2]);
            Assert.Equal(folders["security"], items[3]);
        });
    }


    [Fact]
    public void From_command_line_argument_style_single_string()
    {
        var folders = Folders.Create("nup=tables;sprocs=storedprocedures;views=projections");
        var items = folders.ToImmutableArray();

        Assert.Multiple(() =>
        {
            Assert.Equal("nup", items[0].Key);
            Assert.Equal("tables", items[0].Value!.Path);

            Assert.Equal("sprocs", items[1].Key);
            Assert.Equal("storedprocedures", items[1].Value!.Path);

            Assert.Equal("views", items[2].Key);
            Assert.Equal("projections", items[2].Value!.Path);
        });
    }
    
    [Fact]
    public void From_multiple_string_arguments()
    {
        var folders = Folders.Create("zup=tables", "sprocs=path:storedprocedures,type:anytime", "views=projections");
        var items = folders.ToImmutableArray();

        Assert.Multiple(() =>
        {
            Assert.Equal("zup", items[0].Key);
            Assert.Equal("tables", items[0].Value!.Path);

            Assert.Equal("sprocs", items[1].Key);
            Assert.Equal("storedprocedures", items[1].Value!.Path);
            Assert.Equal(MigrationType.AnyTime, items[1].Value!.Type);

            Assert.Equal("views", items[2].Key);
            Assert.Equal("projections", items[2].Value!.Path);
        });
    }
    
    

}
