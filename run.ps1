#Requires -Version 7.4
# SPDX-License-Identifier: MIT
#
# reaper-harness: drives a real REAPER through a private configuration to test VST3 plugins. See docs/USAGE.md.
#   pwsh run.ps1 -Config <config.json> -CfgDir <private configuration directory> -PluginDir <directory with the .vst3
#                bundles> -ResultDir <directory> [-SkipMarker <path>]... [-ExtraGuiLock <Local\name>]... [-Only <id regex>]
#                [-Repeat <n>] [-NoNegative] [-BuildLabel <label>] [-KeepWork] [-ReaperExe <reaper.exe>]
#   pwsh run.ps1 -List params -Config ... -CfgDir ... -PluginDir ... -ResultDir ... [-ListPlugin <id,id...>]
#                [-ListParam <name> | -ListParamFile <file of names>] [-ListValues <v,v...>]
#                lists the parameters of the configured plugins (one learn launch under every guard; no scenario runs)
#   pwsh run.ps1 -SelfTest [-ExtraGuiLock <Local\name>]... [-CollisionSample <a .ps1 with variable names that differ only
#                by case>]   no REAPER needed; its dialog cases take the GUI locks like a real run
#   pwsh run.ps1 -WriteSchema    regenerates schema/config.schema.json from the validator in src/Config.psm1
# -CfgDir only accepts an explicit absolute path holding the sentinel written by doctor.ps1 -Init; the default REAPER
# resource directory (%APPDATA%\REAPER) is never touched, and -ResultDir may not be in it either.
# Exit codes: 0 all PASS, 1 a FAIL, 2 an INCOMPLETE (no conclusion, an unexpected error or a result file that could not be
# written included; never counted as PASS),
# 3 the whole suite SKIPPED, 64 refused by a guard or usage error (including a configuration with problems, -Only
# picking nothing, or -List options that do not fit).
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
    # Every -List option is a plain string, so Test-HarnessListRequest checks its value (64), not the binder (1). An option
    # given no value at all (-List as the last argument) is still refused by the binder (1), as every option is.
    [string]$List = '',
    [string]$ListPlugin = '',
    [string]$ListParam = '',
    [string]$ListParamFile = '',
    [string]$ListValues = '',
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
Import-Module (Join-Path $PSScriptRoot 'src/Scenarios.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'src/Suite.psm1') -ErrorAction Stop

try {
    $listRequest = Test-HarnessListRequest -Bound $PSBoundParameters # $null without -List
    $params = @{
        CfgDir = $CfgDir; Config = [IO.Path]::GetFullPath($Config); PluginDir = [IO.Path]::GetFullPath($PluginDir); ResultDir = [IO.Path]::GetFullPath($ResultDir)
        ReaperExe = $ReaperExe; SkipMarker = $SkipMarker; ExtraGuiLock = $ExtraGuiLock; Only = $Only; Repeat = $Repeat; NoNegative = $NoNegative; BuildLabel = $BuildLabel; KeepWork = $KeepWork
        List = $listRequest
    }
    $outcome = Invoke-HarnessSuite @params
    $exitCode = Complete-HarnessRun -Outcome $outcome -ResultDir $params.ResultDir
} catch {
    $message = Hide-HarnessPaths $_.Exception.Message
    if ($message -like 'REFUSED:*' -or $message -like 'USAGE:*') { Write-Host $message; exit 64 }
    # Exit code 1 is for a criterion that was checked and not met; this run has no conclusion at all
    Write-Host "INCOMPLETE: the run stopped on an unexpected error and left no result file: $($message -replace '\s+', ' ')"
    exit 2
}
exit $exitCode
