#!/usr/bin/env pwsh

param ( 
     [Parameter(Mandatory=$true)] [string] $grateExe,
     [Parameter(Mandatory=$true)] [string] $version,
     [Parameter(Mandatory=$true)] [string] $arch
)

$Root = Resolve-Path "$($PSScriptRoot)";

# Debian sorts ~ before the final version; a SemVer '-' would sort after it.
# Replace only the core/prerelease separator, preserving hyphens in identifiers.
$pkgVersion = ($version -replace '^([0-9]+\.[0-9]+\.[0-9]+)-', '$1~') + '-1';

function Recreate {
	param ($dirName)

	$dir = Join-Path $Root $dirName;

	If (Test-Path($dir)) {
	   $null = Remove-Item -Recurse $dir
	}
	New-Item -Path $dir -Type Directory;
}

$debianDir = Recreate "debian"


# Create a dpkg

$DEBIAN=New-Item -Type Directory -Path $(Join-Path $debianDir "DEBIAN")
$binDir=New-Item -Type Directory -Path $(Join-Path $debianDir "usr/bin")

$templateDir = Join-Path $Root template
$templateControl = Join-Path $templateDir DEBIAN

$controlTemplateFile = Join-Path $templateControl control
$controlDest = Join-Path $DEBIAN control

cp $grateExe $binDir
$executable = $(basename $grateExe)
chmod a+x $(Join-Path $binDir $executable)

cp -R $templateDir/* $debianDir

((Get-Content -path $controlTemplateFile -Raw) `
	-replace '%%%VERSION%%%',$pkgVersion `
	-replace '%%%ARCH%%%',$arch `
	) | Set-Content -Path $controlDest


$manFile = Join-Path $debianDir usr share man man1 grate.1
$changelog = Join-Path $debianDir usr share doc grate changelog

#groff -man -Tascii $manFile
gzip -n --best $manFile
gzip -n --best $changelog
ln -s changelog.gz "${changelog}.Debian.gz"

#(Get-Item $manFile).LastWriteTime=("12 December 2016 14:00:00")


fakeroot dpkg-deb --build $debianDir

$built = Join-Path $Root debian.deb
# Keep the SemVer filename expected by the release workflow; Debian reads the
# independently formatted Version field from the package metadata.
$final = Join-Path $Root "grate_${version}-1_${arch}.deb"

mv $built $final

