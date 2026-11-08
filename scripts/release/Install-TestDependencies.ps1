#!/usr/bin/env pwsh
# YAML is needed only by workflow policy tests, not release commands.
# Package: https://www.powershellgallery.com/packages/powershell-yaml/0.4.12
$ErrorActionPreference = 'Stop'
if (!(Get-Module -ListAvailable powershell-yaml | Where-Object Version -EQ '0.4.12')) {
    Install-Module powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser -Repository PSGallery -Force
}
Import-Module powershell-yaml -RequiredVersion 0.4.12 -ErrorAction Stop
