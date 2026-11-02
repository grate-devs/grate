# Observations from actual WinGet commands, independently checked across both
# catalogs and the unfiltered installed view. No tracking databases are edited.
function Assert-WinGetSourceCorrelation {
    param(
        [Parameter(Mandatory)][hashtable]$Queries,
        [Parameter(Mandatory)]$Export,
        [Parameter(Mandatory)][string]$PublicSourceIdentifier,
        [Parameter(Mandatory)][string]$CandidateSourceIdentifier,
        [Parameter(Mandatory)][string]$CandidateSourceName,
        [switch]$Legacy
    )
    $old='erikbra.grate'
    $new='grate-devs.grate'
    foreach ($source in @('global','winget',$CandidateSourceName)) {
        foreach ($id in @($old,$new)) {
            $visible=if ($Legacy) { $id -eq $old -and $source -in @('global','winget') } else { $id -eq $new -and $source -in @('global',$CandidateSourceName) }
            $expected=if ($visible) { '0x00000000' } else { '0x8A150014' }
            if ($Queries["$source/$id"] -ne $expected) { throw "Unexpected installed correlation for $source/$id. Expected $expected; got $($Queries["$source/$id"])." }
        }
    }
    $expectedId=if ($Legacy) { $old } else { $new }
    $expectedSource=if ($Legacy) { $PublicSourceIdentifier } else { $CandidateSourceIdentifier }
    Assert-WinGetExportIdentity -Export $Export -ExpectedId $expectedId -ExpectedSourceIdentifier $expectedSource
}

function Assert-WinGetExportIdentity {
    param(
        [Parameter(Mandatory)]$Export,
        [Parameter(Mandatory)][string]$ExpectedId,
        [Parameter(Mandatory)][string]$ExpectedSourceIdentifier
    )
    $records=@(foreach ($source in $Export.Sources) {
        foreach ($package in $source.Packages) {
            if ($package.PackageIdentifier -in @('erikbra.grate','grate-devs.grate')) {
                [pscustomobject]@{Id=$package.PackageIdentifier; Source=$source.SourceDetails.Identifier}
            }
        }
    })
    if ($records.Count -ne 1 -or $records[0].Id -ne $ExpectedId -or $records[0].Source -ne $ExpectedSourceIdentifier) { throw 'Global export must contain exactly the expected grate ID under its actual source identity.' }
}
