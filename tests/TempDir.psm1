# SPDX-License-Identifier: MIT
#
# Scratch directories for the self-test. A recursive delete only ever removes a directory this process created with
# New-HarnessTempDir, checked again by real path right before deleting:
#   - created one level below the system temporary directory, named <prefix><32 random hex digits> (a name that
#     already exists is never taken over), its real path recorded;
#   - Remove-HarnessTempDir resolves the real path again (junctions and symbolic links followed at every level); it
#     must be the recorded one, still one level below the current system temporary directory and still start with the
#     prefix, otherwise nothing is deleted and the reason is returned. Junctions and links inside are removed as links,
#     their targets are not entered. When a child process still holds a file, it retries for -WaitSeconds.
#   New-HarnessTempDir -Prefix <reaper-harness-...->   returns the full path
#   Remove-HarnessTempDir -Path <dir> [-WaitSeconds <s>]   $null when removed (or already gone), else the reason

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '../src/Guard.psm1') -ErrorAction Stop

$script:Made = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase) # real path -> prefix

function New-HarnessTempDir {
    param([Parameter(Mandatory)][ValidatePattern('^reaper-harness-[a-z0-9-]+-$')][string]$Prefix)
    $root = [IO.Path]::GetTempPath()
    for ($i = 0; $i -lt 100; $i++) {
        $dir = [IO.Path]::Join($root, $Prefix + [guid]::NewGuid().ToString('N'))
        try { $null = New-Item -ItemType Directory -Path $dir -ErrorAction Stop }
        catch { if (Test-Path -LiteralPath $dir) { continue }; throw }
        $script:Made[(Resolve-HarnessRealPath $dir)] = $Prefix
        return $dir
    }
    throw "could not create a $Prefix directory under the temporary directory"
}

function Get-HarnessTempDirCheck([string]$Path) {
    $real = Resolve-HarnessRealPath $Path
    $madeWith = $null
    if (-not $script:Made.TryGetValue($real, [ref]$madeWith)) { return "not created by New-HarnessTempDir in this process (real path $real)" }
    $root = (Resolve-HarnessRealPath ([IO.Path]::GetTempPath())).TrimEnd('\')
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($real), $root, [StringComparison]::OrdinalIgnoreCase)) { return "real path $real is not one level below the temporary directory $root" }
    if (-not ([IO.Path]::GetFileName($real)).StartsWith($madeWith, [StringComparison]::Ordinal)) { return "the name of $real does not start with $madeWith" }
    $real
}

function Remove-HarnessTempDir {
    param([AllowEmptyString()][string]$Path, [double]$WaitSeconds = 0)
    if (-not $Path) { return $null }
    $deadline = [datetime]::UtcNow.AddSeconds($WaitSeconds)
    while ($true) {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $real = Get-HarnessTempDirCheck $Path
        if (-not [IO.Path]::IsPathRooted($real)) { return "not removing $($Path): $real" }
        try {
            Remove-Item -LiteralPath $real -Recurse -Force -ErrorAction Stop
            $null = $script:Made.Remove($real)
            return $null
        } catch {
            if ([datetime]::UtcNow -ge $deadline) { return "could not remove $($Path): $($_.Exception.Message)" }
            Start-Sleep -Milliseconds 200
        }
    }
}

Export-ModuleMember -Function New-HarnessTempDir, Remove-HarnessTempDir
