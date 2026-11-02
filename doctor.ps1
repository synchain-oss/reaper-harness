#Requires -Version 7.4
# SPDX-License-Identifier: MIT
#
# Checks and initialisation for reaper-harness. Never starts REAPER.
#   pwsh doctor.ps1 -CfgDir <private configuration directory> -Init
#       creates the configuration directory (private plugins directory, minimal reaper.ini) and writes the sentinel
#   pwsh doctor.ps1 -CfgDir <dir>
#       checks the configuration directory
# -Init only takes over a directory that does not exist, an empty one, or one initialised before (with the
# sentinel); a directory with content but no sentinel is refused and nothing is written. A -CfgDir under AppData (or
# pointing there) is always refused, -Init included.
# Exit codes: 0 ready, 64 refused by a guard or usage error.
[CmdletBinding()]
param(
    [string]$CfgDir = '',
    [switch]$Init
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src/Guard.psm1') -ErrorAction Stop

try {
    if ($Init) {
        $made = New-HarnessCfgDir $CfgDir
        Write-Host "initialised: sentinel and reaper.ini ready ($(Split-Path -Leaf $made.Dir))"
        exit 0
    }
    $null = Assert-HarnessCfgDir $CfgDir # a bad path is refused; a missing sentinel is refused too
    Write-Host '[OK] configuration directory (outside the default resource directory, with sentinel and reaper.ini)'
    exit 0
} catch {
    if ($_.Exception.Message -like 'REFUSED:*' -or $_.Exception.Message -like 'USAGE:*') { Write-Host $_.Exception.Message; exit 64 }
    throw
}
