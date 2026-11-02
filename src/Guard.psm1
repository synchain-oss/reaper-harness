# SPDX-License-Identifier: MIT
#
# Safety rails for the REAPER host tests. Everything here works on paths and text only and never starts REAPER.
# Why this exists: REAPER does not fail on a -cfgfile path that does not exist. It silently falls back to
# %APPDATA%\REAPER and writes the user's own configuration. So before every launch all of these must hold: the
# configuration directory is an explicit absolute path, it is not under (and does not point into) %APPDATA%, it
# holds the sentinel written by doctor.ps1 -Init, nothing at its top level leads out of it, and reaper.ini exists. If
# any of them fails a REFUSED: error is thrown and the caller must not start REAPER.
#   Assert-HarnessCfgDir        checks the directory and returns @{ Dir; Ini }; New-HarnessCfgDir creates one for -Init
#   Initialize-HarnessCfg       checks it, walks its whole tree once, and pins the ini path into a read-only constant;
#                               from then on the -cfgfile argument can only come from Get-HarnessCfgArgument
#   Set-HarnessIniValue         changes one key in the private ini (bytes round-trip, no other line changes)
#   Get-HarnessDefaultCfgSnapshot / Compare-HarnessDefaultCfgSnapshot
#                               read-only listing (size and write time) of %APPDATA%\REAPER, compared before and after
#   Get-HarnessFileIdentity     file identity of a directory (volume serial + file ID): however a path is spelled,
#                               the same directory has the same identity
#   Find-HarnessVariableCaseCollisions / Find-HarnessControlChars / Test-HarnessScriptLint
#                               variable names must not differ only by case (PowerShell variable names are case
#                               insensitive, $c overwrites $C); scripts must not contain invisible control characters

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The identity comes from an open handle (FILE_ID_INFO), so 8.3 short names, case, trailing separators, subst
# drives, junctions and symbolic links all collapse to the same value. That is more reliable than comparing string
# prefixes. FILE_FLAG_OPEN_REPARSE_POINT is not used, so links are followed to their targets.
if (-not ('HarnessFileId' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HarnessFileId {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(IntPtr handle, int infoClass, byte[] buffer, uint size);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    public static string Get(string path) {
        // FILE_READ_ATTRIBUTES, share everything, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS (needed for directories)
        IntPtr h = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (h == new IntPtr(-1)) {
            int err = Marshal.GetLastWin32Error();
            // 2 and 3: the path does not exist, which is normal (a directory not created yet). Any other error means
            // the identity is unknown, which must never be taken as "not the same directory".
            return (err == 2 || err == 3) ? null : "ERROR:" + err;
        }
        try {
            byte[] b = new byte[24]; // FILE_ID_INFO: 8-byte volume serial + 16-byte file ID
            if (!GetFileInformationByHandleEx(h, 18, b, (uint)b.Length)) return "ERROR:" + Marshal.GetLastWin32Error();
            return BitConverter.ToString(b);
        } finally { CloseHandle(h); }
    }
    // How many names this file has on its volume, or -1 when that cannot be read. The name given is looked at itself:
    // a link is not followed (FILE_FLAG_OPEN_REPARSE_POINT on top of the flags above).
    public static long LinkCount(string path) {
        IntPtr h = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (h == new IntPtr(-1)) return -1;
        try {
            byte[] b = new byte[24]; // FILE_STANDARD_INFO: two 8-byte sizes, 4-byte NumberOfLinks, two flags, padding
            if (!GetFileInformationByHandleEx(h, 1, b, (uint)b.Length)) return -1;
            return BitConverter.ToUInt32(b, 16);
        } finally { CloseHandle(h); }
    }
}
'@
}

$script:SentinelName = '.reaper-harness-sentinel'
$script:SentinelMagic = 'reaper-harness-private-cfg v1'

function Get-HarnessSentinel { [pscustomobject]@{ Name = $script:SentinelName; Magic = $script:SentinelMagic } }

function Stop-Refuse([string]$Why) { throw [System.InvalidOperationException]::new("REFUSED: $Why") }

# Identity string of the directory (or file) a path points to; $null if the path does not exist; 'ERROR:<code>' if
# it exists but cannot be opened (callers must treat that as "cannot prove").
function Get-HarnessFileIdentity([string]$Path) { [HarnessFileId]::Get($Path) }

# How many names a file has on its volume, below 1 when that cannot be read. A function of its own so that the self-test
# can stand in for a count that cannot be read: nothing it can do to a real file makes that happen.
function Get-HarnessFileLinkCount([string]$Path) { [HarnessFileId]::LinkCount($Path) }

# Resolves junctions and symbolic links level by level and returns the real path; parts that do not exist are
# appended literally.
function Resolve-HarnessRealPath([string]$Path, [int]$Depth = 0) {
    if ($Depth -gt 32) { Stop-Refuse "links nested too deep: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    $cur = [IO.Path]::GetPathRoot($full)
    foreach ($part in @($full.Substring($cur.Length) -split '[\\/]' | Where-Object { $_ })) {
        $next = [IO.Path]::Join($cur, $part)
        $attr = try { [IO.File]::GetAttributes($next) } catch { $null }
        if ($null -ne $attr -and ($attr -band [IO.FileAttributes]::ReparsePoint)) {
            $info = ($attr -band [IO.FileAttributes]::Directory) ? [IO.DirectoryInfo]::new($next) : [IO.FileInfo]::new($next)
            $target = $info.ResolveLinkTarget($true)
            if ($target) { $cur = Resolve-HarnessRealPath $target.FullName ($Depth + 1); continue }
        }
        $cur = $next
    }
    $cur
}

# $Path equals $Root or is below it (case insensitive, both slash kinds).
function Test-HarnessUnder([string]$Path, [string]$Root) {
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') + '\'
    $r = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + '\'
    $p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)
}

# The type of the drive a path is on, by name (Fixed, Removable, Network...), or '' when it cannot be read. A function
# of its own so that the self-test can stand in for a mapped network drive: making a real one would change the machine.
function Get-HarnessDriveType([string]$Path) {
    try { [string][IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path)).DriveType } catch { '' }
}

# One spelling of the directory: it has to start with a drive letter, and that drive has to be one this machine holds
# itself. A mapped network drive can lead back here (net use Z: \\localhost\C$\...) and the identity SMB reports need
# not equal the local one, so neither of the later layers can be trusted on it. A drive whose type cannot be read, or
# that does not exist, proves nothing and is refused the same way.
function Assert-HarnessLocalDrive([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { Stop-Refuse '-CfgDir must be an absolute path on a local drive letter (D:\...), and a link in it must not lead anywhere else: \\?\ prefixes, \\.\ device paths, UNC paths and admin shares such as \\localhost\C$\ are not accepted' }
    $kind = Get-HarnessDriveType $Path
    if (-not $kind -or $kind -in 'Network', 'Unknown', 'NoRootDirectory') { Stop-Refuse "-CfgDir must be on a local drive: this is a network drive, or a drive whose type cannot be read ('$kind')" }
}

# Checks the path itself, not its contents: an explicit absolute path that is not under (and does not point into)
# AppData. Returns the real path. Three layers, none optional:
#   1. Only absolute paths that start with a drive letter, as given and after expanding links, on a drive this machine
#      holds itself. \\?\ prefixes, \\.\ device paths and \\server\share (including \\localhost\C$\ admin shares
#      pointing back at this machine) name the same directory but slip past string comparison, and on a mapped network
#      drive neither comparison can be trusted, so they are all refused;
#   2. string comparison: after expanding .. and junctions / symbolic links, not under the AppData string prefix;
#   3. file identity: the directory itself and every parent up to the drive root is compared with AppData by
#      identity (8.3 short names, subst drives and other spellings strings cannot see). An existing path whose
#      identity cannot be read (access denied and so on) is refused too: what cannot be proven is not allowed.
#      Parts of the path that do not exist yet ($null) are skipped.
function Assert-HarnessOutsideDefaultDir([string]$CfgDir) {
    if ([string]::IsNullOrWhiteSpace($CfgDir)) { Stop-Refuse 'no -CfgDir given (only an explicit absolute path is accepted)' }
    if (-not [IO.Path]::IsPathFullyQualified($CfgDir)) { Stop-Refuse '-CfgDir must be an absolute path' }
    $spelled = [IO.Path]::GetFullPath($CfgDir)
    Assert-HarnessLocalDrive $spelled
    $appData = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($appData)) { Stop-Refuse 'APPDATA is not set, so the configuration directory cannot be proven to be outside it' }
    $full = $spelled.TrimEnd('\', '/')
    $resolved = Resolve-HarnessRealPath $full
    Assert-HarnessLocalDrive $resolved
    $real = $resolved.TrimEnd('\', '/')
    $bases = @($appData, (Resolve-HarnessRealPath $appData))
    foreach ($candidate in @($full, $real)) {
        foreach ($base in $bases) {
            if (Test-HarnessUnder $candidate $base) { Stop-Refuse 'the configuration directory is under AppData (or points there): the default REAPER resource directory is never touched' }
        }
    }
    $baseId = Get-HarnessFileIdentity $appData
    if (-not $baseId -or $baseId.StartsWith('ERROR:')) { Stop-Refuse 'the AppData directory cannot be opened to read its file identity, so the configuration directory cannot be proven to be outside it' }
    foreach ($start in @($full, $real)) {
        # Walk up to the drive root: with a subst drive the root itself can be AppData
        for ($p = $start; $p; $p = [IO.Path]::GetDirectoryName($p)) {
            $id = Get-HarnessFileIdentity $p
            if ($id -and $id.StartsWith('ERROR:')) { Stop-Refuse "the file identity of the configuration directory or one of its parents cannot be read ($id), so it cannot be proven not to be AppData" }
            if ($id -ceq $baseId) { Stop-Refuse 'the configuration directory is under AppData (or points there; detected by file identity): the default REAPER resource directory is never touched' }
        }
    }
    $real
}

# Checks one level of the directory: the layers above only look at the directory itself, while REAPER and
# Set-HarnessIniValue read and write through whatever is in it. Refused: any entry that is a link or junction, a level
# that cannot be listed, and any file with more than one name on its volume. That last one is a hard link: writing the
# file changes it under its other name too, and that name can be anywhere on the volume and called anything, so looking
# for it in the default resource directory could never be complete. A count that cannot be read proves nothing and is
# refused as well. Returns the directories of this level, for the walk below. Root only sets how an entry is named in
# the refusal.
function Assert-HarnessCfgEntries([string]$Folder, [string]$Root = $Folder) {
    $entries = try { @(Get-ChildItem -LiteralPath $Folder -Force -ErrorAction Stop) } catch { Stop-Refuse 'the configuration directory cannot be listed, so nothing in it can be proven to stay inside it' }
    foreach ($entry in $entries) {
        $shown = [IO.Path]::GetRelativePath($Root, $entry.FullName)
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-Refuse "the configuration directory holds a link or junction ($shown): reads and writes would follow it out of the directory" }
        if ($entry.PSIsContainer) { $entry.FullName; continue }
        $names = Get-HarnessFileLinkCount $entry.FullName
        if ($names -lt 1) { Stop-Refuse "the number of names of $shown in the configuration directory cannot be read, so it cannot be proven to be a file of its own" }
        if ($names -gt 1) { Stop-Refuse "$shown in the configuration directory is a hard link (the file has $names names on this volume): writing it would change the file under its other names too, wherever they are" }
    }
}

# Every level of the tree, the same way. A link is refused and so never entered. This is what Initialize-HarnessCfg does
# once per process, and not what every start does: a configuration directory can hold thousands of entries (plugin
# presets, for one) and each launch checks several times, while the top level, where REAPER and the harness open files
# by a fixed name, stays cheap enough to look at every time.
function Assert-HarnessCfgTree([string]$Folder) {
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Folder)
    while ($pending.get_Count() -gt 0) {
        foreach ($sub in (Assert-HarnessCfgEntries ($pending.Pop()) $Folder)) { $pending.Push($sub) }
    }
}

function Assert-HarnessCfgDir {
    param([string]$CfgDir)
    $real = Assert-HarnessOutsideDefaultDir $CfgDir
    if (-not (Test-Path -LiteralPath $real -PathType Container)) { Stop-Refuse 'the configuration directory does not exist' }
    if (-not (Test-HarnessSentinel $real)) { Stop-Refuse 'the configuration directory has no sentinel file (initialise it with doctor.ps1 -Init first)' }
    $null = Assert-HarnessCfgEntries $real # on every start, since a link can appear after -Init
    $ini = Join-Path $real 'reaper.ini'
    if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) { Stop-Refuse 'the configuration directory has no reaper.ini' }
    [pscustomobject]@{ Dir = $real; Ini = $ini }
}

# Whether the directory holds the sentinel doctor.ps1 -Init wrote (first line is exactly the magic).
function Test-HarnessSentinel([string]$Folder) {
    $sentinel = Join-Path $Folder $script:SentinelName
    (Test-Path -LiteralPath $sentinel -PathType Leaf) -and ("$(Get-Content -LiteralPath $sentinel -TotalCount 1)".Trim() -ceq $script:SentinelMagic)
}

# For doctor.ps1 -Init: after the path checks, creates the directory, the private plugin directory, a minimal
# reaper.ini (dummy audio device) and the sentinel. Only three kinds of directory are taken over: one that does not
# exist yet, an empty one, and one that already has the sentinel (initialised before; an existing ini is left alone).
# A directory with content but no sentinel is always refused and nothing is written, and there is no switch to
# override that: it is most likely a real REAPER configuration (for example a portable install), and the tests would
# rewrite its reaper.ini and copy plugins into its plugin directory.
function New-HarnessCfgDir {
    param([string]$CfgDir)
    $real = Assert-HarnessOutsideDefaultDir $CfgDir
    if (Test-Path -LiteralPath $real) {
        if (-not (Test-Path -LiteralPath $real -PathType Container)) { Stop-Refuse '-CfgDir points to a file, not a directory' }
        if (-not (Test-HarnessSentinel $real) -and @(Get-ChildItem -LiteralPath $real -Force).Count -gt 0) {
            Stop-Refuse '-CfgDir has content but no sentinel file: only a missing directory, an empty one or one initialised before is taken over; nothing was written'
        }
        $null = Assert-HarnessCfgEntries $real # before anything is written: the writes below would go through a link
    }
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $real 'plugins')
    $ini = Join-Path $real 'reaper.ini'
    if (-not (Test-Path -LiteralPath $ini)) {
        [IO.File]::WriteAllText($ini, "[REAPER]`npromptendrec=0`n[audioconfig]`nmode=4`ndummy_srate=48000`ndummy_blocksize=512`n", [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $real $script:SentinelName), "$($script:SentinelMagic)`n", [Text.UTF8Encoding]::new($false))
    Assert-HarnessCfgDir $real
}

# Pins the ini path into a read-only constant (Constant cannot be changed even with -Force): any later assignment,
# including one through a same-name variable that differs only by case, is a hard error. The whole tree is walked first,
# so a refusal leaves nothing pinned; a later call in the same process only checks what every start checks.
function Initialize-HarnessCfg {
    param([string]$CfgDir)
    $g = Assert-HarnessCfgDir $CfgDir
    $held = Get-Variable -Name HarnessPinnedCfgIni -Scope Script -ErrorAction SilentlyContinue
    if ($held) {
        if ($held.Value -cne $g.Ini) { Stop-Refuse 'this process has already pinned a different configuration directory' }
    } else {
        Assert-HarnessCfgTree $g.Dir # once per process
        New-Variable -Name HarnessPinnedCfgIni -Value $g.Ini -Option Constant -Scope Script
    }
    $g
}

# The only source of the value of the -cfgfile argument: checks the directory again, then returns the path from the
# constant, without quotes. Invoke-HarnessHost passes it as one element of ArgumentList, and .NET does the quoting.
function Get-HarnessCfgArgument {
    if (-not (Get-Variable -Name HarnessPinnedCfgIni -Scope Script -ErrorAction SilentlyContinue)) { Stop-Refuse 'Initialize-HarnessCfg has not run' }
    $g = Assert-HarnessCfgDir (Split-Path -Parent $script:HarnessPinnedCfgIni)
    if ($g.Ini -cne $script:HarnessPinnedCfgIni) { Stop-Refuse 'the real path of the configuration directory changed' }
    return $script:HarnessPinnedCfgIni
}

# The pinned configuration directory (real path), for callers that need to place files in it (plugins, cache).
function Get-HarnessPinnedCfgDir {
    $null = Get-HarnessCfgArgument
    Split-Path -Parent $script:HarnessPinnedCfgIni
}

# Changes one key in ini text (pure function, used directly by the self-test): a missing section is appended at the
# end, a missing key goes after the last non-empty line of its section. The line-ending style is kept.
function Set-HarnessIniText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Value)
    $eol = $Text.Contains("`r`n") ? "`r`n" : "`n"
    $lines = [Collections.Generic.List[string]]::new([string[]]($Text -split '\r?\n'))
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    $head = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq "[$Section]") { $head = $i; break } }
    if ($head -lt 0) {
        $lines.Add("[$Section]"); $lines.Add("$Key=$Value")
    } else {
        $end = $head + 1
        while ($end -lt $lines.Count -and -not $lines[$end].TrimStart().StartsWith('[')) { $end++ }
        $hit = -1
        for ($i = $head + 1; $i -lt $end; $i++) { if ($lines[$i] -imatch ('^' + [regex]::Escape($Key) + '=')) { $hit = $i; break } }
        if ($hit -ge 0) {
            if ($lines[$hit] -ceq "$Key=$Value") { return $Text }
            $lines[$hit] = "$Key=$Value"
        } else {
            $at = $end
            while ($at -gt $head + 1 -and $lines[$at - 1].Trim() -eq '') { $at-- }
            $lines.Insert($at, "$Key=$Value")
        }
    }
    ($lines -join $eol) + $eol
}

# Changes one key of the private ini. Read and written as Latin-1 so bytes round-trip; only written when the text
# actually changed. Returns whether it changed.
function Set-HarnessIniValue {
    param([Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Value)
    $null = Get-HarnessCfgArgument
    $iniPath = $script:HarnessPinnedCfgIni
    $enc = [Text.Encoding]::Latin1
    $old = $enc.GetString([IO.File]::ReadAllBytes($iniPath))
    $new = Set-HarnessIniText -Text $old -Section $Section -Key $Key -Value $Value
    if ($new -ceq $old) { return $false }
    [IO.File]::WriteAllBytes($iniPath, $enc.GetBytes($new))
    $true
}

# The default resource directory REAPER uses without -cfgfile, i.e. %APPDATA%\REAPER. Only used to take listings and
# to build the "must be refused" negative case; never written.
function Get-HarnessDefaultCfgDir { Join-Path $env:APPDATA 'REAPER' }

# Listing of everything under the default resource directory, read only. Files are recorded as "size|write-time
# ticks"; directories only as present: NTFS updates the time stamps of subdirectories in the parent listing lazily,
# so two reads in a row can differ and would cause false alarms. Changes inside a directory show up on its files.
# A directory that cannot be listed is recorded as "unreadable" (the root itself under the name "."), not left out: a
# change inside it could not show up, so the comparison must not call it unchanged. A missing directory gives an empty
# listing. Root is only for the self-test.
function Get-HarnessDefaultCfgSnapshot {
    param([string]$Root = (Get-HarnessDefaultCfgDir))
    $snap = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        # Test-Path also says no for a path it cannot look at: that is not a missing directory
        $rootId = Get-HarnessFileIdentity $Root
        if ($rootId -and $rootId.StartsWith('ERROR:')) { $snap['.'] = 'unreadable' }
        return $snap
    }
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    foreach ($e in Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable listingFaults) {
        $snap[$e.FullName.Substring($prefix.Length)] = $e.PSIsContainer ? 'dir' : ('{0}|{1}' -f $e.Length, $e.LastWriteTimeUtc.Ticks)
    }
    foreach ($fault in $listingFaults) {
        $faultPath = try { [IO.Path]::GetFullPath([string]$fault.TargetObject) } catch { '' }
        $snap[$faultPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) ? $faultPath.Substring($prefix.Length) : '.'] = 'unreadable'
    }
    $snap
}

function Compare-HarnessDefaultCfgSnapshot {
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    $changed = [Collections.Generic.List[string]]::new()
    foreach ($k in $Before.get_Keys()) {
        if (-not $After.Contains($k)) { $changed.Add("removed:$k") }
        elseif ($After[$k] -cne $Before[$k]) { $changed.Add("changed:$k") }
    }
    foreach ($k in $After.get_Keys()) { if (-not $Before.Contains($k)) { $changed.Add("added:$k") } }
    # Unreadable in either listing, even in both: nothing can be said about what is in there, so it does not count as unchanged
    $unreadable = [Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($listing in @($Before, $After)) {
        foreach ($entry in $listing.GetEnumerator()) { if ($entry.Value -ceq 'unreadable') { $null = $unreadable.Add($entry.Key) } }
    }
    [pscustomobject]@{ Same = ($changed.Count -eq 0 -and $unreadable.get_Count() -eq 0); Count = $Before.get_Count(); Changed = $changed.ToArray(); Unreadable = @($unreadable) }
}

# Variable names in a script that differ only by case (file wide, stricter than PowerShell's scoping). A parse
# failure is a problem too and is not let through.
function Find-HarnessVariableCaseCollisions {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    $out = [Collections.Generic.List[string]]::new()
    foreach ($e in $parseErrors) { $out.Add("parse error: $($e.Message)") }
    $spellings = @{}
    $isVar = { param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }
    foreach ($v in $ast.FindAll($isVar, $true)) {
        $name = $v.VariablePath.UserPath -replace '^(?:script|global|local|private):', ''
        $lower = $name.ToLowerInvariant()
        if (-not $spellings.ContainsKey($lower)) { $spellings[$lower] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
        $null = $spellings[$lower].Add($name)
    }
    foreach ($entry in $spellings.GetEnumerator()) {
        if ($entry.Value.Count -gt 1) { $out.Add('variable names differ only by case: ' + (($entry.Value | Sort-Object | ForEach-Object { '$' + $_ }) -join ' / ')) }
    }
    , $out.ToArray()
}

# Invisible control characters in a text, one description each (line, column, code point). TAB, LF and a CR right
# before LF (Windows line ends) are fine; every other C0 control character, DEL, and a CR not at a line end count.
# They are invisible in editors and diffs, and once one is swallowed the meaning of a regex or string changes.
function Find-HarnessControlChars {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $out = [Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($Text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]|\r(?!\n)')) {
        $leading = $Text.Substring(0, $m.Index)
        $line = ($leading.Length - $leading.Replace("`n", '').Length) + 1
        $col = $m.Index - $leading.LastIndexOf("`n")
        $out.Add(('line {0} column {1}: U+{2:X4}' -f $line, $col, [int][char]$m.Value))
    }
    , $out.ToArray()
}

# Scans the .ps1 / .psm1 files under a set of paths (directories are walked recursively, files taken as they are).
# Besides variable case collisions: every file has Set-StrictMode -Version Latest; the -cfgfile literal appears
# exactly once overall and only in src/Host.psm1; APPDATA is only mentioned in src/Guard.psm1 and tests/SelfTest.psm1 (no
# other file should even read it; LOCALAPPDATA, a different directory, is not meant). Those exemptions go by the path
# relative to the repository root, not by the file name: a tests/Host.psm1 is not src/Host.psm1. Root defaults to the
# repository this module is in; the self-test passes its scratch directories. Comments do not count. .Keys and
# .Values are never read as properties: on a dictionary that has an entry named "Keys" or "Values" (a key from a
# config, a file name, a variable name) the property returns that entry instead, and a check that walks the keys
# silently walks one value; .get_Keys() / .get_Values() / .GetEnumerator() cannot be shadowed. .ps1 / .psm1 / .lua /
# .json files must not contain invisible control characters.
function Test-HarnessScriptLint {
    param([Parameter(Mandatory)][string[]]$Paths, [string]$Root = (Split-Path -Parent $PSScriptRoot))
    $problems = [Collections.Generic.List[string]]::new()
    $sites = 0
    $isStrict = { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ieq 'Set-StrictMode' -and $n.Extent.Text -imatch '-Version\s+Latest' }
    $isShadowable = {
        param($n)
        $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Member.Value -in 'Keys', 'Values'
    }
    $word = 'cfg' + 'file' # built from two parts: this file's own rule literal must not count as a -cfgfile site
    $isCfg = {
        param($n)
        ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -imatch $word) -or
        ($n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $n.Value -imatch $word) -or
        ($n -is [System.Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -ieq $word)
    }.GetNewClosure()
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($Path in $Paths) {
        if (Test-Path -LiteralPath $Path -PathType Container) { foreach ($f in Get-ChildItem -LiteralPath $Path -Recurse -File) { $files.Add($f) } }
        elseif (Test-Path -LiteralPath $Path -PathType Leaf) { $files.Add((Get-Item -LiteralPath $Path)) }
        else { $problems.Add("path does not exist: $(Split-Path -Leaf $Path)") }
    }
    foreach ($f in $files | Where-Object { $_.Extension -in '.lua', '.json' }) {
        foreach ($c in (Find-HarnessControlChars -Text ([IO.File]::ReadAllText($f.FullName)))) { $problems.Add("$($f.Name): contains an invisible control character ($c)") }
    }
    foreach ($f in $files | Where-Object { $_.Extension -in '.ps1', '.psm1' }) {
        $source = [IO.File]::ReadAllText($f.FullName)
        foreach ($c in (Find-HarnessControlChars -Text $source)) { $problems.Add("$($f.Name): contains an invisible control character ($c)") }
        foreach ($c in (Find-HarnessVariableCaseCollisions -Text $source)) { $problems.Add("$($f.Name): $c") }
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
        foreach ($m in $ast.FindAll($isShadowable, $true)) { $problems.Add("$($f.Name): line $($m.Extent.StartLineNumber): .$($m.Member.Value) read as a property (a dictionary entry of that name would shadow it): use .get_$($m.Member.Value)()") }
        if (@($ast.FindAll($isStrict, $true)).Count -eq 0) { $problems.Add("$($f.Name): missing Set-StrictMode -Version Latest") }
        $n = @($ast.FindAll($isCfg, $true)).Count
        $sites += $n
        $rel = [IO.Path]::GetRelativePath($Root, $f.FullName).Replace('\', '/')
        if ($n -gt 0 -and $rel -ine 'src/Host.psm1') { $problems.Add("${rel}: -$word may only be built in src/Host.psm1") }
        if ($rel -inotin 'src/Guard.psm1', 'tests/SelfTest.psm1' -and @($tokens | Where-Object { $_.Kind -ne 'Comment' -and $_.Text -imatch '(?<!local)appdata' }).Count -gt 0) {
            $problems.Add("${rel}: only src/Guard.psm1 and tests/SelfTest.psm1 may mention APPDATA")
        }
    }
    if ($sites -ne 1) { $problems.Add("the -$word literal must appear exactly once, found $sites") }
    , $problems.ToArray()
}

Export-ModuleMember -Function Get-HarnessSentinel, Get-HarnessFileIdentity, Resolve-HarnessRealPath, Test-HarnessUnder, Assert-HarnessCfgDir, New-HarnessCfgDir, Initialize-HarnessCfg,
    Get-HarnessCfgArgument, Get-HarnessPinnedCfgDir, Set-HarnessIniText, Set-HarnessIniValue, Get-HarnessDefaultCfgDir, Get-HarnessDefaultCfgSnapshot, Compare-HarnessDefaultCfgSnapshot,
    Find-HarnessVariableCaseCollisions, Find-HarnessControlChars, Test-HarnessScriptLint
