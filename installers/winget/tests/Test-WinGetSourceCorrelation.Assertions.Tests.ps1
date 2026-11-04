#!/usr/bin/env pwsh
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/WinGetSourceCorrelation.Assertions.ps1"
$count=0
foreach ($legacy in @($true,$false)) {
    $queries=@{
        'global/erikbra.grate'='0x8A150014'; 'global/grate-devs.grate'='0x00000000'
        'winget/erikbra.grate'='0x8A150014'; 'winget/grate-devs.grate'='0x8A150014'
        'candidate/erikbra.grate'='0x8A150014'; 'candidate/grate-devs.grate'='0x00000000'
    }
    if ($legacy) {
        $queries['global/erikbra.grate']='0x00000000'; $queries['global/grate-devs.grate']='0x8A150014'
        $queries['winget/erikbra.grate']='0x00000000'; $queries['candidate/grate-devs.grate']='0x8A150014'
    }
    $export=@{Sources=@(@{SourceDetails=@{Identifier=$(if($legacy){'public-identity'}else{'private-identity'})}; Packages=@(@{PackageIdentifier=$(if($legacy){'erikbra.grate'}else{'grate-devs.grate'})})})}
    $parameters=@{Queries=$queries; Export=$export; PublicSourceIdentifier='public-identity'; CandidateSourceIdentifier='private-identity'; CandidateSourceName='candidate'; Legacy=$legacy}
    Assert-WinGetSourceCorrelation @parameters
    $count++
    foreach ($key in @($queries.Keys)) {
        $original=$queries[$key]
        $queries[$key]=if ($original -eq '0x00000000') { '0x8A150014' } else { '0x00000000' }
        $rejected=$false
        try { Assert-WinGetSourceCorrelation @parameters } catch { $rejected=$_.Exception.Message -like 'Unexpected installed correlation*' }
        if (!$rejected) { throw "Correlation assertion accepted wrong result for $key." }
        $queries[$key]=$original
        $count++
    }
    foreach ($mutation in @('wrong-source','alias','missing')) {
        $bad=$export | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
        switch ($mutation) {
            'wrong-source' { $bad.Sources[0].SourceDetails.Identifier='some-other-source' }
            'alias' { $bad.Sources[0].Packages+=@{PackageIdentifier=$(if($legacy){'grate-devs.grate'}else{'erikbra.grate'})} }
            'missing' { $bad.Sources[0].Packages=@() }
        }
        $parameters.Export=$bad
        $rejected=$false
        try { Assert-WinGetSourceCorrelation @parameters } catch { $rejected=$_.Exception.Message -like 'Global export must*' }
        if (!$rejected) { throw "Global export assertion accepted $mutation." }
        $count++
    }
}
Write-Host "PASS: $count public/private/global correlation and export checks, including changed-and-rejected aliases and source identities."
