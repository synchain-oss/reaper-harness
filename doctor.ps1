#Requires -Version 7
# SPDX-License-Identifier: MIT
#
# Checks and initialisation for reaper-harness. Never starts REAPER.
#   pwsh doctor.ps1 -CfgDir <private configuration directory> -Init
#       creates the configuration directory (private plugins directory, minimal reaper.ini) and writes the sentinel
#   pwsh doctor.ps1 -Config <config.json>
#       validates the configuration (and its extensions) only
#   pwsh doctor.ps1 -CfgDir <dir> [-Config <config.json> -PluginDir <dir> [-SkipMarker <path>]... [-ReaperExe <exe>]]
#       checks the configuration directory; with -Config and -PluginDir also runs the same preflight as run.ps1
# -Init only takes over a directory that does not exist, an empty one, or one initialised before (with the
# sentinel); a directory with content but no sentinel is refused and nothing is written. A -CfgDir under AppData (or
# pointing there) is always refused, -Init included.
# Exit codes: 0 ready to run, 3 run.ps1 would be SKIPPED, 64 refused by a guard or usage error.
[CmdletBinding()]
param(
    [string]$CfgDir = '',
    [switch]$Init,
    [string]$Config = '',
    [string]$PluginDir = '',
    [string[]]$SkipMarker = @(),
    [string]$ReaperExe = (Join-Path $env:ProgramFiles 'REAPER (x64)\reaper.exe')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src/Guard.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'src/Config.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'src/Extensions.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'src/States.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'src/Scenarios.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'src/Suite.psm1') -ErrorAction Stop

try {
    if ($Init) {
        $made = New-HarnessCfgDir $CfgDir
        Write-Host "initialised: sentinel and reaper.ini ready ($(Split-Path -Leaf $made.Dir))"
        exit 0
    }
    $conf = $null
    if ($Config) {
        $ext = Import-HarnessExtensions (Read-HarnessConfigExtensions $Config)
        $conf = Read-HarnessConfig -Path $Config -Kinds $ext.Kinds
        $states = Read-HarnessStates -Config $conf
        Write-Host ("[OK] configuration '{0}': {1} plugins, {2} layouts, {3} scenarios, {4} negative cases of its own, {5} extension kinds, {6} plugin states" -f $conf.Name, $conf.Plugins.Count, $conf.Layouts.Count,
            @($conf.Scenarios).Count, @($conf.Negative).Count, $ext.Kinds.Count, $states.get_Count())
        if (-not $CfgDir) { exit 0 }
    }
    $null = Assert-HarnessCfgDir $CfgDir # a bad path is refused; a missing sentinel is refused too
    Write-Host '[OK] configuration directory (outside the default resource directory, with sentinel and reaper.ini)'
    $problems = [Collections.Generic.List[string]]::new()
    if ($conf -and $PluginDir) {
        $pre = Get-HarnessPreflight -ReaperExe $ReaperExe -PluginDir $PluginDir -Config $conf -SkipMarkers $SkipMarker -ExtensionPreflight $ext.Preflight
        foreach ($r in $pre.Reasons) { $problems.Add((Hide-HarnessPaths $r)) }
        if (-not $pre.Reasons.Count) {
            $infos = [ordered]@{}
            foreach ($id in $pre.Plugins.get_Keys()) { $infos[$id] = $pre.Plugins[$id].Info }
            Assert-HarnessStateIdentity -States $states -Infos $infos
            Write-Host "[OK] REAPER $($pre.ReaperVersion); $($pre.Plugins.Count) plugin bundles readable; every plugin state belongs to its plugin; no other REAPER running; no skip marker"
        }
    } else {
        Write-Host '(no -Config and -PluginDir given: only the configuration directory was checked)'
    }
    foreach ($p in $problems) { Write-Host "[missing] $p" }
    if ($problems.Count) { Write-Host 'SKIPPED: run.ps1 would not run because of the items above'; exit 3 }
    Write-Host 'ready: run.ps1 can run'
    exit 0
} catch {
    if ($_.Exception.Message -like 'REFUSED:*' -or $_.Exception.Message -like 'USAGE:*') { Write-Host $_.Exception.Message; exit 64 }
    throw
}
