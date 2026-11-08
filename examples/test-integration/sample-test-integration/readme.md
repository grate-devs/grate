# Example of using grate in Automated Tests

A simplified example of one way to use `grate` in your automated tests.

The solution targets .NET 8 and uses xUnit v2 with VSTest. Install the .NET 8
runtime and a stable .NET SDK 8.0.100 or newer, plus Docker with support for the
SQL Server Linux image. The local `global.json` allows newer stable SDKs.

Package versions are explicit so the whole `sample-test-integration` directory
can be copied into another repository without grate's development build settings
or central package versions. From that directory, run:

```sh
dotnet test sample-test-integration.sln
```

This is certainly not the only way of integrating `grate` into your tests, but is a pattern that's been used in multiple companies with success.

⚠️ There's an implicit assumption that `grate` is installed on the system running the tests.  Ensure you have a 
step in your pipeline to install `grate` on the build server for CI (and that it's installed locally for development).
