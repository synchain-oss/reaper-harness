#Requires -Version 7.4
# SPDX-License-Identifier: MIT
#
# reaper-harness: drives a real REAPER through a private configuration to test VST3 plugins.
#   pwsh run.ps1 -SelfTest [-ExtraGuiLock <Local\name>]... [-CollisionSample <a .ps1 with variable names that differ only
#                by case>]   no REAPER needed; its dialog cases take the GUI locks like a real run
# Running scenarios against REAPER is not part of this version yet; only the self-test of the safety base and the
# comparer is.
# Exit codes: 0 all passed, 1 a case failed, 64 usage error.
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [string[]]$ExtraGuiLock = @(),
    [string]$CollisionSample = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $SelfTest) { Write-Host 'USAGE: only -SelfTest is available in this version'; exit 64 }
Import-Module (Join-Path $PSScriptRoot 'tests/SelfTest.psm1') -ErrorAction Stop
try {
    exit (Invoke-HarnessSelfTest -RepoRoot $PSScriptRoot -CollisionSample $CollisionSample -ExtraGuiLock $ExtraGuiLock)
} catch {
    if ($_.Exception.Message -like 'USAGE:*') { Write-Host $_.Exception.Message; exit 64 }
    throw
}
