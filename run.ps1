#Requires -Version 7
# SPDX-License-Identifier: MIT
#
# reaper-harness: drives a real REAPER through a private configuration to test VST3 plugins. See docs/USAGE.md.
#   pwsh run.ps1 -Config <config.json> -CfgDir <private configuration directory> -PluginDir <directory with the .vst3
#                bundles> -ResultDir <directory> [-SkipMarker <path>]... [-ExtraGuiLock <Local\name>]... [-Only <id regex>]
#                [-Repeat <n>] [-NoNegative] [-BuildLabel <label>] [-KeepWork] [-ReaperExe <reaper.exe>]
#   pwsh run.ps1 -SelfTest [-ExtraGuiLock <Local\name>]... [-CollisionSample <a .ps1 with variable names that differ only
#                by case>]   no REAPER needed; its dialog cases take the GUI locks like a real run
#   pwsh run.ps1 -WriteSchema    regenerates schema/config.schema.json from the validator in src/Config.psm1
# -CfgDir only accepts an explicit absolute path holding the sentinel written by doctor.ps1 -Init; the default REAPER
# resource directory (%APPDATA%\REAPER) is never touched.
# Exit codes: 0 all PASS, 1 a FAIL, 2 an INCOMPLETE (no conclusion; never counted as PASS), 3 the whole suite SKIPPED,
# 64 refused by a guard or usage error (including a configuration with problems, or -Only picking nothing).
[CmdletBinding()]
param(
    [string]$Config = '',
    [string]$CfgDir = '',
    [string]$PluginDir = '',
    [string]$ResultDir = '',
    [string]$ReaperExe = (Join-Path $env:ProgramFiles 'REAPER (x64)\reaper.exe'),
    [string[]]$SkipMarker = @(),
    [string[]]$ExtraGuiLock = @(),
    [string]$Only = '',
    [int]$Repeat = 1,
    [switch]$NoNegative,
    [string]$BuildLabel = '',
    [switch]$KeepWork,
    [switch]$SelfTest,
    [string]$CollisionSample = '',
    [switch]$WriteSchema
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($SelfTest) {
    Import-Module (Join-Path $PSScriptRoot 'tests/SelfTest.psm1') -ErrorAction Stop
    try { exit (Invoke-HarnessSelfTest -RepoRoot $PSScriptRoot -CollisionSample $CollisionSample -ExtraGuiLock $ExtraGuiLock) }
    catch { if ($_.Exception.Message -like 'USAGE:*') { Write-Host $_.Exception.Message; exit 64 }; throw }
}
if ($WriteSchema) {
    Import-Module (Join-Path $PSScriptRoot 'src/Config.psm1') -ErrorAction Stop
    $schemaPath = Join-Path $PSScriptRoot 'schema/config.schema.json'
    [IO.File]::WriteAllText($schemaPath, (ConvertTo-HarnessJsonSchema), [Text.UTF8Encoding]::new($false))
    Write-Host 'schema/config.schema.json written'
    exit 0
}

foreach ($need in @(@('-Config', $Config), @('-PluginDir', $PluginDir), @('-ResultDir', $ResultDir))) {
    if (-not $need[1]) { Write-Host "USAGE: $($need[0]) is required"; exit 64 }
}
Import-Module (Join-Path $PSScriptRoot 'src/Suite.psm1') -ErrorAction Stop

$params = @{
    CfgDir = $CfgDir; Config = [IO.Path]::GetFullPath($Config); PluginDir = [IO.Path]::GetFullPath($PluginDir); ResultDir = [IO.Path]::GetFullPath($ResultDir)
    ReaperExe = $ReaperExe; SkipMarker = $SkipMarker; ExtraGuiLock = $ExtraGuiLock; Only = $Only; Repeat = $Repeat; NoNegative = $NoNegative; BuildLabel = $BuildLabel; KeepWork = $KeepWork
}
try {
    $outcome = Invoke-HarnessSuite @params
} catch {
    if ($_.Exception.Message -like 'REFUSED:*' -or $_.Exception.Message -like 'USAGE:*') { Write-Host $_.Exception.Message; exit 64 }
    throw
}
$resultFile = Write-HarnessResult -Data $outcome -ResultDir $params.ResultDir
if ($outcome.verdict -eq 'SKIPPED') { Write-Host "SKIPPED: $($outcome.skipReasons -join '; ')" }
Write-Host ('reaper-harness {0}  config {1}  build {2}  {3} rounds  REAPER started {4} times  result {5}' -f $outcome.verdict, $outcome.config, $outcome.buildLabel, $outcome.runs.Count, $outcome.launches, $resultFile)
$exitCodes = @{ PASS = 0; FAIL = 1; INCOMPLETE = 2; SKIPPED = 3 }
exit $exitCodes[$outcome.verdict]
