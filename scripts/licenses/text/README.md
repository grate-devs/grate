# Original upstream legal texts

Browse by upstream owner/repository, for example
[Npgsql](npgsql/npgsql/license.txt),
[SqlClient](dotnet/sqlclient/license.txt) and
[the Azure SDK](azure/azure-sdk-for-net/license.txt).
When a repository has different original texts across package versions, the
filename identifies the package/version variant. Identical bytes may serve
several package versions; every retained copy is checked by its full SHA256.

[sources.json](../sources.json) maps each NuGet package/version to these files,
the exact upstream URL/revision and expected hash. Names are for people;
validation never infers a license or trusts content from its filename.

Use [Update-LicenseSources.ps1](../Update-LicenseSources.ps1) to refresh evidence
and review the original notices. Do not normalize their copyright, whitespace,
encoding or line endings. These source files are retained byte-for-byte.
