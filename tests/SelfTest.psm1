# SPDX-License-Identifier: MIT
#
# The self-test of reaper-harness. It never starts REAPER: everything happens in a fake APPDATA and in a scratch
# directory under the system temporary directory; the real %APPDATA%\REAPER is only listed once at the start and once
# at the end, and the two listings must be equal.
# Each case is (label, bad, passed): a bad case is one that must be stopped or turned red, and passed means it was.
# Cases that need the configuration directory pinned into the process (irreversible once Initialize-HarnessCfg ran)
# run in a child process, tests/SelfTestChild.ps1, which also runs the whole suite against a stand-in for REAPER.
#   Invoke-HarnessSelfTest -RepoRoot <repo> [-CollisionSample <a .ps1 with variable names that differ only by case>]
#                          [-ExtraGuiLock <Local\name>]...   returns the exit code (0 all passed, 1 otherwise)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Src = Join-Path $PSScriptRoot '../src'
foreach ($m in 'Guard', 'Host', 'Locks', 'Json', 'Wav', 'Report', 'Config', 'Rpp', 'Plugins', 'Transport', 'Sources', 'Scenarios', 'Learn', 'Extensions', 'States', 'Renders', 'Suite') { Import-Module (Join-Path $script:Src "$m.psm1") -ErrorAction Stop }
Import-Module (Join-Path $PSScriptRoot 'TempDir.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FakeReaper.psm1') -ErrorAction Stop

function Test-Refused([scriptblock]$Action, [string]$Like = '*') {
    try { $null = & $Action; $false } catch { $_.Exception.Message -like 'REFUSED:*' -and $_.Exception.Message -like $Like }
}
function Test-Usage([scriptblock]$Action, [string]$Like = '*') {
    try { $null = & $Action; $false } catch { $_.Exception.Message -like 'USAGE:*' -and $_.Exception.Message -like $Like }
}
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $psi = [Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $p = [Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    [pscustomobject]@{ Exit = $p.ExitCode; Out = $so.Result; Err = $se.Result }
}
function New-CaseList { , [Collections.Generic.List[object]]::new() }

# Runs Action with one internal function of the guard module replaced, and always puts the original back. This reaches
# states the self-test must not or cannot make on the machine it runs on (a mapped network drive, a link count that
# cannot be read).
function Invoke-WithGuardStub([string]$Inner, [scriptblock]$Stub, [scriptblock]$Action) {
    $guard = (Get-Command Assert-HarnessCfgDir).Module
    $original = & $guard { param($n) (Get-Item "function:$n").ScriptBlock } $Inner
    & $guard { param($n, $s) Set-Item "function:script:$n" $s } $Inner $Stub
    try { & $Action } finally { & $guard { param($n, $s) Set-Item "function:script:$n" $s } $Inner $original }
}

# The same for the module that holds Command: one function as that module calls it (its own or one it imported) is
# replaced while Action runs. This reaches failures a real file cannot be made to show on demand (a file a scanner holds
# right after it was moved).
function Invoke-WithModuleStub([string]$Command, [string]$Inner, [scriptblock]$Stub, [scriptblock]$Action) {
    $module = (Get-Command $Command).Module
    $original = & $module { param($n) (Get-Item "function:$n").ScriptBlock } $Inner
    & $module { param($n, $s) Set-Item "function:script:$n" $s } $Inner $Stub
    try { & $Action } finally { & $module { param($n, $s) Set-Item "function:script:$n" $s } $Inner $original }
}

# Runs Action while a directory of this self-test cannot be listed (a deny entry for everyone, taken away again whatever
# happens). Denied says whether the listing really failed; where it did not, the caller's case has not run for real.
# Restored says whether the entry was taken away again: when it was not, the scratch directory cannot be deleted, so the
# caller turns that into a red case.
function Invoke-WithListingDenied([string]$Folder, [scriptblock]$Action) {
    $outcome = [pscustomobject]@{ Denied = $false; Result = $null; Restored = $true }
    & icacls.exe $Folder /deny '*S-1-1-0:(RD)' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $outcome }
    try {
        $outcome.Denied = try { $null = Get-ChildItem -LiteralPath $Folder -Force -ErrorAction Stop; $false } catch { $true }
        if ($outcome.Denied) { $outcome.Result = & $Action }
    } finally {
        & icacls.exe $Folder /remove:d '*S-1-1-0' 2>&1 | Out-Null
        $outcome.Restored = $LASTEXITCODE -eq 0
    }
    $outcome
}

$script:ScratchPrefix = 'reaper-harness-selftest-' # New-HarnessTempDir appends 32 random hex digits
$script:SubstLetters = 'Z', 'Y', 'X', 'W', 'V', 'U' # letters the self-test borrows for subst (first free one), and the only ones cleaned up

# A subst mapping is visible to the whole logon session: when the self-test is ended hard (Ctrl+C twice, a watchdog,
# a closed terminal) the "subst /d" in its finally block never runs, and the letter keeps pointing at a scratch
# directory that was deleted. So the self-test cleans up first. Only mappings meeting both conditions are removed:
# the letter is one of Z..U, and the target is a directory named <prefix><32 hex digits> (the scratch naming) or
# below one. Any other mapping (the user's own) is left alone. Returns what was handled (letter, target, cleared) for
# the caller to print; targets only go to the local console.
function Get-SelfTestStalePrefix { [IO.Path]::Join([IO.Path]::GetTempPath(), $script:ScratchPrefix) }

function Clear-HarnessSelftestSubst {
    param([string]$Prefix = (Get-SelfTestStalePrefix), [string[]]$Letters = $script:SubstLetters)
    $done = [Collections.Generic.List[object]]::new()
    $listing = try { (& subst.exe 2>&1 | Out-String) } catch { '' }
    $prefixFull = [IO.Path]::GetFullPath($Prefix)
    $owned = '^' + [regex]::Escape($prefixFull) + '[0-9a-f]{32}(\\|$)'
    foreach ($line in ($listing -split "`r?`n")) {
        $m = [regex]::Match($line, '^([A-Za-z]):\\: => (.+)$')
        if (-not $m.Success) { continue }
        $driveLetter = $m.Groups[1].Value.ToUpperInvariant()
        if ($driveLetter -notin $Letters) { continue }
        $target = $m.Groups[2].Value.Trim()
        $full = try { [IO.Path]::GetFullPath($target) } catch { '' }
        if (-not $full -or $full -inotmatch $owned) { continue }
        & subst.exe "${driveLetter}:" /d 2>&1 | Out-Null
        $done.Add([pscustomobject]@{ Letter = $driveLetter; Target = $target; Cleared = ($LASTEXITCODE -eq 0) })
    }
    $done.ToArray() # one by one (not wrapped): the caller collects with @(), so nothing left is an empty array
}

# ---------------------------------------------------------------- guards
function Get-GuardCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $defaultDir = Get-HarnessDefaultCfgDir
    # Two layers refuse with different reasons: the string layer (prefixes after expanding .. and links) and the file
    # identity layer. The cases assert the reason, so removing either layer turns a case red.
    $byString = '*under AppData (or points there): *never touched*'
    $byIdentity = '*detected by file identity*'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $defaultDir 'Data')
    & $add 'no -CfgDir is refused' $true (Test-Refused { Assert-HarnessCfgDir '' })
    & $add 'a relative path is refused' $true (Test-Refused { Assert-HarnessCfgDir 'reaper-cfg' } '*absolute path*')
    & $add 'the default resource directory itself is refused' $true (Test-Refused { Assert-HarnessCfgDir $defaultDir } $byString)
    & $add 'a directory below the default resource directory is refused (it need not exist)' $true (Test-Refused { Assert-HarnessCfgDir (Join-Path $defaultDir 'Data\x') } $byString)
    & $add 'the default resource directory written in upper case with forward slashes is refused' $true (Test-Refused { Assert-HarnessCfgDir ($defaultDir.ToUpperInvariant() -replace '\\', '/') } $byString)
    $junction = Join-Path $Tmp 'link-to-default'
    $null = New-Item -ItemType Junction -Path $junction -Target $defaultDir
    try { & $add 'a junction pointing at the default resource directory is refused' $true (Test-Refused { Assert-HarnessCfgDir $junction } $byString) }
    finally { [IO.Directory]::Delete($junction) } # removes the link only
    # Other spellings of the same directory (or its parent): all must be refused. All of them are paths in the fake
    # APPDATA, the real one is never used here.
    $roam = Split-Path -Parent $defaultDir
    $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($defaultDir).ShortPath
    $hasShort = $short -cne $defaultDir
    $noShort = $hasShort ? '' : ' (this volume has no 8.3 short names; not run for real)'
    & $add "the default resource directory as an 8.3 short name is refused (GetFullPath expands it; identity is the second layer)$noShort" $true ((-not $hasShort) -or (Test-Refused { Assert-HarnessCfgDir $short } '*never touched*'))
    & $add "a directory that does not exist yet below the 8.3 short name is refused too$noShort" $true ((-not $hasShort) -or (Test-Refused { Assert-HarnessCfgDir (Join-Path $short 'Data\not-yet') } '*never touched*'))
    & $add "file identity: the 8.3 short name and the long name are the same$noShort" $false ((-not $hasShort) -or ((Get-HarnessFileIdentity $short) -ceq (Get-HarnessFileIdentity $defaultDir)))
    & $add 'file identity: different directories differ, a missing path has none' $false ((Get-HarnessFileIdentity $defaultDir) -and (Get-HarnessFileIdentity $defaultDir) -cne (Get-HarnessFileIdentity $Tmp) -and $null -eq (Get-HarnessFileIdentity (Join-Path $Tmp 'nope-nope')))
    & $add "the 8.3 short name in lower case is refused too (short names are case insensitive)$noShort" $true ((-not $hasShort) -or (Test-Refused { Assert-HarnessCfgDir $short.ToLowerInvariant() } '*never touched*'))
    & $add 'the default resource directory with a \\?\ prefix is refused' $true (Test-Refused { Assert-HarnessCfgDir ('\\?\' + $defaultDir) } '*drive letter*')
    & $add 'the default resource directory as a \\.\ device path or with \??\ is refused' $true ((Test-Refused { Assert-HarnessCfgDir ('\\.\' + $defaultDir) } '*drive letter*') -and (Test-Refused { Assert-HarnessCfgDir ('\??\' + $defaultDir) } '*drive letter*'))
    $admin = '\\localhost\' + $defaultDir.Substring(0, 1) + '$' + $defaultDir.Substring(2)
    & $add 'the default resource directory through the \\localhost admin share is refused' $true (Test-Refused { Assert-HarnessCfgDir $admin } '*drive letter*')
    # Beyond the first layer (drive letters only) the identity layer itself recognises these spellings, so a bypass of
    # the first layer still meets a second one. The admin share only has an identity when it is enabled on this
    # machine; when it cannot be read this part is not judged.
    $idDefault = Get-HarnessFileIdentity $defaultDir
    $idAdmin = Get-HarnessFileIdentity $admin
    & $add 'file identity: the \\?\ and \\.\ spellings equal the directory; so does the admin share when it can be read' $false (($idDefault -ceq (Get-HarnessFileIdentity ('\\?\' + $defaultDir))) -and ($idDefault -ceq (Get-HarnessFileIdentity ('\\.\' + $defaultDir))) -and ((-not $idAdmin) -or $idAdmin.StartsWith('ERROR:') -or ($idAdmin -ceq $idDefault)))
    & $add 'trailing separators do not change the verdict' $true ((Test-Refused { Assert-HarnessCfgDir ($defaultDir + '\') } $byString) -and (Test-Refused { Assert-HarnessCfgDir ($defaultDir + '\\') } $byString))
    & $add 'trailing dots and spaces do not change the verdict (Win32 drops them)' $true ((Test-Refused { Assert-HarnessCfgDir ($defaultDir + '.') } $byString) -and (Test-Refused { Assert-HarnessCfgDir ($defaultDir + ' ') } $byString))
    # A subst drive: nothing in the string shows it is APPDATA, only the file identity catches it. The walk must go
    # up to the drive root, which is APPDATA itself here.
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
    $letter = @($script:SubstLetters) | Where-Object { $_ -notin $used } | Select-Object -First 1
    $substOk = $false
    if ($letter) { & subst.exe "${letter}:" $roam 2>&1 | Out-Null; $substOk = ($LASTEXITCODE -eq 0) }
    if ($substOk) {
        try {
            & $add 'with a subst drive pointing at APPDATA, \REAPER on that drive is refused (the directory and its parents up to the root compared by identity)' $true ((Test-Refused { Assert-HarnessCfgDir "${letter}:\REAPER" } $byIdentity) -and (Test-Refused { Assert-HarnessCfgDir "${letter}:\REAPER\Data\not-yet" } $byIdentity) -and (Test-Refused { Assert-HarnessCfgDir "${letter}:\" } $byIdentity))
            & $add 'file identity: the root of a subst drive equals the directory it points at' $false ((Get-HarnessFileIdentity "${letter}:\") -ceq (Get-HarnessFileIdentity $roam))
            & $add 'result directory: on a subst drive pointing at APPDATA it is refused by file identity, also when it does not exist yet' $true ((Test-Refused { Assert-HarnessResultDir "${letter}:\REAPER" } '*-ResultDir*detected by file identity*') -and (Test-Refused { Assert-HarnessResultDir "${letter}:\REAPER\Data\not-yet" } '*-ResultDir*detected by file identity*'))
        } finally {
            & subst.exe "${letter}:" /d 2>&1 | Out-Null
            & $add 'the subst drive pointing at APPDATA was removed again' $false ($LASTEXITCODE -eq 0)
        }
    } else {
        & $add '(no subst drive could be made on this machine: the subst cases did not run for real)' $false $true
    }
    # An identity that cannot be read is never let through: here an invalid file name causes a Win32 error other than "not found"
    & $add 'an unreadable file identity (invalid name) is refused, not let through' $true ((Test-Refused { Assert-HarnessCfgDir (Join-Path $Tmp 'bad|name') } '*file identity*cannot be read*') -and ((Get-HarnessFileIdentity (Join-Path $Tmp 'bad|name')) -like 'ERROR:*'))
    & $add 'spellings with .. that lead back into the default resource directory are refused' $true ((Test-Refused { Assert-HarnessCfgDir "$defaultDir\Data\..\Data\x" } $byString) -and (Test-Refused { Assert-HarnessCfgDir ($roam + '\..\' + (Split-Path -Leaf $roam) + '\REAPER') } $byString))
    $junctionUp = Join-Path $Tmp 'link-to-roaming'
    $null = New-Item -ItemType Junction -Path $junctionUp -Target $roam
    try { & $add 'directories below a junction pointing at APPDATA (also ones that do not exist yet) are refused' $true ((Test-Refused { Assert-HarnessCfgDir (Join-Path $junctionUp 'REAPER\Data') } $byString) -and (Test-Refused { Assert-HarnessCfgDir (Join-Path $junctionUp 'not\yet') } $byString)) }
    finally { [IO.Directory]::Delete($junctionUp) }
    $sibling = Join-Path $Tmp ((Split-Path -Leaf $roam) + '-Other')
    & $add 'a sibling whose name only starts with the APPDATA directory name is not refused' $false ((New-HarnessCfgDir $sibling).Dir -like '*-Other')
    & $add 'New-HarnessCfgDir refuses the default resource directory too and creates nothing' $true ((Test-Refused { New-HarnessCfgDir $defaultDir } $byString) -and -not (Test-Path -LiteralPath (Join-Path $defaultDir (Get-HarnessSentinel).Name)))
    foreach ($c in (Get-InitCases $Tmp $RepoRoot)) { $cases.Add($c) }
    foreach ($c in (Get-CfgEntryCases $Tmp)) { $cases.Add($c) }
    foreach ($c in (Get-DriveCases $Tmp)) { $cases.Add($c) }
    foreach ($c in (Get-ResultDirCases $Tmp)) { $cases.Add($c) }
    $gone = Join-Path $Tmp 'not-there'
    & $add 'a directory that does not exist is refused' $true (Test-Refused { Assert-HarnessCfgDir $gone } '*does not exist*')
    $bare = Join-Path $Tmp 'bare'; $null = New-Item -ItemType Directory -Path $bare; Set-Content -LiteralPath (Join-Path $bare 'reaper.ini') -Value '[REAPER]'
    & $add 'an ini without the sentinel is refused' $true (Test-Refused { Assert-HarnessCfgDir $bare } '*sentinel*')
    Set-Content -LiteralPath (Join-Path $bare (Get-HarnessSentinel).Name) -Value 'something else'
    & $add 'a sentinel with the wrong content is refused' $true (Test-Refused { Assert-HarnessCfgDir $bare } '*sentinel*')
    $good = Join-Path $Tmp 'good'
    $made = New-HarnessCfgDir $good
    & $add 'a properly initialised configuration directory passes' $false ($made.Ini -like '*good\reaper.ini' -and (Assert-HarnessCfgDir $good).Dir -eq $made.Dir)
    Remove-Item -LiteralPath (Join-Path $good 'reaper.ini')
    & $add 'sentinel present but reaper.ini gone is refused' $true (Test-Refused { Assert-HarnessCfgDir $good } '*reaper.ini*')
    $cases
}

# What lies in the configuration directory: a link or a hard link would carry the reads and writes of REAPER and of
# Set-HarnessIniValue out of it, and the checks of the directory itself cannot see that. The top level is looked at on
# every check, the whole tree when the path is pinned. A pin that is refused pins nothing, so those cases run here; what
# happens after a real pin is in the child process.
function Get-CfgEntryCases([string]$Tmp) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $defaultDir = Get-HarnessDefaultCfgDir
    # Files are written to the default resource directory below, so it has to be the fake one in the scratch directory
    if (-not $defaultDir.StartsWith($Tmp, [StringComparison]::OrdinalIgnoreCase)) { throw 'not writing to a default resource directory that is not the fake one of this self-test' }
    $twin = Join-Path $defaultDir 'reaper.ini'
    $newCfg = { param([string]$DirName) $dir = Join-Path $Tmp $DirName; $null = New-HarnessCfgDir $dir; $dir }
    # Both directories hold a reaper.ini from here on: same name, different files, which is the normal case
    [IO.File]::WriteAllText($twin, "[REAPER]`nuser=1`n")
    try {
        $plain = & $newCfg 'entries-plain'
        & $add 'top level: files named like those in the default resource directory but different files pass' $false ((Assert-HarnessCfgDir $plain).Dir -like '*entries-plain')
        # Puts another name of Source (made first when it is not there) at the path Inside a new configuration directory
        $hardFor = {
            param([string]$DirName, [string]$Inside, [string]$Source)
            $dir = & $newCfg $DirName
            $at = Join-Path $dir $Inside
            if (Test-Path -LiteralPath $at) { Remove-Item -LiteralPath $at }
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $at)
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Source)
            if (-not (Test-Path -LiteralPath $Source)) { [IO.File]::WriteAllText($Source, 'x') }
            $made = try { $null = New-Item -ItemType HardLink -Path $at -Target $Source -ErrorAction Stop; $true } catch { $false }
            [pscustomobject]@{ Dir = $dir; Made = $made; At = $at }
        }
        $hard = & $hardFor 'entries-hard' 'reaper.ini' $twin
        $noHard = $hard.Made ? '' : ' (hard links cannot be made here; not run for real)'
        & $add "top level: reaper.ini as a hard link to the one in the default resource directory is refused$noHard" $true ((-not $hard.Made) -or (Test-Refused { Assert-HarnessCfgDir $hard.Dir } '*hard link*'))
        $renamed = & $hardFor 'entries-hard-renamed' 'reaper.ini' (Join-Path $defaultDir 'reaper-render.ini')
        & $add "top level: reaper.ini as a hard link to a file of another name in the default resource directory is refused$noHard" $true ((-not $renamed.Made) -or (Test-Refused { Assert-HarnessCfgDir $renamed.Dir } '*hard link*'))
        $intoSub = & $hardFor 'entries-hard-into-sub' 'extra.ini' (Join-Path $defaultDir 'Data\reaper-deep.ini')
        & $add "top level: another file as a hard link to a file in a subdirectory of the default resource directory is refused$noHard" $true ((-not $intoSub.Made) -or (Test-Refused { Assert-HarnessCfgDir $intoSub.Dir } '*hard link*'))
        $unrelated = & $hardFor 'entries-hard-unrelated' 'extra.ini' (Join-Path $Tmp 'entries-unrelated.txt')
        & $add "top level: a hard link to a file that has nothing to do with REAPER is refused too$noHard" $true ((-not $unrelated.Made) -or (Test-Refused { Assert-HarnessCfgDir $unrelated.Dir } '*hard link*'))
        $initHard = & $hardFor 'entries-hard-init' 'reaper.ini' (Join-Path $defaultDir 'reaper-init.ini')
        $initSentinel = Join-Path $initHard.Dir (Get-HarnessSentinel).Name
        $sentinelWritten = (Get-Item -LiteralPath $initSentinel).LastWriteTimeUtc
        & $add "-Init: a directory with the sentinel and a hard link in it is refused before anything is written$noHard" $true ((-not $initHard.Made) -or ((Test-Refused { New-HarnessCfgDir $initHard.Dir } '*hard link*') -and (Get-Item -LiteralPath $initSentinel).LastWriteTimeUtc -eq $sentinelWritten))
        # The reader itself, and what is done with a count that cannot be read: nothing done to a real file gets there
        $linkCount = { param([string]$Path) & (Get-Command Assert-HarnessCfgDir).Module { param($p) Get-HarnessFileLinkCount $p } $Path }
        $ownIni = (Assert-HarnessCfgDir $plain).Ini
        & $add "link count: a file of its own has one name, a hard link and its source have two$noHard" $false ((& $linkCount $ownIni) -eq 1 -and ((-not $unrelated.Made) -or ((& $linkCount $unrelated.At) -eq 2 -and (& $linkCount (Join-Path $Tmp 'entries-unrelated.txt')) -eq 2)))
        & $add 'link count: a path that cannot be opened has no count (below 1), a missing file and an invalid name alike' $true ((& $linkCount (Join-Path $Tmp 'nope-nope')) -lt 1 -and (& $linkCount (Join-Path $Tmp 'bad|name')) -lt 1)
        $countSays = { param($Answer) { param([string]$Path) $Answer }.GetNewClosure() }
        & $add 'top level: a link count that cannot be read is refused' $true ((Invoke-WithGuardStub 'Get-HarnessFileLinkCount' (& $countSays (-1)) { Test-Refused { Assert-HarnessCfgDir $plain } '*number of names*cannot be read*' }) -and (Invoke-WithGuardStub 'Get-HarnessFileLinkCount' (& $countSays 0) { Test-Refused { Assert-HarnessCfgDir $plain } '*number of names*cannot be read*' }))
        # A name the default directory does not have is nothing special: the count is what decides
        $lonely = Join-Path $plain 'only-here.ini'
        [IO.File]::WriteAllText($lonely, 'x')
        & $add 'top level: a file of its own that the default resource directory has no namesake for passes' $false ((Assert-HarnessCfgDir $plain).Dir -like '*entries-plain')
        Remove-Item -LiteralPath $lonely
        # The whole tree, when the path is pinned
        $deep = 'plugins\Some Plugin.vst3\Contents'
        $deepHard = & $hardFor 'tree-hard' "$deep\x.dll" (Join-Path $defaultDir 'reaper-tree.ini')
        & $add "whole tree: a hard link in a subdirectory is refused when the path is pinned$noHard" $true ((-not $deepHard.Made) -or (Test-Refused { Initialize-HarnessCfg $deepHard.Dir } "*$deep\x.dll*hard link*"))
        # On purpose: the check before every start stays at the top level, a tree of thousands of entries is walked once
        & $add "top level only: the check before every start does not look below the top level$noHard" $false ((-not $deepHard.Made) -or (Assert-HarnessCfgDir $deepHard.Dir).Dir -like '*tree-hard')
        $treeJunction = & $newCfg 'tree-junction'
        $elsewhere = Join-Path $treeJunction "$deep\elsewhere"
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $elsewhere)
        $null = New-Item -ItemType Junction -Path $elsewhere -Target $defaultDir
        try { & $add 'whole tree: a junction in a subdirectory is refused when the path is pinned' $true (Test-Refused { Initialize-HarnessCfg $treeJunction } '*link or junction*') }
        finally { [IO.Directory]::Delete($elsewhere) } # removes the link only
        $treeClosed = & $newCfg 'tree-closed'
        $closedSub = Join-Path $treeClosed 'plugins\deep'
        $null = New-Item -ItemType Directory -Path $closedSub
        $refusalOf = { param([scriptblock]$Action) try { $null = & $Action; '' } catch { $_.Exception.Message } }
        $subDenied = Invoke-WithListingDenied $closedSub { & $refusalOf { Initialize-HarnessCfg $treeClosed } }
        $noSubDeny = $subDenied.Denied ? '' : ' (a deny entry has no effect here; not run for real)'
        & $add "whole tree: a subdirectory that cannot be listed is refused when the path is pinned$noSubDeny" $true ((-not $subDenied.Denied) -or $subDenied.Result -like 'REFUSED:*cannot be listed*')
        & $add "whole tree: that refusal names the level, relative to the configuration directory$noSubDeny" $true ((-not $subDenied.Denied) -or $subDenied.Result -clike 'REFUSED:*cannot be listed (plugins\deep),*')
        & $add 'whole tree: that deny entry was taken away again' $false ($subDenied.Restored -and (Assert-HarnessCfgDir $treeClosed).Dir -like '*tree-closed' -and @(Get-ChildItem -LiteralPath $closedSub -Force).Count -eq 0)
        # A symbolic link needs a privilege most sessions do not have (runners do); a junction does not
        $sym = & $newCfg 'entries-symlink'
        Remove-Item -LiteralPath (Join-Path $sym 'reaper.ini')
        $symMade = try { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $sym 'reaper.ini') -Target $twin -ErrorAction Stop; $true } catch { $false }
        $noSym = $symMade ? '' : ' (symbolic links cannot be made in this session; not run for real)'
        & $add "top level: reaper.ini as a symbolic link is refused$noSym" $true ((-not $symMade) -or (Test-Refused { Assert-HarnessCfgDir $sym } '*link or junction*'))
        $junc = & $newCfg 'entries-junction'
        $plugins = Join-Path $junc 'plugins'
        Remove-Item -LiteralPath $plugins
        Remove-Item -LiteralPath (Join-Path $junc 'reaper.ini')
        $null = New-Item -ItemType Junction -Path $plugins -Target $defaultDir
        try {
            & $add 'top level: plugins as a junction is refused' $true (Test-Refused { Assert-HarnessCfgDir $junc } '*link or junction*')
            & $add '-Init: a directory with the sentinel and a junction in it is refused before anything is written through it' $true ((Test-Refused { New-HarnessCfgDir $junc } '*link or junction*') -and -not (Test-Path -LiteralPath (Join-Path $junc 'reaper.ini')))
        } finally { [IO.Directory]::Delete($plugins) } # removes the link only
        # A directory that cannot be listed: nothing in it can be proven to stay inside it
        $closed = & $newCfg 'entries-closed'
        $denied = Invoke-WithListingDenied $closed { & $refusalOf { Assert-HarnessCfgDir $closed } }
        $noDeny = $denied.Denied ? '' : ' (a deny entry has no effect here; not run for real)'
        & $add "top level: a configuration directory that cannot be listed is refused$noDeny" $true ((-not $denied.Denied) -or $denied.Result -like 'REFUSED:*cannot be listed*')
        & $add "top level: that refusal names the level as .$noDeny" $true ((-not $denied.Denied) -or $denied.Result -clike 'REFUSED:*cannot be listed (.),*')
        & $add 'top level: that deny entry was taken away again' $false ($denied.Restored -and (Assert-HarnessCfgDir $closed).Dir -like '*entries-closed')
    } finally { Get-ChildItem -LiteralPath $defaultDir -Recurse -Filter 'reaper*.ini' -File | Remove-Item } # only this self-test's fake directory
    $cases
}

# The result directory is written during a run: never the default resource directory, whatever leads there
function Get-ResultDirCases([string]$Tmp) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $defaultDir = Get-HarnessDefaultCfgDir
    $byPath = '*-ResultDir*never touched'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $defaultDir 'Data')
    & $add 'result directory: the default resource directory itself is refused' $true (Test-Refused { Assert-HarnessResultDir $defaultDir } $byPath)
    & $add 'result directory: below the default resource directory is refused, it need not exist' $true (Test-Refused { Assert-HarnessResultDir (Join-Path $defaultDir 'Data\results') } $byPath)
    & $add 'result directory: upper case and forward slashes change nothing' $true (Test-Refused { Assert-HarnessResultDir ($defaultDir.ToUpperInvariant() -replace '\\', '/') } $byPath)
    $toDefault = Join-Path $Tmp 'result-to-default'
    $toData = Join-Path $Tmp 'result-to-data'
    $null = New-Item -ItemType Junction -Path $toDefault -Target $defaultDir
    $null = New-Item -ItemType Junction -Path $toData -Target (Join-Path $defaultDir 'Data')
    try {
        & $add 'result directory: a junction pointing at the default resource directory is refused' $true (Test-Refused { Assert-HarnessResultDir $toDefault } $byPath)
        & $add 'result directory: below a junction pointing inside the default resource directory is refused' $true (Test-Refused { Assert-HarnessResultDir (Join-Path $toData 'results') } $byPath)
    } finally { [IO.Directory]::Delete($toDefault); [IO.Directory]::Delete($toData) } # removes the links only
    & $add 'result directory: a sibling whose name only starts the same way, elsewhere under AppData, is fine' $false (-not (Test-Refused { Assert-HarnessResultDir "$defaultDir-results" }))
    & $add 'result directory: anywhere else is fine, it need not exist' $false (-not (Test-Refused { Assert-HarnessResultDir (Join-Path $Tmp 'results\not-yet') }))
    # An identity that cannot be read proves nothing: that of the default resource directory, or of a parent on the way up
    $errorFor = { param([string]$Bad) { param([string]$Path) ([IO.Path]::GetFullPath($Path).TrimEnd('\') -ieq $Bad) ? 'ERROR:5' : [HarnessFileId]::Get($Path) }.GetNewClosure() }
    $unread = '*file identity*cannot be read (ERROR:5)*'
    & $add 'result directory: a default resource directory whose file identity cannot be read is refused' $true (
        Invoke-WithGuardStub 'Get-HarnessFileIdentity' (& $errorFor $defaultDir) { Test-Refused { Assert-HarnessResultDir (Join-Path $Tmp 'results\elsewhere') } $unread })
    $upper = Join-Path $Tmp 'result-parent'
    $null = New-Item -ItemType Directory -Force -Path $upper
    & $add 'result directory: a parent whose file identity cannot be read is refused' $true (
        Invoke-WithGuardStub 'Get-HarnessFileIdentity' (& $errorFor $upper) { Test-Refused { Assert-HarnessResultDir (Join-Path $upper 'results') } $unread })
    & $add 'result directory: the same directory with every identity readable is fine' $false (-not (Test-Refused { Assert-HarnessResultDir (Join-Path $upper 'results') }))
    # No default resource directory yet: there is no identity to compare, only the path can say it
    $savedAppData = $env:APPDATA
    $fresh = Join-Path $Tmp 'appdata-without-reaper'
    $freshLink = Join-Path $Tmp 'appdata-link'
    $null = New-Item -ItemType Directory -Force -Path $fresh
    $null = New-Item -ItemType Junction -Path $freshLink -Target $fresh
    try {
        $env:APPDATA = $fresh
        & $add 'result directory: with no default resource directory yet, the place it would be in is refused' $true (Test-Refused { Assert-HarnessResultDir (Join-Path $fresh 'REAPER\results') } $byPath)
        $env:APPDATA = $freshLink
        & $add 'result directory: the same when APPDATA itself is a link' $true (Test-Refused { Assert-HarnessResultDir (Join-Path $fresh 'REAPER\results') } $byPath)
    } finally { $env:APPDATA = $savedAppData; [IO.Directory]::Delete($freshLink) }
    $cases
}

# The drive the directory is on, as spelled and after expanding links. The types come through a stand-in: a real mapped
# drive would change the machine, so one is only made on a hosted runner, which is thrown away afterwards.
function Get-DriveCases([string]$Tmp) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $ok = Join-Path $Tmp 'drive-ok'
    $null = New-HarnessCfgDir $ok
    $alwaysType = { param([string]$Answer) { param([string]$Path) $Answer }.GetNewClosure() }
    $resolveTo = { param([string]$LeadsTo) { param([string]$Path, [int]$Depth = 0) $LeadsTo }.GetNewClosure() }
    # Network only on the letter Q, every other drive local
    $networkOnQ = { param([string]$Path) if ($Path -like 'Q:*') { 'Network' } else { 'Fixed' } }
    foreach ($kind in 'Network', 'Unknown', 'NoRootDirectory', '') {
        & $add "drive: a configuration directory on a drive of type '$kind' is refused" $true (Invoke-WithGuardStub 'Get-HarnessDriveType' (& $alwaysType $kind) { Test-Refused { Assert-HarnessCfgDir $ok } '*must be on a local drive*' })
    }
    foreach ($kind in 'Fixed', 'Removable') {
        & $add "drive: a configuration directory on a drive of type '$kind' passes" $false (Invoke-WithGuardStub 'Get-HarnessDriveType' (& $alwaysType $kind) { (Assert-HarnessCfgDir $ok).Dir -like '*drive-ok' })
    }
    & $add 'drive: a link that leads to a network drive is refused (the real path is checked too)' $true (
        Invoke-WithGuardStub 'Get-HarnessDriveType' $networkOnQ { Invoke-WithGuardStub 'Resolve-HarnessRealPath' (& $resolveTo 'Q:\cfg') { Test-Refused { Assert-HarnessCfgDir $ok } '*must be on a local drive*' } })
    & $add 'drive: a link that leads to a UNC path is refused (the real path is checked too)' $true (
        Invoke-WithGuardStub 'Resolve-HarnessRealPath' (& $resolveTo '\\server\share\cfg') { Test-Refused { Assert-HarnessCfgDir $ok } '*drive letter*' })
    & $add 'drive: a path on a network drive is refused even when its links lead back to a local path (the spelling is checked too)' $true (
        Invoke-WithGuardStub 'Get-HarnessDriveType' $networkOnQ { Invoke-WithGuardStub 'Resolve-HarnessRealPath' (& $resolveTo $ok) { Test-Refused { Assert-HarnessCfgDir 'Q:\cfg' } '*must be on a local drive*' } })
    & $add 'drive: a UNC path is refused even when its links lead back to a local path (the spelling is checked too)' $true (
        Invoke-WithGuardStub 'Resolve-HarnessRealPath' (& $resolveTo $ok) { Test-Refused { Assert-HarnessCfgDir '\\server\share\cfg' } '*drive letter*' })
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
    $free = @($script:SubstLetters | Where-Object { $_ -notin $used }) | Select-Object -First 1
    if (-not $free) {
        & $add '(no free letter among Z..U: the cases with a real drive letter did not run for real)' $false $true
        return $cases
    }
    & $add 'drive: a root whose type cannot be read gives no type at all (a UNC root has none)' $true (-not (& (Get-Command Assert-HarnessCfgDir).Module { Get-HarnessDriveType '\\server\share\cfg' }))
    # Without any stand-in: the real drive type of a letter nothing is mounted on
    & $add 'drive: a letter with nothing mounted on it is refused (the real type is read)' $true (Test-Refused { Assert-HarnessCfgDir "${free}:\cfg" } '*must be on a local drive*')
    # A subst drive stands for a local directory: it stays allowed
    $substHome = Join-Path $Tmp 'drive-subst'
    $null = New-Item -ItemType Directory -Path $substHome
    & subst.exe "${free}:" $substHome 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        try { & $add 'drive: a subst drive pointing at a local directory is not refused' $false ((New-HarnessCfgDir "${free}:\cfg").Dir -ieq "${free}:\cfg" -and (Assert-HarnessCfgDir "${free}:\cfg").Dir -ieq "${free}:\cfg") }
        finally {
            & subst.exe "${free}:" /d 2>&1 | Out-Null
            & $add 'drive: that subst drive was removed again' $false ($LASTEXITCODE -eq 0)
        }
    } else {
        & $add '(no subst drive could be made on this machine: the subst drive positive case did not run for real)' $false $true
    }
    # A real mapped drive only where the machine is thrown away afterwards
    $mapped = $false
    if ($env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted') {
        $share = '\\localhost\' + $ok.Substring(0, 1) + '$' + $ok.Substring(2)
        & net.exe use "${free}:" $share 2>&1 | Out-Null
        $mapped = $LASTEXITCODE -eq 0
    }
    if ($mapped) {
        try { & $add 'drive: a real mapped network drive leading back to this machine is refused' $true (Test-Refused { Assert-HarnessCfgDir "${free}:\" } '*must be on a local drive*') }
        finally {
            & net.exe use "${free}:" /delete /y 2>&1 | Out-Null
            & $add 'drive: that mapped drive was deleted again' $false ($LASTEXITCODE -eq 0)
        }
    } else {
        & $add '(a mapped network drive is only made on a hosted runner, and it could not be made here: the mapped drive case did not run for real)' $false $true
    }
    $cases
}

# doctor.ps1 -Init (New-HarnessCfgDir) only takes over three kinds of directory: missing, empty, initialised before
# (with the sentinel). One with content but no sentinel is always refused with nothing written: the whole tree is
# compared before and after by name, size, write time and content hash.
function Get-TreeFingerprint([string]$TreeDir) {
    @(Get-ChildItem -LiteralPath $TreeDir -Recurse -Force | Sort-Object FullName | ForEach-Object {
            $rel = $_.FullName.Substring($TreeDir.Length)
            $_.PSIsContainer ? "$rel|dir" : ('{0}|{1}|{2}|{3}' -f $rel, $_.Length, $_.LastWriteTimeUtc.Ticks, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)
        }) -join "`n"
}

function Get-InitCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $sentinel = (Get-HarnessSentinel).Name
    $refusedUntouched = {
        param([string]$TreeDir)
        $before = Get-TreeFingerprint $TreeDir
        $refused = Test-Refused { New-HarnessCfgDir $TreeDir } '*has content but no sentinel*'
        $refused -and (Get-TreeFingerprint $TreeDir) -ceq $before -and -not (Test-Path -LiteralPath (Join-Path $TreeDir $sentinel))
    }
    # What a portable REAPER looks like: a reaper.ini and a plugins directory
    $portable = Join-Path $Tmp 'init-portable'
    $null = New-Item -ItemType Directory -Path (Join-Path $portable 'plugins')
    [IO.File]::WriteAllText((Join-Path $portable 'reaper.ini'), "[REAPER]`nvstpath64=elsewhere`n[audioconfig]`nmode=3`n")
    [IO.File]::WriteAllText((Join-Path $portable 'plugins/user.dll'), 'bits')
    & $add '-Init: a directory with content but no sentinel (for example a portable REAPER) is refused, nothing written (tree unchanged, no sentinel)' $true (& $refusedUntouched $portable)
    $hiddenOnly = Join-Path $Tmp 'init-hidden-only'
    $null = New-Item -ItemType Directory -Path $hiddenOnly
    $hiddenFile = Join-Path $hiddenOnly 'desktop.ini'
    [IO.File]::WriteAllText($hiddenFile, 'x')
    (Get-Item -LiteralPath $hiddenFile -Force).Attributes = 'Hidden'
    & $add '-Init: a directory with only a hidden file counts as content: refused, nothing written' $true (& $refusedUntouched $hiddenOnly)
    $subOnly = Join-Path $Tmp 'init-subdir-only'
    $null = New-Item -ItemType Directory -Path (Join-Path $subOnly 'empty-sub')
    & $add '-Init: a directory with only an empty subdirectory counts as content: refused, nothing written' $true (& $refusedUntouched $subOnly)
    $wrongMagic = Join-Path $Tmp 'init-wrong-sentinel'
    $null = New-Item -ItemType Directory -Path $wrongMagic
    [IO.File]::WriteAllText((Join-Path $wrongMagic $sentinel), "something else`n")
    [IO.File]::WriteAllText((Join-Path $wrongMagic 'reaper.ini'), "[REAPER]`n")
    $before = Get-TreeFingerprint $wrongMagic
    & $add '-Init: a sentinel with the wrong content does not count as initialised before: refused, nothing written' $true ((Test-Refused { New-HarnessCfgDir $wrongMagic } '*has content but no sentinel*') -and (Get-TreeFingerprint $wrongMagic) -ceq $before)
    $aFile = Join-Path $Tmp 'init-a-file'
    [IO.File]::WriteAllText($aFile, 'x')
    & $add '-Init: a -CfgDir that is a file is refused, the file untouched' $true ((Test-Refused { New-HarnessCfgDir $aFile } '*points to a file*') -and [IO.File]::ReadAllText($aFile) -ceq 'x')
    $empty = Join-Path $Tmp 'init-empty'
    $null = New-Item -ItemType Directory -Path $empty
    $made = try { New-HarnessCfgDir $empty } catch { $null }
    & $add '-Init: an empty directory is taken over (plugins, reaper.ini, sentinel)' $false ($made -and (Test-Path -LiteralPath (Join-Path $empty $sentinel)) -and (Test-Path -LiteralPath (Join-Path $empty 'plugins') -PathType Container) -and (Test-Path -LiteralPath (Join-Path $empty 'reaper.ini')))
    $newIni = $made ? [IO.File]::ReadAllText((Join-Path $empty 'reaper.ini')) : ''
    & $add "-Init: the new reaper.ini has the dummy audio device and REAPER's version check off" $false (
        (Get-HarnessIniTextValue -Text $newIni -Section REAPER -Key verchk) -ceq '0' -and (Get-HarnessIniTextValue -Text $newIni -Section audioconfig -Key mode) -ceq '4')
    [IO.File]::WriteAllText((Join-Path $empty 'reaper.ini'), "[REAPER]`nkept=1`n")
    $again = try { New-HarnessCfgDir $empty } catch { $null }
    & $add '-Init: a directory initialised before (with the sentinel) stays usable; its reaper.ini is left alone' $false ($again -and [IO.File]::ReadAllText((Join-Path $empty 'reaper.ini')) -ceq "[REAPER]`nkept=1`n")
    $fresh = Join-Path $Tmp 'init-not-yet'
    & $add '-Init: a directory that does not exist is created' $false ($(try { New-HarnessCfgDir $fresh } catch { $null }) -and (Test-Path -LiteralPath (Join-Path $fresh $sentinel)))
    # Through the real entry point: doctor.ps1 -Init on content without a sentinel exits 64 and writes nothing
    $viaDoctor = Join-Path $Tmp 'init-doctor-portable'
    $null = New-Item -ItemType Directory -Path $viaDoctor
    [IO.File]::WriteAllText((Join-Path $viaDoctor 'reaper.ini'), "[REAPER]`nportable=1`n")
    $before = Get-TreeFingerprint $viaDoctor
    $run = Invoke-Native -Exe (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'doctor.ps1'), '-CfgDir', $viaDoctor, '-Init')
    & $add '-Init entry point: doctor.ps1 -Init on content without a sentinel exits 64 and writes nothing' $true ($run.Exit -eq 64 -and $run.Out -match 'REFUSED:' -and (Get-TreeFingerprint $viaDoctor) -ceq $before)
    $viaDoctorNew = Join-Path $Tmp 'init-doctor-new'
    $run = Invoke-Native -Exe (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'doctor.ps1'), '-CfgDir', $viaDoctorNew, '-Init')
    & $add '-Init entry point: doctor.ps1 -Init creates a new directory and exits 0; doctor.ps1 -CfgDir then reports it ready' $false (
        $run.Exit -eq 0 -and (Test-Path -LiteralPath (Join-Path $viaDoctorNew $sentinel)) -and
        (Invoke-Native -Exe (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'doctor.ps1'), '-CfgDir', $viaDoctorNew)).Exit -eq 0)
    $cases
}

# The clean-up at the start of the self-test (Clear-HarnessSelftestSubst), with real subst mappings: made, cleaned,
# checked. Often only one of Z..U is free, so one letter is used for all four kinds of mapping in turn; every mapping
# and directory made here is removed here, nothing else is touched.
function Get-SubstResidueCases([string]$Tmp) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    # The prefix of the clean-up must be the real scratch naming ($Tmp is this run's scratch directory), otherwise
    # real residue would not be recognised
    $fullPrefix = [IO.Path]::GetFullPath((Get-SelfTestStalePrefix))
    & $add 'subst residue: the clean-up prefix is the scratch naming of the self-test (prefix + 32 hex digits)' $false ([IO.Path]::GetFullPath($Tmp) -imatch ('^' + [regex]::Escape($fullPrefix) + '[0-9a-f]{32}$'))
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
    $slot = @($script:SubstLetters | Where-Object { $_ -notin $used }) | Select-Object -First 1
    if (-not $slot) {
        & $add '(no free letter among Z..U: the subst clean-up did not run for real)' $false $true
        return $cases
    }
    $hex = { [guid]::NewGuid().ToString('N') }
    $stalePrefix = Join-Path $Tmp 'stale-'
    $listed = { (& subst.exe 2>&1 | Out-String) }
    # Points $slot at Place (created first), optionally deletes Place (the target gone, the mapping left: what a hard
    # stop leaves behind), cleans up, returns the report and whether the mapping is still there
    $attempt = {
        param([string]$Place, [bool]$Dangling, [string[]]$Scope)
        $null = New-Item -ItemType Directory -Path $Place
        try {
            & subst.exe "${slot}:" $Place 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { return $null }
            if ($Dangling) { Remove-Item -LiteralPath $Place }
            $report = @(Clear-HarnessSelftestSubst -Prefix $stalePrefix -Letters $Scope)
            [pscustomobject]@{ Report = $report; Still = [bool]((& $listed) -match ('(?m)^' + $slot + ':\\: =>')) }
        } finally {
            # Only the mapping made here. Its exit code says nothing when the clean-up under test already removed the
            # mapping, so what counts is checked once at the end: the letter is free again
            & subst.exe "${slot}:" /d 2>&1 | Out-Null
            if (Test-Path -LiteralPath $Place) { Remove-Item -LiteralPath $Place } # empty directory, not recursive
        }
    }
    $r = & $attempt "$stalePrefix$(& $hex)" $true $script:SubstLetters
    & $add 'subst residue: a mapping among Z..U to a scratch directory (prefix + 32 hex) is removed, with letter and target reported' $false ($r -and -not $r.Still -and $r.Report.Count -eq 1 -and $r.Report[0].Letter -ceq $slot -and $r.Report[0].Cleared -and $r.Report[0].Target -like "*$stalePrefix*")
    $r = & $attempt (Join-Path $Tmp "keep-$(& $hex)") $false $script:SubstLetters
    & $add "subst residue: a mapping somewhere else (the user's own) is left alone" $true ($r -and $r.Still -and $r.Report.Count -eq 0)
    $r = & $attempt "${stalePrefix}notes" $false $script:SubstLetters
    & $add 'subst residue: a target where the prefix is not followed by 32 hex digits is left alone' $true ($r -and $r.Still -and $r.Report.Count -eq 0)
    $r = & $attempt "$stalePrefix$(& $hex)" $false @('Q')
    & $add 'subst residue: a letter outside the clean-up range is left alone (even pointing at a scratch directory)' $true ($r -and $r.Still -and $r.Report.Count -eq 0)
    & $add 'subst residue: the clean-up range is Z..U' $false (($script:SubstLetters -join '') -ceq 'ZYXWVU')
    & $add 'subst residue: with nothing left over nothing is done' $false (@(Clear-HarnessSelftestSubst -Prefix $stalePrefix).Count -eq 0)
    & $add 'subst residue: no mapping made for these cases is left on the letter' $false (-not ((& $listed) -match ('(?m)^' + $slot + ':\\: =>')))
    $cases
}

function Get-IniCases {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $crlf = "[REAPER]`r`nvstpath64=x`r`n[audioconfig]`r`nmode=3`r`n[nag]`r`nnag=1`r`n"
    $t = Set-HarnessIniText -Text $crlf -Section audioconfig -Key mode -Value 4
    & $add 'ini: changing a key touches only that line and keeps CRLF' $false ($t -ceq $crlf.Replace('mode=3', 'mode=4'))
    $t = Set-HarnessIniText -Text $crlf -Section audioconfig -Key dummy_srate -Value 44100
    & $add 'ini: a missing key goes to the end of its section, not into the next one' $false ($t -ceq "[REAPER]`r`nvstpath64=x`r`n[audioconfig]`r`nmode=3`r`ndummy_srate=44100`r`n[nag]`r`nnag=1`r`n")
    & $add 'ini: an unchanged value returns the text as it was' $false ((Set-HarnessIniText -Text $crlf -Section audioconfig -Key mode -Value 3) -ceq $crlf)
    $t = Set-HarnessIniText -Text "[REAPER]`nx=1`n" -Section audioconfig -Key mode -Value 4
    & $add 'ini: a missing section is appended, LF style kept' $false ($t -ceq "[REAPER]`nx=1`n[audioconfig]`nmode=4`n")
    & $add 'ini: a mode key in [REAPER] is not taken for the one in [audioconfig]' $false ((Set-HarnessIniText -Text "[REAPER]`nmode=9`n[audioconfig]`n" -Section audioconfig -Key mode -Value 4) -ceq "[REAPER]`nmode=9`n[audioconfig]`nmode=4`n")
    $two = "[REAPER]`r`nworkrender=16`r`n[audioconfig]`r`nworkrender=99`r`n"
    & $add 'ini: a key is read from its own section only' $false (
        (Get-HarnessIniTextValue -Text $two -Section REAPER -Key workrender) -ceq '16' -and (Get-HarnessIniTextValue -Text $two -Section audioconfig -Key workrender) -ceq '99' -and $null -eq (Get-HarnessIniTextValue -Text $two -Section nag -Key workrender))
    & $add 'host: anticipative FX is bit 0 of workrender; without the key REAPER uses 17; the other bits are kept' $false (
        (Get-HarnessWorkrender '' $true) -eq 17 -and (Get-HarnessWorkrender $null $false) -eq 16 -and (Get-HarnessWorkrender '16' $true) -eq 17 -and (Get-HarnessWorkrender '7' $false) -eq 6 -and
        (Get-HarnessWorkrender 'x' $false) -eq 16 -and (Get-HarnessWorkrender '17' $true) -eq 17)
    $dev = @{ dev_bsize = '2048'; dev_srate = '48000'; cfg_workrender = '16' }
    & $add 'host: the device step accepts block, rate and anticipative FX as configured (workrender 16 is off, 17 on)' $false (
        (Test-HarnessHostReadback -Facts $dev -Block 2048 -Sr 48000 -AnticipativeFx $false).Count -eq 0 -and
        (Test-HarnessHostReadback -Facts @{ dev_bsize = '32'; dev_srate = '44100'; cfg_workrender = '17' } -Block 32 -Sr 44100 -AnticipativeFx $true).Count -eq 0)
    & $add 'host: anticipative FX read back other than configured is a problem naming both' $true (
        ((Test-HarnessHostReadback -Facts $dev -Block 2048 -Sr 48000 -AnticipativeFx $true) -join ';') -ceq 'anticipative FX processing reads off, expected on' -and
        ((Test-HarnessHostReadback -Facts @{ dev_bsize = '2048'; dev_srate = '48000'; cfg_workrender = '17' } -Block 2048 -Sr 48000 -AnticipativeFx $false) -join ';') -ceq 'anticipative FX processing reads on, expected off')
    & $add 'host: a workrender the driver could not read, a block size or a rate other than configured are problems' $true (
        ((Test-HarnessHostReadback -Facts @{ dev_bsize = '2048'; dev_srate = '48000'; cfg_workrender = 'unavailable' } -Block 2048 -Sr 48000 -AnticipativeFx $false) -join ';') -ceq "workrender reads 'unavailable'" -and
        ((Test-HarnessHostReadback -Facts $dev -Block 512 -Sr 44100 -AnticipativeFx $false) -join ';') -ceq 'block size reads 2048, expected 512;sample rate reads 48000, expected 44100')
    $cases
}

function Get-SnapshotCases([string]$Tmp) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $root = Join-Path $Tmp 'snap'
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'sub')
    Set-Content -LiteralPath (Join-Path $root 'a.ini') -Value 'aaaa'
    Set-Content -LiteralPath (Join-Path $root 'sub\b.ini') -Value 'bbbb'
    $same = { param($s) (Compare-HarnessDefaultCfgSnapshot -Before $s -After (Get-HarnessDefaultCfgSnapshot -Root $root)).Same }
    $s0 = Get-HarnessDefaultCfgSnapshot -Root $root
    & $add 'listing: nothing changed, equal before and after' $false (& $same $s0)
    Add-Content -LiteralPath (Join-Path $root 'a.ini') -Value 'x'
    & $add 'listing: a size change is a change' $true (-not (& $same $s0))
    $s1 = Get-HarnessDefaultCfgSnapshot -Root $root
    (Get-Item -LiteralPath (Join-Path $root 'sub\b.ini')).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-3)
    & $add 'listing: only the write time changed is a change too' $true (-not (& $same $s1))
    $s2 = Get-HarnessDefaultCfgSnapshot -Root $root
    Set-Content -LiteralPath (Join-Path $root 'new.ini') -Value n
    & $add 'listing: a new file is a change' $true (-not (& $same $s2))
    $s3 = Get-HarnessDefaultCfgSnapshot -Root $root
    Remove-Item -LiteralPath (Join-Path $root 'new.ini')
    & $add 'listing: a deleted file is a change' $true (-not (& $same $s3))
    $s4 = Get-HarnessDefaultCfgSnapshot -Root $root
    (Get-Item -LiteralPath (Join-Path $root 'sub')).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-5)
    & $add "listing: a directory's own time stamp is not reported (it lags and would give false alarms; changes show on its files)" $false (& $same $s4)
    & $add 'listing: a missing directory is an empty listing, not an error' $false ((Get-HarnessDefaultCfgSnapshot -Root (Join-Path $Tmp 'nope')).Count -eq 0)
    # Entries named like the members of a dictionary: the listing's own keys and count must still be walked
    $odd = Join-Path $Tmp 'snap-odd'
    $null = New-Item -ItemType Directory -Path $odd
    foreach ($leaf in 'Keys', 'Values', 'Count', 'other.ini') { Set-Content -LiteralPath (Join-Path $odd $leaf) -Value $leaf }
    $o0 = Get-HarnessDefaultCfgSnapshot -Root $odd
    $oc = Compare-HarnessDefaultCfgSnapshot -Before $o0 -After (Get-HarnessDefaultCfgSnapshot -Root $odd)
    & $add 'listing: files named Keys, Values and Count: unchanged is equal, and all four entries are counted' $false ($oc.Same -and $oc.Count -eq 4)
    Add-Content -LiteralPath (Join-Path $odd 'other.ini') -Value 'x'
    $oc = Compare-HarnessDefaultCfgSnapshot -Before $o0 -After (Get-HarnessDefaultCfgSnapshot -Root $odd)
    & $add 'listing: files named Keys, Values and Count: a change to another file is found, and only that one' $true (-not $oc.Same -and $oc.Changed.Count -eq 1 -and $oc.Changed[0] -ceq 'changed:other.ini')
    # What cannot be listed cannot be called unchanged
    $halfOpen = [ordered]@{ 'a.ini' = '1|2'; 'sub' = 'unreadable' }
    $hc = Compare-HarnessDefaultCfgSnapshot -Before $halfOpen -After $halfOpen
    & $add 'listing: an unreadable entry in both listings is not "unchanged", it is named' $true (-not $hc.Same -and $hc.Changed.Count -eq 0 -and $hc.Unreadable.Count -eq 1 -and $hc.Unreadable[0] -ceq 'sub')
    $hc = Compare-HarnessDefaultCfgSnapshot -Before ([ordered]@{ 'a.ini' = '1|2' }) -After $halfOpen
    & $add 'listing: an entry unreadable only afterwards is named too' $true (-not $hc.Same -and $hc.Unreadable.Count -eq 1)
    $hc = Compare-HarnessDefaultCfgSnapshot -Before $halfOpen -After ([ordered]@{ 'a.ini' = '1|2'; 'sub' = 'dir' })
    & $add 'listing: an entry unreadable only before is named too' $true (-not $hc.Same -and $hc.Unreadable.Count -eq 1)
    $hc = Compare-HarnessDefaultCfgSnapshot -Before ([ordered]@{ 'a.ini' = '1|2' }) -After ([ordered]@{ 'a.ini' = '1|2' })
    & $add 'listing: nothing unreadable, the list is there and empty' $false ($hc.Same -and $hc.Unreadable.Count -eq 0)
    # A real subdirectory and a real root that cannot be listed: deny entries on directories of this self-test only
    $aclRoot = Join-Path $Tmp 'snap-acl'
    $aclSub = Join-Path $aclRoot 'locked'
    $null = New-Item -ItemType Directory -Path $aclSub
    Set-Content -LiteralPath (Join-Path $aclRoot 'a.ini') -Value 'a'
    Set-Content -LiteralPath (Join-Path $aclSub 'b.ini') -Value 'b'
    $subRun = Invoke-WithListingDenied $aclSub { Get-HarnessDefaultCfgSnapshot -Root $aclRoot }
    $noDeny = $subRun.Denied ? '' : ' (a deny entry has no effect here; not run for real)'
    & $add "listing: a subdirectory that cannot be listed is recorded as unreadable$noDeny" $true ((-not $subRun.Denied) -or ($subRun.Result['locked'] -ceq 'unreadable' -and -not $subRun.Result.Contains('locked\b.ini') -and $subRun.Result['a.ini'] -cne 'unreadable'))
    & $add "listing: listed twice with that subdirectory closed, the comparison does not say unchanged$noDeny" $true ((-not $subRun.Denied) -or -not (Compare-HarnessDefaultCfgSnapshot -Before $subRun.Result -After $subRun.Result).Same)
    $rootRun = Invoke-WithListingDenied $aclRoot { Get-HarnessDefaultCfgSnapshot -Root $aclRoot }
    & $add "listing: a root that cannot be listed is recorded as unreadable under the name .$noDeny" $true ((-not $rootRun.Denied) -or $rootRun.Result['.'] -ceq 'unreadable')
    $openAgain = Get-HarnessDefaultCfgSnapshot -Root $aclRoot
    & $add 'listing: the deny entries were taken away again' $false ($subRun.Restored -and $rootRun.Restored -and $openAgain.Contains('locked\b.ini') -and -not $openAgain.Contains('.'))
    # A root that Test-Path says no to but whose identity reads as an error is not a missing directory
    $weird = Get-HarnessDefaultCfgSnapshot -Root (Join-Path $Tmp 'bad|name')
    & $add 'listing: a root that cannot even be looked at is unreadable, not an empty listing' $true ($weird.Contains('.') -and $weird['.'] -ceq 'unreadable')
    $cases
}

# ---------------------------------------------------------------- lint
function Get-LintCases([string]$Tmp, [string]$RepoRoot, [string]$CollisionSample) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $word = '-cfg' + 'file'
    $strict = 'Set-StrictMode -Version Latest'
    $lint = {
        param($Files)
        $dir = Join-Path $Tmp ('lint-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $null = New-Item -ItemType Directory -Path $dir
        foreach ($name in $Files.get_Keys()) {
            $at = Join-Path $dir $name
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $at)
            [IO.File]::WriteAllText($at, $Files[$name])
        }
        Test-HarnessScriptLint -Paths $dir -Root $dir # the directory stays until the whole scratch directory goes
    }
    $hostOk = @{ 'src/Host.psm1' = "$strict`n`$a = '$word'`n" }
    & $add 'lint: a clean sample has no problems' $false ((& $lint $hostOk).Count -eq 0)
    & $add 'lint: $c and $C differing only by case is red' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$c = 1`n`$C = 2`n" })) -match 'differ only by case')
    & $add 'lint: "$c" inside a string and a parameter $C collide too' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`nparam(`$C)`n`"`$c\reaper.ini`"`n" })) -match 'differ only by case')
    & $add 'lint: the same names in two different functions of one file collide too (file wide)' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`nfunction a { `$Dir = 1 }`nfunction b { `$dir = 2 }`n" })) -match 'differ only by case')
    & $add 'lint: variables named $keys and $values do not switch the case scan off' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$keys = 1`n`$values = 2`n`$c = 1`n`$C = 2`n" })) -match 'differ only by case')
    & $add 'lint: .Keys or .Values read as a property is red (a dictionary entry of that name would be returned instead)' $true (
        ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$h = @{}`nforeach (`$k in `$h.Keys) { }`n" })) -match '\.Keys read as a property') -and
        ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$h = @{}`n`$v = `$h.Values`n" })) -match '\.Values read as a property'))
    & $add 'lint: .get_Keys(), .get_Values(), .GetEnumerator() and an entry looked up by index are fine' $false ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$h = @{}`n`$a = `$h.get_Keys()`n`$b = `$h.get_Values()`n`$e = `$h.GetEnumerator()`n`$k = `$h['Keys']`n" })).Count -eq 0)
    & $add 'lint: scope prefixes do not hide a collision ($script:Root and $root)' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$script:Root = 1`n`$root = 2`n" })) -match 'differ only by case')
    & $add 'lint: a missing Set-StrictMode is red' $true ((& $lint ($hostOk + @{ 'x.ps1' = "`$a = 1`n" })) -match 'StrictMode')
    & $add 'lint: the configuration file argument literal outside src/Host.psm1 is red' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$b = '$word'`n" })) -match 'may only be built in src/Host')
    # The exemptions go by the path from the repository root: another file of the same name gets none
    & $add 'lint: the literal in a file that is only named like it (tests/Host.psm1) is red' $true (((& $lint ($hostOk + @{ 'tests/Host.psm1' = "$strict`n`$b = '$word'`n" })) -match 'tests/Host\.psm1: .*may only be built in') -and ((& $lint @{ 'tests/Host.psm1' = "$strict`n`$b = '$word'`n" }) -match 'may only be built in'))
    & $add 'lint: APPDATA in files only named like the exempted ones (tests/Guard.psm1, src/SelfTest.psm1) is red' $true (((& $lint ($hostOk + @{ 'tests/Guard.psm1' = "$strict`n`$p = `$env:APPDATA`n" })) -match 'tests/Guard\.psm1: only') -and ((& $lint ($hostOk + @{ 'src/SelfTest.psm1' = "$strict`n`$p = `$env:APPDATA`n" })) -match 'src/SelfTest\.psm1: only'))
    & $add 'lint: APPDATA in src/Guard.psm1 and tests/SelfTest.psm1 is fine' $false ((& $lint ($hostOk + @{ 'src/Guard.psm1' = "$strict`n`$p = `$env:APPDATA`n"; 'tests/SelfTest.psm1' = "$strict`n`$p = `$env:APPDATA`n" })).Count -eq 0)
    & $add 'lint: no configuration file argument literal at all is red' $true ((& $lint @{ 'x.ps1' = "$strict`n" }) -match 'exactly once')
    & $add 'lint: the configuration file argument literal twice is red' $true ((& $lint @{ 'src/Host.psm1' = "$strict`n`$a = '$word'`n`$b = '$word'`n" }) -match 'exactly once')
    & $add 'lint: mentioning it in a comment does not count' $false ((& $lint @{ 'src/Host.psm1' = "$strict`n# $word`n`$a = '$word'`n" }).Count -eq 0)
    & $add 'lint: a file other than src/Guard.psm1 or tests/SelfTest.psm1 mentioning APPDATA is red' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$p = `$env:APPDATA`n" })) -match 'APPDATA')
    & $add 'lint: LOCALAPPDATA (a different directory) is not taken for APPDATA' $false ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$p = `$env:LOCALAPPDATA`n" })).Count -eq 0)
    $cr = [string][char]13; $esc = [string][char]27
    & $add 'lint: a CR not at a line end inside a script is red (invisible in editors; swallowed, it changes a regex)' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$r = '(;|${cr}?`$)'`n" })) -match 'control character')
    & $add 'lint: another C0 control character (ESC) inside a script is red' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$r = 'a${esc}b'`n" })) -match 'control character')
    & $add 'lint: control characters in .lua and .json files are red too' $true (((& $lint ($hostOk + @{ 'x.lua' = "local a = 'b${esc}c'`n" })) -match 'control character') -and ((& $lint ($hostOk + @{ 'x.json' = "{ `"a`": `"b${esc}c`" }`n" })) -match 'control character'))
    & $add 'lint: CRLF line ends and TAB are not control characters' $false ((& $lint @{ 'src/Host.psm1' = "$strict${cr}`n`t`$a = '$word'${cr}`n" }).Count -eq 0)
    $ctl = Find-HarnessControlChars -Text "ab${cr}cd`nx${esc}y`n"
    & $add 'control characters: line, column and code point are reported' $true ($ctl.Count -eq 2 -and $ctl[0] -ceq 'line 1 column 3: U+000D' -and $ctl[1] -ceq 'line 2 column 2: U+001B')
    & $add 'control characters: clean text, empty text and CRLF line ends have none' $false ((Find-HarnessControlChars -Text "a`tb${cr}`nc`n").Count -eq 0 -and (Find-HarnessControlChars -Text '').Count -eq 0)
    & $add 'lint: a script that does not parse is red' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`nif (`n" })) -match 'parse error')
    # The kind of loop that once overwrote a configuration directory: $cfgDir in the loop, $CfgDir the parameter
    $incident = "param([string]`$CfgDir)`nforeach (`$d in `$list) { `$cfgDir = Join-Path `$d 'x' }`n& reaper.exe `$CfgDir`n"
    & $add 'lint: the classic incident (a loop variable that silently overwrites a parameter of the same name) is found' $true ((Find-HarnessVariableCaseCollisions -Text $incident).Count -gt 0)
    if ($CollisionSample -and (Test-Path -LiteralPath $CollisionSample)) {
        $sample = [IO.File]::ReadAllText($CollisionSample)
        & $add 'lint: the given -CollisionSample is found to have a collision' $true ((Find-HarnessVariableCaseCollisions -Text $sample).Count -gt 0)
    }
    $own = @('src', 'tests', 'lua', 'schema', 'run.ps1', 'doctor.ps1') | ForEach-Object { Join-Path $RepoRoot $_ }
    $real = Test-HarnessScriptLint -Paths $own
    & $add "lint: this repository's own scripts are clean ($($real -join '; '))" $false ($real.Count -eq 0)
    $cases
}

# ---------------------------------------------------------------- pure functions
function New-Facts([hashtable]$Set = @{}) {
    $f = [HarnessCompareFacts]::new()
    $f.RateA = 48000; $f.RateB = 48000; $f.ChannelsA = 2; $f.ChannelsB = 2; $f.FramesA = 96000; $f.FramesB = 96000; $f.FormatA = 'float32'; $f.FormatB = 'float32'
    $f.Comparable = $true; $f.Identical = $true; $f.BestLag = 0; $f.ExpectLag = 0; $f.MaxDiff = 0; $f.HeadDiff = 0; $f.PeakA = 0.5; $f.PeakB = 0.5
    foreach ($k in $Set.get_Keys()) { $f.$k = $Set[$k] }
    $f
}

function Get-HostCases {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $v = { param($c, $vis, $t) (Get-HarnessModalVerdict -Class $c -Visible $vis -Title $t) }
    & $add 'dialog: REAPER Query is answered No' $false ((& $v '#32770' $true 'REAPER Query').Action -eq 'PressNo')
    & $add 'dialog: the render progress window is let be' $false ((& $v '#32770' $true 'Rendering to x.wav').Action -eq 'Benign')
    & $add 'dialog: the plugin scan progress window is let be' $false ((& $v '#32770' $true 'Scanning VST plugins...').Action -eq 'Benign')
    & $add 'dialog: the peak building progress window is let be' $false ((& $v '#32770' $true 'Building Peaks...').Action -eq 'Benign')
    foreach ($progress in 'Rendering to file...', 'Render', 'Scanning VST', 'Building peaks') {
        & $add "dialog: '$progress' is a progress window" $false ((& $v '#32770' $true $progress).Action -eq 'Benign')
    }
    # A title that reports trouble is no progress window, whatever it starts with: left alone it would only end at the
    # timeout, and the outcome would not name it
    foreach ($trouble in 'Render failed', 'Render error', 'RENDER FAILED', 'Scanning error', 'Building peaks failed') {
        $r = & $v '#32770' $true $trouble
        & $add "dialog: '$trouble' counts as stuck (unknown-dialog), not as a progress window" $true ($r.Action -eq 'Fatal' -and $r.Name -eq 'unknown-dialog')
    }
    # The first four as REAPER 7.82 titled them (a VST3 and a JSFX floated from one track, the chain windows of a track and of the master)
    foreach ($window in 'VST3: Fixture Gain (Fixture Audio) - Track 1 [1/2]', 'JS: reaper-harness PDC delay - Track 1 [2/2]', 'FX: Track 1', 'FX: Master Track', 'VST3: Fixture Gain (Fixture Audio) - Track 1', 'VST3i: Synth (Vendor) - Track 2', 'VST: Old (Vendor)', 'VSTi: Old Synth (Vendor)', 'CLAP: Gain (Vendor)', 'CLAPi: Synth (Vendor)', 'JS: reaper-harness PDC delay - Track 1', 'FX: Track 1 "Voice"', 'VST3: Render failed (Vendor) - Track 1') {
        $r = & $v '#32770' $true $window
        & $add "dialog: '$window' is the floating window of a plugin or an FX chain, no dialog: left alone" $false ($r.Action -eq 'Benign' -and $r.Name -eq 'plugin-window')
    }
    # The prefix must start the title, in REAPER's case, with the blank after it; a dialog a plugin opens itself has a title of its own
    foreach ($box in 'Fake VST3: x', ' VST3: x', 'vst3: x', 'VST3:x', 'JSFX: x', 'Fixture Gain - Activation', 'FXs: x') {
        $r = & $v '#32770' $true $box
        & $add "dialog: '$box' is no plugin window: stuck (unknown-dialog)" $true ($r.Action -eq 'Fatal' -and $r.Name -eq 'unknown-dialog')
    }
    $fin = & $v '#32770' $true 'Finished in 0:06 (1.0x realtime)'
    & $add 'dialog: the finished render window ("Finished in ...", as REAPER 7.82 titles it) is let be: it stays until REAPER quits' $false ($fin.Action -eq 'Benign' -and $fin.Name -ceq 'render-finished')
    # Anchored, case-sensitive, with the blank after it, and never with trouble in the title
    foreach ($box in 'Finished', 'Finished in', 'Finish in 0:06', 'finished in 0:06', 'FINISHED IN 0:06', ' Finished in 0:06', 'Fake Finished in 0:06', 'Finished in 0:06 (error)', 'Finished in 0:06 - render failed') {
        $r = & $v '#32770' $true $box
        & $add "dialog: '$box' is no finished render window: stuck (unknown-dialog)" $true ($r.Action -eq 'Fatal' -and $r.Name -eq 'unknown-dialog')
    }
    & $add 'dialog: the evaluation licence reminder is never clicked away; stuck, and named' $true (($nag = & $v '#32770' $true 'About REAPER v7.82/win64 rev 1 (Oct') -and $nag.Action -eq 'Fatal' -and $nag.Name -eq 'license-nag')
    foreach ($pair in @(@('Project Load Warning', 'project-load-warning'), @('REAPER Error', 'reaper-error'), @('Select files to save or delete', 'record-save-prompt'), @('REAPER', 'no-audio-device'), @('Brand New Box', 'unknown-dialog'))) {
        $r = & $v '#32770' $true $pair[0]
        & $add "dialog: '$($pair[0])' counts as stuck ($($pair[1]))" $true ($r.Action -eq 'Fatal' -and $r.Name -eq $pair[1])
    }
    & $add 'dialog: an invisible dialog is ignored' $false ((& $v '#32770' $false 'REAPER Error').Action -eq 'Ignore')
    & $add 'dialog: the main window and other non-dialogs are ignored' $false ((& $v 'REAPERwnd' $true 'REAPER v7').Action -eq 'Ignore')
    & $add 'paths in dialog titles are masked' $false ((ConvertTo-HarnessSafeTitle 'Error in D:\scratch\proj.rpp now') -notmatch 'scratch')
    & $add 'drive paths and UNC paths in result text are masked' $false ((Hide-HarnessPaths 'a D:\scratch\y.wav b \\host\share\z c E:/fwd/x') -notmatch 'scratch|host|fwd')
    # Assembled from two parts: the repository's privacy scan flags a complete user directory path, as it should
    $spaced = 'C:\Us' + 'ers\John Smith\a.rpp'
    $hide = { param($text, $want) (Hide-HarnessPaths $text) -ceq $want }
    & $add 'result text: a drive path with spaces is masked to its end, nothing of a user name is left' $true (& $hide "cannot open $spaced" 'cannot open <path>')
    & $add 'result text: a UNC path with spaces is masked to its end' $true (& $hide 'cannot open \\server\my share\a b.rpp' 'cannot open <path>')
    & $add 'result text: forward slashes are masked as well, with a drive letter or without' $true ((& $hide 'in D:/my files/a b.rpp' 'in <path>') -and (& $hide 'in //server/my share/a b.rpp' 'in <path>'))
    & $add 'result text: a double-quoted path is masked up to its closing quote, the rest stays' $true (& $hide "cannot open `"$spaced`" now" 'cannot open "<path>" now')
    & $add 'result text: a single-quoted path, the way .NET writes them, is masked to its closing quote, the sentence stays' $true (& $hide "Access to the path '$spaced' is denied." "Access to the path '<path>' is denied.")
    & $add 'result text: an apostrophe does not end a quoted path' $true (& $hide "the path 'D:\o'brien\my files\a.wav' is denied" "the path '<path>' is denied")
    & $add 'result text: an apostrophe does not end an unquoted path' $true (& $hide "in D:\o'brien\my files\a.wav" 'in <path>')
    & $add 'result text: an opening quote with no closing one: an apostrophe in a name leaves nothing of the path' $true (& $hide "'D:\Jane O'Neil\x y.wav: boom" "'<path>: boom")
    & $add 'result text: an apostrophe further on in the sentence is no closing quote' $true (& $hide "'D:\my files\a.wav' isn't there" "'<path>' isn't there")
    & $add 'result text: an apostrophe and a blank inside a name, the path going on after it: nothing of the name is left' $true (& $hide "'D:\Jane O' Neil\x.wav: boom" "'<path>: boom")
    & $add 'result text: a closing quote with another path later on its line: the line goes with it, nothing of either path is left' $true ((& $hide "'D:\a b' then D:\c d" "'<path>") -and (& $hide "'D:\a b' then //host/c" "'<path>"))
    & $add 'result text: a closing quote with no separator after it keeps the sentence, on this line only' $false (& $hide "'D:\a b' now`nnext D:\c" "'<path>' now`nnext <path>")
    & $add 'result text: a closing quote before punctuation or at the end of the text keeps the sentence' $true ((& $hide "at 'D:\a b'" "at '<path>'") -and (& $hide "'D:\a b': boom" "'<path>': boom") -and (& $hide "'D:\a b', then" "'<path>', then") -and (& $hide "'D:\a b'. Then" "'<path>'. Then") -and (& $hide "('D:\a b')" "('<path>')") -and (& $hide "['D:\a b']" "['<path>']") -and (& $hide "'D:\a b'; then" "'<path>'; then"))
    & $add 'result text: a semicolon and a comma do not end a path' $true (& $hide 'in D:\a;b c,d\e.wav' 'in <path>')
    & $add 'result text: a colon ends a path (a Lua error names the file and the line) and the message stays' $true (& $hide 'D:\my ext\a b.lua:12: attempt to index' '<path>:12: attempt to index')
    & $add 'result text: < > | ? * end a path too: no file name can have them' $true ((& $hide 'D:\a b>c' '<path>>c') -and (& $hide 'D:\a b|c' '<path>|c') -and (& $hide 'D:\a b?c' '<path>?c') -and (& $hide 'D:\a b*c' '<path>*c') -and (& $hide 'D:\a b<c' '<path><c'))
    & $add 'result text: the end of the line ends a path, the next line stays' $true ((& $hide "D:\a b`nnext" "<path>`nnext") -and (& $hide "D:\a b`r`nnext" "<path>`r`nnext"))
    & $add 'result text: device path prefixes and file URLs leave nothing of the path' $true ((Hide-HarnessPaths ('\\.\' + $spaced)) -cnotmatch 'John|Smith' -and (Hide-HarnessPaths ('\\?\' + $spaced)) -cnotmatch 'John|Smith' -and (Hide-HarnessPaths ('file:///' + ($spaced -replace '\\', '/'))) -cnotmatch 'John|Smith')
    & $add 'result text: a text without a path stays as it is' $false (& $hide 'identical=no lag=1 maxdiff=-6.0 head=0 50/50 a: b VST3: Fixture Gain (Vendor)' 'identical=no lag=1 maxdiff=-6.0 head=0 50/50 a: b VST3: Fixture Gain (Vendor)')
    & $add 'result text: masking twice changes nothing, and nothing stays empty text' $false ((& $hide (Hide-HarnessPaths "in '$spaced' now") "in '<path>' now") -and (Hide-HarnessPaths $null) -ceq '')
    # What an extension puts into the facts of an outcome goes into the result file
    $factsIn = [ordered]@{ n = 3; ok = $true; none = $null; text = "at $spaced"; deep = [ordered]@{ list = @('a', 'D:\my files\b', [ordered]@{ x = '\\host\my share\c' }) }; obj = [pscustomobject]@{ p = 'E:/my files/d' }; 'D:\key with space\k' = 1; one = @('D:\my files\e'); empty = @() }
    $factsOut = Hide-HarnessFacts $factsIn
    & $add 'facts: strings are masked at any depth, in lists, dictionaries and objects' $true ($factsOut.text -ceq 'at <path>' -and $factsOut.deep.list[1] -ceq '<path>' -and $factsOut.deep.list[2].x -ceq '<path>' -and $factsOut.obj.p -ceq '<path>')
    & $add 'facts: keys are masked too' $true ($factsOut.Contains('<path>') -and -not $factsOut.Contains('D:\key with space\k'))
    & $add 'facts: numbers, booleans and nothing stay what they are, and lists stay lists' $false ($factsOut.n -eq 3 -and $factsOut.n -is [int] -and $factsOut.ok -is [bool] -and $factsOut.ok -and $null -eq $factsOut.none -and (ConvertTo-HarnessJsonText $factsOut.one) -ceq '["<path>"]' -and (ConvertTo-HarnessJsonText $factsOut.empty) -ceq '[]' -and $factsOut.deep.list[0] -ceq 'a')
    $deepFacts = 'D:\my files\bottom'
    foreach ($level in 1..40) { $deepFacts = [ordered]@{ down = $deepFacts } }
    $twoStrings = [Collections.Generic.KeyValuePair[string, string]]::new('file', 'D:\my files\f')
    $kept = Hide-HarnessFacts ([ordered]@{ pair = $twoStrings; when = [DateTime]::new(2026, 11, 2, 0, 0, 0, [DateTimeKind]::Utc); day = [DayOfWeek]::Monday; c = [char]'x'; big = [uint64]::MaxValue; half = 0.5 })
    & $add 'facts: a value type whose text can hold a path (a pair of strings) is masked as text; dates, enums, characters and numbers stay what they are' $true (
        $kept.pair -ceq '[file, <path>' -and $kept.when -is [DateTime] -and $kept.day -is [DayOfWeek] -and $kept.c -is [char] -and $kept.big -is [uint64] -and $kept.half -is [double])
    & $add 'facts: nesting deeper than any real result is cut off, without a path' $true (($deepText = ConvertTo-HarnessJsonText (Hide-HarnessFacts $deepFacts)) -and $deepText -clike '*<too deep>*' -and $deepText -cnotlike '*my files*')
    & $add 'dialog title: a drive path with spaces is masked to its end, nothing of a user name is left' $true ((ConvertTo-HarnessSafeTitle "Error in $spaced") -ceq 'Error in <path>')
    & $add 'dialog title: a UNC path with spaces is masked to its end' $true ((ConvertTo-HarnessSafeTitle 'Error in \\server\my share\a b.rpp') -ceq 'Error in <path>')
    & $add 'dialog title: forward slashes are masked as well, with a drive letter or without' $true ((ConvertTo-HarnessSafeTitle 'Error in D:/my files/a b.rpp') -ceq 'Error in <path>' -and (ConvertTo-HarnessSafeTitle 'Error in //server/my share/a b.rpp') -ceq 'Error in <path>')
    & $add 'dialog title: a quoted path is masked up to its closing quote, the rest stays' $true ((ConvertTo-HarnessSafeTitle "Cannot open `"$spaced`" now") -ceq 'Cannot open "<path>" now')
    & $add 'dialog title: a title without a path is left as it is' $false ((ConvertTo-HarnessSafeTitle 'Brand New Box 50/50') -ceq 'Brand New Box 50/50')
    & $add 'dialog title: still cut to 40 characters' $false ((ConvertTo-HarnessSafeTitle ('x' * 60)).Length -eq 40)
    # The module proof (which file of the tested binary's name was loaded), with an injected "same file" test
    $same = { param($a, $b) [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase) }
    $exp = @{ 'A.vst3' = 'P:\plugins\A.vst3\Contents\x86_64-win\A.vst3'; 'B.vst3' = 'P:\plugins\B.vst3\Contents\x86_64-win\B.vst3' }
    $mv = { param($seen) Get-HarnessModuleVerdict -Expected $exp -Seen $seen -SameFile $same }
    $both = @{ 'A.vst3' = @($exp['A.vst3']); 'B.vst3' = @($exp['B.vst3'].ToUpperInvariant()) }
    & $add 'module proof: every tested binary seen only from its private file is Proven' $false ((& $mv $both).Verdict -eq 'Proven')
    $mixed = @{ 'A.vst3' = @($exp['A.vst3'], 'S:\VST3\A.vst3\Contents\x86_64-win\A.vst3'); 'B.vst3' = @($exp['B.vst3']) }
    $r = & $mv $mixed
    & $add 'module proof: a file of the same name from elsewhere is Foreign, even when the private one was loaded too' $true ($r.Verdict -eq 'Foreign' -and $r.Binaries['A.vst3'] -eq 'Foreign' -and $r.Binaries['B.vst3'] -eq 'Private')
    $r = & $mv @{ 'A.vst3' = @($exp['A.vst3']) }
    & $add 'module proof: a tested binary never seen is Unseen (not proven), never Proven' $true ($r.Verdict -eq 'Unseen' -and $r.Binaries['B.vst3'] -eq 'Unseen')
    & $add 'module proof: nothing seen at all is Unseen' $true ((& $mv @{}).Verdict -eq 'Unseen')
    & $add 'module proof: nothing expected proves nothing: Unseen, not Proven' $true ((Get-HarnessModuleVerdict -Expected @{} -Seen @{ 'A.vst3' = @($exp['A.vst3']) } -SameFile $same).Verdict -eq 'Unseen')
    & $add 'same file: an identity that cannot be read is never the same file' $true (-not (Test-HarnessSameFile 'Q:\does\not\exist.vst3' 'Q:\does\not\exist-either.vst3'))
    $badA = Join-Path ([IO.Path]::GetTempPath()) 'bad|one.vst3'; $badB = Join-Path ([IO.Path]::GetTempPath()) 'bad|two.vst3'
    & $add 'same file: two paths whose identities both fail to read (the same error) are not the same file' $true ((Get-HarnessFileIdentity $badA) -like 'ERROR:*' -and (Get-HarnessFileIdentity $badA) -ceq (Get-HarnessFileIdentity $badB) -and -not (Test-HarnessSameFile $badA $badB))
    $cases
}

function Get-WavCases([string]$Tmp) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    # Verdicts on facts
    $good = Get-HarnessCompareVerdict -Facts (New-Facts)
    & $add 'compare verdict: identical, lag 0: PASS, and the line starts with the fixed facts' $false ($good.Status -eq 'PASS' -and $good.Detail -cmatch '^identical=yes lag=0 maxdiff=-inf head=-inf frames=96000/96000 channels=2/2 rate=48000/48000 format=float32/float32 nonfinite=0/0 peak=')
    & $add 'compare verdict: not bit-identical without a tolerance is FAIL' $true ((Get-HarnessCompareVerdict -Facts (New-Facts @{ Identical = $false; MaxDiff = 1e-9 })).Detail -like '*failed: not bit-identical*')
    & $add 'compare verdict: lag 1 when 0 is expected is FAIL' $true ((Get-HarnessCompareVerdict -Facts (New-Facts @{ Identical = $false; BestLag = 1 })).Detail -like '*lag is 1, expected 0*')
    & $add 'compare verdict: lag 1 when 1 is expected, within the tolerance, is PASS' $false ((Get-HarnessCompareVerdict -Facts (New-Facts @{ Identical = $false; BestLag = 1; ExpectLag = 1; MaxDiff = 1e-8 }) -Lag 1 -MaxDiffDb -120).Status -eq 'PASS')
    & $add 'compare verdict: a residual of -140 dBFS within -120 is PASS' $false ((Get-HarnessCompareVerdict -Facts (New-Facts @{ Identical = $false; MaxDiff = 1e-7 }) -MaxDiffDb -120).Status -eq 'PASS')
    & $add 'compare verdict: a residual of -100 dBFS above -120 is FAIL' $true ((Get-HarnessCompareVerdict -Facts (New-Facts @{ Identical = $false; MaxDiff = 1e-5 }) -MaxDiffDb -120).Detail -like '*residual -100.00 dBFS above -120.00*')
    & $add 'compare verdict: with a tolerance, different frame counts are FAIL' $true ((Get-HarnessCompareVerdict -Facts (New-Facts @{ Identical = $false; FramesB = 95999 }) -MaxDiffDb -120).Detail -like '*frame counts differ*')
    & $add 'compare verdict: NaN or Inf in a file is FAIL' $true ((Get-HarnessCompareVerdict -Facts (New-Facts @{ Identical = $false; NonFiniteB = 3 }) -MaxDiffDb 0).Detail -like '*NaN or Inf*')
    $nc = Get-HarnessCompareVerdict -Facts (New-Facts @{ Identical = $false; Comparable = $false; RateB = 44100 })
    & $add 'compare verdict: different rates cannot be compared: FAIL, and the lag is shown as ?' $true ($nc.Status -eq 'FAIL' -and $nc.Detail -like 'identical=no lag=? *cannot be compared*')
    & $add 'compare verdict: a peak above peakMaxDb is FAIL' $true ((Get-HarnessCompareVerdict -Facts (New-Facts @{ PeakB = 1.5 }) -PeakMaxDb 0).Detail -like '*peak 3.52 dBFS above 0.00*')
    & $add 'compare verdict: notSilent with a silent render is FAIL' $true ((Get-HarnessCompareVerdict -Facts (New-Facts @{ PeakB = 0 }) -NotSilent).Detail -like '*silent*')
    # Channel criteria: key -> @{ Key; Channels; Min; Max }, as the configuration gives them
    $cc = { param([string]$Key, [double]$Min, [double]$Max) [ordered]@{ $Key = [pscustomobject]@{ Key = $Key; Channels = @($Key -split '/' | ForEach-Object { ConvertTo-ChannelNumber $_ }); Min = $Min; Max = $Max } } }
    $lv = New-Facts @{ Identical = $false; MaxDiff = 0.05; RmsA = [double[]](0.1, 0.1); RmsB = [double[]](0.05, 0.1) } # A: -20 / -20 dBFS; B: -26.02 / -20
    $v = Get-HarnessCompareVerdict -Facts $lv -MaxDiffDb 0 -RmsDb (& $cc 'L' -27 -25)
    & $add 'channel criteria: an RMS within its range is PASS; the RMS of every channel of both files follows the fixed facts' $false ($v.Status -eq 'PASS' -and $v.Detail -cmatch '^identical=no lag=0 .* peak=\S+ rms=-20\.00,-20\.00/-26\.02,-20\.00$')
    & $add 'channel criteria: an RMS outside its range is FAIL naming the channel' $true ((Get-HarnessCompareVerdict -Facts $lv -MaxDiffDb 0 -RmsDb (& $cc 'R' -27 -25)).Detail -like '*failed: rms R -20.00 dB outside `[-27.00, -25.00`]')
    & $add 'channel criteria: a ratio of two channels of the render within its range is PASS' $false ((Get-HarnessCompareVerdict -Facts $lv -MaxDiffDb 0 -EnergyRatioDb (& $cc 'L/R' -6.1 -5.9)).Status -eq 'PASS')
    & $add 'channel criteria: the ratio the other way round is FAIL' $true ((Get-HarnessCompareVerdict -Facts $lv -MaxDiffDb 0 -EnergyRatioDb (& $cc 'R/L' -6.1 -5.9)).Detail -like '*failed: ratio R/L 6.02 dB outside*')
    & $add 'channel criteria: a change against the reference within its range is PASS' $false ((Get-HarnessCompareVerdict -Facts $lv -MaxDiffDb 0 -RmsChangeDb (& $cc 'L' -6.1 -5.9)).Status -eq 'PASS')
    & $add 'channel criteria: no change where one is expected is FAIL' $true ((Get-HarnessCompareVerdict -Facts $lv -MaxDiffDb 0 -RmsChangeDb (& $cc 'R' -6.1 -5.9)).Detail -like '*failed: rms change R 0.00 dB outside*')
    $quiet = New-Facts @{ RmsA = [double[]](0, 0); RmsB = [double[]](0, 0.1); PeakB = 0.1 }
    & $add 'channel criteria: digital silence counts as -400 dB, so [-400, -400] accepts a silent channel and a level does not' $true (
        (Get-HarnessCompareVerdict -Facts $quiet -RmsDb (& $cc 'L' -400 -400)).Status -eq 'PASS' -and (Get-HarnessCompareVerdict -Facts $quiet -RmsDb (& $cc 'R' -400 -400)).Status -eq 'FAIL')
    $silentBoth = New-Facts @{ RmsA = [double[]](0, 0); RmsB = [double[]](0, 0); PeakB = 0 }
    & $add 'channel criteria: the ratio of two silent channels is undefined: FAIL whatever the range' $true ((Get-HarnessCompareVerdict -Facts $silentBoth -EnergyRatioDb (& $cc 'L/R' -400 24)).Detail -like '*ratio L/R is undefined (both channels are silent)*')
    & $add 'channel criteria: a channel without finite samples has no RMS: FAIL' $true ((Get-HarnessCompareVerdict -Facts (New-Facts @{ RmsB = [double[]]([double]::NaN, 0.1) }) -RmsDb (& $cc 'L' -400 24)).Detail -like '*rms L is undefined*')
    & $add 'channel criteria: a channel the render does not have is FAIL' $true ((Get-HarnessCompareVerdict -Facts (New-Facts @{ ChannelsB = 1; RmsB = [double[]](0.1) }) -RmsDb (& $cc 'R' -400 24)).Detail -like '*the render has no channel 2*')
    $nf = Get-HarnessCompareVerdict -Facts (New-Facts @{ Identical = $false; NanB = 2; InfB = 1; NonFiniteB = 3 }) -MaxDiffDb 0
    & $add 'compare verdict: NaN and Inf are counted apart after the fixed facts' $true ($nf.Status -eq 'FAIL' -and $nf.Detail -like '* nan=0/2 inf=0/1; failed: *NaN or Inf*')
    $one = Get-HarnessRenderVerdict -Facts (New-Facts @{ RmsB = [double[]](0.05, 0.1) }) -EnergyRatioDb (& $cc 'L/R' -6.1 -5.9) -PeakMaxDb 0 -NotSilent
    & $add 'render verdict: one render judged on its own starts with its own facts; criteria within range are PASS' $false ($one.Status -eq 'PASS' -and $one.Detail -cmatch '^frames=96000 channels=2 rate=48000 format=float32 nonfinite=0 peak=-6\.02 rms=-26\.02,-20\.00$')
    & $add 'render verdict: Inf in a render judged on its own is FAIL and counted' $true ((Get-HarnessRenderVerdict -Facts (New-Facts @{ InfB = 1; NonFiniteB = 1 })).Detail -like '* inf=1; failed: NaN or Inf*')
    $noFrames = { param([hashtable]$Set, [hashtable]$Criteria = @{}) (Get-HarnessCompareVerdict -Facts (New-Facts $Set) @Criteria).Status }
    & $add 'compare verdict: no frames on both sides is INCOMPLETE, with or without criteria' $true ((& $noFrames @{ FramesA = 0; FramesB = 0 }) -eq 'INCOMPLETE' -and (& $noFrames @{ FramesA = 0; FramesB = 0 } @{ MaxDiffDb = -120 }) -eq 'INCOMPLETE' -and (& $noFrames @{ FramesA = 0; FramesB = 0 } @{ NotSilent = $true }) -eq 'INCOMPLETE')
    & $add 'compare verdict: no frames on either one side is INCOMPLETE' $true ((& $noFrames @{ FramesA = 0; Identical = $false }) -eq 'INCOMPLETE' -and (& $noFrames @{ FramesB = 0; Identical = $false }) -eq 'INCOMPLETE')
    & $add 'compare verdict: no frames goes before every other criterion (different rates are not FAIL then)' $true ((& $noFrames @{ FramesA = 0; FramesB = 0; Comparable = $false; RateB = 44100; Identical = $false }) -eq 'INCOMPLETE')
    & $add 'render verdict: a render with no frames judged on its own is INCOMPLETE, with or without criteria' $true ((Get-HarnessRenderVerdict -Facts (New-Facts @{ FramesA = 0; FramesB = 0 })).Status -eq 'INCOMPLETE' -and (Get-HarnessRenderVerdict -Facts (New-Facts @{ FramesA = 0; FramesB = 0; PeakB = 0 }) -NotSilent).Status -eq 'INCOMPLETE')
    # Hand-made files through the C# reader and comparer
    $n = 4800
    $base = [double[]]::new($n * 2)
    $rng = [Random]::new(5)
    for ($i = 0; $i -lt $base.Length; $i++) { $base[$i] = ($rng.NextDouble() - 0.5) * 0.2 }
    $base[200] = 1.0; $base[201] = -1.0 # an impulse, so -6 dB shows as exactly -6.02 dBFS
    $file = { param($name, [double[]]$s, $format = 'float32', $rate = 48000, $ch = 2, [switch]$Ext) $p = Join-Path $Tmp $name; Write-HarnessWav -Path $p -Rate $rate -Channels $ch -Format $format -Samples $s -Extensible:$Ext; $p }
    $a = & $file 'a.wav' $base
    $same = & $file 'same.wav' $base
    $shift = [double[]]::new($base.Length); [Array]::Copy($base, 0, $shift, 2, $base.Length - 2)
    $half = [double[]]($base | ForEach-Object { $_ * 0.5 })
    $nan = [double[]]$base.Clone(); $nan[1000] = [double]::NaN
    $short = [double[]]::new($base.Length - 2); [Array]::Copy($base, $short, $short.Length)
    $cmp = { param($b, [hashtable]$opt = @{}) Compare-HarnessWavFiles -A $a -B $b @opt }
    & $add 'WAV: two identical files are bit-identical: PASS' $false ((& $cmp $same).Detail -cmatch '^identical=yes lag=0 ')
    $o1 = & $cmp (& $file 'offset.wav' $shift)
    & $add 'WAV: B one sample later is FAIL with lag=1 (what the built-in negative case matches)' $true ($o1.Status -eq 'FAIL' -and $o1.Detail -cmatch (Get-HarnessBuiltinNegatives | Where-Object id -eq 'neg-offset-1-sample').expectDetail)
    $m6 = & $cmp (& $file 'half.wav' $half)
    & $add 'WAV: B at -6 dB is FAIL with lag=0 maxdiff=-6.02 (what the built-in negative case matches)' $true ($m6.Status -eq 'FAIL' -and $m6.Detail -cmatch (Get-HarnessBuiltinNegatives | Where-Object id -eq 'neg-track-minus-6db').expectDetail -and $m6.Detail -like '*maxdiff=-6.02 *')
    & $add 'WAV: a NaN sample in B is FAIL even with a generous tolerance, and is counted' $true (((& $cmp (& $file 'nan.wav' $nan) @{ MaxDiffDb = 0 }).Detail) -like '*nonfinite=0/1*NaN or Inf*')
    & $add 'WAV: B one frame shorter is not bit-identical: FAIL' $true ((& $cmp (& $file 'short.wav' $short)).Detail -like '*frames=4800/4799*not bit-identical*')
    $p24 = & $cmp (& $file 'pcm24.wav' $base 'pcm24')
    & $add 'WAV: the same signal as PCM 24 is not identical (the format differs) but passes a -120 dBFS tolerance (24-bit rounding is far below it)' $false ($p24.Detail -like 'identical=no *format=float32/pcm24*' -and (& $cmp (& $file 'pcm24b.wav' $base 'pcm24') @{ MaxDiffDb = -120 }).Status -eq 'PASS')
    # values that PCM 16 holds exactly decode to the same doubles from both files: only the format tells them apart
    # (+ 0.0 turns -0.0 into 0.0: PCM has no negative zero, and -0.0 alone would already make the two differ)
    $q16 = [double[]]($base | ForEach-Object { [Math]::Round($_ * 32767) / 32768 + 0.0 })
    $q = Compare-HarnessWavFiles -A (& $file 'q16-float.wav' $q16) -B (& $file 'q16-pcm16.wav' $q16 'pcm16')
    & $add 'WAV: the same sample values as float 32 and PCM 16 are not bit-identical (the format is part of identity)' $true ($q.Status -eq 'FAIL' -and $q.Detail -like 'identical=no lag=0 maxdiff=-inf *format=float32/pcm16*not bit-identical*')
    & $add 'WAV: a different sample rate cannot be compared: FAIL' $true ((& $cmp (& $file 'r44.wav' $base 'float32' 44100)).Detail -like '*rate=48000/44100*cannot be compared*')
    & $add 'WAV: WAVE_FORMAT_EXTENSIBLE float32 reads back the same samples' $false ((& $cmp (& $file 'ext.wav' $base 'float32' 48000 2 -Ext)).Detail -cmatch '^identical=yes ')
    $rt = $true
    foreach ($fmt in 'pcm16', 'pcm32', 'float64') {
        $w = Read-HarnessWav (& $file "rt-$fmt.wav" $base $fmt)
        $rt = $rt -and $w.Frames -eq $n -and $w.Channels -eq 2 -and $w.Format -eq $fmt
    }
    & $add 'WAV: PCM 16, PCM 32 and float 64 are read with the right format, channels and frames' $false $rt
    $badWav = Join-Path $Tmp 'bad-header.wav'; [IO.File]::WriteAllBytes($badWav, [Text.Encoding]::ASCII.GetBytes('RIFX....WAVEjunk'))
    $bh = & $cmp $badWav
    & $add 'WAV: a damaged header gives INCOMPLETE with a WAV: reason (never a crash, never PASS)' $true ($bh.Status -eq 'INCOMPLETE' -and $bh.Detail -like '*WAV:*')
    # a.wav is plain float32 stereo: RIFF header (12 bytes), fmt chunk (8 + 16), data chunk header at 36, size at 40
    $bytes = [IO.File]::ReadAllBytes($a)
    $cutHead = Join-Path $Tmp 'cut-header.wav'; [IO.File]::WriteAllBytes($cutHead, $bytes[0..29])
    $ch = & $cmp $cutHead
    & $add 'WAV: a file cut off inside its fmt chunk is INCOMPLETE with a WAV: reason' $true ($ch.Status -eq 'INCOMPLETE' -and $ch.Detail -like '*WAV: *fmt*')
    # The fmt chunk declares a length that int addition cannot hold: the check must not overflow into "fine"
    $hugeFmt = [byte[]]$bytes.Clone(); [BitConverter]::GetBytes([uint32]::MaxValue).CopyTo($hugeFmt, 16)
    $hf = Join-Path $Tmp 'huge-fmt.wav'; [IO.File]::WriteAllBytes($hf, $hugeFmt)
    $hr = & $cmp $hf
    & $add 'WAV: a fmt chunk declaring an enormous length is INCOMPLETE and names the fmt chunk' $true ($hr.Status -eq 'INCOMPLETE' -and $hr.Detail -like '*WAV: fmt chunk is too short or truncated*')
    # A render with no frames: the header of a.wav with data length 0
    $emptyBytes = [byte[]]$bytes[0..43]; [BitConverter]::GetBytes([uint32]0).CopyTo($emptyBytes, 40)
    $emptyA = Join-Path $Tmp 'empty-a.wav'; [IO.File]::WriteAllBytes($emptyA, $emptyBytes)
    $emptyB = Join-Path $Tmp 'empty-b.wav'; [IO.File]::WriteAllBytes($emptyB, $emptyBytes)
    $e2 = Compare-HarnessWavFiles -A $emptyA -B $emptyB
    & $add 'WAV: two empty renders are INCOMPLETE, not a bit-identical PASS; the fixed facts still start the line' $true ($e2.Status -eq 'INCOMPLETE' -and $e2.Detail -cmatch '^identical=yes lag=0 maxdiff=n/a head=n/a frames=0/0 .*; incomplete: a render has no frames')
    & $add 'WAV: one empty render on its own is INCOMPLETE, with notSilent as well (not FAIL)' $true ((Test-HarnessWavFile -Path $emptyA).Status -eq 'INCOMPLETE' -and (Test-HarnessWavFile -Path $emptyA -NotSilent).Status -eq 'INCOMPLETE')
    & $add 'WAV: an empty render against a real one is INCOMPLETE, either way round' $true ((Compare-HarnessWavFiles -A $emptyA -B $a).Status -eq 'INCOMPLETE' -and (Compare-HarnessWavFiles -A $a -B $emptyA).Status -eq 'INCOMPLETE')
    & $add 'WAV: two empty renders with a tolerance or notSilent are INCOMPLETE too' $true ((Compare-HarnessWavFiles -A $emptyA -B $emptyB -MaxDiffDb -120).Status -eq 'INCOMPLETE' -and (Compare-HarnessWavFiles -A $emptyA -B $emptyB -NotSilent).Status -eq 'INCOMPLETE')
    $cutData = Join-Path $Tmp 'cut-data.wav'; [IO.File]::WriteAllBytes($cutData, $bytes[0..(44 + 8 * 100 - 1)])
    $cd = & $cmp $cutData
    & $add 'WAV: a file cut off inside its data (100 whole frames left) is INCOMPLETE, not a shorter render' $true ($cd.Status -eq 'INCOMPLETE' -and $cd.Detail -like '*WAV: data chunk is truncated*')
    $partial = [byte[]]$bytes.Clone(); [BitConverter]::GetBytes([uint32](8 * $n - 4)).CopyTo($partial, 40)
    $pf = Join-Path $Tmp 'partial-frame.wav'; [IO.File]::WriteAllBytes($pf, $partial)
    $pr = & $cmp $pf
    & $add 'WAV: a data chunk that ends inside a frame is INCOMPLETE' $true ($pr.Status -eq 'INCOMPLETE' -and $pr.Detail -like '*WAV: data chunk does not hold whole frames*')
    # The placeholder length 0xFFFFFFFF: the writer never filled in the length, so the file is not finished. This one holds
    # every frame of a.wav and nothing else, so reading it to its end would find nothing wrong and compare as identical
    $open = [byte[]]$bytes.Clone(); [BitConverter]::GetBytes([uint32]::MaxValue).CopyTo($open, 40)
    $of = Join-Path $Tmp 'open-length.wav'; [IO.File]::WriteAllBytes($of, $open)
    $ofp = Join-Path $Tmp 'open-length-partial.wav'; [IO.File]::WriteAllBytes($ofp, [byte[]]($open + [byte[]](1, 2, 3)))
    $neverWritten = 'WAV: the data length was never written*'
    $readError = { param($p) try { $null = Read-HarnessWav $p; '' } catch { $_.Exception.Message } }
    & $add 'WAV: a data length of 0xFFFFFFFF does not read, with a reason of its own, also when the file ends inside a frame' $true ((& $readError $of) -like $neverWritten -and (& $readError $ofp) -like $neverWritten)
    $openB = & $cmp $of
    $openA = Compare-HarnessWavFiles -A $of -B $a
    & $add 'WAV: a data length of 0xFFFFFFFF compared on either side is INCOMPLETE, not bit-identical' $true ($openB.Status -eq 'INCOMPLETE' -and $openB.Detail -like "cannot read render B: $neverWritten" -and $openA.Status -eq 'INCOMPLETE' -and $openA.Detail -like "cannot read render A: $neverWritten")
    $openAlone = Test-HarnessWavFile -Path $of
    $openLoud = Test-HarnessWavFile -Path $of -NotSilent -PeakMaxDb 6
    & $add 'WAV: a data length of 0xFFFFFFFF on its own is INCOMPLETE, with or without criteria the frames would meet (never PASS)' $true ($openAlone.Status -eq 'INCOMPLETE' -and $openAlone.Detail -like "cannot read the render: $neverWritten" -and $openLoud.Status -eq 'INCOMPLETE')
    & $add 'WAV: a missing render is INCOMPLETE' $true ((& $cmp (Join-Path $Tmp 'none.wav')).Status -eq 'INCOMPLETE')
    $silent = & $file 'silent.wav' ([double[]]::new(200))
    & $add 'WAV: one render on its own: silent with notSilent is FAIL; the signal passes' $true ((Test-HarnessWavFile -Path $silent -NotSilent).Status -eq 'FAIL' -and (Test-HarnessWavFile -Path $a -NotSilent).Status -eq 'PASS')
    # Right channel at half the left one: RMS per channel from the file
    $lr = [double[]]$base.Clone(); for ($i = 1; $i -lt $lr.Length; $i += 2) { $lr[$i] = 0.5 * $lr[$i - 1] }
    $lrFile = & $file 'left-right.wav' $lr
    & $add 'WAV: the RMS of each channel comes from the file: right at half the left is a ratio of 6.02 dB' $true (
        (Test-HarnessWavFile -Path $lrFile -EnergyRatioDb (& $cc 'L/R' 6.0 6.05)).Status -eq 'PASS' -and (Test-HarnessWavFile -Path $lrFile -EnergyRatioDb (& $cc 'L/R' -0.5 0.5)).Status -eq 'FAIL')
    & $add 'WAV: a change of level against the reference is measured per channel (B at half A: -6.02 dB)' $true (
        (& $cmp (& $file 'half2.wav' $half) @{ MaxDiffDb = 0; RmsChangeDb = (& $cc 'L' -6.05 -6.0) }).Status -eq 'PASS' -and (& $cmp (& $file 'half3.wav' $half) @{ MaxDiffDb = 0; RmsChangeDb = (& $cc 'L' -0.5 0.5) }).Status -eq 'FAIL')
    $inf = [double[]]$base.Clone(); $inf[10] = [double]::PositiveInfinity; $inf[11] = [double]::NaN
    $inff = Test-HarnessWavFile -Path (& $file 'inf.wav' $inf)
    & $add 'WAV: a render on its own with Inf and NaN is FAIL, both counted' $true ($inff.Status -eq 'FAIL' -and $inff.Detail -like '*nonfinite=2 * nan=1 inf=1; failed: NaN or Inf*')
    $infRms = Test-HarnessWavFile -Path (& $file 'inf-rms.wav' $inf) -RmsDb (& $cc 'L' -400 24)
    & $add 'WAV: the RMS of a channel leaves out its NaN and Inf samples (they only fail the render for being there)' $false (
        $infRms.Detail -cmatch ' rms=-?\d+\.\d\d,-?\d+\.\d\d nan=1 inf=1; failed: NaN or Inf samples present$')
    # The test signal is deterministic: the same seed gives the same bytes
    $s1 = Join-Path $Tmp 'sig1.wav'; $s2 = Join-Path $Tmp 'sig2.wav'; $s3 = Join-Path $Tmp 'sig3.wav'
    New-HarnessSignalFile -Path $s1 -Seconds 0.2 -Seed 7; New-HarnessSignalFile -Path $s2 -Seconds 0.2 -Seed 7; New-HarnessSignalFile -Path $s3 -Seconds 0.2 -Seed 8
    & $add 'signal: the same seed gives the same file, another seed another one' $false ((Get-FileHash $s1).Hash -ceq (Get-FileHash $s2).Hash -and (Get-FileHash $s1).Hash -cne (Get-FileHash $s3).Hash)
    # A residual that is only reported (maxDiffDb "report"): measured and written down, never judged
    $rep = { param([hashtable]$Set, [hashtable]$Criteria = @{}) Get-HarnessCompareVerdict -Facts (New-Facts $Set) -ReportResidual @Criteria }
    $v1 = & $rep @{}
    & $add 'report verdict: bit-identical renders are PASS: the fixed facts, then "reported: bit-identical"' $false ($v1.Status -ceq 'PASS' -and $v1.Detail -cmatch '^identical=yes lag=0 maxdiff=-inf head=-inf frames=96000/96000 .*; reported: bit-identical$')
    $drifted = @{ Identical = $false; MaxDiff = [Math]::Pow(2, -10); HeadDiff = [Math]::Pow(2, -10); FirstDiff = 100; MaxDiffFrame = 100; PairCount = 192000; ResidualSumSq = 1e-6; SignalSumSq = 1.0 }
    $v2 = & $rep $drifted
    & $add "report verdict: renders that differ are PASS; the residual, its RMS against the reference, the lags, where it is largest and where it starts are reported ($($v2.Detail))" $false (
        $v2.Status -ceq 'PASS' -and $v2.Detail -cmatch '^identical=no lag=0 maxdiff=-60\.21 head=-60\.21 ' -and
        $v2.Detail.EndsWith('; reported: not bit-identical, residual -60.21 dBFS (rms -60.00 dB against the reference) measured at lag 0 (expected), best lag 0, largest at 0.002083 s, first difference at frame 100'))
    $v3 = & $rep @{ Identical = $false; BestLag = 5; MaxDiff = 0.01 }
    $r3 = Get-HarnessResidualFacts -Facts (New-Facts @{ Identical = $false; BestLag = 5; MaxDiff = 0.01 }) -Reported
    & $add 'report verdict: a best lag other than the expected one is reported, not judged; lag= of the line is the best lag, the lag of the residual facts the one it was measured at' $false (
        $v3.Status -ceq 'PASS' -and $v3.Detail -cmatch '^identical=no lag=5 ' -and $v3.Detail -clike '*measured at lag 0 (expected), best lag 5*' -and $v3.Detail -cnotlike '*lag is 5*' -and $r3['lag'] -eq 0 -and $r3['bestLag'] -eq 5)
    $v4 = & $rep @{ Identical = $false; MaxDiff = 0.01; NanB = 1; NonFiniteB = 1 }
    & $add 'report verdict: NaN or Inf is FAIL' $true ($v4.Status -ceq 'FAIL' -and $v4.Detail -clike '*; reported: not bit-identical, *; failed: NaN or Inf samples present')
    $v5 = & $rep @{ Identical = $false; Comparable = $false; RateB = 44100; MaxDiff = [double]::NaN; HeadDiff = [double]::NaN }
    & $add 'report verdict: renders that cannot be compared are FAIL' $true ($v5.Status -ceq 'FAIL' -and $v5.Detail -clike '*; failed: sample rate or channel count differ, the renders cannot be compared')
    $v6 = & $rep @{ Identical = $false; FramesB = 95999 }
    & $add "report verdict: frame counts that differ are FAIL (one of the two renders is broken) ($($v6.Detail))" $true (
        $v6.Status -ceq 'FAIL' -and $v6.Detail.EndsWith('; reported: not bit-identical, residual -inf dBFS measured at lag 0 (expected), best lag 0; failed: frame counts differ'))
    $v7 = & $rep @{ FramesA = 0; FramesB = 0 }
    & $add 'report verdict: a render without frames is INCOMPLETE first, with the text of a judged comparison' $true ($v7.Status -ceq 'INCOMPLETE' -and $v7.Detail -ceq (Get-HarnessCompareVerdict -Facts (New-Facts @{ FramesA = 0; FramesB = 0 })).Detail)
    $v8 = & $rep @{ Identical = $false; MaxDiff = [double]::NaN; HeadDiff = [double]::NaN }
    $v8n = & $rep @{ Identical = $false; MaxDiff = [double]::NaN; HeadDiff = [double]::NaN; NanB = 4; NonFiniteB = 4 }
    & $add "report verdict: no residual measured (no overlapping finite samples) is INCOMPLETE; with NaN as well FAIL wins ($($v8.Detail))" $true (
        $v8.Status -ceq 'INCOMPLETE' -and $v8.Detail.EndsWith('; reported: not bit-identical, best lag 0; incomplete: no residual was measured (no overlapping finite samples)') -and $v8n.Status -ceq 'FAIL')
    & $add 'report verdict: a peak above peakMaxDb and a level change outside rmsChangeDb are still FAIL' $true (
        (& $rep @{ PeakB = 1.5 } @{ PeakMaxDb = 0 }).Status -ceq 'FAIL' -and (Get-HarnessCompareVerdict -Facts $lv -ReportResidual -RmsChangeDb (& $cc 'R' -6.1 -5.9)).Detail -clike '*; reported: *; failed: rms change R 0.00 dB outside*')
    & $add 'report verdict: to report and to judge a limit at once is a programming error: it throws' $true ($(try { $null = Get-HarnessCompareVerdict -Facts (New-Facts) -ReportResidual -MaxDiffDb -120; $false } catch { $_.Exception.Message -clike '*exclude each other*' }))
    $rf = Get-HarnessResidualFacts -Facts (New-Facts) -Reported
    & $add "residual facts: identical renders: maxDiff 0 and every value that cannot be given an explicit null, in the documented order ($(@($rf.get_Keys()) -join ','))" $true (
        (@($rf.get_Keys()) -join ',') -ceq 'reported,identical,lag,bestLag,maxDiff,residualDb,residualRmsDb,maxDiffFrame,maxDiffSeconds,firstDiffFrame,frames,referenceFrames' -and
        $rf['reported'] -eq $true -and $rf['identical'] -eq $true -and $rf['lag'] -eq 0 -and $rf['bestLag'] -eq 0 -and $rf['maxDiff'] -eq 0 -and $null -eq $rf['residualDb'] -and $null -eq $rf['residualRmsDb'] -and
        $null -eq $rf['maxDiffFrame'] -and $null -eq $rf['maxDiffSeconds'] -and $null -eq $rf['firstDiffFrame'] -and $rf['frames'] -eq 96000 -and $rf['referenceFrames'] -eq 96000)
    $rd = Get-HarnessResidualFacts -Facts (New-Facts $drifted)
    & $add 'residual facts: renders that differ: the residual in dBFS and against the reference to 6 decimals, where it is largest (frame and seconds), where it starts' $false (
        $rd['reported'] -eq $false -and $rd['maxDiff'] -eq [Math]::Pow(2, -10) -and $rd['residualDb'] -eq -60.205999 -and $rd['residualRmsDb'] -eq -60.0 -and $rd['maxDiffFrame'] -eq 100 -and
        $rd['maxDiffSeconds'] -eq 0.002083 -and $rd['firstDiffFrame'] -eq 100)
    $rn = Get-HarnessResidualFacts -Facts (New-Facts @{ Identical = $false; MaxDiff = [double]::NaN })
    $rc = Get-HarnessResidualFacts -Facts (New-Facts @{ Identical = $false; Comparable = $false; RateB = 44100; MaxDiff = [double]::NaN })
    $nanFree = @(@($rf, $rd, $rn, $rc) | Where-Object { (ConvertTo-HarnessJsonText -Value $_) -clike '*NaN*' }).Count -eq 0
    & $add 'residual facts: nothing measured gives maxDiff null, renders that cannot be compared bestLag null; their JSON has null, never "NaN"' $true (
        $rn.Contains('maxDiff') -and $null -eq $rn['maxDiff'] -and $null -eq $rn['residualDb'] -and $rc.Contains('bestLag') -and $null -eq $rc['bestLag'] -and $null -eq $rc['maxDiff'] -and $nanFree -and
        (ConvertTo-HarnessJsonText -Value $rn) -clike '*"maxDiff":null*' -and (ConvertTo-HarnessJsonText -Value $rc) -clike '*"bestLag":null*')
    # The C# comparer on samples in memory: the first and the largest difference are frames of the reference
    $mem = { param([double[]]$SampleList) $w = [HarnessWavData]::new(); $w.Rate = 48000; $w.Channels = 1; $w.Frames = $SampleList.Length; $w.Format = 'float32'; $w.Samples = $SampleList; $w }
    $va = [double[]](1..20 | ForEach-Object { $_ / 32.0 })
    $vb = [double[]]$va.Clone(); $vb[7] += 0.5
    $vl = [double[]]::new(20); [Array]::Copy($va, 0, $vl, 1, 19); $vl[8] += 0.5
    $f0 = [HarnessWav]::Compare((& $mem $va), (& $mem $vb), 0, 2, 0)
    $f1 = [HarnessWav]::Compare((& $mem $va), (& $mem $vl), 1, 2, 0)
    $fi = [HarnessWav]::Compare((& $mem $va), (& $mem $va), 0, 2, 0)
    $sumSq = 0.0; foreach ($x in $va) { $sumSq += $x * $x }
    & $add "comparer: the first and the largest difference are frames of the reference at the expected lag, over the finite pairs; identical renders have none ($($f0.FirstDiff), $($f1.FirstDiff), $($fi.FirstDiff))" $true (
        $f0.FirstDiff -eq 7 -and $f0.MaxDiffFrame -eq 7 -and $f0.PairCount -eq 20 -and $f0.ResidualSumSq -eq 0.25 -and $f0.SignalSumSq -eq $sumSq -and
        $f1.FirstDiff -eq 7 -and $f1.MaxDiffFrame -eq 7 -and $f1.PairCount -eq 19 -and $f1.ResidualSumSq -eq 0.25 -and
        $fi.FirstDiff -eq -1 -and $fi.MaxDiffFrame -eq -1 -and $fi.ResidualSumSq -eq 0 -and $fi.PairCount -eq 20)
    # The level at the end of a render: only the last frames are read
    $endSamples = [double[]]::new(9600); $endSamples[10] = 0.75; $endSamples[9000] = -0.25; $endSamples[9599] = 0.125
    $endFile = & $file 'end-peak.wav' $endSamples 'float32' 48000 1
    $quietEnd = [double[]]::new(9600); $quietEnd[10] = 0.5
    & $add 'end level: the peak of the last 100 ms in dBFS, 6 decimals; the whole file when it is shorter; null when that end is silent or the file cannot be read' $true (
        (Get-HarnessEndPeakDb $endFile) -eq [Math]::Round(20 * [Math]::Log10(0.25), 6) -and (Get-HarnessEndPeakDb $endFile 1) -eq [Math]::Round(20 * [Math]::Log10(0.75), 6) -and
        $null -eq (Get-HarnessEndPeakDb (& $file 'quiet-end.wav' $quietEnd 'float32' 48000 1)) -and $null -eq (Get-HarnessEndPeakDb (Join-Path $Tmp 'none.wav')) -and $null -eq (Get-HarnessEndPeakDb $badWav))
    # The residual a comparison returns, and the comparison facts of a row built from it
    $missingB = Compare-HarnessWavFiles -A $a -B (Join-Path $Tmp 'none.wav') -ReportResidual
    $onItsOwn = Test-HarnessWavFile -Path $a
    $judgedSame = & $cmp $same
    $earlyFacts = New-HarnessComparisonFacts 'repeat' $missingB @()
    & $add 'comparison: a file that is missing gives Residual null and the comparison facts master null; a render judged on its own has Residual null; a judged comparison has its residual, not reported' $true (
        $missingB.Status -ceq 'INCOMPLETE' -and $missingB.PSObject.Properties['Residual'] -and $null -eq $missingB.Residual -and $earlyFacts.Contains('master') -and $null -eq $earlyFacts['master'] -and
        @($earlyFacts['stems']).Count -eq 0 -and $onItsOwn.PSObject.Properties['Residual'] -and $null -eq $onItsOwn.Residual -and $judgedSame.Residual['reported'] -eq $false -and $judgedSame.Residual['identical'] -eq $true)
    $stemList = @([pscustomobject]@{ Track = 'A'; Compare = 'none'; Result = $onItsOwn }, [pscustomobject]@{ Track = 'B'; Compare = 'reference'; Result = $judgedSame }, [pscustomobject]@{ Track = 'C'; Compare = 'reference'; Result = $missingB })
    $withStems = New-HarnessComparisonFacts 'dry' $judgedSame $stemList
    & $add 'comparison: only stems compared with the reference are listed, each with its track first; a stem whose comparison returned early has its track only' $true (
        $withStems['against'] -ceq 'dry' -and $withStems['master']['identical'] -eq $true -and (@($withStems['stems'] | ForEach-Object { $_['track'] }) -join ',') -ceq 'B,C' -and
        (@(@($withStems['stems'][0].get_Keys())[0..1]) -join ',') -ceq 'track,reported' -and @($withStems['stems'][1].get_Keys()).Count -eq 1)
    # Only the exact word: criteria built by hand (an extension's Judge) are not validated
    $wordCtx = [pscustomobject]@{ Limits = [pscustomobject]@{ lagSearch = 64; headSeconds = 2 } }
    $later = & $file 'later.wav' $shift
    $judgeWord = {
        param($MaxDiffWord)
        $wordCriteria = [pscustomobject]@{ maxDiffDb = $MaxDiffWord; lag = 0; peakMaxDb = $null; notSilent = $false; rmsDb = $null; energyRatioDb = $null; rmsChangeDb = $null }
        try { (Invoke-HarnessCompare $wordCtx $wordCriteria $a $later).Status } catch { 'INCOMPLETE' } # a scenario that throws is INCOMPLETE
    }
    $words = @(@('report', 'Report', 'reported', '12') | ForEach-Object { & $judgeWord $_ })
    & $add "comparison: only the exact word report means a residual that is only reported: Report, reported and 12 on renders a sample apart are never PASS ($($words -join ', '))" $true (($words -join ',') -ceq 'PASS,INCOMPLETE,INCOMPLETE,FAIL')
    $cases
}

function Get-VerdictCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    & $add 'summary: INCOMPLETE is not PASS' $true ((Get-HarnessWorstStatus @('PASS', 'INCOMPLETE')) -eq 'INCOMPLETE')
    & $add 'summary: FAIL beats INCOMPLETE' $true ((Get-HarnessWorstStatus @('INCOMPLETE', 'FAIL', 'PASS')) -eq 'FAIL')
    & $add 'summary: only all SKIPPED is SKIPPED; mixed with PASS it is INCOMPLETE' $false ((Get-HarnessWorstStatus @('SKIPPED', 'SKIPPED')) -eq 'SKIPPED' -and (Get-HarnessWorstStatus @('PASS', 'SKIPPED')) -eq 'INCOMPLETE')
    & $add 'summary: an empty list (nothing ran) is never PASS' $true ((Get-HarnessWorstStatus @()) -eq 'INCOMPLETE' -and (Get-HarnessWorstStatus $null) -eq 'INCOMPLETE')
    & $add 'round: a round without any rows is not PASS' $true ((Get-HarnessRunVerdict -RowStatuses @() -CfgChanged $false -Residual 0) -eq 'INCOMPLETE')
    & $add 'round: all rows green but the default resource directory changed is FAIL' $true ((Get-HarnessRunVerdict -RowStatuses @('PASS', 'PASS') -CfgChanged $true -Residual 0) -eq 'FAIL')
    & $add 'round: all rows green but a process of this round left after it is FAIL' $true ((Get-HarnessRunVerdict -RowStatuses @('PASS') -CfgChanged $false -Residual 1) -eq 'FAIL')
    & $add 'round: all green, directory unchanged, nothing left: PASS' $false ((Get-HarnessRunVerdict -RowStatuses @('PASS', 'PASS') -CfgChanged $false -Residual 0) -eq 'PASS')
    & $add 'round: all rows green but the directory could not be listed in full: INCOMPLETE, neither PASS nor FAIL' $true ((Get-HarnessRunVerdict -RowStatuses @('PASS') -CfgUnreadable $true) -ceq 'INCOMPLETE')
    & $add 'round: a change that was seen stays FAIL when something else could not be listed too' $true ((Get-HarnessRunVerdict -RowStatuses @('PASS') -CfgChanged $true -CfgUnreadable $true) -ceq 'FAIL')
    & $add 'round: a FAIL row stays FAIL when the directory could not be listed' $true ((Get-HarnessRunVerdict -RowStatuses @('FAIL') -CfgUnreadable $true) -ceq 'FAIL')
    & $add 'round: all rows green but a process that could not be ended: INCOMPLETE, neither PASS nor FAIL' $true ((Get-HarnessRunVerdict -RowStatuses @('PASS') -StillRunning $true) -ceq 'INCOMPLETE')
    & $add 'round: a FAIL row stays FAIL when a process could not be ended' $true ((Get-HarnessRunVerdict -RowStatuses @('PASS', 'FAIL') -StillRunning $true) -ceq 'FAIL')
    & $add 'round: a process nobody reported stays FAIL next to one that was reported' $true ((Get-HarnessRunVerdict -RowStatuses @('PASS') -Residual 1 -StillRunning $true) -ceq 'FAIL')
    & $add 'rounds: a changed default resource directory stops all further rounds' $true ((Get-HarnessRoundStop -CfgChanged $true) -like '*changed*')
    & $add 'rounds: a default resource directory that could not be listed stops all further rounds' $true ((Get-HarnessRoundStop -CfgUnreadable $true) -like '*could not be listed*')
    & $add 'rounds: a process that could not be ended stops all further rounds' $true ((Get-HarnessRoundStop -StillRunning $true) -like '*could not be ended*')
    & $add 'rounds: a round that broke on an unexpected error stops all further rounds' $true ((Get-HarnessRoundStop -RoundBroke $true) -like '*unexpected error*')
    & $add 'rounds: with none of those the next round runs' $false ((Get-HarnessRoundStop) -ceq '')
    # What was seen to change, next to what could not be read
    $seen = { param([string[]]$Changed, [string[]]$Unreadable) @(Get-HarnessCfgChangesSeen -Changed $Changed -Unreadable $Unreadable) -join '|' }
    & $add 'directory changes: with nothing unreadable every change counts' $true ((& $seen @('changed:a.ini', 'added:b\c', 'removed:d') @()) -ceq 'changed:a.ini|added:b\c|removed:d')
    & $add 'directory changes: an entry that could not be read and all below it are no change that was seen, in any case of letters' $false ((& $seen @('changed:DATA', 'removed:data\x.ini') @('Data')) -ceq '')
    & $add 'directory changes: a change next to an unreadable entry counts, also when its name only starts the same' $true ((& $seen @('changed:Data2\x.ini', 'changed:a.ini') @('Data')) -ceq 'changed:Data2\x.ini|changed:a.ini')
    & $add 'directory changes: when the directory itself could not be read nothing was seen' $false ((& $seen @('removed:a.ini') @('.')) -ceq '')
    # Negative rows need both the outcome and the reason. The outcome alone can be reached without the case running:
    # with the GUI lock busy REAPER is not started, and a watchdog case is INCOMPLETE then too, without any watchdog
    $negs = @{}
    foreach ($neg in (Get-HarnessBuiltinNegatives)) { $negs[$neg.id] = $neg }
    $verdict = { param($id, $observed, $detail) Get-HarnessNegativeVerdict -Expect $negs[$id].expect -ExpectDetail $negs[$id].expectDetail -Observed $observed -Detail $detail }
    $hang = { param($state, $exitCode = 0) $w = Get-HarnessHostFailure ([pscustomobject]@{ Status = $state; Seconds = 8.2; ExitCode = $exitCode; Modal = 'license-nag'; Windows = @('license-nag') }); "$w; the process has ended and the GUI locks are free" } # the shape the hang kind builds
    # A process that could not be ended cannot verify the watchdog cases, even with the "free" text glued on
    $stuckText = Get-HarnessHostFailure ([pscustomobject]@{ Status = 'Timeout'; Seconds = 8.2; ExitCode = $null; Modal = $null; Windows = @(); Pid = 77; StillRunning = $true })
    & $add 'negative verdict: a process the watchdog could not end has its own text and verifies neither watchdog case' $true ($stuckText -like 'the watchdog could not end process 77*' -and (& $verdict 'neg-timeout' 'INCOMPLETE' "$stuckText; the process has ended and the GUI locks are free").Status -ceq 'INCOMPLETE' -and (& $verdict 'neg-killed' 'INCOMPLETE' "$stuckText; the process has ended and the GUI locks are free").Status -ceq 'INCOMPLETE')
    & $add 'negative verdict (built-in): the timeout case is PASS only when ended at the timeout' $false ((& $verdict 'neg-timeout' 'INCOMPLETE' (& $hang 'Timeout')).Status -eq 'PASS')
    & $add 'negative verdict (built-in): the kill case is PASS only when ended at the kill point' $false ((& $verdict 'neg-killed' 'INCOMPLETE' (& $hang 'Killed')).Status -eq 'PASS')
    $busy = & $verdict 'neg-timeout' 'INCOMPLETE' 'the GUI locks were not available in time; REAPER was not started; the watchdog could not be checked'
    & $add 'negative verdict: a busy GUI lock (REAPER never started) is INCOMPLETE too, but cannot make the watchdog case PASS; the row says it was not verified' $true ($busy.Status -eq 'INCOMPLETE' -and $busy.Detail -match 'not verified')
    & $add 'negative verdict: the kill case cannot pass on a busy lock either' $true ((& $verdict 'neg-killed' 'INCOMPLETE' (& $hang 'LockBusy')).Status -eq 'INCOMPLETE')
    & $add 'negative verdict: a watchdog case stuck on a dialog, or REAPER exiting by itself, is INCOMPLETE but not verified' $true (((& $verdict 'neg-timeout' 'INCOMPLETE' (& $hang 'Modal')).Status -eq 'INCOMPLETE') -and ((& $verdict 'neg-timeout' 'INCOMPLETE' (& $hang 'Exited' 3)).Status -eq 'INCOMPLETE') -and ((& $verdict 'neg-killed' 'INCOMPLETE' (& $hang 'Modal')).Status -eq 'INCOMPLETE'))
    & $add 'negative verdict: timeout and kill cannot stand in for each other' $true (((& $verdict 'neg-timeout' 'INCOMPLETE' (& $hang 'Killed')).Status -eq 'INCOMPLETE') -and ((& $verdict 'neg-killed' 'INCOMPLETE' (& $hang 'Timeout')).Status -eq 'INCOMPLETE'))
    & $add 'negative verdict: the 1-sample offset case needs lag=1' $false ((& $verdict 'neg-offset-1-sample' 'FAIL' (Get-HarnessCompareVerdict -Facts (New-Facts @{ Identical = $false; BestLag = 1 })).Detail).Status -eq 'PASS')
    & $add 'negative verdict: the 1-sample offset case with a FAIL that has no lag (renders not comparable) is not verified' $true ((& $verdict 'neg-offset-1-sample' 'FAIL' (Get-HarnessCompareVerdict -Facts (New-Facts @{ Identical = $false; Comparable = $false })).Detail).Status -eq 'INCOMPLETE')
    & $add 'negative verdict: the -6 dB case needs lag=0 and maxdiff -6.0x' $false ((& $verdict 'neg-track-minus-6db' 'FAIL' (Get-HarnessCompareVerdict -Facts (New-Facts @{ Identical = $false; MaxDiff = 0.5 })).Detail).Status -eq 'PASS')
    & $add 'negative verdict: the -6 dB case cannot pass on a lag=1 FAIL' $true ((& $verdict 'neg-track-minus-6db' 'FAIL' (Get-HarnessCompareVerdict -Facts (New-Facts @{ Identical = $false; BestLag = 1 })).Detail).Status -eq 'INCOMPLETE')
    & $add 'negative verdict: observed INCOMPLETE (the case could not run) when FAIL is expected is INCOMPLETE, not FAIL' $true ((& $verdict 'neg-offset-1-sample' 'INCOMPLETE' 'cannot read render A: WAV: no RIFF header').Status -eq 'INCOMPLETE')
    & $add 'negative verdict: what should have turned red did not (observed PASS, expected FAIL) is FAIL' $true ((& $verdict 'neg-offset-1-sample' 'PASS' 'identical=yes lag=0 ').Status -eq 'FAIL')
    # A render with no frames says nothing, so a comparer case cannot pass on one: not PASS, and not FAIL either
    $noFrames = Get-HarnessCompareVerdict -Facts (New-Facts @{ FramesA = 0; FramesB = 0; Identical = $false; BestLag = 1 })
    & $add 'negative verdict: an empty render when the comparer cases expect FAIL is INCOMPLETE, whatever else its facts say' $true ($noFrames.Status -ceq 'INCOMPLETE' -and (& $verdict 'neg-offset-1-sample' $noFrames.Status $noFrames.Detail).Status -ceq 'INCOMPLETE' -and (& $verdict 'neg-track-minus-6db' $noFrames.Status $noFrames.Detail).Status -ceq 'INCOMPLETE')
    $refusal = { param($block) try { $null = & $block; 'NOTHROW' } catch { $_.Exception.Message -replace '\s+', ' ' } } # the shape Invoke-HarnessGuardNegative records
    $msgDefault = & $refusal { Assert-HarnessCfgDir (Get-HarnessDefaultCfgDir) }
    $bareDir = Join-Path $Tmp 'neg-bare'
    $null = New-Item -ItemType Directory -Path $bareDir
    Set-Content -LiteralPath (Join-Path $bareDir 'reaper.ini') -Value '[REAPER]'
    $msgBare = & $refusal { Assert-HarnessCfgDir $bareDir }
    & $add 'negative verdict (built-in): the missing-sentinel case is PASS only for the sentinel reason; the default-directory reason cannot stand in' $true (((& $verdict 'neg-sentinel-missing' 'REFUSED' $msgBare).Status -eq 'PASS') -and ((& $verdict 'neg-sentinel-missing' 'REFUSED' $msgDefault).Status -eq 'INCOMPLETE'))
    & $add 'negative verdict (built-in): the default-directory case is PASS only for "never touched"; the sentinel reason cannot stand in' $true (((& $verdict 'neg-default-dir' 'REFUSED' $msgDefault).Status -eq 'PASS') -and ((& $verdict 'neg-default-dir' 'REFUSED' $msgBare).Status -eq 'INCOMPLETE'))
    & $add 'negative verdict (built-in): the skip-marker case needs the marker reason; a SKIPPED made of other reasons (no reaper.exe) does not count' $true (
        ((& $verdict 'neg-skip-marker' 'SKIPPED' 'launches=0; skip marker present: SKIP (someone is using this machine; REAPER is not started)').Status -eq 'PASS') -and
        ((& $verdict 'neg-skip-marker' 'SKIPPED' 'launches=0; reaper.exe not found').Status -eq 'INCOMPLETE'))
    & $add 'built-in negative cases: all seven are there, each with an expected outcome and a reason regex' $false (@($negs.get_Keys()).Count -eq 7 -and @($negs.get_Values() | Where-Object { -not $_.expect -or -not $_.expectDetail -or -not $_.builtin }).Count -eq 0)
    # Default build label
    $labels = @(1, 2, 3, 4, 5, 6, 9) | ForEach-Object {
        $shas = [ordered]@{}
        for ($k = 1; $k -le $_; $k++) { $shas["p$k"] = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]@($k)))).ToLowerInvariant() }
        Get-HarnessDefaultLabel $shas
    }
    & $add 'build label: up to three plugins, 12 hex digits each joined by -; more plugins fewer digits; above five one hash; always within the label pattern' $false (
        $labels[0] -cmatch '^[0-9a-f]{12}$' -and $labels[1] -cmatch '^[0-9a-f]{12}-[0-9a-f]{12}$' -and $labels[3] -cmatch '^([0-9a-f]{9}-){3}[0-9a-f]{9}$' -and $labels[5] -cmatch '^[0-9a-f]{12}$' -and
        $labels[5] -cne $labels[6] -and @($labels | Where-Object { $_ -cnotmatch '^[0-9A-Za-z._-]{1,40}$' }).Count -eq 0 -and (Get-HarnessDefaultLabel ([ordered]@{})) -ceq 'unknown')
    # What a round counts as left over: a process it started itself, by PID and start time
    $t0 = [DateTime]::new(2026, 11, 2, 1, 0, 0, [DateTimeKind]::Utc)
    $startedRows = @(
        [pscustomobject]@{ Pid = 11; StartUtc = $t0 }, [pscustomobject]@{ Pid = 22; StartUtc = $t0 }, [pscustomobject]@{ Pid = 33; StartUtc = $t0 }, [pscustomobject]@{ Pid = 44; StartUtc = $null }, [pscustomobject]@{ Pid = 55; StartUtc = $null }
    )
    $startOf = { param($id) switch ($id) { 11 { $t0 } 22 { $t0.AddSeconds(30) } 33 { $null } 44 { $t0 } 55 { $null } } }.GetNewClosure()
    $leftIds = @((Get-HarnessOwnProcessesLeft -Started $startedRows -StartOf $startOf) | ForEach-Object { $_.Pid })
    & $add 'left over: a process of this round still alive, same PID and same start time, counts' $true (11 -in $leftIds)
    & $add 'left over: the same PID with another start time is a later process that got the number: it does not count' $false (22 -notin $leftIds)
    & $add 'left over: a PID that is gone does not count, with or without a start time' $false (33 -notin $leftIds -and 55 -notin $leftIds)
    & $add 'left over: a start time that was never read cannot tell it apart, so a live PID counts' $true (44 -in $leftIds)
    & $add 'left over: nothing started, nothing left' $false (@(Get-HarnessOwnProcessesLeft -Started @() -StartOf $startOf).Count -eq 0)
    & $add 'left over: this very process found through the real lookup, with its real start time' $true (@(Get-HarnessOwnProcessesLeft -Started @([pscustomobject]@{ Pid = $PID; StartUtc = (Get-HarnessProcessStartUtc (Get-Process -Id $PID)) })).Count -eq 1)
    $cases
}

# ---------------------------------------------------------------- configuration and schema
function Get-ConfigCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $configFile = Join-Path $RepoRoot 'tests/fixtures/config.json'
    $extensions = Import-HarnessExtensions (Read-HarnessConfigExtensions $configFile)
    $conf = Read-HarnessConfig -Path $configFile -Kinds $extensions.Kinds
    & $add 'configuration: the fixture configuration is valid; the matrix expands to four scenarios' $false ($conf.Name -eq 'fixture' -and @($conf.Scenarios).Count -eq 23 -and @($conf.Scenarios | Where-Object { $_.id -like 'chain-*-4*' }).Count -eq 4)
    $text = [IO.File]::ReadAllText($configFile)
    $problems = {
        param([scriptblock]$Edit)
        $raw = ConvertFrom-HarnessJson $text
        & $Edit $raw
        @((Test-HarnessConfigData -Raw $raw -Kinds $extensions.Kinds).Problems)
    }
    $scenario = { param($raw, $id) @($raw['scenarios'] | Where-Object { $_['id'] -eq $id })[0] }
    $vary = { param($raw, [object[]]$VariantList) (& $scenario $raw 'chain-repeat')['variants'] = $VariantList }
    $gainVariant = { param([string]$VariantId, $GainFx) [ordered]@{ id = $VariantId; fx = [ordered]@{ gain = $GainFx } } }
    $mutations = @(
        @{ L = 'an unknown key at the top'; E = { param($c) $c['surprise'] = 1 }; M = "unknown key 'surprise'" }
        @{ L = 'an unknown key in a scenario'; E = { param($c) (& $scenario $c 'bus')['speed'] = 2 }; M = "unknown key 'speed'" }
        @{ L = 'a configuration without any plugin (a run would have no binary to prove)'; E = { param($c) $c['plugins'] = [ordered]@{} }; M = 'config.plugins: needs at least 1 entry' }
        @{ L = 'schema 2'; E = { param($c) $c['schema'] = 2 }; M = 'schema' }
        @{ L = 'a string where a number belongs'; E = { param($c) $c['signal']['seconds'] = 'long' }; M = 'seconds' }
        @{ L = 'a sample rate out of range'; E = { param($c) (& $scenario $c 'bus')['sr'] = 100 }; M = 'sr' }
        @{ L = 'a scenario id that breaks the pattern'; E = { param($c) (& $scenario $c 'bus')['id'] = 'Bus Two' }; M = 'id' }
        @{ L = 'two scenarios with the same id'; E = { param($c) (& $scenario $c 'bus-device')['id'] = 'bus' }; M = 'used twice' }
        @{ L = 'a scenario naming a layout that does not exist'; E = { param($c) (& $scenario $c 'bus')['layout'] = 'nowhere' }; M = 'nowhere' }
        @{ L = 'a layout naming a plugin that does not exist'; E = { param($c) $c['layouts']['chain']['tracks'][0]['fx'][0]['plugin'] = 'ghost' }; M = 'ghost' }
        @{ L = 'a track whose parent is not a folder track'; E = { param($c) $c['layouts']['bus']['tracks'][2]['parent'] = 'Vox 1' }; M = 'folder' }
        @{ L = 'an unknown kind'; E = { param($c) (& $scenario $c 'bus')['kind'] = 'nope' }; M = 'nope' }
        @{ L = 'the internal kind hang in a configuration'; E = { param($c) $c['negative'][0]['kind'] = 'hang' }; M = 'hang' }
        @{ L = 'a negative case without expectDetail'; E = { param($c) $c['negative'][0].Remove('expectDetail') }; M = 'expectDetail' }
        @{ L = 'a negative case whose expectDetail is not a valid regex'; E = { param($c) $c['negative'][0]['expectDetail'] = '(' }; M = 'expectDetail' }
        @{ L = 'a negative case with an empty expectDetail (it would match any reason)'; E = { param($c) $c['negative'][0]['expectDetail'] = '' }; M = 'expectDetail' }
        @{ L = 'a negative case whose expectDetail is .* (it matches the empty text, so any reason)'; E = { param($c) $c['negative'][0]['expectDetail'] = '.*' }; M = 'empty text' }
        @{ L = 'a negative case whose expectDetail is ^ (it matches the empty text, so any reason)'; E = { param($c) $c['negative'][0]['expectDetail'] = '^' }; M = 'empty text' }
        @{ L = 'an unknown expected outcome'; E = { param($c) $c['negative'][0]['expect'] = 'MAYBE' }; M = 'expect' }
        @{ L = 'a matrix in a negative case'; E = { param($c) $c['negative'][0]['matrix'] = [ordered]@{ sr = @(48000) } }; M = 'matrix' }
        @{ L = 'an axis both in the matrix and given directly'; E = { param($c) (& $scenario $c 'chain')['sr'] = 48000 }; M = 'both directly and in matrix' }
        @{ L = 'a negative id that clashes with a built-in one'; E = { param($c) $c['negative'][0]['id'] = 'neg-timeout' }; M = 'neg-timeout' }
        @{ L = 'an extension kind with a bad field (its own Validate)'; E = { param($c) (& $scenario $c 'ext-count')['count'] = 99 }; M = 'count' }
        @{ L = 'a state with both a template and a state file'; E = { param($c) $c['plugins']['gain']['states']['loud']['template'] = 'states/template.rpp' }; M = 'must be { template, track, fx } or { stateFile }' }
        @{ L = 'a template state without the FX number'; E = { param($c) $c['plugins']['gain']['states']['quiet'].Remove('fx') }; M = "states.quiet: missing 'fx'" }
        @{ L = 'an FX naming a state its plugin does not have'; E = { param($c) $c['layouts']['states']['tracks'][0]['fx'][0]['state'] = 'nope' }; M = "has no state 'nope'" }
        @{ L = 'states on a JSFX'; E = { param($c) $c['plugins']['delay']['states'] = [ordered]@{ x = [ordered]@{ stateFile = 'states/loud.RfxChain' } } }; M = 'states are only for VST3 plugins' }
        @{ L = 'a plugin with both a bundle and a JSFX'; E = { param($c) $c['plugins']['delay']['bundle'] = 'Other.vst3' }; M = 'needs exactly one of bundle' }
        @{ L = 'a plugin with neither a bundle nor a JSFX'; E = { param($c) $c['plugins']['bus'].Remove('bundle') }; M = 'needs exactly one of bundle' }
        @{ L = 'an unknown JSFX'; E = { param($c) $c['plugins']['delay']['jsfx'] = 'other-delay' }; M = 'plugins.delay.jsfx' }
        @{ L = 'a send to a track that is not in the layout'; E = { param($c) $c['layouts']['routing']['tracks'][0]['sends'][0]['to'] = 'Nowhere' }; M = "sends to 'Nowhere'" }
        @{ L = 'a track sending to itself'; E = { param($c) $c['layouts']['routing']['tracks'][0]['sends'][0]['to'] = 'Drums' }; M = 'sends to itself' }
        @{ L = 'a loop of sends'; E = { param($c) $c['layouts']['routing']['tracks'][2]['sends'] = @([ordered]@{ to = 'Drums' }) }; M = 'the routing has a loop: Drums -> Verb -> Drums' }
        @{ L = 'a loop through a folder (the folder sends to its child, the child feeds the folder)'; E = { param($c) $c['layouts']['bus']['tracks'][0]['sends'] = @([ordered]@{ to = 'Vox 1' }) }; M = 'the routing has a loop: Bus -> Vox 1 -> Bus' }
        @{ L = 'an unknown send mode'; E = { param($c) $c['layouts']['routing']['tracks'][0]['sends'][0]['mode'] = 'side' }; M = 'sends[0].mode' }
        @{ L = 'a pan out of range'; E = { param($c) $c['layouts']['routing']['tracks'][0]['pan'] = 2 }; M = 'tracks[0].pan' }
        @{ L = 'a signal on a track that carries none'; E = { param($c) $c['layouts']['routing']['tracks'][2]['signal'] = [ordered]@{ seed = 3 } }; M = 'source is false' }
        @{ L = 'a stem that is not a track of the layout'; E = { param($c) (& $scenario $c 'states')['stems'][0]['track'] = 'Ghost' }; M = "'Ghost' is not a track of layout 'states'" }
        @{ L = 'a stem whose track name cannot name a file (not ASCII)'; E = { param($c) (& $scenario $c 'states')['stems'][0]['track'] = 'V' + [char]0xF6 + 'x' }; M = 'cannot name a stem file' }
        @{ L = 'a stem whose track name ends in a dot'; E = { param($c) (& $scenario $c 'states')['stems'][0]['track'] = 'Quiet.' }; M = 'cannot name a stem file' }
        @{ L = 'a stem whose track name is one dot (it ends in a dot too)'; E = { param($c) (& $scenario $c 'states')['stems'][0]['track'] = '.' }; M = 'cannot name a stem file' }
        @{ L = 'a stem named Master (the name of the master file)'; E = { param($c) (& $scenario $c 'states')['stems'][0]['track'] = 'master' }; M = 'a track named Master cannot be a stem' }
        @{ L = 'a stem listed twice, differing only by case'; E = { param($c) (& $scenario $c 'routing')['stems'] += 'drums' }; M = "'drums' is listed twice" }
        @{ L = 'a stem compared with the reference when the scenario compares with none'; E = { param($c) (& $scenario $c 'routing-alone')['stems'] = @([ordered]@{ track = 'Cue'; compare = 'reference' }) }; M = 'compare reference needs a reference' }
        @{ L = 'a stem the compared layout does not have'; E = { param($c) (& $scenario $c 'states')['compare'] = [ordered]@{ layout = 'chain' } }; M = "the layout compared with ('chain') has no track 'Quiet'" }
        @{ L = 'maxDiffDb when the render is compared with none'; E = { param($c) (& $scenario $c 'routing-alone')['maxDiffDb'] = -120 }; M = 'maxDiffDb needs a reference' }
        @{ L = 'rmsChangeDb when the render is compared with none'; E = { param($c) (& $scenario $c 'routing-alone')['rmsChangeDb'] = [ordered]@{ L = @(0, 1) } }; M = 'rmsChangeDb needs a reference' }
        @{ L = 'a channel criterion on R of a mono render'; E = { param($c) (& $scenario $c 'states')['mono'] = $true }; M = 'rmsChangeDb.R: the render has 1 channel' }
        @{ L = 'a channel criterion on channel 3 of a stereo render'; E = { param($c) (& $scenario $c 'states')['rmsChangeDb']['3'] = @(0, 1) }; M = 'rmsChangeDb.3: the render has 2 channels' }
        @{ L = 'a ratio of a channel with itself'; E = { param($c) (& $scenario $c 'routing')['energyRatioDb'] = [ordered]@{ 'L/1' = @(0, 1) } }; M = 'a ratio needs two different channels' }
        @{ L = 'a range whose min is above its max'; E = { param($c) (& $scenario $c 'routing')['energyRatioDb']['L/R'] = @(7, 5) }; M = 'min 7 is above max 5' }
        @{ L = 'a range of one number'; E = { param($c) (& $scenario $c 'routing')['energyRatioDb']['L/R'] = @(5) }; M = 'needs at least 2 items' }
        @{ L = 'a range of three numbers'; E = { param($c) (& $scenario $c 'routing')['energyRatioDb']['L/R'] = @(1, 2, 3) }; M = 'has more than 2 items' }
        @{ L = 'savereopen with 0 cycles'; E = { param($c) (& $scenario $c 'states-reopen')['cycles'] = 0 }; M = 'cycles' }
        @{ L = 'an unknown host setting'; E = { param($c) (& $scenario $c 'pdc')['host']['lowLatency'] = $true }; M = "unknown key 'lowLatency'" }
        @{ L = 'a render mode axis in the matrix of a device scenario (the device step renders nothing)'; E = { param($c) (& $scenario $c 'bus-device')['matrix'] = [ordered]@{ mode = @('offline', '1x') } }; M = "matrix: unknown key 'mode'" }
        @{ L = 'a transport state with an unknown transport (recording is no state the harness can be asked for)'; E = { param($c) (& $scenario $c 'monitor-states')['states'][0]['transport'] = 'record' }; M = 'states[0].transport' }
        @{ L = 'a transport state with an unknown monitoring mode'; E = { param($c) (& $scenario $c 'monitor-states')['states'][0]['monitor'] = 'always' }; M = 'states[0].monitor' }
        @{ L = 'a transport state without arm'; E = { param($c) (& $scenario $c 'monitor-states')['states'][0].Remove('arm') }; M = "missing 'arm'" }
        @{ L = 'a transport state whose arm is not a boolean'; E = { param($c) (& $scenario $c 'monitor-states')['states'][0]['arm'] = 1 }; M = 'states[0].arm' }
        @{ L = 'an unknown key in a transport state'; E = { param($c) (& $scenario $c 'monitor-states')['states'][0]['record'] = $true }; M = "unknown key 'record'" }
        @{ L = 'an unknown key in the expectation of a state'; E = { param($c) (& $scenario $c 'monitor-states')['states'][0]['expect']['latency'] = 0 }; M = "unknown key 'latency'" }
        @{ L = 'an unknown input expectation'; E = { param($c) (& $scenario $c 'monitor-states')['states'][0]['expect']['input'] = 'loud' }; M = 'expect.input' }
        @{ L = 'an unknown channel layout of a feed'; E = { param($c) (& $scenario $c 'monitor-states')['feed']['channels'] = 'both' }; M = 'feed.channels' }
        @{ L = 'a state window shorter than 64 samples'; E = { param($c) (& $scenario $c 'monitor-states')['states'][0]['samples'] = 32 }; M = 'states[0].samples' }
        @{ L = 'a negative settle time'; E = { param($c) (& $scenario $c 'monitor-states')['settleSamples'] = -1 }; M = 'settleSamples' }
        @{ L = 'a transport scenario without states'; E = { param($c) (& $scenario $c 'monitor-states')['states'] = @() }; M = 'states: needs at least 1' }
        @{ L = 'a transport scenario of 65 states'; E = { param($c) $t = & $scenario $c 'monitor-states'; $firstState = $t['states'][0]; $t['states'] = @(foreach ($i in 1..65) { $n = ConvertFrom-HarnessJson (ConvertTo-HarnessJsonText -Value $firstState); $n['name'] = "s$i"; $n }) }; M = 'has more than 64 items' }
        @{ L = 'a render mode axis in the matrix of a transport scenario (nothing is rendered)'; E = { param($c) (& $scenario $c 'monitor-states')['matrix'] = [ordered]@{ mode = @('offline', '1x') } }; M = "matrix: unknown key 'mode'" }
        @{ L = 'Run FX when stopped that is not a boolean'; E = { param($c) (& $scenario $c 'monitor-states')['host'] = [ordered]@{ runFxWhenStopped = 'yes' } }; M = 'runFxWhenStopped' }
        @{ L = 'a state name that breaks the pattern'; E = { param($c) (& $scenario $c 'monitor-states')['states'][0]['name'] = 'a b' }; M = 'states[0].name' }
        @{ L = 'a tool JSFX of the transport kind configured as a plugin'; E = { param($c) $c['plugins']['delay']['jsfx'] = 'harness-feed' }; M = 'plugins.delay.jsfx' }
        @{ L = 'a state name used twice'; E = { param($c) (& $scenario $c 'monitor-states')['states'][1]['name'] = 'stopped-unarmed' }; M = "state name 'stopped-unarmed' is used twice" }
        @{ L = 'no state with an expectation (the scenario would judge nothing)'; E = { param($c) foreach ($st in (& $scenario $c 'monitor-states')['states']) { $st.Remove('expect') } }; M = 'no state has an expect' }
        @{ L = 'an empty expectation'; E = { param($c) (& $scenario $c 'monitor-states')['states'][0]['expect'] = [ordered]@{} }; M = 'needs at least one of called, input, channels, monitoring' }
        @{ L = 'called false together with an input'; E = { param($c) (& $scenario $c 'monitor-states')['states'][0]['expect'] = [ordered]@{ called = $false; input = 'silent' } }; M = 'called false leaves no input to judge' }
        @{ L = 'input silent together with channels'; E = { param($c) (& $scenario $c 'monitor-states')['states'][0]['expect'] = [ordered]@{ input = 'silent'; channels = 'left' } }; M = 'channels describe a signal' }
        @{ L = 'a state window of fewer than 4 device blocks'; E = { param($c) $t = & $scenario $c 'monitor-states'; $t['block'] = 512; $t['states'][0]['samples'] = 1024 }; M = '1024 samples are less than 4 blocks of 512' }
        @{ L = 'a tested track that is not in the layout'; E = { param($c) (& $scenario $c 'monitor-states')['track'] = 'Ghost' }; M = "track: 'Ghost' is not a track of layout 'chain'" }
        @{ L = 'a layout of several tracks without naming the tested one'; E = { param($c) (& $scenario $c 'monitor-states')['layout'] = 'bus' }; M = "layout 'bus' has 3 tracks: name the tested one in 'track'" }
        @{ L = 'a negative id that clashes with the built-in transport one'; E = { param($c) $c['negative'][0]['id'] = 'neg-transport-probe' }; M = 'neg-transport-probe' }
        @{ L = 'a file on a track that carries no signal'; E = { param($c) $c['layouts']['bus']['tracks'][0]['file'] = 'a.wav' }; M = 'tracks[0]: file is given but the track carries no signal' }
        @{ L = 'a file and a signal on one track'; E = { param($c) $c['layouts']['routing']['tracks'][0]['file'] = 'a.wav' }; M = 'tracks[0]: file and signal are both given' }
        @{ L = 'a file that is not a string'; E = { param($c) $c['layouts']['chain']['tracks'][0]['file'] = 5 }; M = 'tracks[0].file' }
        @{ L = 'keep on a device scenario (only renders are kept)'; E = { param($c) (& $scenario $c 'bus-device')['keep'] = $true }; M = "unknown key 'keep'" }
        @{ L = 'keep in a negative case'; E = { param($c) $c['negative'][0]['keep'] = $true }; M = "unknown key 'keep'" }
        @{ L = 'keep that is not a boolean'; E = { param($c) (& $scenario $c 'bus')['keep'] = 'yes' }; M = 'keep' }
        @{ L = 'two variants with one id'; E = { param($c) & $vary $c @([ordered]@{ id = 'a' }, [ordered]@{ id = 'a'; bypass = $true }) }; M = "variants[1]: variant id 'a' is used twice" }
        @{ L = 'a variant of a plugin that is not defined'; E = { param($c) & $vary $c @([ordered]@{ id = 'a'; fx = [ordered]@{ nope = [ordered]@{ params = [ordered]@{ Gain = 0.5 } } } }) }; M = "fx.nope: plugin 'nope' is not defined in plugins" }
        @{ L = 'a variant of a plugin its layout does not use'; E = { param($c) & $vary $c @([ordered]@{ id = 'a'; fx = [ordered]@{ delay = [ordered]@{ params = [ordered]@{ 'Delay (samples)' = 0.5 } } } }) }; M = "fx.delay: plugin 'delay' is not used in layout 'chain'" }
        @{ L = 'a variant state the plugin does not have'; E = { param($c) & $vary $c @((& $gainVariant 'a' ([ordered]@{ state = 'nowhere' }))) }; M = "fx.gain: plugin 'gain' has no state 'nowhere'" }
        @{ L = 'the FX of a variant with empty parameters and no state'; E = { param($c) & $vary $c @((& $gainVariant 'a' ([ordered]@{ params = [ordered]@{} }))) }; M = 'fx.gain: needs state or params' }
        @{ L = 'the FX of a variant with nothing in it'; E = { param($c) & $vary $c @((& $gainVariant 'a' ([ordered]@{}))) }; M = 'fx.gain: needs state or params' }
        @{ L = 'a variant that bypasses a plugin its layout does not use'; E = { param($c) & $vary $c @([ordered]@{ id = 'a'; bypass = @('delay') }) }; M = "variants[0].bypass: plugin 'delay' is not used in that layout" }
        @{ L = 'variants without compare (a render of a variant compares with something or says "none")'; E = { param($c) (& $scenario $c 'chain-bypass')['variants'] = @([ordered]@{ id = 'a' }) }; M = 'a scenario with variants needs compare' }
        @{ L = 'a variant id that makes the scenario id longer than 80 characters'; E = { param($c) $s = & $scenario $c 'chain-repeat'; $s['id'] = 'chain-repeat-' + ('x' * 30); $s['variants'] = @([ordered]@{ id = 'v' + ('w' * 39) }) }; M = 'is longer than 80 characters after matrix and variant expansion' }
        @{ L = 'a variant whose scenario id is that of another scenario'; E = { param($c) $s = & $scenario $c 'bus'; $s['compare'] = [ordered]@{ block = 256 }; $s['variants'] = @([ordered]@{ id = 'device' }) }; M = "scenario id 'bus-device' is used twice" }
        @{ L = 'a scenario with the id of the learn row'; E = { param($c) (& $scenario $c 'bus')['id'] = 'learn' }; M = "scenario id 'learn' is the id of a row the tool writes" }
        @{ L = 'a scenario with the id of the round-error row'; E = { param($c) (& $scenario $c 'bus')['id'] = 'round-error' }; M = "scenario id 'round-error' is the id of a row the tool writes" }
        @{ L = 'two display texts for one learned setting'; E = { param($c) $c['layouts']['chain']['tracks'][0]['fx'][0]['params']['Gain'] = [ordered]@{ normalized = 0.25; display = '0.3' } }; M = "plugin 'gain' parameter 'Gain' at 0.25 is asked to show both '0.3' and '0.25'" }
        @{ L = 'variants on a device scenario (only renders have variants)'; E = { param($c) (& $scenario $c 'bus-device')['variants'] = @([ordered]@{ id = 'a' }) }; M = "unknown key 'variants'" }
        @{ L = 'variants in a negative case'; E = { param($c) $c['negative'][0]['variants'] = @([ordered]@{ id = 'a' }) }; M = "unknown key 'variants'" }
        @{ L = 'a variant without an id'; E = { param($c) & $vary $c @([ordered]@{ bypass = $true }) }; M = "variants[0]: missing 'id'" }
        @{ L = 'a variant id that breaks the pattern'; E = { param($c) & $vary $c @([ordered]@{ id = 'Dry Run' }) }; M = "'Dry Run' does not match" }
        @{ L = 'an empty list of variants'; E = { param($c) & $vary $c @() }; M = 'variants: needs at least 1 item' }
        @{ L = 'more than 1000 variants'; E = { param($c) & $vary $c @(1..1001 | ForEach-Object { [ordered]@{ id = "v$_" } }) }; M = 'variants: has more than 1000 items' }
        @{ L = 'an unknown key in a variant'; E = { param($c) & $vary $c @([ordered]@{ id = 'a'; params = [ordered]@{ Gain = 0.5 } }) }; M = "variants[0]: unknown key 'params'" }
        @{ L = 'an unknown key in the FX of a variant'; E = { param($c) & $vary $c @((& $gainVariant 'a' ([ordered]@{ bypass = $true }))) }; M = "fx.gain: unknown key 'bypass'" }
        @{ L = 'a variant with an empty fx'; E = { param($c) & $vary $c @([ordered]@{ id = 'a'; fx = [ordered]@{} }) }; M = 'fx: needs at least 1 entry' }
        @{ L = 'an expectPdc word other than report'; E = { param($c) $c['plugins']['delay']['expectPdc'] = 'reported' }; M = 'plugins.delay.expectPdc' }
        @{ L = 'a learn batch size of 0'; E = { param($c) $c['limits']['learnBatchSize'] = 0 }; M = 'learnBatchSize: must be between 1 and 256' }
        @{ L = 'a learn batch size of 257'; E = { param($c) $c['limits']['learnBatchSize'] = 257 }; M = 'learnBatchSize: must be between 1 and 256' }
        @{ L = 'a maxDiffDb word other than report (Report: the word is case sensitive)'; E = { param($c) (& $scenario $c 'chain-repeat')['maxDiffDb'] = 'Report' }; M = 'maxDiffDb: must be one of report' }
        @{ L = 'a maxDiffDb word other than report (reported)'; E = { param($c) (& $scenario $c 'chain-repeat')['maxDiffDb'] = 'reported' }; M = 'maxDiffDb: must be one of report' }
        @{ L = 'a maxDiffDb of true'; E = { param($c) (& $scenario $c 'chain-repeat')['maxDiffDb'] = $true }; M = 'maxDiffDb: must be a number -400..24, or "report"' }
        @{ L = 'a maxDiffDb of 25'; E = { param($c) (& $scenario $c 'chain-repeat')['maxDiffDb'] = 25 }; M = 'maxDiffDb: must be at least -400 and at most 24' }
        @{ L = 'a reported residual without a reference'; E = { param($c) (& $scenario $c 'routing-alone')['maxDiffDb'] = 'report' }; M = 'maxDiffDb needs a reference, but this render is compared with none' }
        @{ L = 'a reported residual on a stem judged on its own'; E = { param($c) (& $scenario $c 'routing')['stems'] = @([ordered]@{ track = 'Keys'; compare = 'none'; maxDiffDb = 'report' }) }; M = 'stems[0]: maxDiffDb needs a reference' }
        @{ L = 'a tail of -1 s'; E = { param($c) (& $scenario $c 'chain-repeat')['tailSeconds'] = -1 }; M = 'tailSeconds: must be at least 0 and at most 60' }
        @{ L = 'a tail of 60.5 s'; E = { param($c) (& $scenario $c 'chain-repeat')['tailSeconds'] = 60.5 }; M = 'tailSeconds: must be at least 0 and at most 60' }
        @{ L = 'a tail given as a string'; E = { param($c) (& $scenario $c 'chain-repeat')['tailSeconds'] = '1' }; M = 'tailSeconds: must be a number' }
        @{ L = 'a tail shorter than one frame'; E = { param($c) (& $scenario $c 'chain-repeat')['tailSeconds'] = 0.00001 }; M = 'tailSeconds: 1E-05 s is less than one frame at 48000 Hz' }
        @{ L = 'a tail on a savereopen scenario (only renders have one)'; E = { param($c) (& $scenario $c 'bus-reopen')['tailSeconds'] = 1 }; M = "unknown key 'tailSeconds'" }
        @{ L = 'a tail on a device scenario'; E = { param($c) (& $scenario $c 'bus-device')['tailSeconds'] = 1 }; M = "unknown key 'tailSeconds'" }
        @{ L = 'a tail on a transport scenario'; E = { param($c) (& $scenario $c 'monitor-states')['tailSeconds'] = 1 }; M = "unknown key 'tailSeconds'" }
        @{ L = 'a tail on a layout without a source track (no layout may lack one)'; E = { param($c) $c['layouts']['chain']['tracks'][0]['source'] = $false; (& $scenario $c 'chain-repeat')['tailSeconds'] = 0.5 }; M = 'layouts.chain: no track has source: true' }
        @{ L = 'keepFirst without keep'; E = { param($c) $s = & $scenario $c 'chain-repeat'; $s['maxDiffDb'] = 'report'; $s['keepFirst'] = $true }; M = 'keepFirst: needs keep true, compare "repeat" and maxDiffDb "report"' }
        @{ L = 'keepFirst on a render compared with dry'; E = { param($c) $s = & $scenario $c 'bus'; $s['maxDiffDb'] = 'report'; $s['keep'] = $true; $s['keepFirst'] = $true }; M = 'keepFirst: needs keep true, compare "repeat"' }
        @{ L = 'keepFirst on a repeat that judges its residual'; E = { param($c) $s = & $scenario $c 'chain-repeat'; $s['keep'] = $true; $s['keepFirst'] = $false }; M = 'keepFirst: needs keep true' }
        @{ L = 'keepFirst that is not a boolean'; E = { param($c) (& $scenario $c 'chain-repeat')['keepFirst'] = 'yes' }; M = 'keepFirst: must be true or false' }
        @{ L = 'keepFirst in a negative case'; E = { param($c) $c['negative'][0]['keepFirst'] = $true }; M = "unknown key 'keepFirst'" }
        @{ L = 'keepFirst on a device scenario'; E = { param($c) (& $scenario $c 'bus-device')['keepFirst'] = $true }; M = "unknown key 'keepFirst'" }
    )
    foreach ($mu in $mutations) {
        $found = & $problems $mu.E
        & $add "configuration: $($mu.L) is a problem ($($found -join ' | '))" $true (@($found | Where-Object { $_ -match [regex]::Escape($mu.M) }).Count -gt 0)
    }
    & $add 'configuration: a device scenario still takes a matrix of rates and block sizes' $false (@(& $problems { param($c) $d = & $scenario $c 'bus-device'; $d.Remove('block'); $d['matrix'] = [ordered]@{ sr = @(44100, 48000); block = @(64, 1024) } }).Count -eq 0)
    & $add 'configuration: every problem is listed at once, not just the first' $true (@(& $problems { param($c) $c['surprise'] = 1; $c['signal']['seconds'] = 'long' }).Count -ge 2)
    $badFile = Join-Path $Tmp 'config-bad.json'
    [IO.File]::WriteAllText($badFile, $text.Replace('"schema": 1,', '"schema": 1, "surprise": true,').Replace('"ext/', '"../fixtures/ext/'))
    & $add 'configuration: Read-HarnessConfig throws USAGE: with the problems' $true (Test-Usage { Read-HarnessConfig -Path $badFile -Kinds $extensions.Kinds } "*unknown key 'surprise'*")
    [IO.File]::WriteAllText($badFile, '{ "schema": 1, ')
    & $add 'configuration: a file that is not JSON is a usage error' $true (Test-Usage { Read-HarnessConfig -Path $badFile })
    & $add 'configuration: a missing file is a usage error' $true (Test-Usage { Read-HarnessConfig -Path (Join-Path $Tmp 'none.json') } '*not found*')
    # The hash a manifest names the configuration by is the hash of the bytes that were parsed (one read; a byte order
    # mark is read past as before, and is part of the hash)
    $bomFile = Join-Path $Tmp 'config-bom.json'
    [IO.File]::WriteAllText($bomFile, $text.Replace('"ext/', '"../fixtures/ext/'), [Text.UTF8Encoding]::new($true))
    $bomConf = try { Read-HarnessConfig -Path $bomFile -Kinds $extensions.Kinds } catch { $null }
    & $add 'configuration: Read-HarnessConfig gives the SHA-256 of the bytes it parsed, a byte order mark included' $false (
        $conf.FileSha256 -ceq (Get-FileHash -LiteralPath $configFile -Algorithm SHA256).Hash.ToLowerInvariant() -and $null -ne $bomConf -and $bomConf.Name -ceq 'fixture' -and
        $bomConf.FileSha256 -ceq (Get-FileHash -LiteralPath $bomFile -Algorithm SHA256).Hash.ToLowerInvariant() -and [IO.File]::ReadAllBytes($bomFile)[0] -eq 0xEF)
    # Ids and names that are also member names of a dictionary (Keys, Values, Count) are entries like any other
    $named = ConvertFrom-HarnessJson $text
    $named['plugins']['values'] = $named['plugins']['gain']; $named['plugins']['keys'] = $named['plugins']['bus']
    $found = @((Test-HarnessConfigData -Raw $named -Kinds $extensions.Kinds).Problems)
    & $add "configuration: plugins with the ids values and keys: two plugins using one bundle is still found ($($found -join ' | '))" $true (@($found -match 'same bundle').Count -gt 0)
    $named = ConvertFrom-HarnessJson $text
    $named['layouts']['chain']['tracks'][0]['fx'][0]['params'] = ConvertFrom-HarnessJson '{ "Keys": 0.25, "Values": 0.5, "Count": 0.75, "count": 1 }'
    $r = Test-HarnessConfigData -Raw $named -Kinds $extensions.Kinds
    $fx0 = $r.Config ? $r.Config.Layouts['chain'].Tracks[0].Fx[0] : $null
    & $add "configuration: parameters named Keys, Values, Count and count are four parameters ($(@($r.Problems) -join ' | '))" $false (
        @($r.Problems).Count -eq 0 -and $null -ne $fx0 -and (@($fx0.Params.get_Keys()) -join ',') -ceq 'count,Count,Keys,Values' -and $fx0.Variant -ceq 'gain|count=1;Count=0.75;Keys=0.25;Values=0.5')
    $jsonText = '{"Count":0,"Keys":{"Values":[1]},"Values":"v"}'
    $unusual = [ordered]@{ nan = [double]::NaN; up = [double]::PositiveInfinity; down = [double]::NegativeInfinity; f = [single]::NaN; list = @(1, [double]::NaN)
        when = [DateTime]::new(2026, 11, 2, 3, 4, 5, [DateTimeKind]::Utc); off = [DateTimeOffset]::new(2026, 11, 2, 3, 4, 5, [TimeSpan]::FromHours(1)); day = [DayOfWeek]::Monday
        c = [char]'x'; big = [uint64]::MaxValue; small = [byte]7; id = [guid]'00000000-0000-0000-0000-000000000001'; span = [TimeSpan]::FromSeconds(90); half = 0.5; n = 3 }
    $unusualText = try { ConvertTo-HarnessJsonText -Value $unusual } catch { "threw: $($_.Exception.Message)" }
    $want = '{"nan":"NaN","up":"Infinity","down":"-Infinity","f":"NaN","list":[1, "NaN"],"when":"2026-11-02T03:04:05.0000000Z","off":"2026-11-02T03:04:05.0000000+01:00","day":"Monday","c":"x","big":18446744073709551615,"small":7,"id":"00000000-0000-0000-0000-000000000001","span":"00:01:30","half":0.5,"n":3}'
    & $add "JSON: NaN and infinities and dates are written as strings, enums by name, other value types as their text, numbers as numbers ($unusualText)" $true ($unusualText -ceq $want)
    & $add 'JSON: what is written for them reads back as JSON' $false $(try { $null = ConvertFrom-HarnessJson $unusualText; $true } catch { $false })
    & $add 'JSON: keys named Count, Keys and Values are written back as they were read' $false ((ConvertTo-HarnessJsonText -Value (ConvertFrom-HarnessJson $jsonText)) -ceq $jsonText)
    # Selection
    $picked = Select-HarnessScenarios -Config $conf
    & $add 'selection: without -Only every scenario and negative case (own and built-in, the transport one too) is picked' $false ($picked.Positive.Count -eq 23 -and $picked.Negative.Count -eq 13 -and @($picked.Negative)[-1].id -ceq 'neg-transport-probe')
    # Defaults and the parts of the extended layouts
    $rt = @($conf.Layouts['routing'].Tracks)
    & $add 'configuration: a send is post-fader at volume 1 unless given; master send is on unless turned off; pan and mute as given' $false (
        $rt[0].Sends[0].Mode -ceq 'post' -and $rt[0].Sends[0].Volume -eq 0.5 -and $rt[0].Sends[1].Mode -ceq 'pre' -and $rt[0].Sends[1].Volume -eq 1 -and $rt[0].Pan -eq -0.5 -and
        $rt[1].Mute -and $rt[1].MasterSend -and -not $rt[3].MasterSend -and $rt[2].Pan -eq 0 -and -not $rt[2].Mute)
    & $add 'configuration: a track signal takes the top-level fields it does not give; a track without one has none of its own' $false (
        $rt[0].Signal.Seed -eq 11 -and $rt[0].Signal.NoiseDb -eq -24 -and $rt[0].Signal.SineHz -eq 440 -and $rt[1].Signal.SineHz -eq 1000 -and $rt[1].Signal.SineDb -eq -20 -and $null -eq $rt[2].Signal)
    $routing = @($conf.Scenarios | Where-Object id -eq 'routing')[0]
    $alone = @($conf.Scenarios | Where-Object id -eq 'routing-alone')[0]
    & $add 'configuration: a stem takes maxDiffDb, lag, peakMaxDb and notSilent of its scenario, never its channel criteria' $false (
        $routing.stems[0].Criteria.maxDiffDb -eq 0 -and $null -eq $routing.stems[0].Criteria.rmsChangeDb -and $null -eq $routing.stems[0].Criteria.energyRatioDb -and
        $null -ne $routing.stems[2].Criteria.energyRatioDb -and $null -eq $routing.stems[2].Criteria.rmsChangeDb -and $routing.stems[0].Compare -ceq 'reference' -and $routing.stems[3].Compare -ceq 'none' -and
        $alone.stems[0].Compare -ceq 'none' -and $alone.stems[0].Criteria.notSilent)
    $pdcDev = @($conf.Scenarios | Where-Object id -eq 'pdc-device')[0]
    & $add 'configuration: anticipative FX is on unless a scenario turns it off; savereopen cycles default to 1' $false (
        $routing.host.AnticipativeFx -and -not $pdcDev.host.AnticipativeFx -and (@($conf.Scenarios | Where-Object id -eq 'bus-reopen')[0]).cycles -eq 1 -and (@($conf.Scenarios | Where-Object id -eq 'states-reopen')[0]).cycles -eq 3)
    $pl = $conf.Plugins
    & $add 'configuration: a JSFX plugin has its kind and parameters; states keep their source' $false (
        $pl['delay'].Kind -ceq 'jsfx' -and $pl['delay'].Jsfx -ceq 'harness-pdc-delay' -and $pl['gain'].Kind -ceq 'vst3' -and $pl['gain'].States['quiet'].Template -ceq 'states/template.rpp' -and
        $pl['gain'].States['quiet'].Track -ceq 'Lead' -and $pl['gain'].States['quiet'].Fx -eq 1 -and $pl['gain'].States['loud'].StateFile -ceq 'states/loud.RfxChain')
    $loopTracks = @([pscustomobject]@{ Name = 'A'; Sends = @([pscustomobject]@{ To = 'B' }); Parent = ''; MasterSend = $true }, [pscustomobject]@{ Name = 'B'; Sends = @(); Parent = ''; MasterSend = $true })
    & $add 'routing: a send without a way back is no loop; a parent that the child does not feed (master send off) is no loop either' $false (
        (Find-RoutingCycle $loopTracks) -ceq '' -and (Find-RoutingCycle @([pscustomobject]@{ Name = 'F'; Sends = @([pscustomobject]@{ To = 'C' }); Parent = ''; MasterSend = $true }, [pscustomobject]@{ Name = 'C'; Sends = @(); Parent = 'F'; MasterSend = $false })) -ceq '')
    $one = Select-HarnessScenarios -Config $conf -Only '^chain-offline-48000$' -NoNegative
    & $add 'selection: -Only picks one scenario; -NoNegative leaves the negative cases out' $false ($one.Positive.Count -eq 1 -and $one.Negative.Count -eq 0)
    & $add 'selection: -Only picking nothing is a usage error' $true (Test-Usage { Select-HarnessScenarios -Config $conf -Only '^no-such-scenario$' } '*picked no scenario*')
    & $add 'selection: -Only picking only a negative case together with -NoNegative is a usage error' $true (Test-Usage { Select-HarnessScenarios -Config $conf -Only '^neg-timeout$' -NoNegative } '*-NoNegative*')
    & $add 'selection: an -Only that is not a valid regex is a usage error' $true (Test-Usage { Select-HarnessScenarios -Config $conf -Only '(' } '*not a valid regex*')
    & $add 'learning: needed by every scenario with a configured layout, by instances and by extension kinds; never by built-in negative cases' $false (
        (Test-HarnessNeedsLearn @($conf.Scenarios)[0]) -and (Test-HarnessNeedsLearn (@($conf.Scenarios) | Where-Object id -eq 'instances')) -and (Test-HarnessNeedsLearn (@($conf.Scenarios) | Where-Object id -eq 'ext-count')) -and
        @(Get-HarnessBuiltinNegatives -Transport | Where-Object { Test-HarnessNeedsLearn $_ }).Count -eq 0)
    # The schema file is generated from the validator: it must be current, and Test-Json must agree with the validator
    $schemaFile = Join-Path $RepoRoot 'schema/config.schema.json'
    $schemaText = [IO.File]::ReadAllText($schemaFile)
    & $add 'schema: schema/config.schema.json is what run.ps1 -WriteSchema generates now (regenerate it after changing Config.psm1)' $false ($schemaText -ceq (ConvertTo-HarnessJsonSchema))
    $agree = { param([string]$Json, [bool]$Accepted) $schemaOk = try { Test-Json -Json $Json -Schema $schemaText -ErrorAction Stop } catch { $false }; $schemaOk -eq $Accepted }
    & $add 'schema: Test-Json accepts the fixture configuration, like the validator' $false (& $agree $text $true)
    $withFile = ConvertFrom-HarnessJson $text
    $withFile['layouts']['chain']['tracks'][0]['file'] = 'sources/voice.wav'
    (& $scenario $withFile 'chain')['keep'] = $true
    $fileConf = Test-HarnessConfigData -Raw $withFile -Kinds $extensions.Kinds
    $kept = @($fileConf.Config ? @($fileConf.Config.Scenarios | Where-Object { $_.id -cmatch '^chain-(offline|1x)-' }) : @())
    & $add "configuration: a source track may play a file; keep on a render holds for every scenario of its matrix, each knowing the id it was written with ($(@($fileConf.Problems) -join ' | '))" $false (
        @($fileConf.Problems).Count -eq 0 -and $fileConf.Config.Layouts['chain'].Tracks[0].File -ceq 'sources/voice.wav' -and $kept.Count -eq 4 -and @($kept | Where-Object { $_.keep -ne $true -or $_.baseId -cne 'chain' }).Count -eq 0 -and
        @($fileConf.Config.Scenarios | Where-Object { $_.id -ceq 'chain-repeat' })[0].keep -eq $false -and (Get-HarnessDryLayout).Tracks[0].File -ceq '' -and @(Get-HarnessBuiltinNegatives | Where-Object { $_.kind -ceq 'render' -and $_.keep -ne $false }).Count -eq 0)
    & $add 'schema: Test-Json accepts a source file on a track and keep on a render, like the validator' $false (& $agree (ConvertTo-HarnessJsonText -Value $withFile) $true)
    $withVariants = ConvertFrom-HarnessJson $text
    & $vary $withVariants @([ordered]@{ id = 'dry'; bypass = $true }, (& $gainVariant 'loud-up' ([ordered]@{ state = 'loud'; params = [ordered]@{ Trim = [ordered]@{ normalized = 0.75; display = '0.75' } } })), [ordered]@{ id = 'no-bus'; fx = [ordered]@{ gain = [ordered]@{ params = [ordered]@{ Gain = 0.125 } } }; bypass = @('bus') })
    $withVariants['plugins']['delay']['expectPdc'] = 'report'
    $withVariants['limits']['learnBatchSize'] = 8
    $variantConf = Test-HarnessConfigData -Raw $withVariants -Kinds $extensions.Kinds
    & $add "schema: Test-Json accepts variants, expectPdc `"report`" and learnBatchSize, like the validator ($(@($variantConf.Problems) -join ' | '))" $false (
        @($variantConf.Problems).Count -eq 0 -and $variantConf.Config.Limits.learnBatchSize -eq 8 -and @($variantConf.Config.Scenarios | Where-Object { $_.baseId -ceq 'chain-repeat' }).Count -eq 3 -and (& $agree (ConvertTo-HarnessJsonText -Value $withVariants) $true))
    & $add 'configuration: learnBatchSize is 32 unless given' $false ($conf.Limits.learnBatchSize -eq 32)
    # maxDiffDb "report", a tail, keepFirst: accepted where they belong, normalised per leg of a matrix
    $withReport = ConvertFrom-HarnessJson $text
    $rs = & $scenario $withReport 'chain-repeat'; $rs['maxDiffDb'] = 'report'; $rs['keep'] = $true; $rs['keepFirst'] = $true; $rs['tailSeconds'] = 0.5
    $rr = & $scenario $withReport 'routing'; $rr['maxDiffDb'] = 'report'; $rr['stems'][1]['maxDiffDb'] = -90
    (& $scenario $withReport 'chain')['tailSeconds'] = 0.5
    $withReport['negative'][0]['tailSeconds'] = 0.1; $withReport['negative'][0]['maxDiffDb'] = 'report'
    $reportConf = Test-HarnessConfigData -Raw $withReport -Kinds $extensions.Kinds
    $scOf = { param([string]$ScId) @($reportConf.Config ? @($reportConf.Config.Scenarios | Where-Object { $_.id -ceq $ScId }) : @())[0] }
    $repeatSc = & $scOf 'chain-repeat'
    $routingSc = & $scOf 'routing'
    & $add "configuration: maxDiffDb `"report`" is kept as the word; a stem without its own takes it, a stem with its own number keeps that ($(@($reportConf.Problems) -join ' | '))" $false (
        @($reportConf.Problems).Count -eq 0 -and $repeatSc.maxDiffDb -is [string] -and $repeatSc.maxDiffDb -ceq 'report' -and $routingSc.stems[0].Criteria.maxDiffDb -ceq 'report' -and
        $routingSc.stems[1].Criteria.maxDiffDb -eq -90 -and $routingSc.stems[1].Criteria.maxDiffDb -isnot [string] -and $repeatSc.keepFirst -eq $true -and (Test-HarnessScenarioReports $routingSc) -and
        -not (Test-HarnessScenarioReports (& $scOf 'bus')))
    & $add 'configuration: the frames of a tail are counted at the rate of each leg of a matrix (0.5 s: 22050 at 44100 Hz, 24000 at 48000 Hz)' $true (
        (& $scOf 'chain-offline-44100').tailFrames -eq 22050 -and (& $scOf 'chain-offline-48000').tailFrames -eq 24000 -and (& $scOf 'chain-1x-44100').tailSeconds -eq 0.5 -and $repeatSc.tailFrames -eq 24000)
    $negTail = @($reportConf.Config ? @($reportConf.Config.Negative) : @())[0]
    $builtinRenders = @(Get-HarnessBuiltinNegatives | Where-Object { $_.kind -ceq 'render' })
    & $add 'configuration: a negative render case may report its residual and have a tail; the built-in negatives have no tail and keep nothing first' $true (
        $negTail.maxDiffDb -ceq 'report' -and $negTail.tailFrames -eq 4800 -and $builtinRenders.Count -ge 2 -and
        @($builtinRenders | Where-Object { -not $_.PSObject.Properties['tailSeconds'] -or -not $_.PSObject.Properties['tailFrames'] -or -not $_.PSObject.Properties['keepFirst'] -or
                $_.tailSeconds -ne 0 -or $_.tailFrames -ne 0 -or $_.keepFirst -ne $false }).Count -eq 0)
    & $add 'configuration: a render without a tail has tailSeconds 0 and tailFrames 0, without keepFirst false' $false ((& $scOf 'bus').tailSeconds -eq 0 -and (& $scOf 'bus').tailFrames -eq 0 -and (& $scOf 'bus').keepFirst -eq $false)
    $withReportVariants = ConvertFrom-HarnessJson (ConvertTo-HarnessJsonText -Value $withReport)
    & $vary $withReportVariants @([ordered]@{ id = 'dry'; bypass = $true }, [ordered]@{ id = 'as-is' })
    $reportVariants = Test-HarnessConfigData -Raw $withReportVariants -Kinds $extensions.Kinds
    $rv = @($reportVariants.Config ? @($reportVariants.Config.Scenarios | Where-Object { $_.baseId -ceq 'chain-repeat' }) : @())
    & $add "configuration: each variant takes the tail and the reported residual of its scenario ($(@($reportVariants.Problems) -join ' | '))" $false (
        $rv.Count -eq 2 -and @($rv | Where-Object { $_.tailFrames -ne 24000 -or $_.tailSeconds -ne 0.5 -or $_.maxDiffDb -cne 'report' -or $_.keepFirst -ne $true }).Count -eq 0)
    & $add 'schema: Test-Json accepts maxDiffDb "report", a tail and keepFirst where the validator does' $false (& $agree (ConvertTo-HarnessJsonText -Value $withReport) $true)
    $structural = @($mutations | Where-Object { $_.L -in 'an unknown key at the top', 'an unknown key in a scenario', 'schema 2', 'a string where a number belongs', 'a sample rate out of range', 'a scenario id that breaks the pattern', 'an unknown expected outcome', 'a negative case without expectDetail',
            'a state with both a template and a state file', 'a template state without the FX number', 'an unknown JSFX', 'an unknown send mode', 'a pan out of range', 'a range of one number', 'a range of three numbers', 'savereopen with 0 cycles', 'an unknown host setting', 'a render mode axis in the matrix of a device scenario (the device step renders nothing)',
            'a transport state with an unknown transport (recording is no state the harness can be asked for)', 'a transport state with an unknown monitoring mode', 'a transport state without arm', 'a transport state whose arm is not a boolean',
            'an unknown key in a transport state', 'an unknown key in the expectation of a state', 'an unknown input expectation', 'an unknown channel layout of a feed', 'a state window shorter than 64 samples', 'a negative settle time',
            'a transport scenario without states', 'a transport scenario of 65 states', 'a render mode axis in the matrix of a transport scenario (nothing is rendered)', 'Run FX when stopped that is not a boolean', 'a state name that breaks the pattern',
            'a tool JSFX of the transport kind configured as a plugin', 'a file that is not a string', 'keep on a device scenario (only renders are kept)', 'keep in a negative case', 'keep that is not a boolean',
            'variants on a device scenario (only renders have variants)', 'variants in a negative case', 'a variant without an id', 'a variant id that breaks the pattern', 'an empty list of variants', 'more than 1000 variants',
            'an unknown key in a variant', 'an unknown key in the FX of a variant', 'the FX of a variant with nothing in it', 'a variant with an empty fx', 'an expectPdc word other than report', 'a learn batch size of 0', 'a learn batch size of 257',
            'a maxDiffDb word other than report (Report: the word is case sensitive)', 'a maxDiffDb word other than report (reported)', 'a maxDiffDb of true', 'a maxDiffDb of 25', 'a tail of -1 s', 'a tail of 60.5 s', 'a tail given as a string',
            'a tail on a savereopen scenario (only renders have one)', 'a tail on a device scenario', 'a tail on a transport scenario', 'keepFirst that is not a boolean', 'keepFirst in a negative case', 'keepFirst on a device scenario' })
    $disagree = @(foreach ($mu in $structural) {
            $raw = ConvertFrom-HarnessJson $text
            & $mu.E $raw
            if (-not (& $agree (ConvertTo-HarnessJsonText -Value $raw) $false)) { $mu.L }
        })
    & $add "schema: Test-Json rejects the structural mutations the validator rejects ($($disagree -join ', '))" $true ($structural.Count -eq 64 -and $disagree.Count -eq 0)
    $cases
}

# ---------------------------------------------------------------- projects, Lua jobs, plugins, learning
function Get-ProjectCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $configFile = Join-Path $RepoRoot 'tests/fixtures/config.json'
    $conf = Read-HarnessConfig -Path $configFile -Kinds (Import-HarnessExtensions (Read-HarnessConfigExtensions $configFile)).Kinds
    $bus = $conf.Layouts['bus']
    $blocks = @{}
    foreach ($t in $conf.Layouts.get_Values()) { foreach ($t2 in $t.Tracks) { foreach ($fx in $t2.Fx) { $blocks[$fx.Variant] = @("<VST `"VST3: $($fx.Plugin)`" x.vst3 0 `"`" 1{0123456789ABCDEF0123456789ABCDEF} `"`"", 'STATE', '>') } } }
    $text = New-HarnessProjectText -Layout $bus -Blocks $blocks -SourceWav 'S.wav' -RenderDir 'D' -RenderName 'N' -SampleRate 44100 -Channels 2 -Mode '1x' -Bypass @('bus') -VolumeScale 0.5
    & $add 'project: folder flags open the folder on the bus track and close it on the last child' $false (@([regex]::Matches($text, 'ISBUS (\S+ \S+)') | ForEach-Object { $_.Groups[1].Value }) -join ',' -ceq '1 1,0 0,2 -1')
    & $add 'project: the source signal is an item on the source tracks only; the folder track has none' $false ([regex]::Matches($text, 'FILE "S.wav"').Count -eq 2)
    & $add 'project: -Bypass of a plugin id writes BYPASS 1 before that FX only' $false ([regex]::Matches($text, 'BYPASS 1 0 0').Count -eq 1 -and $text.IndexOf('BYPASS 1 0 0') -lt $text.IndexOf('NAME "Vox 1"'))
    & $add 'project: the volume scale applies to source tracks only (Vox 2: 0.5 x 0.5; the bus keeps 1)' $false ($text -match 'VOLPAN 0.25 ' -and $text -match 'NAME "Bus"\n    VOLPAN 1 ')
    & $add 'project: rate, channels, 1x speed and the float WAV render format are written' $false ($text -match 'RENDER_FMT 0 2 44100' -and $text -match 'RENDER_1X 1' -and $text -match 'SAMPLERATE 44100 ' -and $text -match 'ZXZhdyAAAQ==')
    & $add 'project: the learned block lines are written as they are' $false ([regex]::Matches($text, '(?m)^      STATE$').Count -eq 3)
    & $add 'project: -NoFx writes no FXCHAIN (the dry reference)' $false ((New-HarnessProjectText -Layout $bus -SourceWav 'S' -RenderDir 'D' -RenderName 'N' -NoFx) -notmatch 'FXCHAIN')
    & $add 'project: a plugin without a learned block is an error, never a hand-written block' $true ($(try { $null = New-HarnessProjectText -Layout $bus -Blocks @{} -SourceWav 'S' -RenderDir 'D' -RenderName 'N'; $false } catch { $_.Exception.Message -like '*no learned block*' }))
    $rl = $conf.Layouts['routing']
    $rb = @{}
    foreach ($t2 in $rl.Tracks) { foreach ($fx in $t2.Fx) { $rb[$fx.Variant] = @('<VST "x"', 'S', '>') } }
    $rt = New-HarnessProjectText -Layout $rl -Blocks $rb -SourceWav 'S.wav' -Sources @{ Drums = 'D.wav' } -RenderDir 'D' -RenderName 'N' -Stems @('Drums', 'Cue')
    $part = { param($name) [regex]::Match($rt, "(?s)  <TRACK\n    NAME `"$name`"\n.*?\n  >\n").Value }
    & $add 'project: pan, mute and the master send are written per track' $false (
        (& $part 'Drums') -match 'VOLPAN 1 -0.5 -1 -1 1' -and (& $part 'Keys') -match 'MUTESOLO 1 0 0' -and (& $part 'Drums') -match 'MUTESOLO 0 0 0' -and (& $part 'Cue') -match 'MAINSEND 0 0' -and (& $part 'Verb') -match 'MAINSEND 1 0')
    & $add 'project: a send is a receive of the receiving track: source track index, mode (0 post-fader, 3 pre-fader) and volume' $false (
        (& $part 'Verb') -match "AUXRECV 0 0 0.5 0 0 0 0 0 0 -1:U 0 -1 ''" -and (& $part 'Verb') -match 'AUXRECV 1 0 1 0 ' -and (& $part 'Cue') -match 'AUXRECV 0 3 1 0 ' -and (& $part 'Drums') -notmatch 'AUXRECV' -and [regex]::Matches($rt, 'AUXRECV').Count -eq 3)
    $pfx = [pscustomobject]@{ Tracks = @(
            [pscustomobject]@{ Name = 'A'; Source = $true; Folder = $false; Depth = 0; Volume = 1.0; Pan = 0.0; Mute = $false; MasterSend = $true; Sends = @([pscustomobject]@{ To = 'B'; Mode = 'prefx'; Volume = 0.25 }); Fx = @() }
            [pscustomobject]@{ Name = 'B'; Source = $false; Folder = $false; Depth = 0; Volume = 1.0; Pan = 0.0; Mute = $false; MasterSend = $true; Sends = @(); Fx = @() }) }
    & $add 'project: a pre-FX send is mode 1' $false ((New-HarnessProjectText -Layout $pfx -SourceWav 'S' -RenderDir 'D' -RenderName 'N') -match 'AUXRECV 0 1 0.25 0 ')
    & $add 'project: a track with a signal of its own gets that file; the other source tracks the shared one' $false ((& $part 'Drums') -match 'FILE "D.wav"' -and (& $part 'Keys') -match 'FILE "S.wav"' -and (& $part 'Verb') -notmatch 'FILE')
    $lt = New-HarnessProjectText -Layout $rl -Blocks $rb -SourceWav 'S.wav' -Sources @{ Drums = 'F.wav' } -Lengths @{ Drums = 0.29478458049886624 } -RenderDir 'D' -RenderName 'N' -Seconds 0.5
    $lpart = { param($name) [regex]::Match($lt, "(?s)  <TRACK
    NAME `"$name`"
.*?
  >
").Value }
    & $add 'project: the item of a track that plays a file is as long as the file (every digit of the length written); the other items as long as the test signal; all at position 0' $false (
        (& $lpart 'Drums') -match '(?m)^      POSITION 0
      LENGTH 0\.29478458049886624
' -and (& $lpart 'Keys') -match '(?m)^      LENGTH 0\.5
' -and [regex]::Matches($lt, 'LENGTH ').Count -eq 2)
    $ltHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($lt))).ToLowerInvariant()
    $looped = New-HarnessProjectText -Layout $rl -Blocks $rb -SourceWav 'S.wav' -Sources @{ Drums = 'F.wav' } -Lengths @{ Drums = 0.29478458049886624 } -RenderDir 'D' -RenderName 'N' -Seconds 0.5 -NoLoop
    & $add "project: without -NoLoop the text is the one of before, byte for byte; with it every item plays its source once (LOOP 0 right after its LENGTH), nothing else changes ($ltHash)" $true (
        $ltHash -ceq 'ab00bbf3588784f5a57a1846324f66ec7832554f95b50d7606330509127c769b' -and $lt -cnotmatch 'LOOP' -and [regex]::Matches($looped, '(?m)^      LOOP 0$').Count -eq 2 -and
        $looped -ceq ($lt -replace '(?m)^(      LENGTH [^\n]*\n)', "`${1}      LOOP 0`n"))
    # The stand-in plays an item longer than its file as REAPER does with "loop source" on, unless the item has LOOP 0
    $loopSrc = Join-Path $Tmp 'loop-src.wav'
    [HarnessWav]::Write($loopSrc, 48000, 1, 'float32', $false, [double[]](0.5, 0.25, 0.125, 0.0625))
    $loopLayout = [pscustomobject]@{ Tracks = @([pscustomobject]@{ Name = 'A'; Source = $true; Folder = $false; Depth = 0; Volume = 1.0; Pan = 0.0; Mute = $false; MasterSend = $true; Sends = @(); Fx = @() }) }
    $fakeOf = { param([switch]$NoLoop) @((Get-FakeMix (New-HarnessProjectText -Layout $loopLayout -SourceWav $loopSrc -Lengths @{ A = (Get-HarnessItemLength 10 48000) } -RenderDir 'D' -RenderName 'N' -Channels 1 -NoLoop:$NoLoop)).Master) -join ',' }
    & $add "stand-in: an item longer than its file plays the file again, unless it has LOOP 0: then the rest is silent ($(& $fakeOf) / $(& $fakeOf -NoLoop))" $true (
        (& $fakeOf) -ceq '0.5,0.25,0.125,0.0625,0.5,0.25,0.125,0.0625,0.5,0.25' -and (& $fakeOf -NoLoop) -ceq '0.5,0.25,0.125,0.0625,0,0,0,0,0,0')
    & $add 'project: with stems each file is named <name>-stem-<track>, REAPER renders master and stems, only the stem tracks are selected' $false (
        $rt -match 'RENDER_PATTERN "N-stem-\$track"' -and $rt -match 'RENDER_STEMS 1' -and (@([regex]::Matches($rt, 'SEL (\d)') | ForEach-Object { $_.Groups[1].Value }) -join '') -ceq '1001')
    # The files a render expects are the ones its render pattern makes REAPER write ($track is Master for the master)
    $wf = Get-HarnessRunFiles 'W' 'N' @('Drums', 'Cue')
    $pat = [regex]::Match($rt, 'RENDER_PATTERN "([^"]*)"').Groups[1].Value
    & $add "work files: the project, the master and each stem are where the render pattern puts them ($(Split-Path -Leaf $wf.Wav), $(Split-Path -Leaf $wf.Stems['Cue']))" $false (
        (Split-Path -Leaf $wf.Project) -ceq 'N.rpp' -and (Split-Path -Leaf $wf.Wav) -ceq "$($pat.Replace('$track', 'Master')).wav" -and
        (Split-Path -Leaf $wf.Stems['Drums']) -ceq "$($pat.Replace('$track', 'Drums')).wav" -and (Split-Path -Leaf $wf.Stems['Cue']) -ceq "$($pat.Replace('$track', 'Cue')).wav" -and
        (Split-Path -Leaf (Get-HarnessRunFiles 'W' 'N').Wav) -ceq 'N.wav')
    # No stem of the test render of scenario x takes a file of its first or variant render (with or without stems of
    # their own): not a stem named first (the first render's master without stems), first-Master or variant-a
    $tf = Get-HarnessRunFiles 'W' 'x' @('first', 'first-Master', 'variant', 'variant-a', 'Master2')
    $testFiles = @($tf.Project, $tf.Wav) + @($tf.Stems.get_Values())
    $clash = @(foreach ($rf in @((Get-HarnessRunFiles 'W' 'x-first'), (Get-HarnessRunFiles 'W' 'x-first' @('a')), (Get-HarnessRunFiles 'W' 'x-variant'), (Get-HarnessRunFiles 'W' 'x-variant' @('a')))) {
            foreach ($f in @($rf.Project, $rf.Wav) + @($rf.Stems.get_Values())) { if ($f -in $testFiles) { Split-Path -Leaf $f } }
        })
    & $add "work files: no stem takes the name of a file of the scenario's first or variant render (file names ignore case)$($clash.Count ? ": $($clash -join ', ')" : '')" $true ($clash.Count -eq 0)
    # The files the scenarios of a round share start with _, which no scenario id does: a scenario named like one
    # renders into a file of its own
    $sigCtx = [pscustomobject]@{ Work = $Tmp; Signals = @{}; Files = [Collections.Generic.List[string]]::new(); Signal = [pscustomobject]@{ Seconds = 0.5; Seed = 1; NoiseDb = -20.0; SineHz = 0.0; SineDb = -20.0 } }
    $sig = Get-HarnessSignal $sigCtx 48000 2
    $dryName = Get-HarnessReferenceName 'l' 48000 512 'offline' 2
    & $add "work files: a scenario named like a dry reference or a signal renders into a file of its own ($dryName, $(Split-Path -Leaf $sig))" $true (
        $dryName -ceq '_dry-l-48000-512-offline-2' -and (Get-HarnessReferenceName 'l' 48000 512 'offline' 2 @('A') $false) -clike '_dry-l-48000-512-offline-2-noaf-stems-*' -and
        (Split-Path -Leaf $sig) -ceq '_signal-48000-2-0.wav' -and (Test-Path -LiteralPath $sig) -and
        (Get-HarnessRunFiles $Tmp 'dry-l-48000-512-offline-2').Wav -notin @((Get-HarnessRunFiles $Tmp $dryName).Wav, $sig) -and (Get-HarnessRunFiles $Tmp 'signal-48000-2-0').Wav -notin @($sig))
    & $add 'work files: a dry reference with a tail is another render, its name ends in -tail<frames>; without a tail the name is as before' $true (
        (Get-HarnessReferenceName 'l' 48000 512 'offline' 2 @() $true $true 480) -ceq '_dry-l-48000-512-offline-2-tail480' -and (Get-HarnessReferenceName 'l' 48000 512 'offline' 2 @() $true $true 0) -ceq $dryName -and
        (Get-HarnessReferenceName 'l' 48000 512 'offline' 2 @('A') $false $true 480) -clike '_dry-l-48000-512-offline-2-noaf-stems-*-tail480')
    & $add 'project: without stems one file named as asked, no stem render, no track selected' $false ($text -match 'RENDER_PATTERN "N"' -and $text -notmatch 'RENDER_STEMS' -and $text -notmatch 'SEL 1')
    $lp = New-HarnessLearnProjectText -Variants @([pscustomobject]@{ Key = 'gain|'; State = '' }, [pscustomobject]@{ Key = 'gain@quiet|'; State = 'quiet' }) -States @{ 'gain@quiet|' = @('<VST "q"', 'Q', '>') }
    & $add 'learn project: an empty track per variant, the state block already on the track of a named state' $false ($lp -match '(?s)NAME "learn-1"\n    NCHAN 2\n  >\n  <TRACK\n    NAME "learn-2"\n    NCHAN 2\n    <FXCHAIN\n      BYPASS 0 0 0\n      <VST "q"\n      Q\n      >\n    >')
    & $add 'learn project: a named state without its block is an error' $true ($(try { $null = New-HarnessLearnProjectText -Variants @([pscustomobject]@{ Key = 'k'; State = 's' }); $false } catch { $true }))
    $lpn = New-HarnessLearnProjectText -Variants @([pscustomobject]@{ Key = 'gain|'; State = '' }, [pscustomobject]@{ Key = 'gain@quiet|'; State = 'quiet' }) -States @{ 'gain@quiet|' = @('<VST "q"', 'Q', '>') } -TrackNames @('learn-1', 'Vox 1')
    & $add 'learn project: a track gets the name it is given (the template track of its state) and keeps its block' $false (
        $lpn -match '(?s)NAME "learn-1"\n    NCHAN 2\n  >\n  <TRACK\n    NAME "Vox 1"\n    NCHAN 2\n    <FXCHAIN\n      BYPASS 0 0 0\n      <VST "q"' -and
        (New-HarnessLearnProjectText -Variants @([pscustomobject]@{ Key = 'gain|'; State = '' }) -TrackNames @('')) -match 'NAME "learn-1"')
    $jsb = Get-HarnessFxBlocks "<REAPER_PROJECT`n  <TRACK`n    NAME t`n    <FXCHAIN`n      BYPASS 1 0 0`n      <JS `"reaper-harness/a b.jsfx`" `"`"`n        0 -`n      >`n    >`n  >`n>`n"
    & $add 'saved project: a JS block is found with its path under Effects (quoted when it holds a space); an unquoted track name is read too' $false (
        @($jsb['t']).Count -eq 1 -and @($jsb['t'])[0].Kind -ceq 'JS' -and @($jsb['t'])[0].File -ceq 'reaper-harness/a b.jsfx' -and @($jsb['t'])[0].Bypass)
    & $add 'tokens: REAPER quotes a string with ", '' or ` (one the text does not hold)' $false (((ConvertFrom-HarnessRppTokens "VST 'a `"b`"' ``c'd`` `"`" e") -join '|') -ceq 'VST|a "b"|c''d||e')
    & $add 'project: a double quote in a name or path is refused' $true ($(try { $null = New-HarnessProjectText -Layout $bus -SourceWav 'a"b' -RenderDir 'D' -RenderName 'N' -NoFx; $false } catch { $true }))
    $saved = "<REAPER_PROJECT 0.1`n  <TRACK`n    NAME `"learn-1`"`n    <FXCHAIN`n      BYPASS 1 0 0`n      <VST `"VST3: Fixture Gain (Fixture Audio)`" `"Fixture Gain.vst3`" 0 `"`" 1234567890{5a1b2c3d4e5f60718293a4b5c6d7e8f9} `"`"`n        AAAA`n        <NESTED`n          x`n        >`n      >`n    >`n  >`n  <TRACK`n    NAME `"learn-2`"`n  >`n>`n"
    $fb = Get-HarnessFxBlocks $saved
    $b1 = @($fb['learn-1'])
    & $add 'saved project: the block is found per track, with name, uid, upper-case class ID, bypass state and nested sub-blocks kept' $false (
        $b1.Count -eq 1 -and $b1[0].Name -ceq 'VST3: Fixture Gain (Fixture Audio)' -and $b1[0].Uid -ceq '1234567890' -and $b1[0].Cid -ceq '5A1B2C3D4E5F60718293A4B5C6D7E8F9' -and $b1[0].Bypass -and
        $b1[0].Lines.Count -eq 6 -and $b1[0].Lines[-1] -ceq '>' -and @($fb['learn-2']).Count -eq 0)
    & $add 'saved project: a block that is not closed is an error' $true ($(try { $null = Get-HarnessFxBlocks "<TRACK`n NAME x`n <VST `"a`" b 0 `"`" 1{0123456789ABCDEF0123456789ABCDEF} `"`"`n AAAA`n"; $false } catch { $true }))
    $luaText = ConvertTo-HarnessLuaTable ([ordered]@{ p = "a\b`"c`nd"; n = 0.5; list = @(1, 'x'); flag = $true; none = $null })
    & $add 'Lua job: backslashes, quotes and line breaks are escaped; keys sorted; numbers invariant' $false ($luaText -ceq "return {[`"flag`"]=true,[`"list`"]={1,`"x`"},[`"n`"]=0.5,[`"none`"]=nil,[`"p`"]=`"a\\b\`"c\nd`"}`n")
    $back = ConvertFrom-FakeLua $luaText
    & $add "Lua job: the stand-in's reader gets back what was written" $false ($back['p'] -ceq "a\b`"c`nd" -and $back['n'] -eq 0.5 -and $back['list'][1] -ceq 'x' -and $back['flag'] -eq $true)
    $sigDir = Join-Path $Tmp 'signals'
    $null = New-Item -ItemType Directory -Force -Path $sigDir
    $sigCtx = [pscustomobject]@{ Signal = [pscustomobject]@{ Seconds = 0.1; Seed = [uint32]1; NoiseDb = -20.0; SineHz = 0.0; SineDb = -20.0 }; Signals = @{}; Work = $sigDir; Files = [Collections.Generic.List[string]]::new() }
    $spec = { param([uint32]$Seed, [double]$Hz) [pscustomobject]@{ Seed = $Seed; NoiseDb = -20.0; SineHz = $Hz; SineDb = -20.0 } }
    $top = Get-HarnessSignal $sigCtx 48000 2
    $own = Get-HarnessSignal $sigCtx 48000 2 -Spec (& $spec 11 0)
    $sine = Get-HarnessSignal $sigCtx 48000 2 -Spec (& $spec 11 1000)
    $again = Get-HarnessSignal $sigCtx 48000 2 -Spec (& $spec 11 0)
    $sha = { param($f) (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash }
    & $add 'signals: a track signal of its own gets a file of its own; the same settings give the same file, whichever track asks' $false (
        $again -ceq $own -and @($top, $own, $sine | Select-Object -Unique).Count -eq 3 -and @($top, $own, $sine | ForEach-Object { & $sha $_ } | Select-Object -Unique).Count -eq 3)
    $cases
}

function Get-PluginCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $fixtures = Join-Path $RepoRoot 'tests/fixtures/plugins'
    $gain = Read-HarnessModuleInfo (Join-Path $fixtures 'Fixture Gain.vst3')
    $js = Get-HarnessJsfxInfo 'harness-pdc-delay'
    & $add 'JSFX: the shipped PDC delay is shown as JS: <desc>, added as JS:reaper-harness/<file>, hashed' $false (
        $js.Name -ceq 'JS: reaper-harness PDC delay' -and $js.AddName -ceq 'JS:reaper-harness/harness-pdc-delay.jsfx' -and $js.Ident -ceq 'reaper-harness/harness-pdc-delay.jsfx' -and $js.Sha256 -cmatch '^[0-9a-f]{64}$')
    & $add 'JSFX: one that is not shipped is a plugin error' $true ($(try { $null = Get-HarnessJsfxInfo 'nope'; $false } catch { $_.Exception.Message -like 'PLUGIN:*nope.jsfx*' }))
    $jsText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'jsfx/harness-pdc-delay.jsfx'))
    & $add 'JSFX: the delay reports itself as PDC on both channels only while "Report delay as PDC" is on' $false (
        $jsText -match '(?m)^slider1:0<0,8192,1>Delay \(samples\)$' -and $jsText -match '(?m)^slider2:1<0,1,1\{Off,On\}>Report delay as PDC$' -and $jsText -match 'pdc_delay = slider2 >= 0\.5 \? delay : 0;' -and
        $jsText -match 'pdc_bot_ch = 0;' -and $jsText -match 'pdc_top_ch = 2;')
    & $add 'moduleinfo: the Audio Module Class gives name, vendor and class ID (JSON with trailing commas, as the SDK writes it)' $false ($gain.Name -ceq 'Fixture Gain' -and $gain.Vendor -ceq 'Fixture Audio' -and $gain.Cid -ceq '5A1B2C3D4E5F60718293A4B5C6D7E8F9')
    & $add 'REAPER name: "VST3: <Name> (<Vendor>)"' $false ((Get-HarnessReaperName $gain) -ceq 'VST3: Fixture Gain (Fixture Audio)')
    $plugins = Join-Path $Tmp 'pre-plugins'
    Copy-Item -LiteralPath $fixtures -Destination $plugins -Recurse
    $mi = Join-Path $plugins 'Fixture Bus.vst3\Contents\Resources\moduleinfo.json'
    $miText = [IO.File]::ReadAllText($mi)
    [IO.File]::WriteAllText($mi, $miText.Replace('"Category": "Audio Module Class"', '"Category": "Something Else"'))
    & $add 'moduleinfo: without exactly one Audio Module Class it is an error' $true ($(try { $null = Read-HarnessModuleInfo (Split-Path (Split-Path (Split-Path $mi))); $false } catch { $_.Exception.Message -like 'PLUGIN:*exactly one Audio Module Class*' }))
    [IO.File]::WriteAllText($mi, $miText)
    # Preflight
    $configFile = Join-Path $RepoRoot 'tests/fixtures/config.json'
    $conf = Read-HarnessConfig -Path $configFile -Kinds (Import-HarnessExtensions (Read-HarnessConfigExtensions $configFile)).Kinds
    $pwshExe = (Get-Process -Id $PID).Path
    $pre = { param([string]$Exe = $pwshExe, [string]$InDir = $plugins, [string[]]$Markers = @(), [object[]]$Ext = @()) Get-HarnessPreflight -ReaperExe $Exe -PluginDir $InDir -Config $conf -SkipMarkers $Markers -ExtensionPreflight $Ext }
    $mine = { param($p) @($p.Reasons | Where-Object { $_ -notmatch 'a reaper.exe not started by this tool' }) }
    $ok = & $pre
    & $add "preflight: with everything in place there is nothing missing ($((& $mine $ok) -join '; '))" $false (@(& $mine $ok).Count -eq 0 -and $ok.Plugins.Count -eq 2 -and $ok.Plugins['gain'].Sha256 -cmatch '^[0-9a-f]{64}$' -and $ok.ReaperVersion)
    & $add 'preflight: no reaper.exe is a reason' $true ((& $pre (Join-Path $Tmp 'no.exe')).Reasons -match 'reaper.exe not found')
    & $add 'preflight: no plugin directory is a reason' $true ((& $pre $pwshExe (Join-Path $Tmp 'none')).Reasons -match 'plugin directory')
    Remove-Item -LiteralPath $mi
    & $add 'preflight: a bundle without moduleinfo.json is a reason, naming the plugin' $true ((& $pre).Reasons -match '^plugin bus: .*moduleinfo.json')
    [IO.File]::WriteAllText($mi, $miText.Replace('"Name": "Fixture Bus"', '"Name": "Fixture Gain"'))
    & $add 'preflight: two plugins with the same REAPER name are a reason (they cannot be told apart)' $true ((& $pre).Reasons -match 'same name in REAPER')
    [IO.File]::WriteAllText($mi, $miText)
    $bin = Join-Path $plugins 'Fixture Bus.vst3\Contents\x86_64-win\Fixture Bus.vst3'
    Move-Item -LiteralPath $bin -Destination "$bin.away"
    & $add 'preflight: a bundle without a Windows binary is a reason' $true ((& $pre).Reasons -match 'no Windows binary')
    Move-Item -LiteralPath "$bin.away" -Destination $bin
    Rename-Item -LiteralPath (Join-Path $plugins 'Fixture Bus.vst3') -NewName 'Other.vst3'
    & $add 'preflight: a configured bundle missing from the plugin directory is a reason' $true ((& $pre).Reasons -match 'bundle Fixture Bus.vst3 not found')
    # A listing checks only the plugins it lists (-PluginIds): a bundle it was not asked about does not skip it
    $preFor = { param([string[]]$Ids) Get-HarnessPreflight -ReaperExe $pwshExe -PluginDir $plugins -Config $conf -PluginIds $Ids }
    $gainOnly = & $preFor @('gain', 'delay')
    & $add "preflight: -PluginIds checks those plugins only: another plugin's missing bundle is no reason then, and is one when that plugin is asked for ($((& $mine $gainOnly) -join '; '))" $true (
        @(& $mine $gainOnly).Count -eq 0 -and (@($gainOnly.Plugins.get_Keys()) -join ',') -ceq 'gain' -and @((& $preFor @('bus')).Reasons -match '^plugin bus: bundle Fixture Bus\.vst3 not found').Count -eq 1)
    Rename-Item -LiteralPath (Join-Path $plugins 'Other.vst3') -NewName 'Fixture Bus.vst3'
    $marker = Join-Path $Tmp 'MARKER'
    Set-Content -LiteralPath $marker -Value x
    $withMarker = & $pre (Join-Path $Tmp 'no.exe') (Join-Path $Tmp 'none') @((Join-Path $Tmp 'absent'), $marker)
    & $add 'preflight: with a skip marker present that is the only reason (nothing else is even looked at)' $true ($withMarker.Reasons.Count -eq 1 -and $withMarker.Reasons[0] -like 'skip marker present: MARKER *')
    Remove-Item -LiteralPath $marker
    $extPre = @([pscustomobject]@{ Extension = 'demo'; Run = { param($c) 'not today' } }, [pscustomobject]@{ Extension = 'boom'; Run = { throw 'kaput' } })
    $r = (& $pre $pwshExe $plugins @() $extPre).Reasons
    & $add 'preflight: extension checks add reasons with their name; one that throws is a reason too' $true (@($r -match '^extension demo: not today$').Count -eq 1 -and @($r -match '^extension boom: the preflight check threw: kaput$').Count -eq 1)
    # Scan shield, pure part
    & $add 'shield: the cache key keeps letters, digits and dots, everything else becomes _; non-ASCII has no known key' $false ((Get-HarnessCacheKey 'My Plug-in (x64).vst3') -ceq 'My_Plug_in__x64_.vst3' -and $null -eq (Get-HarnessCacheKey 'Plüg.vst3'))
    & $add 'shield: the stamp is the FILETIME as 16 hex digits, little-endian' $false ((ConvertTo-HarnessCacheStamp ([DateTime]::FromFileTimeUtc(0x0102030405060708))) -ceq '0807060504030201')
    $cache = "[vstcache]`r`nOld.vst3=0807060504030201,{x},Old`r`nShell.dll=1111111111111111`r`nShell.dll<1=x`r`nShell.dll<2=y`r`nMine.vst3=AAAA`r`nGone.dll=2222`r`n[other]`r`nOld.vst3=keep`r`n"
    $items = @([pscustomobject]@{ Key = 'Old.vst3'; Stamp = '0807060504030201' }, [pscustomobject]@{ Key = 'Shell.dll'; Stamp = '3333333333333333' }, [pscustomobject]@{ Key = 'New.dll'; Stamp = '4444444444444444' }, [pscustomobject]@{ Key = 'Mine.vst3'; Stamp = '5555555555555555' })
    $u = Update-HarnessScanCacheText -Text $cache -Items $items -Keep @('Mine.vst3')
    & $add 'shield: current entries stay byte for byte; a stale one (with its shell sub-entries) is replaced; a new file gets an empty entry; kept bundles lose theirs; other sections untouched' $false (
        $u.Added -eq 1 -and $u.Replaced -eq 1 -and $u.Removed -eq 1 -and $u.Text -ceq "[vstcache]`r`nShell.dll=3333333333333333`r`nNew.dll=4444444444444444`r`nOld.vst3=0807060504030201,{x},Old`r`nGone.dll=2222`r`n[other]`r`nOld.vst3=keep`r`n")
    & $add 'shield: a second pass over its own output changes nothing' $false ((Update-HarnessScanCacheText -Text $u.Text -Items $items -Keep @('Mine.vst3')).Text -ceq $u.Text)
    & $add 'shield: a cache without a [vstcache] section gets one' $false ((Update-HarnessScanCacheText -Text '' -Items @($items[2])).Text -ceq "[vstcache]`nNew.dll=4444444444444444`n")
    # Plugin path order
    $pv = { param($cur) Get-HarnessPluginPathValue -Current $cur -Private 'P:\cfg\plugins' }
    & $add 'plugin path: the private plugins directory is last, after both system VST3 directories (written even when missing)' $false ((& $pv '') -ceq '%COMMONPROGRAMFILES%\VST3;%LOCALAPPDATA%\Programs\Common\VST3;P:\cfg\plugins')
    & $add 'plugin path: a private directory listed earlier is moved to the end; other entries keep their order; duplicates go' $false ((& $pv 'P:\cfg\plugins\;D:\mine;%COMMONPROGRAMFILES%\VST3;d:\MINE') -ceq 'D:\mine;%COMMONPROGRAMFILES%\VST3;%LOCALAPPDATA%\Programs\Common\VST3;P:\cfg\plugins')
    & $add 'plugin path: applying it twice changes nothing' $false ((& $pv (& $pv 'D:\mine')) -ceq (& $pv 'D:\mine'))
    $cases
}

function Get-LearnCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $configFile = Join-Path $RepoRoot 'tests/fixtures/config.json'
    $conf = Read-HarnessConfig -Path $configFile -Kinds (Import-HarnessExtensions (Read-HarnessConfigExtensions $configFile)).Kinds
    $variants = Get-HarnessLearnVariants -Config $conf -Scenarios @($conf.Scenarios)
    $keys = @($variants | ForEach-Object { $_.Key })
    & $add "learning: one default variant per plugin first, then each distinct parameter set and named state once ($($keys -join ', '))" $false (
        ($keys[0..2] -join ',') -ceq 'gain|,bus|,delay|' -and $keys.Count -eq 10 -and @($keys | Select-Object -Unique).Count -eq 10 -and 'gain@quiet|' -cin $keys -and 'gain@loud|' -cin $keys -and
        @($variants | Where-Object { $_.Key -ceq 'gain@loud|' })[0].State -ceq 'loud' -and 'delay|Delay (samples)=0.0078125' -cin $keys)
    # A state with parameters on top (its own or the plugin's) is learned alone too, before the first variant using it
    $stateFx = { param($p) [pscustomobject]@{ Variant = "gain@quiet|Gain=$p"; Plugin = 'gain'; State = 'quiet'; Params = [ordered]@{ Gain = [pscustomobject]@{ Normalized = $p; Display = $null } } } }
    $pConf = [pscustomobject]@{ Plugins = [ordered]@{ gain = $null }; Layouts = @{ L = [pscustomobject]@{ Tracks = @([pscustomobject]@{ Fx = @((& $stateFx 0.5), (& $stateFx 0.25)) }) } } }
    $pVariants = Get-HarnessLearnVariants -Config $pConf -Scenarios @([pscustomobject]@{ layout = 'L' })
    $pKeys = @($pVariants | ForEach-Object { "$($_.Key)/$($_.Params.get_Count())" })
    & $add "learning: a state used with parameters on top is learned alone once, before its first such variant ($($pKeys -join ', '))" $false (
        ($pKeys -join ',') -ceq 'gain|/0,gain@quiet|/0,gain@quiet|Gain=0.5/1,gain@quiet|Gain=0.25/1' -and $pVariants[1].State -ceq 'quiet')
    $fi = Split-HarnessFxIdent 'C:\x\plugins\A.vst3\Contents\x86_64-win\A.vst3<1234567890{5a1b2c3d4e5f60718293a4b5c6d7e8f9'
    & $add 'fx_ident: path and upper-case class ID (REAPER writes no closing brace); a closing brace or negative uid is fine too; anything else gives nothing' $false (
        $fi.Path -ceq 'C:\x\plugins\A.vst3\Contents\x86_64-win\A.vst3' -and $fi.Cid -ceq '5A1B2C3D4E5F60718293A4B5C6D7E8F9' -and (Split-HarnessFxIdent 'p<-5{5A1B2C3D4E5F60718293A4B5C6D7E8F9}').Path -ceq 'p' -and
        (Split-HarnessFxIdent 'some.dll').Path -eq '' -and (Split-HarnessFxIdent '').Cid -eq '')
    & $add 'parameters: a normalized value within 1e-6 is the same; further off is not; with a display text the text decides' $false (
        $null -eq (Test-HarnessParamValue '0.500000400' '' @{ Normalized = 0.5; Display = $null }) -and (Test-HarnessParamValue '0.500002' '' @{ Normalized = 0.5; Display = $null }) -like 'reads*' -and
        $null -eq (Test-HarnessParamValue '0.3' '0.25' @{ Normalized = 0.25; Display = '0.25' }) -and (Test-HarnessParamValue '0.25' '0.3' @{ Normalized = 0.25; Display = '0.25' }) -like 'shows*' -and
        (Test-HarnessParamValue 'missing' '' @{ Normalized = 0.5; Display = $null }) -eq 'no such parameter')
    $reopen = @{ before_t0_fx0_param1 = '0.5'; after1_t0_fx0_param1 = '0.5'; after2_t0_fx0_param1 = '0.5'; after3_t0_fx0_param1 = '0.5'; before_tracks = '1'; after1_tracks = '1'; after2_tracks = '1'; after3_tracks = '1' }
    & $add 'savereopen: the same values after each of 3 reopens are no problem' $false ((Test-HarnessReopenFacts -Facts $reopen -Cycles 3).Count -eq 0)
    $drifted = $reopen.Clone(); $drifted['after2_t0_fx0_param1'] = '0.6'
    $missing = $reopen.Clone(); $missing.Remove('after3_tracks')
    & $add 'savereopen: a value changed on the second of 3 reopens, or missing after the third, is a problem naming the reopen' $true (
        ((Test-HarnessReopenFacts -Facts $drifted -Cycles 3) -join ';') -ceq "t0_fx0_param1 changed on reopen 2 of 3: '0.5' -> '0.6'" -and
        ((Test-HarnessReopenFacts -Facts $missing -Cycles 3) -join ';') -ceq "tracks changed on reopen 3 of 3: '1' -> ''" -and (Test-HarnessReopenFacts -Facts $drifted -Cycles 1).Count -eq 0)
    # A report as the driver writes it, and a saved project, for two variants
    $installed = @{
        gain = [pscustomobject]@{ Binary = 'P:\plugins\Fixture Gain.vst3\Contents\x86_64-win\Fixture Gain.vst3'; Info = [pscustomobject]@{ Name = 'Fixture Gain'; Vendor = 'Fixture Audio'; Cid = '5A1B2C3D4E5F60718293A4B5C6D7E8F9' } }
        bus  = [pscustomobject]@{ Binary = 'P:\plugins\Fixture Bus.vst3\Contents\x86_64-win\Fixture Bus.vst3'; Info = [pscustomobject]@{ Name = 'Fixture Bus'; Vendor = 'Fixture Audio'; Cid = '0123456789ABCDEF0123456789ABCDEF' } }
    }
    $vs = @([pscustomobject]@{ Key = 'gain|g'; Plugin = 'gain'; State = ''; Params = [ordered]@{ Gain = [pscustomobject]@{ Normalized = 0.5; Display = $null } } }, [pscustomobject]@{ Key = 'bus|'; Plugin = 'bus'; State = ''; Params = [ordered]@{} })
    $report = {
        @{
            fx1_idx = '0'; fx1_name = 'VST3: Fixture Gain (Fixture Audio)'; fx1_offline = 'false'; fx1_ident = "$($installed.gain.Binary)<1{5A1B2C3D4E5F60718293A4B5C6D7E8F9"; fx1_p1 = '0.500000000'; fx1_p1_display = '0.50'
            fx2_idx = '0'; fx2_name = 'VST3: Fixture Bus (Fixture Audio)'; fx2_offline = 'false'; fx2_ident = "$($installed.bus.Binary)<1{0123456789ABCDEF0123456789ABCDEF"
        }
    }
    # The saved learn project: track learn-1 with the gain block (Count copies of it), track learn-2 with the bus block
    $savedOf = {
        param($CidA = '5A1B2C3D4E5F60718293A4B5C6D7E8F9', $Count = 1)
        $vst = { param($name, $c) "      BYPASS 0 0 0`n      <VST `"$name`" x 0 `"`" 1{$c} `"`"`n        S`n      >`n" }
        $track = { param($n, $body) "  <TRACK`n    NAME `"learn-$n`"`n    <FXCHAIN`n$body    >`n  >`n" }
        $gainBlocks = (& $vst 'VST3: Fixture Gain (Fixture Audio)' $CidA) * $Count
        Get-HarnessFxBlocks ("<REAPER_PROJECT`n" + (& $track 1 $gainBlocks) + (& $track 2 (& $vst 'VST3: Fixture Bus (Fixture Audio)' '0123456789ABCDEF0123456789ABCDEF')) + ">`n")
    }
    $same = { param($a, $b) [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase) }
    $check = { param($rep, $saved) Test-HarnessLearnReport -Variants $vs -Installed $installed -Report $rep -Saved $saved -SameFile $same }
    $ok = & $check (& $report) (& $savedOf)
    & $add 'learn report: everything as asked: no failure, nothing foreign, one block per variant' $false ($ok.Fail.Count -eq 0 -and $ok.Foreign.Count -eq 0 -and $ok.Blocks.Count -eq 2 -and $ok.Blocks['gain|g'][0] -like '<VST "VST3: Fixture Gain*')
    $mut = { param([scriptblock]$Edit) $rep = & $report; & $Edit $rep; & $check $rep (& $savedOf) }
    $read = (& $mut { param($r) $r.fx1_pdc = '32'; $r.fx2_pdc = '0' }).Reads
    $gr = $read['gain|g']
    & $add 'learn report: what REAPER read back is kept per variant: its name, latency, each parameter as read and as shown, and the rate and block it was read at' $false (
        $read.Count -eq 2 -and $gr.Name -ceq 'VST3: Fixture Gain (Fixture Audio)' -and $gr.Pdc -ceq '32' -and $gr.Params['Gain'].Read -ceq '0.500000000' -and $gr.Params['Gain'].Display -ceq '0.50' -and
        $gr.Sr -eq 48000 -and $gr.Block -eq 512 -and $read['bus|'].Pdc -ceq '0' -and $read['bus|'].Params.Count -eq 0)
    # The driver reads the latency of each learned plugin once its parameters are set and it had time to settle
    $learnStep = [regex]::Match([IO.File]::ReadAllText((Join-Path $RepoRoot 'lua/driver.lua')), '(?s)
function steps\.learn\(\).*?
end
').Value
    $settle = $learnStep.LastIndexOf('wait(1.0)')
    & $add 'driver: the learn step reads each latency after every parameter is set and the plugins had time to settle' $false (
        $settle -gt $learnStep.IndexOf('"_display"') -and $learnStep.IndexOf('"_pdc"') -gt $settle -and $learnStep.IndexOf('"_pdc"') -lt $learnStep.IndexOf('Main_SaveProjectEx') -and -not $learnStep.Contains('key .. "pdc"'))
    # A parameter listing reads after the save (the saved blocks stay those of a plain learn), an error in it is that
    # entry's and not the step's, and a sweep works on a fresh instance of its own that it removes again
    $driverAll = [IO.File]::ReadAllText((Join-Path $RepoRoot 'lua/driver.lua'))
    $saveAt = $learnStep.IndexOf('Main_SaveProjectEx')
    & $add 'driver: the learn step lists and sweeps only after the save, each call through pcall, an error reported as the entry''s lerror (listing) or serror (sweep)' $true (
        $saveAt -gt 0 -and $learnStep.IndexOf('pcall(listParams, ') -gt $saveAt -and $learnStep.IndexOf('pcall(sweepParams, ') -gt $saveAt -and
        @([regex]::Matches($driverAll, '(?<!function )\b(listParams|sweepParams)\(')).Count -eq 0 -and @([regex]::Matches($learnStep, 'pcall\(listParams, [^\n]*\n\s*if not ok then put\("fx" \.\. n \.\. "_lerror", err\) end')).Count -eq 1 -and
        @([regex]::Matches($learnStep, 'pcall\(sweepParams, [^\n]*\n\s*if not ok then put\("fx" \.\. n \.\. "_serror", err\) end')).Count -eq 1)
    $listBody = [regex]::Match($driverAll, '(?s)\nlocal function listParams\(key, track, idx\)\r?\n.*?\r?\nend\r?\n').Value
    & $add 'driver: a listing only reads (it sets nothing), and reads the count once more after the last parameter' $true (
        $listBody -and $listBody -cnotmatch 'Set\w*\(' -and $listBody -cmatch '(?s)for p = 0, count - 1 do.*\n    end\r?\n    put\(key \.\. "lcount_end", reaper\.TrackFX_GetNumParams\(track, idx\)\)')
    $sweepBody = [regex]::Match($driverAll, '(?s)\nlocal function sweepParams\(key, e\)\r?\n.*?\r?\nend\r?\n').Value
    & $add 'driver: a sweep adds a fresh instance per name (TrackFX_AddByName with -1), reports its name and fx_ident, and deletes its track again' $true (
        $sweepBody -cmatch '(?s)for s, name in ipairs\(e\.sweep\.names\) do.*?InsertTrackAtIndex.*?TrackFX_AddByName\(track, e\.name, false, -1\).*?put\(q \.\. "name", fxName\).*?put\(q \.\. "ident", named\(track, idx, "fx_ident"\)\).*reaper\.DeleteTrack\(track\)\r?\n    end\r?\nend')
    & $add 'learn report: a plugin that could not be added (index -1) is a failure naming it' $true (@((& $mut { param($r) $r.fx2_idx = '-1' }).Fail -match '^bus could not be added').Count -eq 1)
    & $add 'learn report: another plugin matched the name (TrackFX_AddByName is loose) is a failure' $true (@((& $mut { param($r) $r.fx1_name = 'VST3: Fixture Gain Pro (Fixture Audio)' }).Fail -match 'another plugin matched').Count -eq 1)
    & $add 'learn report: an offline FX is a failure' $true (@((& $mut { param($r) $r.fx2_offline = 'true' }).Fail -match 'offline').Count -eq 1)
    $offlineOne = & $mut { param($r) $r.fx2_offline = 'true' }
    $outsideOne = & $mut { param($r) $r.fx1_ident = 'S:\VST3\Fixture Gain.vst3\Contents\x86_64-win\Fixture Gain.vst3<1{5A1B2C3D4E5F60718293A4B5C6D7E8F9' }
    & $add 'learn report: only an entry that failed nothing is taken: not an offline one, nor one loaded from outside the private copy; the clean one next to it is' $true (
        $offlineOne.Blocks.ContainsKey('gain|g') -and -not $offlineOne.Blocks.ContainsKey('bus|') -and -not $offlineOne.Reads.ContainsKey('bus|') -and
        -not $outsideOne.Blocks.ContainsKey('gain|g') -and $outsideOne.Blocks.ContainsKey('bus|'))
    & $add 'learn report: fx_ident naming a binary outside the private directory is foreign (the private copy is not what was tested)' $true (@((& $mut { param($r) $r.fx1_ident = 'S:\VST3\Fixture Gain.vst3\Contents\x86_64-win\Fixture Gain.vst3<1{5A1B2C3D4E5F60718293A4B5C6D7E8F9' }).Foreign).Count -eq 1)
    & $add 'learn report: a class ID in fx_ident other than the one in moduleinfo.json is a failure' $true (@((& $mut { param($r) $r.fx2_ident = "$($installed.bus.Binary)<1{FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" }).Fail -match 'class ID in fx_ident').Count -eq 1)
    & $add 'learn report: a parameter that reads back differently is a failure' $true (@((& $mut { param($r) $r.fx1_p1 = '0.25' }).Fail -match "parameter 'Gain'").Count -eq 1)
    & $add 'learn report: a saved block with another class ID is a failure' $true (@((& $check (& $report) (& $savedOf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')).Fail -match 'saved block has class ID').Count -eq 1)
    & $add 'learn report: two blocks on a learn track is a failure (which one would be the plugin?)' $true (@((& $check (& $report) (& $savedOf '5A1B2C3D4E5F60718293A4B5C6D7E8F9' 2)).Fail -match 'has 2 plugin blocks').Count -eq 1)
    & $add 'learn report: no saved project at all is a failure for every variant' $true ((& $check (& $report) $null).Fail.Count -eq 2)
    # A named state: REAPER loads it from the block on its track; with nothing set on top it must come back as given
    $stBlock = @('<VST "VST3: Fixture Gain (Fixture Audio)" "Fixture Gain.vst3" 0 "" 1234567890{5A1B2C3D4E5F60718293A4B5C6D7E8F9} ""', 'FAKESTATE QUlFRA==', '>')
    $stTable = [ordered]@{ 'gain@quiet' = [pscustomobject]@{ Plugin = 'gain'; State = 'quiet'; Lines = $stBlock; Sha = '0123456789ab' } }
    $sv = @([pscustomobject]@{ Key = 'gain@quiet|'; Plugin = 'gain'; State = 'quiet'; Params = [ordered]@{} })
    $sReport = @{ fx1_idx = '0'; fx1_name = 'VST3: Fixture Gain (Fixture Audio)'; fx1_offline = 'false'; fx1_ident = "$($installed.gain.Binary)<1{5A1B2C3D4E5F60718293A4B5C6D7E8F9" }
    $sSaved = { param([string]$body) Get-HarnessFxBlocks ("<REAPER_PROJECT`n  <TRACK`n    NAME `"learn-1`"`n    <FXCHAIN`n      BYPASS 0 0 0`n      $($stBlock[0])`n        $body`n      >`n    >`n  >`n>`n") }
    $sc = { param($rep, $saved) Test-HarnessLearnReport -Variants $sv -Installed $installed -States $stTable -Report $rep -Saved $saved -SameFile $same }
    $okS = & $sc $sReport (& $sSaved 'FAKESTATE QUlFRA==')
    & $add 'learn report: a named state that comes back as given is learned as a variant of its own' $false ($okS.Fail.Count -eq 0 -and $okS.Blocks.ContainsKey('gain@quiet|'))
    & $add 'learn report: a named state the plugin saves back changed is a failure (it does not hold the state as given)' $true (@((& $sc $sReport (& $sSaved 'FAKESTATE b3RoZXI=')).Fail -match 'saved its state back changed').Count -eq 1)
    $r2 = $sReport.Clone(); $r2.fx1_idx = '-1'
    & $add 'learn report: a named state whose block did not load is a failure saying so' $true (@((& $sc $r2 (& $sSaved 'FAKESTATE QUlFRA==')).Fail -match 'state quiet did not load from its state block').Count -eq 1)
    # The learn project names a template state's track after its template track: the block is looked up there
    $nSaved = Get-HarnessFxBlocks ("<REAPER_PROJECT`n  <TRACK`n    NAME `"Vox 1`"`n    <FXCHAIN`n      BYPASS 0 0 0`n      $($stBlock[0])`n        FAKESTATE QUlFRA==`n      >`n    >`n  >`n>`n")
    $okN = Test-HarnessLearnReport -Variants $sv -Installed $installed -States $stTable -Report $sReport -Saved $nSaved -TrackNames @('Vox 1') -SameFile $same
    & $add 'learn report: the block is taken from the track the learn project named (a template track name)' $false ($okN.Fail.Count -eq 0 -and $okN.Blocks.ContainsKey('gain@quiet|'))
    & $add 'learn report: a block on a track of another name is not taken for the variant' $true (
        @((Test-HarnessLearnReport -Variants $sv -Installed $installed -States $stTable -Report $sReport -Saved $nSaved -SameFile $same).Fail -match 'has 0 plugin blocks on its track').Count -eq 1)
    $tnStates = [ordered]@{
        'input@ch1' = [pscustomobject]@{ Track = 'Vox 1' }; 'input@ch2' = [pscustomobject]@{ Track = 'VOX 1' }; 'input@file' = [pscustomobject]@{ Track = '' }
        'input@q' = [pscustomobject]@{ Track = 'say "hi"' }; 'input@gen' = [pscustomobject]@{ Track = 'Learn-2' }; 'bus@b' = [pscustomobject]@{ Track = 'Bus' }
    }
    $tnV = { param($p, $s) [pscustomobject]@{ Plugin = $p; State = $s } }
    $tn = Get-HarnessLearnTrackNames -Variants @((& $tnV 'input' ''), (& $tnV 'input' 'ch1'), (& $tnV 'input' 'ch2'), (& $tnV 'input' 'file'), (& $tnV 'input' 'q'), (& $tnV 'input' 'gen'), (& $tnV 'bus' 'b'), (& $tnV 'input' 'ch1')) -States $tnStates
    & $add "learn track names: a template state's track is named after its template track, the others learn-<n> ($($tn -join ', '))" $false (
        $tn.Count -eq 8 -and $tn[0] -ceq 'learn-1' -and $tn[1] -ceq 'Vox 1' -and $tn[6] -ceq 'Bus')
    & $add 'learn track names: a name taken already (in any case), a state file, a name with a double quote, one like a generated name and a second variant of the same state get learn-<n>' $true (
        ($tn[2..5] + $tn[7]) -join ',' -ceq 'learn-3,learn-4,learn-5,learn-6,learn-8')
    # The same state alone and with a parameter on top (the variants above): a plugin that ignores the state is caught
    # on the track that has it alone, although the parameter reads back fine
    $pReport = $sReport.Clone()
    foreach ($k in 'idx', 'name', 'offline', 'ident') { $pReport["fx2_$k"] = $sReport["fx1_$k"] }
    $pReport.fx2_p1 = '0.500000000'; $pReport.fx2_p1_display = '0.50'
    $pSaved = {
        param([string]$body)
        $t = { param($n) "  <TRACK`n    NAME `"learn-$n`"`n    <FXCHAIN`n      BYPASS 0 0 0`n      $($stBlock[0])`n        $body`n      >`n    >`n  >`n" }
        Get-HarnessFxBlocks ("<REAPER_PROJECT`n" + (& $t 1) + (& $t 2) + ">`n")
    }
    $pc = { param($saved) Test-HarnessLearnReport -Variants $pVariants[1..2] -Installed $installed -States $stTable -Report $pReport -Saved $saved -SameFile $same }
    $okP = & $pc (& $pSaved 'FAKESTATE QUlFRA==')
    & $add 'learn report: a state the plugin holds is learned alone and with the parameter on top' $false ($okP.Fail.Count -eq 0 -and $okP.Blocks.ContainsKey('gain@quiet|') -and $okP.Blocks.ContainsKey('gain@quiet|Gain=0.5'))
    & $add 'learn report: a plugin that ignores a state used with parameters on top fails on the state learned alone' $true (
        ((& $pc (& $pSaved 'FAKESTATE b3RoZXI=')).Fail -join ';') -ceq 'gain state quiet : the plugin saved its state back changed, so it does not hold the state as given')
    # The JSFX shipped with the tool: checked by the name REAPER shows and its path under Effects
    $jsfx = @{ delay = [pscustomobject]@{ Name = 'JS: reaper-harness PDC delay'; AddName = 'JS:reaper-harness/harness-pdc-delay.jsfx'; Ident = 'reaper-harness/harness-pdc-delay.jsfx' } }
    $jv = @([pscustomobject]@{ Key = 'delay|'; Plugin = 'delay'; State = ''; Params = [ordered]@{} })
    $jReport = @{ fx1_idx = '0'; fx1_name = 'JS: reaper-harness PDC delay'; fx1_offline = 'false'; fx1_ident = 'reaper-harness/harness-pdc-delay.jsfx' }
    $jSaved = { param([string]$Header = '<JS reaper-harness/harness-pdc-delay.jsfx ""') Get-HarnessFxBlocks ("<REAPER_PROJECT`n  <TRACK`n    NAME `"learn-1`"`n    <FXCHAIN`n      BYPASS 0 0 0`n      $Header`n        0 1 - -`n      >`n    >`n  >`n>`n") }
    $jc = { param($rep, $saved) Test-HarnessLearnReport -Variants $jv -Installed $installed -Jsfx $jsfx -Report $rep -Saved $saved -SameFile $same }
    $okJ = & $jc $jReport (& $jSaved)
    & $add 'learn report: the JSFX is learned by the name REAPER shows and its path; it is added as JS:<path>' $false (
        $okJ.Fail.Count -eq 0 -and $okJ.Blocks['delay|'][0] -like '<JS reaper-harness/*' -and $okJ.AddNames['delay'] -ceq 'JS:reaper-harness/harness-pdc-delay.jsfx' -and $okJ.Names['delay'] -ceq 'JS: reaper-harness PDC delay')
    $r3 = $jReport.Clone(); $r3.fx1_ident = 'other/harness-pdc-delay.jsfx'
    & $add 'learn report: a JSFX of that name from another path is a failure' $true (@((& $jc $r3 (& $jSaved)).Fail -match "has fx_ident 'other/").Count -eq 1)
    & $add 'learn report: a saved JS block of another effect is a failure' $true (@((& $jc $jReport (& $jSaved '<JS other/harness-pdc-delay.jsfx ""')).Fail -match 'not the JS block').Count -eq 1)
    # The state proof: what REAPER saves back with the project open, against the blocks it was given
    $spLayout = $conf.Layouts['states']
    $spBlocks = @{ 'gain@quiet|' = @('<VST "q"', 'Q', '>'); 'gain@loud|' = @('<VST "l"', 'L', '>') }
    $spStates = [ordered]@{ 'gain@quiet' = [pscustomobject]@{ Sha = 'aaaaaaaaaaaa' }; 'gain@loud' = [pscustomobject]@{ Sha = 'bbbbbbbbbbbb' } }
    $spSaved = {
        param($q = 'Q', $l = 'L')
        $one = { param($name, $rename, $body) "  <TRACK`n    NAME `"$name`"`n    <FXCHAIN`n      BYPASS 0 0 0`n      <VST `"VST3: x`" x 0 `"$rename`" 1{0123456789ABCDEF0123456789ABCDEF} `"`"`n        $body`n      >`n    >`n  >`n" }
        Get-HarnessFxBlocks ("<REAPER_PROJECT`n" + (& $one 'Quiet' 'renamed' $q) + (& $one 'Loud' '' $l) + ">`n")
    }
    $sp = Test-HarnessStateProof -Layout $spLayout -Blocks $spBlocks -States $spStates -Saved (& $spSaved)
    & $add 'state proof: blocks saved back as loaded (the header line aside) prove both states, named with their hashes' $false ($sp.Problems.Count -eq 0 -and ($sp.Proven -join ',') -ceq 'gain quiet aaaaaaaaaaaa,gain loud bbbbbbbbbbbb')
    & $add 'state proof: a block saved back changed is a problem naming the track' $true (@((Test-HarnessStateProof -Layout $spLayout -Blocks $spBlocks -States $spStates -Saved (& $spSaved 'Q' 'X')).Problems -match "^track 'Loud' FX 1 .*differs").Count -eq 1)
    # The same through the extension API, from the text of the saved project
    $api = Get-HarnessApi
    $one = { param($name, $body) "  <TRACK`n    NAME `"$name`"`n    <FXCHAIN`n      BYPASS 0 0 0`n      <VST `"VST3: x`" x 0 `"`" 1{0123456789ABCDEF0123456789ABCDEF} `"`"`n        $body`n      >`n    >`n  >`n" }
    $apiProof = & $api.StateProof -Layout $spLayout -Blocks $spBlocks -States $spStates -Saved (& $api.FxBlocks ("<REAPER_PROJECT`n" + (& $one 'Quiet' 'Q') + (& $one 'Loud' 'L') + ">`n"))
    & $add 'extension API: StateProof over FxBlocks of a saved project text proves the states as device does' $false ($apiProof.Problems.Count -eq 0 -and ($apiProof.Proven -join ',') -ceq 'gain quiet aaaaaaaaaaaa,gain loud bbbbbbbbbbbb')
    & $add 'state proof: state FX missing from the saved project are problems' $true (@((Test-HarnessStateProof -Layout $spLayout -Blocks $spBlocks -States $spStates -Saved (Get-HarnessFxBlocks "<REAPER_PROJECT`n>`n")).Problems -match 'not in the saved project').Count -eq 2)
    $cases
}

# ---------------------------------------------------------------- parameter variants and learning in batches
function Get-VariantCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $configFile = Join-Path $RepoRoot 'tests/fixtures/config.json'
    $kinds = (Import-HarnessExtensions (Read-HarnessConfigExtensions $configFile)).Kinds
    $text = [IO.File]::ReadAllText($configFile)
    $scenario = { param($raw, $id) @($raw['scenarios'] | Where-Object { $_['id'] -eq $id })[0] }
    # The fixture with a change: the result of Test-HarnessConfigData (Problems, Config)
    $with = { param([scriptblock]$Edit) $raw = ConvertFrom-HarnessJson $text; & $Edit $raw; Test-HarnessConfigData -Raw $raw -Kinds $kinds }
    $v = { param([string]$VariantId, $FxSet = $null, $Bypass = $null) $o = [ordered]@{ id = $VariantId }; if ($null -ne $FxSet) { $o['fx'] = $FxSet }; if ($null -ne $Bypass) { $o['bypass'] = $Bypass }; $o }
    $gainP = { param($p) [ordered]@{ gain = [ordered]@{ params = $p } } }
    $renderOnly = { param($s) foreach ($k in 'maxDiffDb', 'notSilent', 'peakMaxDb') { $s.Remove($k) }; $s['compare'] = 'none' }
    $byId = { param($r, [string]$ScenarioId) $r.Config ? ($r.Config.Scenarios | Where-Object { $_.id -ceq $ScenarioId } | Select-Object -First 1) : $null }
    # The keys a scenario needs, joined (the function returns its list as one object)
    $needs = { param($OfConfig, $OfScenario) $k = Get-HarnessScenarioLearnKeys -Config $OfConfig -Scenario $OfScenario; @($k | ForEach-Object { $_.Key }) -join ',' }
    $keysOf = { param($l) @($l.Tracks | ForEach-Object { $_.Fx } | ForEach-Object { $_.Variant }) -join ' ; ' }
    # The learn entries of scenarios; a throw is an entry naming it, so the cases below fail by name, not the whole group
    $learnOf = {
        param($OfConfig, [object[]]$ScenarioList)
        try { Get-HarnessLearnVariants -Config $OfConfig -Scenarios $ScenarioList }
        catch { , @([pscustomobject]@{ Key = "threw: $($_.Exception.Message)"; Plugin = ''; State = ''; Params = [ordered]@{}; For = '' }) }
    }
    # [For] of each entry with that key ('' when there is none)
    $forOf = { param([object[]]$Entries, [string]$WantKey) @($Entries | Where-Object { $_.Key -ceq $WantKey } | ForEach-Object { "[$($_.For)]" }) -join ',' }

    # Expansion: <id>[-<matrix suffix>]-<variant id>, legs of the matrix outside, the variants inside, in the order written
    $m = & $with { param($c) $s = & $scenario $c 'chain'; $s['compare'] = 'none'; $s['variants'] = @((& $v 'dry' $null $true), (& $v 'as-written'), (& $v 't025' (& $gainP ([ordered]@{ Trim = 0.25 })))) }
    $chainIds = @($m.Config ? @($m.Config.Scenarios | Where-Object { $_.baseId -ceq 'chain' } | ForEach-Object { $_.id }) : @())
    & $add "variants: a matrix of four legs and three variants give twelve scenarios, the legs outside, the variants inside, each knowing its variant and the id as written ($($chainIds -join ', '))" $false (
        @($m.Problems).Count -eq 0 -and $chainIds.Count -eq 12 -and ($chainIds[0..3] -join ',') -ceq 'chain-offline-44100-dry,chain-offline-44100-as-written,chain-offline-44100-t025,chain-offline-48000-dry' -and
        $chainIds[11] -ceq 'chain-1x-48000-t025' -and @($m.Config.Scenarios | Where-Object { $_.baseId -ceq 'chain' -and ($_.layout -cne 'chain' -or -not $_.variant) }).Count -eq 0 -and
        (& $byId $m 'chain-1x-44100-t025').variant -ceq 't025' -and (& $byId $m 'chain-1x-44100-t025').mode -ceq '1x' -and (& $byId $m 'chain-1x-44100-t025').sr -eq 44100)
    $one = & $with { param($c) $s = & $scenario $c 'bus'; & $renderOnly $s; $s['variants'] = @((& $v 'a'), (& $v 'b' $null @('bus'))) }
    & $add 'variants: without a matrix the ids are <id>-<variant id>; a scenario without variants has none and keeps its id' $false (
        @($one.Problems).Count -eq 0 -and (& $byId $one 'bus-a').baseId -ceq 'bus' -and (& $byId $one 'bus-b').variant -ceq 'b' -and $null -eq (& $byId $one 'bus') -and
        $null -eq (& $byId $one 'routing').variant -and $null -eq (& $byId $one 'routing').variantLayout -and $null -ne (& $byId $one 'bus-a').variantLayout)
    # The overlay: plugin < layout FX < variant, a state replaces the FX's, every instance of the plugin, nothing else
    $o = & $with {
        param($c)
        $s = & $scenario $c 'bus'; & $renderOnly $s
        $s['variants'] = @((& $v 'trim' (& $gainP ([ordered]@{ Trim = 0.75 }))), (& $v 'gain' (& $gainP ([ordered]@{ Gain = 0.125 }))), (& $v 'loud' ([ordered]@{ gain = [ordered]@{ state = 'loud' } })), (& $v 'trim-again' (& $gainP ([ordered]@{ Trim = 0.75 }))))
        $c['scenarios'] += [ordered]@{ id = 'pdc-vary'; kind = 'render'; layout = 'pdc'; compare = 'none'; variants = @((& $v 'report-off' ([ordered]@{ delay = [ordered]@{ params = [ordered]@{ 'Report delay as PDC' = 0 } } })), (& $v 'longer' ([ordered]@{ delay = [ordered]@{ params = [ordered]@{ 'Delay (samples)' = 0.015625 } } }))) }
    }
    $busLayout = $o.Config ? $o.Config.Layouts['bus'] : $null
    $trim = (& $byId $o 'bus-trim').variantLayout
    & $add "variants: a variant's parameters go on top of the FX's own, on every FX of that plugin; the other plugins and the layout itself are left as they were ($(& $keysOf $trim))" $false (
        @($o.Problems).Count -eq 0 -and (& $keysOf $trim) -ceq 'bus| ; gain|Trim=0.75 ; gain|Gain=0.25;Trim=0.75' -and $trim.Tracks[1].Fx[0].Params['Trim'].Normalized -eq 0.75 -and
        $trim.Tracks[2].Fx[0].Params['Gain'].Display -ceq '0.25' -and [object]::ReferenceEquals($trim.Tracks[0].Fx[0], $busLayout.Tracks[0].Fx[0]) -and
        (& $keysOf $busLayout) -ceq 'bus| ; gain| ; gain|Gain=0.25' -and -not $busLayout.Tracks[1].Fx[0].Params.Contains('Trim'))
    & $add 'variants: a parameter the FX has is replaced by the variant, its state by the variant state; the key is that of the new setting' $false (
        (& $keysOf (& $byId $o 'bus-gain').variantLayout) -ceq 'bus| ; gain|Gain=0.125 ; gain|Gain=0.125' -and (& $keysOf (& $byId $o 'bus-loud').variantLayout) -ceq 'bus| ; gain@loud| ; gain@loud|Gain=0.25' -and
        (& $byId $o 'bus-loud').variantLayout.Tracks[1].Fx[0].State -ceq 'loud')
    $pdcVary = & $byId $o 'pdc-vary-longer'
    $offVary = & $byId $o 'pdc-vary-report-off'
    & $add 'variants: the plugin''s own parameters stay under the FX''s and the variant''s (a JSFX with a parameter set by its plugin)' $false (
        $pdcVary.variantLayout.Tracks[0].Fx[0].Params['Delay (samples)'].Normalized -eq 0.015625 -and $offVary.variantLayout.Tracks[0].Fx[0].Params['Delay (samples)'].Normalized -eq 0.0078125 -and
        $offVary.variantLayout.Tracks[0].Fx[0].Params['Report delay as PDC'].Normalized -eq 0 -and $offVary.variantLayout.Tracks[0].Fx[1].Variant -ceq 'gain|')
    $differ = @(for ($t = 0; $t -lt $busLayout.Tracks.Count; $t++) {
            foreach ($pn in @($busLayout.Tracks[$t].PSObject.Properties.Name | Where-Object { $_ -cne 'Fx' })) { if (-not [object]::Equals($busLayout.Tracks[$t].$pn, $trim.Tracks[$t].$pn)) { "$t.$pn" } }
        })
    & $add "variants: every property of a track but its FX is that of the layout ($($differ -join ', '))" $false ($differ.Count -eq 0 -and $trim.Tracks.Count -eq 3 -and $trim.Id -ceq 'bus')
    $learned = & $learnOf $o.Config @($o.Config.Scenarios | Where-Object { $_.baseId -ceq 'bus' })
    & $add 'variants: two variants asking the same setting share one learned entry, first used by the first' $false (
        (& $forOf $learned 'gain|Trim=0.75') -ceq '[bus-trim]' -and (& $forOf $learned 'gain@loud|') -ceq '[bus-loud]' -and (& $forOf $learned 'gain|') -ceq '[]')
    # A file source and an FX of its own bypass flag stay as they are under a variant
    $fb = & $with {
        param($c)
        $c['layouts']['chain']['tracks'][0]['file'] = 'sources/voice.wav'; $c['layouts']['chain']['tracks'][0]['fx'][1]['bypass'] = $true
        $s = & $scenario $c 'chain-repeat'; $s['compare'] = 'none'; $s['bypass'] = @('gain'); $s['variants'] = @((& $v 'b' ([ordered]@{ bus = [ordered]@{ params = [ordered]@{ Trim = 0.5 } } }) @('bus', 'gain')), (& $v 'all' $null $true))
    }
    $fbV = (& $byId $fb 'chain-repeat-b')
    & $add 'variants: a file source keeps its file and an FX bypassed in the layout stays bypassed when a variant sets it' $false (
        @($fb.Problems).Count -eq 0 -and $fbV.variantLayout.Tracks[0].File -ceq 'sources/voice.wav' -and $fbV.variantLayout.Tracks[0].Fx[1].Bypass -eq $true -and $fbV.variantLayout.Tracks[0].Fx[1].Variant -ceq 'bus|Trim=0.5')
    & $add "variants: the bypass of a variant adds to the scenario's, each plugin once (also one in both lists); true (every FX) wins ($($fbV.bypass -join ','))" $false (
        ($fbV.bypass -join ',') -ceq 'gain,bus' -and ((& $byId $fb 'chain-repeat-all').bypass -join ',') -ceq '*')
    $blocks = @{ 'gain|Gain=0.5' = @('<VST "g"', 'G', '>'); 'bus|Trim=0.5' = @('<VST "b"', 'B', '>'); 'bus|' = @('<VST "b0"', 'B0', '>') }
    $rppB = New-HarnessProjectText -Layout $fbV.variantLayout -Blocks $blocks -SourceWav 'S.wav' -Sources @{ Voice = 'V.wav' } -RenderDir 'D' -RenderName 'N' -Bypass @()
    $fbFacts = @((Get-HarnessFxFacts @{ Installed = @{}; Jsfx = @{}; LearnReads = @{}; States = @{}; Blocks = @{} } $fbV.variantLayout @()) | Where-Object { $_.track -ceq $fbV.variantLayout.Tracks[0].Name } | ForEach-Object { "$($_.plugin)=$($_.bypass)" }) -join ','
    & $add "variants: an FX bypassed in the layout and set by a variant is written BYPASS 1 with the block of the variant, and its manifest line says bypass true ($fbFacts)" $false (
        $rppB -cmatch '(?s)BYPASS 0 0 0\n      <VST "g".*BYPASS 1 0 0\n      <VST "b"\n' -and $fbFacts -ceq 'gain=False,bus=True')
    # A compare variant without a layout of its own renders the same variant layout and, without its own bypass, the
    # scenario's after expansion; with its own of either it keeps that
    $cv = & $with {
        param($c)
        $s = & $scenario $c 'chain-block'; $s['variants'] = @((& $v 'dry' $null $true), (& $v 't' (& $gainP ([ordered]@{ Trim = 0.25 }))))
        $c['scenarios'] += [ordered]@{ id = 'cmp-own'; kind = 'render'; layout = 'chain'; compare = [ordered]@{ block = 256; bypass = @('bus') }; variants = @((& $v 'dry' $null $true)) }
        $c['scenarios'] += [ordered]@{ id = 'cmp-other'; kind = 'render'; layout = 'chain'; compare = [ordered]@{ layout = 'bus' }; variants = @((& $v 't' (& $gainP ([ordered]@{ Trim = 0.25 }))), (& $v 'dry' $null $true)) }
    }
    $cDry = & $byId $cv 'chain-block-dry'; $cT = & $byId $cv 'chain-block-t'
    & $add 'variants: a compare variant without layout and bypass of its own compares the variant layout with the bypass of the variant' $false (
        @($cv.Problems).Count -eq 0 -and $cDry.compare.SameLayout -and ($cDry.compare.Bypass -join ',') -ceq '*' -and $cDry.compare.Block -eq 1024 -and ($cT.compare.Bypass -join ',') -ceq '' -and
        (& $needs $cv.Config $cT) -ceq 'gain|Gain=0.5;Trim=0.25,bus|')
    & $add 'variants: a compare variant with a bypass or a layout of its own keeps it, and its layout is learned as written' $false (
        ((& $byId $cv 'cmp-own-dry').compare.Bypass -join ',') -ceq 'bus' -and (& $byId $cv 'cmp-own-dry').compare.OwnBypass -and -not (& $byId $cv 'cmp-other-t').compare.SameLayout -and
        (& $needs $cv.Config (& $byId $cv 'cmp-other-t')) -ceq 'gain|Gain=0.5;Trim=0.25,bus|,gain|,gain|Gain=0.25')
    $otherDry = & $byId $cv 'cmp-other-dry'
    & $add "variants: a compare variant with a layout of its own keeps the scenario's bypass as written, also under a variant that bypasses every FX ($($otherDry ? ($otherDry.compare.Bypass -join ',') : 'none'))" $true (
        $null -ne $otherDry -and ($otherDry.bypass -join ',') -ceq '*' -and ($otherDry.compare.Bypass -join ',') -ceq '' -and -not $otherDry.compare.SameLayout)
    # Checked once per item, before the matrix: one problem, not one per leg; a layout that is not there is its own problem only
    $twice = & $with { param($c) $s = & $scenario $c 'chain'; $s['compare'] = 'none'; $s['variants'] = @((& $v 'a'), (& $v 'a')) }
    & $add "variants: a variant id used twice in a scenario of four legs is one problem in all, the second is not expanded ($(@($twice.Problems) -join ' | '))" $true (
        @($twice.Problems).Count -eq 1 -and @($twice.Problems)[0] -like "*variant id 'a' is used twice*")
    $noLayout = try { & $with { param($c) $s = & $scenario $c 'bus'; $s['layout'] = 'nowhere'; & $renderOnly $s; $s['variants'] = @((& $v 'a' (& $gainP ([ordered]@{ Trim = 0.25 })))) } } catch { "threw: $($_.Exception.Message)" }
    & $add "variants: of a scenario whose layout is not defined only that is said, nothing throws ($(($noLayout -is [string]) ? $noLayout : (@($noLayout.Problems) -join ' | ')))" $true (
        $noLayout -isnot [string] -and @($noLayout.Problems).Count -eq 1 -and @($noLayout.Problems)[0] -like "*layout 'nowhere' is not defined in layouts*")
    # The tool's own dry layout is no layout of the configuration: a scenario with variants cannot name it, so its
    # variants are never dropped without a word
    $dryLayout = try { & $with { param($c) $s = & $scenario $c 'bus'; $s['layout'] = '@dry'; & $renderOnly $s; $s['variants'] = @((& $v 'a')) } } catch { "threw: $($_.Exception.Message)" }
    & $add "variants: a scenario with variants that names the tool's own dry layout is a usage error, nothing throws ($(($dryLayout -is [string]) ? $dryLayout : (@($dryLayout.Problems) -join ' | ')))" $true (
        $dryLayout -isnot [string] -and @($dryLayout.Problems).Count -ge 1 -and @($dryLayout.Problems | Where-Object { $_ -clike '*@dry*' }).Count -eq @($dryLayout.Problems).Count)
    # The displays of one learned setting: merged when one side gives none, refused when two differ (in any order, over
    # the layouts and the variant layouts)
    $dWithout = & $with { param($c) $c['layouts']['chain']['tracks'][0]['fx'][0]['params']['Gain'] = 0.25 } # chain (no display) is used before bus (0.25)
    $dWith = & $with { param($c) $c['layouts']['routing']['tracks'][2]['fx'][0]['params'] = [ordered]@{ Gain = 0.25 } } # bus (0.25) before routing (none)
    $entryOf = { param($r, $WantKey) @((Get-HarnessLearnVariants -Config $r.Config -Scenarios @($r.Config.Scenarios)) | Where-Object { $_.Key -ceq $WantKey })[0] }
    & $add 'displays: a display text one use of a setting gives and another leaves out is learned and checked, whichever comes first; the layouts are not changed' $false (
        @($dWithout.Problems).Count -eq 0 -and @($dWith.Problems).Count -eq 0 -and (& $entryOf $dWithout 'gain|Gain=0.25').Params['Gain'].Display -ceq '0.25' -and
        (& $entryOf $dWithout 'gain|Gain=0.25').For -ceq 'chain-offline-44100' -and (& $entryOf $dWith 'gain|Gain=0.25').Params['Gain'].Display -ceq '0.25' -and
        $null -eq $dWithout.Config.Layouts['chain'].Tracks[0].Fx[0].Params['Gain'].Display)
    # The same over the variants of scenarios, in either order
    $dvMerge = & $with {
        param($c)
        $s = & $scenario $c 'bus'; & $renderOnly $s
        $s['variants'] = @((& $v 'plain' (& $gainP ([ordered]@{ Gain = 0.4 }))), (& $v 'shown' (& $gainP ([ordered]@{ Gain = [ordered]@{ normalized = 0.4; display = '0.40' } }))))
        $c['scenarios'] += [ordered]@{ id = 'bus-again'; kind = 'render'; layout = 'bus'; compare = 'none'; variants = @((& $v 'shown' (& $gainP ([ordered]@{ Gain = [ordered]@{ normalized = 0.6; display = '0.60' } }))), (& $v 'plain' (& $gainP ([ordered]@{ Gain = 0.6 })))) }
    }
    $mergedOf = { param([string]$WantKey) @((& $learnOf $dvMerge.Config @($dvMerge.Config.Scenarios)) | Where-Object { $_.Key -ceq $WantKey } | ForEach-Object { "$($_.For)=$($_.Params['Gain'].Display)" }) -join ',' }
    & $add "displays: the same over the variants of scenarios, the variant without a display first or second; the variant layouts are not changed ($(& $mergedOf 'gain|Gain=0.4'); $(& $mergedOf 'gain|Gain=0.6'))" $false (
        @($dvMerge.Problems).Count -eq 0 -and (& $mergedOf 'gain|Gain=0.4') -ceq 'bus-plain=0.40' -and (& $mergedOf 'gain|Gain=0.6') -ceq 'bus-again-shown=0.60' -and
        $null -eq (& $byId $dvMerge 'bus-plain').variantLayout.Tracks[1].Fx[0].Params['Gain'].Display -and $null -eq (& $byId $dvMerge 'bus-again-plain').variantLayout.Tracks[1].Fx[0].Params['Gain'].Display)
    $dTwoLayouts = & $with { param($c) $c['layouts']['chain']['tracks'][0]['fx'][0]['params']['Gain'] = [ordered]@{ normalized = 0.25; display = '0.3' } }
    $dTwoLater = & $with { param($c) $c['layouts']['routing']['tracks'][2]['fx'][0]['params'] = [ordered]@{ Gain = [ordered]@{ normalized = 0.25; display = '0.3' } } }
    $dVariants = & $with { param($c) $c['scenarios'] += [ordered]@{ id = 'dv'; kind = 'render'; layout = 'states'; compare = 'none' }; $c['scenarios'][-1]['variants'] = @((& $v 'x' (& $gainP ([ordered]@{ Gain = [ordered]@{ normalized = 0.4; display = 'x' } }))), (& $v 'y' (& $gainP ([ordered]@{ Gain = [ordered]@{ normalized = 0.4; display = 'y' } })))) }
    $dLayoutVariant = & $with { param($c) $s = & $scenario $c 'bus'; & $renderOnly $s; $s['variants'] = @((& $v 'x' (& $gainP ([ordered]@{ Gain = [ordered]@{ normalized = 0.25; display = '0.3' } })))) }
    $both = { param($r) @($r.Problems | Where-Object { $_ -like "*parameter 'Gain' at * is asked to show both *" }) }
    & $add "displays: one setting asked to show two texts is a usage error, over two layouts in either order, over two variants (once per setting: two states), over a layout and a variant ($(@(& $both $dVariants) -join ' | '))" $true (
        @(& $both $dTwoLayouts).Count -eq 1 -and @(& $both $dTwoLater).Count -eq 1 -and @(& $both $dVariants).Count -eq 2 -and @(& $both $dLayoutVariant).Count -eq 1 -and
        @(& $both $dTwoLayouts)[0] -clike "plugin 'gain' parameter 'Gain' at 0.25 is asked to show both '0.3' and '0.25'*")

    # Batches of learning
    $e = { param([string]$EntryKey, [string]$For) [pscustomobject]@{ Key = $EntryKey; Plugin = 'p'; State = ''; Params = [ordered]@{}; For = $For } }
    $entryList = @((& $e 'a|' ''), (& $e 'b|' ''), (& $e 'c|' ''), (& $e 'x1' 's1'), (& $e 'x2' 's1'), (& $e 'y1' 's2'), (& $e 'y2' 's2'), (& $e 'z1' 's3'), (& $e 'z2' 's3'), (& $e 'z3' 's3'), (& $e 'z4' 's3'), (& $e 'z5' 's3'), (& $e 'w1' 's4'))
    $plan = { param($Size) $launches = Get-HarnessLearnBatches -Variants $entryList -Size $Size; @($launches | ForEach-Object { "$($_.No):" + (@($_.Entries | ForEach-Object { $_.Key }) -join ',') }) -join ' ' }
    $p4 = & $plan 4
    & $add "learn batches: the defaults first and together, then groups of one first use, whole where they fit; a group larger than the size cut in order ($p4)" $false (
        $p4 -ceq '1:a|,b|,c| 2:x1,x2,y1,y2 3:z1,z2,z3,z4 4:z5,w1')
    $p2 = & $plan 2
    $p1 = & $plan 1
    & $add "learn batches: more defaults than the size stay in the first launch; size 1 gives a launch per entry ($p2 / $p1)" $false (
        $p2 -ceq '1:a|,b|,c| 2:x1,x2 3:y1,y2 4:z1,z2 5:z3,z4 6:z5,w1' -and $p1 -ceq '1:a|,b|,c| 2:x1 3:x2 4:y1 5:y2 6:z1 7:z2 8:z3 9:z4 10:z5 11:w1')
    $launches3 = Get-HarnessLearnBatches -Variants $entryList -Size 3
    $flat = @($launches3 | ForEach-Object { $_.Entries } | ForEach-Object { $_.Key })
    & $add 'learn batches: no entry lost, none twice, the order kept' $false (($flat -join ',') -ceq (@($entryList | ForEach-Object { $_.Key }) -join ','))
    & $add 'learn batches: the row of a batch is learn with one batch, learn.<k> with several' $false ((Get-HarnessLearnRowId 1 1) -ceq 'learn' -and (Get-HarnessLearnRowId 2 3) -ceq 'learn.2')
    # One walk: every variant a scenario needs is in exactly one batch, over the fixture and configurations with variants
    $leaks = @(foreach ($r in @($m, $o, $fb, $cv, $dWithout)) {
            $needing = @($r.Config.Scenarios) + @($r.Config.Negative)
            $planned = Get-HarnessLearnBatches -Variants (& $learnOf $r.Config $needing) -Size 2
            foreach ($s in $needing) {
                foreach ($k in @((& $needs $r.Config $s) -split ',' | Where-Object { $_ })) {
                    $in = @($planned | Where-Object { @($_.Entries | Where-Object { $_.Key -ceq $k }).Count })
                    if ($in.Count -ne 1) { "$($s.id): $k in $($in.Count)" }
                }
            }
        })
    & $add "learn batches: every variant each scenario needs is in exactly one batch ($($leaks -join ', '))" $false ($leaks.Count -eq 0)
    # What each kind needs
    $fixture = Read-HarnessConfig -Path $configFile -Kinds $kinds
    $needOf = { param([string]$ScenarioId) & $needs $fixture @(@($fixture.Scenarios) + @($fixture.Negative) + @(Get-HarnessBuiltinNegatives -Transport) | Where-Object { $_.id -ceq $ScenarioId })[0] }
    & $add "learning needs: a render its layout and the layout it compares with, a device and a transport their layout, instances the defaults of its plugins, an extension its layout, a built-in negative nothing ($(& $needOf 'neg-bus-is-not-chain'))" $false (
        (& $needOf 'neg-bus-is-not-chain') -ceq 'bus|,gain|,gain|Gain=0.25,gain|Gain=0.5' -and (& $needOf 'bus-device') -ceq 'bus|,gain|,gain|Gain=0.25' -and (& $needOf 'monitor-states') -ceq 'gain|Gain=0.5,bus|' -and
        (& $needOf 'instances') -ceq ((@($fixture.Scenarios | Where-Object { $_.id -ceq 'instances' })[0].plugins | ForEach-Object { "$_|" }) -join ',') -and (& $needOf 'neg-offset-1-sample') -ceq '' -and
        (& $needOf 'states-device') -ceq 'gain@quiet|,gain@loud|')
    # Why a scenario does not run
    $twoStates = & $with { param($c) $c['layouts']['chain']['tracks'][0]['fx'][0]['state'] = 'quiet'; $c['layouts']['bus']['tracks'][2]['fx'][0]['state'] = 'quiet' }
    $gapCtx = { param($r, [string[]]$Have, [hashtable]$BatchOf, [int]$Count) $bl = @{}; foreach ($k in $Have) { $bl[$k] = @('x') }; @{ Config = $r.Config; Blocks = $bl; LearnBatchOf = $BatchOf; LearnBatchCount = $Count } }
    $sOf = { param($r, $ScenarioId) @(@($r.Config.Scenarios) + @($r.Config.Negative) | Where-Object { $_.id -ceq $ScenarioId })[0] }
    $planned = @{ 'gain@quiet|' = 2; 'gain@quiet|Gain=0.5' = 2; 'bus|' = 1; 'gain@quiet|Gain=0.25' = 3; 'gain|' = 1 }
    $noAlone = & $gapCtx $twoStates @('gain@quiet|Gain=0.5', 'bus|', 'gain@quiet|Gain=0.25', 'gain|') $planned 3
    $gaps = @('chain-repeat', 'bus', 'neg-bus-is-not-chain', 'bus-device' | ForEach-Object { Get-HarnessLearnGap -Context $noAlone -Scenario (& $sOf $twoStates $_) })
    & $add "learning gaps: a state learned alone that failed keeps every scenario using it with parameters on top from running, in either layout ($($gaps -join ' | '))" $true (
        @($gaps | Where-Object { $_ -cne 'not run: learning the plugin blocks it needs did not succeed (see the learn.2 row)' }).Count -eq 0)
    $all = & $gapCtx $twoStates @('gain@quiet|', 'gain@quiet|Gain=0.5', 'bus|', 'gain@quiet|Gain=0.25', 'gain|') $planned 3
    & $add 'learning gaps: a scenario all of whose variants were learned runs; a built-in negative case needs nothing' $false (
        (Get-HarnessLearnGap -Context $all -Scenario (& $sOf $twoStates 'bus-device')) -ceq '' -and (Get-HarnessLearnGap -Context $noAlone -Scenario @(Get-HarnessBuiltinNegatives)[0] -Halt 'not run: x') -ceq '')
    & $add 'learning gaps: a variant no batch was planned for is named; a halt is the reason for every scenario that needs learning' $true (
        (Get-HarnessLearnGap -Context (& $gapCtx $twoStates @() @{} 1) -Scenario (& $sOf $twoStates 'bus-device')) -ceq 'not run: learning did not cover bus as this scenario uses it' -and
        (Get-HarnessLearnGap -Context $all -Scenario (& $sOf $twoStates 'bus-device') -Halt 'not run: learning saw x') -ceq 'not run: learning saw x')
    & $add 'learning gaps: a kind of an extension runs only when every learn row passed (Complete)' $true (
        (Get-HarnessLearnGap -Context $all -Scenario (& $sOf $twoStates 'ext-count')) -clike 'not run: learning did not pass in every batch*(see the learn rows)' -and
        (Get-HarnessLearnGap -Context $all -Scenario (& $sOf $twoStates 'ext-count') -Complete $true) -ceq '')

    # The verdict of one batch: Foreign anywhere first, then a failed launch, then a failed entry, then an unseen binary of the batch
    $binA = 'P:\plugins\A.vst3\Contents\x86_64-win\A.vst3'; $binB = 'P:\plugins\B.vst3\Contents\x86_64-win\B.vst3'
    $inst = @{ a = [pscustomobject]@{ Binary = $binA; BinaryLeaf = 'A.vst3' }; b = [pscustomobject]@{ Binary = $binB; BinaryLeaf = 'B.vst3' } }
    $same = { param($x, $y) [string]::Equals($x, $y, [StringComparison]::OrdinalIgnoreCase) }
    $ent = { param([string]$Plugin, [string]$EntryKey) [pscustomobject]@{ Key = $EntryKey; Plugin = $Plugin; State = ''; Params = [ordered]@{} } }
    $chk = { param([string[]]$Clean, [string[]]$Fail = @(), [string[]]$FromOutside = @()) $bl = @{}; foreach ($k in $Clean) { $bl[$k] = @('x') }; [pscustomobject]@{ Fail = $Fail; Foreign = $FromOutside; Blocks = $bl } }
    $jsTable = @{ js = [pscustomobject]@{ Name = 'JS: js'; AddName = 'JS:js.jsfx'; Ident = 'js.jsfx' } }
    $verdict = { param($BatchEntries, $CheckResult, [hashtable]$ModuleList, [string]$LaunchFailed = '') Get-HarnessLearnVerdict -Variants $BatchEntries -Check $CheckResult -LaunchWhy $LaunchFailed -Installed $inst -Jsfx $jsTable -Seen $ModuleList -SameFile $same }
    $aOnly = @((& $ent 'a' 'a|x'), (& $ent 'js' 'js|'))
    $ok = & $verdict $aOnly (& $chk @('a|x', 'js|')) @{ 'A.vst3' = @($binA) }
    & $add 'learn verdict: a batch whose plugins loaded from the private copy passes, also when the binary of a plugin of another batch was not seen; its facts are about its own binaries' $false (
        $ok.Status -ceq 'PASS' -and ($ok.Commit -join ',') -ceq 'a|x,js|' -and $ok.Modules.Verdict -ceq 'Proven' -and (@($ok.Modules.Binaries.get_Keys()) -join ',') -ceq 'A.vst3' -and -not $ok.Foreign)
    $unseen = & $verdict @((& $ent 'a' 'a|x'), (& $ent 'b' 'b|y'), (& $ent 'js' 'js|')) (& $chk @('a|x', 'b|y', 'js|')) @{ 'A.vst3' = @($binA) }
    & $add 'learn verdict: a binary of a plugin of the batch never seen is INCOMPLETE; what was proven is committed, its entries are not' $true (
        $unseen.Status -ceq 'INCOMPLETE' -and $unseen.Detail -clike '*never showed B.vst3 loaded*' -and ($unseen.Commit -join ',') -ceq 'a|x,js|' -and -not $unseen.Foreign)
    $foreignAny = & $verdict $aOnly (& $chk @('a|x', 'js|')) @{ 'A.vst3' = @($binA); 'B.vst3' = @('S:\VST3\B.vst3') }
    $jsForeign = & $verdict @((& $ent 'js' 'js|')) (& $chk @('js|')) @{ 'B.vst3' = @('S:\VST3\B.vst3') }
    & $add 'learn verdict: a tested binary from outside the private copy, of any plugin, in a batch of JSFX only too, is INCOMPLETE, commits nothing and stops learning' $true (
        $foreignAny.Status -ceq 'INCOMPLETE' -and $foreignAny.Foreign -and $foreignAny.Commit.Count -eq 0 -and $foreignAny.Detail -clike 'not the private copy: a module named B.vst3*' -and
        $jsForeign.Foreign -and $jsForeign.Commit.Count -eq 0 -and $jsForeign.Modules.Verdict -ceq 'NoBinary')
    $identForeign = & $verdict $aOnly (& $chk @('js|') @() @('a was loaded from S:\x')) @{ 'A.vst3' = @($binA) }
    & $add 'learn verdict: an fx_ident outside the private copy is Foreign as well' $true ($identForeign.Foreign -and $identForeign.Commit.Count -eq 0)
    $failed = & $verdict @((& $ent 'a' 'a|x'), (& $ent 'b' 'b|y')) (& $chk @('a|x') @('b (variant 2) is offline')) @{ 'A.vst3' = @($binA) }
    & $add 'learn verdict: a failed entry is FAIL before an unseen binary, and the clean entries of the batch are committed' $true ($failed.Status -ceq 'FAIL' -and ($failed.Commit -join ',') -ceq 'a|x')
    $foreignFail = & $verdict $aOnly (& $chk @('js|') @('a (variant 1) is offline') @('a was loaded from S:\x')) @{ 'A.vst3' = @($binA) }
    $foreignNoLaunch = & $verdict $aOnly $null @{ 'B.vst3' = @('S:\VST3\B.vst3') } 'timed out after 30 s'
    & $add "learn verdict: Foreign comes first, before a failed entry and before a failed launch ($($foreignFail.Status): $($foreignFail.Detail) / $($foreignNoLaunch.Status): $($foreignNoLaunch.Detail))" $true (
        $foreignFail.Status -ceq 'INCOMPLETE' -and $foreignFail.Detail -ceq 'not the private copy: a was loaded from S:\x' -and $foreignFail.Foreign -and $foreignFail.Commit.Count -eq 0 -and
        $foreignNoLaunch.Status -ceq 'INCOMPLETE' -and $foreignNoLaunch.Detail -clike 'not the private copy: a module named B.vst3 *' -and $foreignNoLaunch.Foreign)
    $stranger = & $verdict @((& $ent 'a' 'a|x'), (& $ent 'zz' 'zz|')) (& $chk @('a|x', 'zz|')) @{ 'A.vst3' = @($binA) }
    & $add "learn verdict: an entry of a plugin neither installed nor a JSFX is never committed, whatever its check said ($($stranger.Commit -join ','))" $true (($stranger.Commit -join ',') -ceq 'a|x')
    $noLaunch = & $verdict $aOnly $null @{} 'timed out after 30 s'
    & $add 'learn verdict: a launch that failed is INCOMPLETE and commits nothing' $true ($noLaunch.Status -ceq 'INCOMPLETE' -and $noLaunch.Detail -ceq 'the learn launch failed: timed out after 30 s' -and $noLaunch.Commit.Count -eq 0 -and -not $noLaunch.Foreign)
    $jsOnly = & $verdict @((& $ent 'js' 'js|')) (& $chk @('js|')) @{}
    & $add 'learn verdict: a batch of JSFX only has no binary to prove and passes on fx_ident' $false ($jsOnly.Status -ceq 'PASS' -and $jsOnly.Modules.Verdict -ceq 'NoBinary' -and $jsOnly.Detail -clike '*no plugin binary to check (only JSFX)*')
    # Which failed launch stops learning: one launch of a batch as its Lua step ends (no REAPER, no ini written)
    $stopDir = Join-Path $Tmp 'learn-stop'
    $null = New-Item -ItemType Directory -Force -Path $stopDir
    $stopOf = {
        param([string]$RunStatus, [bool]$Stuck = $false)
        $luaEnd = [pscustomobject]@{ Run = [pscustomobject]@{ Status = $RunStatus; StillRunning = $Stuck; Modules = @{} }; Result = @{}; Why = "the launch ended so: $RunStatus" }
        $luaStub = { $luaEnd }.GetNewClosure() # made here: a closure takes the variables of the scope it is made in
        $ctxL = @{ Work = $stopDir; Files = [Collections.Generic.List[string]]::new(); States = @{}; Jsfx = $jsTable; Installed = @{}; Limits = @{ learnTimeoutSec = 30 }; Blocks = @{}; LearnReads = @{}; Names = @{}; AddNames = @{} }
        $o = try {
            Invoke-WithModuleStub 'Invoke-HarnessLearn' 'Set-HarnessAudioConfig' { } {
                Invoke-WithModuleStub 'Invoke-HarnessLearn' 'Invoke-HarnessLuaStep' $luaStub { Invoke-HarnessLearn -Ctx $ctxL -Variants @(& $ent 'js' 'js|') -BatchNo 2 -BatchCount 3 }
            }
        } catch { [pscustomobject]@{ Stop = "threw: $($_.Exception.Message)" } }
        "$RunStatus$($Stuck ? '+StillRunning' : '')=$($o.Stop)"
    }
    $stops = @((& $stopOf 'LockBusy'), (& $stopOf 'SkipMarker'), (& $stopOf 'Blocked'), (& $stopOf 'Timeout' $true), (& $stopOf 'Timeout'), (& $stopOf 'Modal'), (& $stopOf 'Error')) -join ', '
    & $add "learn stop: a launch that was blocked (a busy lock, a skip marker, an earlier process not ended) or could not be ended stops learning; one that timed out, stuck on a dialog or broke does not ($stops)" $true (
        $stops -ceq 'LockBusy=launch, SkipMarker=launch, Blocked=launch, Timeout+StillRunning=launch, Timeout=, Modal=, Error=')

    # The latency of a plugin that only reports it
    $plugins = [ordered]@{ d = [pscustomobject]@{ ExpectPdc = 'report' }; n = [pscustomobject]@{ ExpectPdc = 64 }; z = [pscustomobject]@{ ExpectPdc = 0 } }
    $fxOf = { param([string]$Plugin) [pscustomobject]@{ Plugin = $Plugin; State = ''; Bypass = $false; Params = [ordered]@{}; Variant = "$Plugin|" } }
    $pl = [pscustomobject]@{ Tracks = @([pscustomobject]@{ Name = 'V'; Fx = @((& $fxOf 'd'), (& $fxOf 'n'), (& $fxOf 'z')) }) }
    $facts = { param([string]$DelayPdc, [string]$NumPdc = '64', [string]$ZeroPdc = '0') @{ tracks = '1'; t0_fx_count = '3'; t0_fx0_pdc = $DelayPdc; t0_fx1_pdc = $NumPdc; t0_fx2_pdc = $ZeroPdc; t0_fx0_bypassed = 'false'; t0_fx1_bypassed = 'false'; t0_fx2_bypassed = 'false'; t0_fx0_offline = 'false'; t0_fx1_offline = 'false'; t0_fx2_offline = 'false' } }
    $fr = { param($FactSet) $g = [Collections.Generic.List[string]]::new(); $fxBad = Test-HarnessFxReport -Facts $FactSet -Layout $pl -Plugins $plugins -Gaps $g; [pscustomobject]@{ Bad = @($fxBad); Gaps = @($g) } }
    $read = & $fr (& $facts '512')
    $withoutGaps = try { $null = Test-HarnessFxReport -Facts (& $facts '') -Layout $pl -Plugins $plugins; 'no throw' } catch { $_.Exception.Message }
    $readWithoutGaps = Test-HarnessFxReport -Facts (& $facts '512') -Layout $pl -Plugins $plugins
    $unreadPdc = & $fr (& $facts '')
    & $add "latency: a plugin with expectPdc `"report`" is not compared, whatever it reports; a reading that is not there is a gap, and throws without -Gaps ($withoutGaps)" $true (
        $read.Bad.Count -eq 0 -and $read.Gaps.Count -eq 0 -and $unreadPdc.Bad.Count -eq 0 -and ($unreadPdc.Gaps -join ';') -ceq 't0_fx0_pdc was not read (the latency of d is only reported)' -and
        (& $fr (& $facts '-1')).Gaps.Count -eq 1 -and $withoutGaps -ceq 't0_fx0_pdc was not read (the latency of d is only reported), and the caller took no -Gaps' -and $readWithoutGaps.Count -eq 0)
    $numeric = try { (& $fr (& $facts '7' '32')).Bad -join ';' } catch { "threw: $($_.Exception.Message)" }
    & $add "latency: a numeric expectPdc is still compared, 0 included ($numeric)" $true ($numeric -ceq 't0_fx1_pdc=32, expected 64' -and (& $fr (& $facts '7' '64' '0')).Bad.Count -eq 0 -and (& $fr (& $facts '7' '64' '3')).Bad.Count -eq 1)
    $pf = Get-HarnessPdcFacts (& $facts '512') '' $pl $plugins
    & $add 'latency: the facts list each FX whose latency is only reported, with what it reported (null when nothing)' $false (
        $pf.Count -eq 1 -and $pf[0].track -ceq 'V' -and $pf[0].index -eq 0 -and $pf[0].plugin -ceq 'd' -and $pf[0].pdc -eq 512 -and $null -eq (Get-HarnessPdcFacts (& $facts '') '' $pl $plugins)[0].pdc)
    $scenarioModule = (Get-Command Get-HarnessPdcFacts).Module
    $gapOf = { param([string]$Judged) & $scenarioModule { param($st) $g = [Collections.Generic.List[string]]::new(); $g.Add('x was not read'); Get-HarnessGapOutcome $st 'judged' $g @() } $Judged }
    $gapFail = & $gapOf 'FAIL'
    $gapPass = & $gapOf 'PASS'
    & $add "latency: a reading that is not there makes a PASS INCOMPLETE and leaves a FAIL a FAIL, saying so ($($gapFail.Status): $($gapFail.Detail))" $true (
        $gapFail.Status -ceq 'FAIL' -and $gapFail.Detail -ceq 'judged; no evidence: x was not read' -and $gapPass.Status -ceq 'INCOMPLETE' -and $gapPass.Detail -ceq 'judged; no evidence: x was not read')
    $reopenPdc = Test-HarnessReopenFacts -Facts @{ before_t0_fx0_pdc = '64'; after1_t0_fx0_pdc = '32' } -Cycles 1
    & $add 'latency: a latency that changes on reopen is still a problem of savereopen' $true (($reopenPdc -join ';') -ceq "t0_fx0_pdc changed on reopen 1 of 1: '64' -> '32'")
    $cfgPdc = & $with { param($c) $c['plugins']['delay']['expectPdc'] = 'report' }
    & $add 'latency: expectPdc "report" is kept as that word, a number as a number' $false (@($cfgPdc.Problems).Count -eq 0 -and $cfgPdc.Config.Plugins['delay'].ExpectPdc -ceq 'report' -and $cfgPdc.Config.Plugins['bus'].ExpectPdc -is [int])
    # The layout a scenario renders
    $sl = { param($s) Get-HarnessScenarioLayout -Config $o.Config -Scenario $s }
    & $add 'scenario layout: the variant layout when there is one, else the layout of the configuration, the dry one for @dry, nothing without a layout' $false (
        [object]::ReferenceEquals((& $sl (& $byId $o 'bus-trim')), $trim) -and [object]::ReferenceEquals((& $sl (& $byId $o 'routing')), $o.Config.Layouts['routing']) -and
        (& $sl ([pscustomobject]@{ layout = '@dry' })).Id -ceq '@dry' -and $null -eq (& $sl ([pscustomobject]@{ id = 'i'; kind = 'instances' })))
    $cases
}

# ---------------------------------------------------------------- parameter listing
function Get-ListingCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    # What run.ps1 hands over: its bound parameters
    $req = { param([hashtable]$BoundArgs) Test-HarnessListRequest -Bound $BoundArgs }
    $sweepOf = { param([hashtable]$More = @{}) $h = @{ List = 'params'; ListPlugin = 'gain'; ListParam = 'Gain' }; foreach ($k in @($More.get_Keys())) { $h[$k] = $More[$k] }; $h }
    $none = & $req @{ Config = 'c.json'; Only = 'x'; Repeat = 2 }
    $plain = & $req @{ List = 'params' }
    $dflt = & $req (& $sweepOf)
    & $add 'list request: no -List is no listing ($null); -List params alone lists every plugin with no sweep; a sweep has the values 0, 0.25, 0.5, 0.75 and 1 by default' $false (
        $null -eq $none -and $plain.Kind -ceq 'params' -and $null -eq $plain.Plugins -and $null -eq $plain.Params -and $null -eq $plain['Values'] -and
        ($dflt.Plugins -join ',') -ceq 'gain' -and ($dflt.Params -join ',') -ceq 'Gain' -and ($dflt['Values'] -join ',') -ceq '0,0.25,0.5,0.75,1')
    $given = & $req (& $sweepOf @{ ListValues = '1, 0.5,0 0.25'; ListPlugin = ' gain ' })
    $blanks = & $req @{ List = 'params'; ListPlugin = 'gain bus' }
    & $add "list request: values are kept in the order given, commas or blanks between them; ids too ($($given['Values'] -join ','); $($blanks.Plugins -join ','))" $false (
        ($given['Values'] -join ',') -ceq '1,0.5,0,0.25' -and ($given.Plugins -join ',') -ceq 'gain' -and ($blanks.Plugins -join ',') -ceq 'gain,bus')
    & $add 'list request: the PowerShell bound parameters of a script (a dictionary that has no .Contains) are read as well as a hashtable' $false (
        & { function Get-Bound { param([string]$List, [string]$ListPlugin, [int]$Repeat = 1) $PSBoundParameters }; $b = Get-Bound -List params -ListPlugin gain; ((& $req $b).Plugins -join ',') -ceq 'gain' })
    foreach ($o in 'ListPlugin', 'ListParam', 'ListParamFile', 'ListValues') {
        & $add "list request: -$o without -List is a usage error" $true (Test-Usage { & $req @{ $o = 'x' } } "USAGE: -$o needs -List params*")
    }
    & $add 'list request: -List with anything but params is a usage error, saying so' $true (Test-Usage { & $req @{ List = 'classes' } } 'USAGE: -List: only "params" can be listed')
    foreach ($o in @(@{ Only = 'x' }, @{ NoNegative = $true }, @{ Repeat = 1 })) {
        $name = @($o.get_Keys())[0]
        & $add "list request: -List with -$name (given at all, -Repeat 1 too) is a usage error" $true (Test-Usage { & $req (@{ List = 'params' } + $o) } "USAGE: -$name does not go with -List*")
    }
    & $add 'list request: a sweep without -ListPlugin, or with two plugins, is a usage error' $true (
        (Test-Usage { & $req @{ List = 'params'; ListParam = 'Gain' } } '*needs exactly one plugin*') -and (Test-Usage { & $req (& $sweepOf @{ ListPlugin = 'gain,bus' }) } '*needs exactly one plugin*'))
    & $add 'list request: an empty plugin id, or one given twice, is a usage error' $true (
        (Test-Usage { & $req @{ List = 'params'; ListPlugin = 'gain,,bus' } } '*an empty plugin id*') -and (Test-Usage { & $req @{ List = 'params'; ListPlugin = 'gain,gain' } } "*plugin 'gain' is given twice*"))
    & $add 'list request: -ListValues without a sweep is a usage error' $true (Test-Usage { & $req @{ List = 'params'; ListPlugin = 'gain'; ListValues = '0.5' } } '*-ListValues needs -ListParam or -ListParamFile*')
    foreach ($wrongValue in '1.5', '-0.1', 'NaN', 'Infinity', 'x', '', '0,,1', '0;1', '0,5') {
        & $add "list request: -ListValues '$wrongValue' is a usage error" $true (Test-Usage { & $req (& $sweepOf @{ ListValues = $wrongValue }) } '*-ListValues:*')
    }
    & $add 'list request: a value given twice (0 and -0 too) is a usage error' $true ((Test-Usage { & $req (& $sweepOf @{ ListValues = '0.5,0.25,0.5' }) } '*0.5 is given twice*') -and (Test-Usage { & $req (& $sweepOf @{ ListValues = '0,-0' }) } '*is given twice*'))
    $values = { param([int]$n) (@(for ($i = 0; $i -lt $n; $i++) { ($i / 1000).ToString([Globalization.CultureInfo]::InvariantCulture) }) -join ',') }
    & $add 'list request: 101 values are fine, 102 are a usage error' $true (@((& $req (& $sweepOf @{ ListValues = (& $values 101) }))['Values']).Count -eq 101 -and (Test-Usage { & $req (& $sweepOf @{ ListValues = (& $values 102) }) } '*at most 101 values*'))
    & $add 'list request: a name of 128 characters (as a configuration takes) is fine; 129, an empty one or one with a control character is a usage error' $true (
        @((& $req (& $sweepOf @{ ListParam = ('n' * 128) })).Params)[0].Length -eq 128 -and (Test-Usage { & $req (& $sweepOf @{ ListParam = ('n' * 129) }) } '*parameter name 1 to sweep is empty, longer than 128*') -and
        (Test-Usage { & $req (& $sweepOf @{ ListParam = '' }) } '*parameter name 1 to sweep is empty*') -and (Test-Usage { & $req (& $sweepOf @{ ListParam = "a`tb" }) } '*control character*') -and
        (Test-Usage { & $req (& $sweepOf @{ ListParam = "ab`n" }) } '*control character*'))
    & $add 'list request: -ListParam and -ListParamFile together are a usage error' $true (Test-Usage { & $req (& $sweepOf @{ ListParamFile = 'x.txt' }) } '*-ListParam and -ListParamFile do not go together*')
    $nameFile = { param([byte[]]$FileBytes) $f = Join-Path $Tmp ('names-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt'); [IO.File]::WriteAllBytes($f, $FileBytes); @{ List = 'params'; ListPlugin = 'gain'; ListParamFile = $f } }
    $utf8 = { param([string]$NameText) [Text.UTF8Encoding]::new($false).GetBytes($NameText) }
    $fromFile = & $req (& $nameFile ([byte[]](0xEF, 0xBB, 0xBF) + (& $utf8 "Band 1 Gain`r`nGain`nEcho $([char]0xE9)`n`n")))
    & $add 'list request: -ListParamFile reads UTF-8 names one a line, a BOM and empty lines at the end left out' $false (($fromFile.Params -join '|') -ceq "Band 1 Gain|Gain|Echo $([char]0xE9)")
    & $add 'list request: -ListParamFile with 33 names, a name twice, an empty line inside, no name or bytes that are not UTF-8 is a usage error' $true (
        (Test-Usage { & $req (& $nameFile (& $utf8 ((@(1..33 | ForEach-Object { "p$_" }) -join "`n") + "`n"))) } '*1 to 32 parameter names*(found 33)') -and
        (Test-Usage { & $req (& $nameFile (& $utf8 "a`nb`na`n")) } '*name 3 to sweep is given twice*') -and (Test-Usage { & $req (& $nameFile (& $utf8 "a`n`nb`n")) } '*name 2 to sweep is empty*') -and
        (Test-Usage { & $req (& $nameFile (& $utf8 "`n")) } '*(found 0)') -and (Test-Usage { & $req (& $nameFile ([byte[]](0x61, 0xFF, 0x0A))) } '*cannot be read as UTF-8*') -and
        @((& $req (& $nameFile (& $utf8 ((@(1..32 | ForEach-Object { "p$_" }) -join "`n") + "`n")))).Params).Count -eq 32)
    & $add 'list request: -ListParamFile of up to 64 KiB is read; a larger one is a usage error' $true (
        ((& $req (& $nameFile (& $utf8 ('a' + ("`n" * 65535))))).Params -join '|') -ceq 'a' -and
        (Test-Usage { & $req (& $nameFile (& $utf8 ('a' + ("`n" * 65536)))) } 'USAGE: -ListParamFile: the file is larger than 64 KiB'))
    & $add 'list request: -ListParamFile that is not there is a usage error that does not repeat the path' $true (Test-Usage { & $req @{ List = 'params'; ListPlugin = 'gain'; ListParamFile = (Join-Path $Tmp 'no-such-names.txt') } } 'USAGE: -ListParamFile: no such file')

    # What the driver reports of a listing (Read-HarnessParamListing): three parameters, two of them of the same name
    $bin = 'P:\plugins\Fixture Gain.vst3\Contents\x86_64-win\Fixture Gain.vst3'
    $cid = '5A1B2C3D4E5F60718293A4B5C6D7E8F9'
    $inst = [pscustomobject]@{ Binary = $bin; Info = [pscustomobject]@{ Name = 'Fixture Gain'; Vendor = 'Fixture Audio'; Cid = $cid } }
    $same = { param($a, $b) [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase) }
    $one = { param([int]$p, [string]$ParamName, [string]$Value = '0.500000000', [string]$Display = '0.50', $Ident = "$p")
        $h = @{ "fx1_l${p}_name" = $ParamName; "fx1_l${p}_exact" = 'true'; "fx1_l${p}_value" = $Value; "fx1_l${p}_display" = $Display; "fx1_l${p}_dexact" = 'true' }
        if ($null -ne $Ident) { $h["fx1_l${p}_ident"] = $Ident }
        $h }
    $base = { param([object[]]$Rows)
        $h = @{ fx1_name = 'VST3: Fixture Gain (Fixture Audio)'; fx1_nparams = "$($Rows.Count)"; fx1_lcount = "$($Rows.Count)"; fx1_lcount_end = "$($Rows.Count)" }
        foreach ($r in $Rows) { foreach ($k in @($r.get_Keys())) { $h[$k] = $r[$k] } }
        $h }
    $three = { & $base @((& $one 0 'Gain'), (& $one 1 'Gain' '0.250000000' '0.25'), (& $one 2 'Mode' '1.000000000' 'On')) }
    $read = { param([hashtable]$Reported, [hashtable]$Sweep = $null) Read-HarnessParamListing -Report $Reported -Key 'fx1_' -Sweep $Sweep -Installed $inst -SameFile $same }
    $ok = & $read (& $three)
    $p0 = $ok.Params[0]; $p1 = $ok.Params[1]; $p2 = $ok.Params[2]
    & $add 'listing: every parameter as REAPER read it: index, name, normalized value, display text, ident; the count and nparams kept' $false (
        -not $ok.Problem -and $ok.Count -eq 3 -and $ok.Nparams -eq 3 -and $ok.Params.Count -eq 3 -and $ok.Unclean -eq 0 -and
        $p0.index -eq 0 -and $p0.name -ceq 'Gain' -and $p0.normalized -eq 0.5 -and $p0.display -ceq '0.50' -and $p0.ident -ceq '0' -and $p2.normalized -eq 1 -and $p2.display -ceq 'On' -and $p2.index -eq 2)
    & $add 'listing: a name used before points at the first parameter of that name (the one learn sets) and is not settable; the first one is' $true (
        $null -eq $p0.sameNameAs -and $p1.sameNameAs -eq 0 -and $p0.settable -and -not $p1.settable -and $p2.settable -and $null -eq $p2.sameNameAs)
    $mut = { param([scriptblock]$Edit, [hashtable]$Sweep = $null) $rep = & $three; & $Edit $rep; & $read $rep $Sweep }
    $whole = { param($res, [string]$Like) [bool]($res.Problem -clike $Like -and $res.Params.Count -eq 0 -and $res.Sweeps.Count -eq 0) }
    & $add 'listing: a parameter without a name is a problem of the whole listing (nothing of it is kept)' $true (& $whole (& $mut { param($r) $r.Remove('fx1_l1_name') }) 'parameter 1 has no name')
    & $add 'listing: no count, or one that is not a whole number from 0 to 65536, is a problem of the whole listing' $true (
        (& $whole (& $mut { param($r) $r.Remove('fx1_lcount') }) "the parameter count '' is not*") -and (& $whole (& $mut { param($r) $r.fx1_lcount = '2.5' }) "the parameter count '2.5'*") -and
        (& $whole (& $mut { param($r) $r.fx1_lcount = '-1' }) '*not a whole number*') -and (& $whole (& $mut { param($r) $r.fx1_lcount = '65537'; $r.fx1_lcount_end = '65537' }) '*from 0 to 65536'))
    & $add 'listing: a count at the end other than at the start is a problem of the whole listing' $true (& $whole (& $mut { param($r) $r.fx1_lcount_end = '4' }) "the parameter count changed while it was read (3, then '4')")
    & $add 'listing: the driver stopping with an error is a problem of the whole listing, with its message' $true (& $whole (& $mut { param($r) $r.fx1_lerror = 'driver.lua:9: boom' }) 'the driver stopped listing: driver.lua:9: boom')
    & $add 'listing: the driver stopping with an error while sweeping is a problem of the whole listing, next to an error while listing' $true (
        (& $whole (& $mut { param($r) $r.fx1_serror = 'driver.lua:9: sweep boom' }) 'the driver stopped sweeping: driver.lua:9: sweep boom') -and
        (& $whole (& $mut { param($r) $r.fx1_lerror = 'driver.lua:8: list boom'; $r.fx1_serror = 'driver.lua:9: sweep boom' }) '*stopped listing: driver.lua:8: list boom*stopped sweeping: driver.lua:9: sweep boom*'))
    $bad1 = { param([scriptblock]$Edit) $res = & $mut $Edit; [pscustomobject]@{ Res = $res; P = ($res.Params.Count -eq 3 ? $res.Params[1] : $null) } }
    $noValue = & $bad1 { param($r) $r.Remove('fx1_l1_value') }
    $high = & $bad1 { param($r) $r.fx1_l1_value = '1.200000000' }
    $word = & $bad1 { param($r) $r.fx1_l1_value = 'nan' }
    $below = & $bad1 { param($r) $r.fx1_l1_value = '-0.100000000' }
    $noDisplay = & $bad1 { param($r) $r.Remove('fx1_l1_display') }
    $inexact = & $bad1 { param($r) $r.fx1_l1_exact = 'false' }
    $perParam = { param($x, [string]$Like) [bool]($x.P -and -not $x.Res.Problem -and $x.Res.Unclean -eq 1 -and $x.P.problem -clike $Like -and -not $x.P.settable -and $x.Res.Params[0].settable) }
    & $add 'listing: a value that is missing, below 0, above 1 or not a number is a problem of that parameter only: written, not settable, counted as unclean' $true (
        (& $perParam $noValue 'its value is not a number from 0 to 1') -and (& $perParam $high 'its value*') -and (& $perParam $word 'its value*') -and (& $perParam $below 'its value*') -and
        $null -eq $noValue.P.normalized -and $null -eq $below.P.normalized)
    & $add 'listing: a display text that is missing is a problem of that parameter only' $true ((& $perParam $noDisplay 'it has no display text') -and $null -eq $noDisplay.P.display -and -not $noDisplay.P.displayUsable)
    & $add 'listing: a name that is not exact (a control character, or not UTF-8) is a problem of that parameter only' $true ((& $perParam $inexact '*control character or is not UTF-8') -and -not $inexact.P.exact)
    $long = & $read (& $base @((& $one 0 ('n' * 129)), (& $one 1 ('n' * 128))))
    & $add 'listing: a name longer than a configuration takes (129 characters) is not settable, and nothing else is said of it' $true (
        -not $long.Problem -and -not $long.Params[0].settable -and $null -eq $long.Params[0].problem -and -not $long.Params[0].masked -and $long.Params[0].exact -and $long.Params[1].settable)
    $pathName = & $read (& $base @((& $one 0 'Out D:\mixes\a.wav'), (& $one 1 'Level' '0.5' 'from //server/x'), (& $one 2 'Gain')))
    & $add 'listing: a name or a display text with a path in it is masked and not settable; a display text with a path is not usable, one next to a name with a path is' $true (
        $pathName.Params[0].masked -and -not $pathName.Params[0].settable -and $pathName.Params[0].displayUsable -and
        $pathName.Params[1].masked -and -not $pathName.Params[1].settable -and -not $pathName.Params[1].displayUsable -and
        -not $pathName.Params[2].masked -and $pathName.Params[2].settable)
    # REAPER's own by ident: ':bypass', ':wet' or ':delta', with the parameter's own index in front or nothing. REAPER 7.82
    # gives every parameter '<index>:<word or number>': the plugin's own its VST3 parameter ID, REAPER's three the words
    $hostAt = { param($res) @($res.Params | Where-Object { $_.host } | ForEach-Object { $_.index }) -join ',' }
    $asReaper = & $read (& $base @(@(for ($i = 0; $i -lt 611; $i++) { & $one $i "P$i" -Ident "${i}:$(97695900 + $i)" }) + @(
                (& $one 611 'Bypass' '0.000000000' 'normal' '611:bypass'), (& $one 612 'Wet' '1.000000000' '100' '612:wet'), (& $one 613 'Delta' '0.000000000' 'normal' '613:delta'))))
    & $add "listing: an ident '<index>:bypass', '<index>:wet' or '<index>:delta' with the parameter's own index is REAPER's own, not settable ('612:wet' of 614 parameters, as REAPER 7.82 gives it; host at $(& $hostAt $asReaper))" $true (
        -not $asReaper.Problem -and $asReaper.Params.Count -eq 614 -and $asReaper.Params[612].ident -ceq '612:wet' -and $asReaper.Params[611].host -and $asReaper.Params[612].host -and
        $asReaper.Params[613].host -and -not $asReaper.Params[612].settable -and -not $asReaper.Params[613].settable -and ($asReaper.HostBy -join ',') -ceq 'ident')
    $hostIdent = & $read (& $base @((& $one 0 'Gain'), (& $one 1 'Wet' '1.000000000' '100.0' ':wet')))
    & $add "listing: an ident ':wet' with nothing in front is REAPER's own, not settable ($($hostIdent.HostBy -join ','))" $true (
        $hostIdent.Params[1].host -and -not $hostIdent.Params[1].settable -and -not $hostIdent.Params[0].host -and ($hostIdent.HostBy -join ',') -ceq 'ident')
    $otherIndex = & $read (& $base @((& $one 0 'Gain' -Ident '0:1000'), (& $one 1 'Bypass' -Ident '11:bypass'), (& $one 2 'Wet' -Ident '5:wet'), (& $one 3 'Delta' -Ident '2:delta')))
    & $add "listing: an ident of REAPER's words with another index than the parameter's own is not REAPER's own, nor are the last three by their names ('11:bypass' at 1, '5:wet' at 2, '2:delta' at 3; host at $(& $hostAt $otherIndex))" $true (
        -not $otherIndex.Problem -and (& $hostAt $otherIndex) -ceq '' -and @($otherIndex.HostBy).Count -eq 0 -and @($otherIndex.Params | Where-Object { $_.settable }).Count -eq 4)
    & $add "listing: a plugin's own ident '<index>:<number>' (its VST3 parameter ID) is not REAPER's own, at its own index too ('15:97695915'; host at $(& $hostAt $asReaper))" $true (
        -not $asReaper.Problem -and @($asReaper.Params | Where-Object { $_.index -lt 611 -and $_.host }).Count -eq 0 -and $asReaper.Params[15].ident -ceq '15:97695915' -and $asReaper.Params[15].settable)
    $otherForm = & $read (& $base @((& $one 0 'Gain' -Ident '0:gain'), (& $one 1 'Wet' -Ident '1:Wet'), (& $one 2 'Delta' -Ident ':DELTA'), (& $one 3 'Wet 2' -Ident '3:wetx'), (& $one 4 'Mix' -Ident 'wet'), (& $one 5 'Wet 3' -Ident "5:wet`n")))
    & $add "listing: an ident with another word, REAPER's word in another case, more after it (a line break too) or no colon is not REAPER's own ('0:gain', '1:Wet', ':DELTA', '3:wetx', 'wet', '5:wet' and a line break; host at $(& $hostAt $otherForm))" $true (
        -not $otherForm.Problem -and (& $hostAt $otherForm) -ceq '' -and @($otherForm.HostBy).Count -eq 0)
    $noIdent = & $read (& $base @((& $one 0 'Gain' -Ident $null), (& $one 1 'Bypass' -Ident $null), (& $one 2 'Wet' -Ident $null), (& $one 3 'Delta' -Ident $null)))
    $notLast = & $read (& $base @((& $one 0 'Bypass' -Ident $null), (& $one 1 'Wet' -Ident $null), (& $one 2 'Delta' -Ident $null), (& $one 3 'Gain' -Ident $null)))
    & $add "listing: without idents the last three named Bypass, Wet and Delta are REAPER's own; the same names elsewhere are not ($($noIdent.HostBy -join ','))" $true (
        @($noIdent.Params | Where-Object { $_.host }).Count -eq 3 -and -not $noIdent.Params[0].host -and $noIdent.Params[0].settable -and ($noIdent.HostBy -join ',') -ceq 'names' -and
        @($notLast.Params | Where-Object { $_.host }).Count -eq 0 -and $null -eq $noIdent.Params[0].ident)
    $dispLong = & $read (& $base @((& $one 0 'Gain' '0.5' ('d' * 129)), (& $one 1 'Mode' '0.5' ('d' * 128))))
    $dispInexact = & $mut { param($r) $r.fx1_l2_dexact = 'false' }
    & $add 'listing: a display text is usable when it is exact and at most 128 characters long' $true (
        -not $dispLong.Params[0].displayUsable -and $dispLong.Params[1].displayUsable -and -not $dispInexact.Params[2].displayUsable -and $dispInexact.Params[2].settable -and $ok.Params[2].displayUsable)
    # Sweeps: a fresh instance per name, proven to be the plugin that was learned
    $sw = @{ Names = @('Gain', 'Volume'); Values = @(0.0, 1.0) }
    $sweepRep = {
        $r = & $three
        foreach ($kv in @{ fx1_s1_idx = '0'; fx1_s1_name = 'VST3: Fixture Gain (Fixture Audio)'; fx1_s1_ident = "$bin<1234567890{$cid"; fx1_s1_index = '0'
                fx1_s1_v1 = '0.000000000'; fx1_s1_v1_display = '0.00'; fx1_s1_v1_dexact = 'true'; fx1_s1_v2 = '1.000000000'; fx1_s1_v2_display = '1.00'; fx1_s1_v2_dexact = 'true'
                fx1_s2_idx = '0'; fx1_s2_name = 'VST3: Fixture Gain (Fixture Audio)'; fx1_s2_ident = "$bin<1234567890{$cid"; fx1_s2_index = 'missing' }.GetEnumerator()) { $r[$kv.Key] = $kv.Value }
        $r
    }
    $swOk = & $read (& $sweepRep) $sw
    & $add "listing: a sweep gives every value asked, read back and shown; a name the plugin does not have is not found ($($swOk.NotFound -join ','))" $false (
        -not $swOk.Problem -and $swOk.Sweeps.Count -eq 1 -and $swOk.Sweeps[0].name -ceq 'Gain' -and $swOk.Sweeps[0].index -eq 0 -and $swOk.Sweeps[0]['values'].Count -eq 2 -and
        $swOk.Sweeps[0]['values'][1].normalized -eq 1 -and $swOk.Sweeps[0]['values'][1].readNormalized -eq 1 -and $swOk.Sweeps[0]['values'][1].display -ceq '1.00' -and $swOk.Sweeps[0]['values'][0].displayUsable -and
        ($swOk.NotFound -join ',') -ceq 'Volume')
    $swMut = { param([scriptblock]$Edit) $r = & $sweepRep; & $Edit $r; & $read $r $sw }
    & $add 'listing: an instance to sweep that was not added is a problem of the whole listing' $true (& $whole (& $swMut { param($r) $r.fx1_s1_idx = '-1' }) "the instance to sweep 'Gain' could not be added (index '-1')")
    & $add 'listing: a swept value that was not read back, or read back outside 0..1, is a problem of the whole listing' $true (
        (& $whole (& $swMut { param($r) $r.Remove('fx1_s1_v2') }) "*'Gain': value 2 was not read back") -and (& $whole (& $swMut { param($r) $r.Remove('fx1_s1_v1_display') }) '*value 1 was not read back') -and
        (& $whole (& $swMut { param($r) $r.fx1_s1_v2 = '1.500000000' }) "*'Gain': value 2 was not read back") -and (& $whole (& $swMut { param($r) $r.fx1_s1_v1 = '-0.500000000' }) "*'Gain': value 1 was not read back"))
    & $add 'listing: an instance to sweep that reports no parameter index for a name is a problem of the whole listing' $true (
        & $whole (& $swMut { param($r) $r.Remove('fx1_s1_index') }) "the instance to sweep 'Gain' has no parameter index")
    $swShown = & $swMut { param($r) $r.fx1_s1_v1_display = 'at //server/x'; $r.fx1_s1_v2_dexact = 'false' }
    $swLong = & $swMut { param($r) $r.fx1_s1_v1_display = ('d' * 129); $r.fx1_s1_v2_display = ('d' * 128) }
    $usable = { param($res) try { @($res.Sweeps[0]['values'] | ForEach-Object { [string]$_.displayUsable }) -join ',' } catch { 'no sweep' } }
    & $add "listing: a swept display text is usable only when it is exact, at most 128 characters long and has no path in it ($(& $usable $swShown); $(& $usable $swLong); $(& $usable $swOk))" $true (
        -not $swShown.Problem -and -not $swLong.Problem -and (& $usable $swShown) -ceq 'False,False' -and (& $usable $swLong) -ceq 'False,True' -and (& $usable $swOk) -ceq 'True,True')
    & $add 'listing: an instance to sweep with another name is not the plugin that was learned: a problem of the whole listing' $true (& $whole (& $swMut { param($r) $r.fx1_s1_name = 'VST3: Fixture Gain Pro (Fixture Audio)' }) "*'Gain' was added as 'VST3: Fixture Gain Pro*")
    & $add 'listing: an instance to sweep loaded from another binary, or of another class, is not the plugin that was learned' $true (
        (& $whole (& $swMut { param($r) $r.fx1_s1_ident = "S:\VST3\Fixture Gain.vst3\Contents\x86_64-win\Fixture Gain.vst3<1234567890{$cid" }) '*is not the plugin that was learned*') -and
        (& $whole (& $swMut { param($r) $r.fx1_s1_ident = "$bin<1234567890{FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" }) '*is not the plugin that was learned*') -and
        (& $whole (& $swMut { param($r) $r.fx1_s2_ident = 'x.dll' }) "the instance to sweep 'Volume' is not the plugin*"))
    $jsRow = [pscustomobject]@{ Ident = 'reaper-harness/harness-pdc-delay.jsfx' }
    $jsRep = { param([string]$Ident) $r = & $three; foreach ($kv in @{ fx1_s1_idx = '0'; fx1_s1_name = 'VST3: Fixture Gain (Fixture Audio)'; fx1_s1_ident = $Ident; fx1_s1_index = 'missing' }.GetEnumerator()) { $r[$kv.Key] = $kv.Value }; $r }
    & $add 'listing: a JSFX instance to sweep is proven by its path under Effects' $true (
        -not (Read-HarnessParamListing -Report (& $jsRep $jsRow.Ident) -Key 'fx1_' -Sweep @{ Names = @('x'); Values = @(0.5) } -Jsfx $jsRow).Problem -and
        (Read-HarnessParamListing -Report (& $jsRep 'other/harness-pdc-delay.jsfx') -Key 'fx1_' -Sweep @{ Names = @('x'); Values = @(0.5) } -Jsfx $jsRow).Problem -clike '*not the plugin that was learned*')

    # The row and the listing of the result (Get-HarnessParamListing), from a context as a learn launch leaves it
    $vstRow = [pscustomobject]@{ Id = 'gain'; Bundle = 'Fixture Gain.vst3'; Binary = $bin; Sha256 = ('ab' * 32); Info = [pscustomobject]@{ Name = 'Fixture Gain'; Vendor = 'Fixture Audio'; Cid = $cid; Version = '1.0.0' } }
    $jsfxRow = [pscustomobject]@{ Id = 'delay'; Jsfx = 'harness-pdc-delay'; Name = 'JS: reaper-harness PDC delay'; Ident = $jsRow.Ident; Sha256 = ('cd' * 32) }
    $block = @('<VST "VST3: Fixture Gain (Fixture Audio)" "Fixture Gain.vst3" 0 "" 1234567890{5A1B2C3D4E5F60718293A4B5C6D7E8F9} ""', 'FAKESTATE QUlFRA==', '>')
    $ctxOf = {
        param([hashtable]$ListingTable, [hashtable]$BlockTable = @{ 'gain|' = $block })
        @{ Config = [pscustomobject]@{ Plugins = [ordered]@{ gain = $null; bus = $null; delay = $null } }; Installed = @{ gain = $vstRow }; Jsfx = @{ delay = $jsfxRow }
            Listing = $ListingTable; Blocks = $BlockTable; LearnReads = @{ 'gain|' = [pscustomobject]@{ Pdc = '32' } } }
    }
    $request = @{ Kind = 'params'; Plugins = $null; Params = $null; Values = $null }
    $jsOk = Read-HarnessParamListing -Report (& $base @((& $one 0 'Delay (samples)'))) -Key 'fx1_' -Jsfx $jsRow
    $both = Get-HarnessParamListing -Ctx (& $ctxOf @{ 'gain|' = $ok; 'delay|' = $jsOk }) -Request $request
    $g = $both.Listing['plugins'][0]; $d = $both.Listing['plugins'][1]
    & $add "listing row: every plugin of the round listed cleanly is PASS; plugins that were not installed are not in it ($($both.Detail))" $false (
        $both.Status -ceq 'PASS' -and $both.Listing['plugins'].Count -eq 2 -and $g['id'] -ceq 'gain' -and $d['id'] -ceq 'delay' -and $both.Facts.listed -eq 2 -and $both.Facts.params -eq 4 -and
        $both.Detail -ceq '2 plugins listed, 4 parameters' -and $both.Lines[0] -ceq 'gain: 3 parameters (0 of them REAPER''s own, 2 settable), 1 name used more than once')
    & $add 'listing row: a plugin is named by its bundle and hash, its class from moduleinfo.json, its learned block by the hash a kept render records, its latency as learn read it' $false (
        $g['bundle'] -ceq 'Fixture Gain.vst3' -and $g['sha256'] -ceq 'abababababab' -and $g['class']['cid'] -ceq $cid -and $g['classFrom'] -ceq 'moduleinfo' -and $g['version'] -ceq '1.0.0' -and
        $g['blockSha256'] -ceq (Get-HarnessBlockTextSha $block) -and $g['blockSha256'] -cmatch '^[0-9a-f]{64}$' -and $g['pdc'] -eq 32 -and $g['paramCount'] -eq 3 -and $g['listed'] -and $null -eq $g['why'] -and
        $null -eq $d['bundle'] -and $d['jsfx'] -ceq 'harness-pdc-delay' -and $null -eq $d['class'] -and $null -eq $d['classFrom'] -and $null -eq $d['blockSha256'])
    & $add 'listing row: the block hash is the SHA-256 of the block as a project holds it (indented, line feeds), the one a kept render manifest has' $false (
        (Get-HarnessBlockTextSha $block) -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes(-join @($block | ForEach-Object { "      $_`n" })))).ToLowerInvariant())
    $missingOne = Get-HarnessParamListing -Ctx (& $ctxOf @{ 'gain|' = $ok }) -Request $request
    & $add 'listing row: a plugin its learn entry did not pass for is INCOMPLETE, not listed, pointing at the learn row' $true (
        $missingOne.Status -ceq 'INCOMPLETE' -and -not $missingOne.Listing['plugins'][1]['listed'] -and $missingOne.Listing['plugins'][1]['why'] -ceq 'not listed: its learn entry did not pass (see the learn row)' -and
        $missingOne.Listing['plugins'][1]['params'].Count -eq 0 -and $missingOne.Listing['plugins'][0]['listed'])
    $probRow = Get-HarnessParamListing -Ctx (& $ctxOf @{ 'gain|' = (& $mut { param($r) $r.fx1_lcount_end = '9' }); 'delay|' = $jsOk }) -Request $request
    & $add 'listing row: a listing with a problem is INCOMPLETE, not listed, its why says the problem; no block hash or latency for it' $true (
        $probRow.Status -ceq 'INCOMPLETE' -and -not $probRow.Listing['plugins'][0]['listed'] -and $probRow.Listing['plugins'][0]['why'] -clike 'not listed: the parameter count changed*' -and
        $null -eq $probRow.Listing['plugins'][0]['blockSha256'] -and $null -eq $probRow.Listing['plugins'][0]['pdc'] -and $probRow.Detail -clike 'gain: not listed: *')
    $uncleanRow = Get-HarnessParamListing -Ctx (& $ctxOf @{ 'gain|' = $noDisplay.Res; 'delay|' = $jsOk }) -Request $request
    & $add 'listing row: parameters not read cleanly make it INCOMPLETE; every parameter that was read is written all the same' $true (
        $uncleanRow.Status -ceq 'INCOMPLETE' -and $uncleanRow.Listing['plugins'][0]['listed'] -and $uncleanRow.Listing['plugins'][0]['params'].Count -eq 3 -and
        $uncleanRow.Listing['plugins'][0]['why'] -ceq '1 parameter could not be read cleanly')
    $swRequest = @{ Kind = 'params'; Plugins = @('gain'); Params = $sw.Names; Values = $sw['Values'] }
    $notFoundRow = Get-HarnessParamListing -Ctx (& $ctxOf @{ 'gain|' = $swOk; 'delay|' = $jsOk }) -Request $swRequest
    & $add "listing row: a swept name the plugin does not have is a FAIL naming it ($($notFoundRow.Detail))" $true (
        $notFoundRow.Status -ceq 'FAIL' -and $notFoundRow.Detail -ceq "gain: no parameter named 'Volume' in gain" -and ($notFoundRow.Facts.notFound -join ',') -ceq 'Volume' -and
        ($notFoundRow.Listing['values'] -join ',') -ceq '0,1' -and $notFoundRow.Listing['plugins'][0]['status'] -ceq 'FAIL' -and $notFoundRow.Listing['plugins'][0]['sweeps'].Count -eq 1)
    & $add "listing row: the line of a plugin says how many parameters were swept, at how many values ($($notFoundRow.Lines[0]))" $false (
        $notFoundRow.Lines[0] -ceq 'gain: 3 parameters (0 of them REAPER''s own, 2 settable), 1 name used more than once, 1 swept at 2 values')
    $notRead = Get-HarnessParamListing -Ctx (& $ctxOf @{ 'gain|' = $ok; 'delay|' = $jsOk }) -Request $request -NotRead 'not listed: the round stopped'
    & $add 'listing row: before anything is read every plugin is not listed, for that reason' $true (
        $notRead.Status -ceq 'INCOMPLETE' -and @($notRead.Listing['plugins'] | Where-Object { $_['listed'] -or $_['why'] -cne 'not listed: the round stopped' }).Count -eq 0 -and $null -eq $notRead.Listing['values'])
    $maskedRow = Get-HarnessParamListing -Ctx (& $ctxOf @{ 'gain|' = $pathName; 'delay|' = $jsOk }) -Request $request
    & $add 'listing row: the listing of the result is masked: no path of a parameter name or display reaches it' $true (
        $maskedRow.Listing['plugins'][0]['params'][0]['name'] -ceq 'Out <path>' -and (ConvertTo-HarnessJsonText -Value $maskedRow.Listing) -cnotmatch 'mixes|//server')
    $nothing = Get-HarnessParamListing -Ctx @{ Config = [pscustomobject]@{ Plugins = [ordered]@{ x = $null } }; Installed = @{}; Jsfx = @{}; Listing = @{}; Blocks = @{}; LearnReads = @{} } -Request $request
    & $add 'listing row: nothing to list is INCOMPLETE, never PASS' $true ($nothing.Status -ceq 'INCOMPLETE' -and $nothing.Detail -ceq 'no plugin to list' -and $nothing.Listing['plugins'].Count -eq 0)
    $cases
}

# ---------------------------------------------------------------- source files
function Get-SourceCases([string]$Tmp) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $dir = Join-Path $Tmp 'sources-config'
    $audio = Join-Path $dir 'audio'
    $null = New-Item -ItemType Directory -Force -Path $audio
    $wav = {
        param([string]$WavName, [int]$WavRate, [int]$WavChannels, [string]$WavFormat, [long]$WavFrames)
        $samples = [double[]]::new($WavFrames * $WavChannels)
        for ($i = 0; $i -lt [Math]::Min($samples.Length, 4000); $i++) { $samples[$i] = (($i % 7) - 3) / 8.0 }
        [HarnessWav]::Write((Join-Path $audio $WavName), $WavRate, $WavChannels, $WavFormat, $false, $samples)
    }
    & $wav 'v16.wav' 44100 1 'pcm16' 1000; & $wav 'v24.wav' 48000 2 'pcm24' 1200; & $wav 'f32.wav' 48000 1 'float32' 900
    & $wav 'p32.wav' 48000 1 'pcm32' 100; & $wav 'f64.wav' 48000 1 'float64' 100; & $wav 'three.wav' 48000 3 'pcm16' 100; & $wav 'empty.wav' 48000 1 'pcm16' 0
    & $wav 'long.wav' 8000 1 'pcm16' (601 * 8000)
    [IO.File]::WriteAllText((Join-Path $audio 'text.wav'), 'not audio')
    [IO.File]::WriteAllText((Join-Path $Tmp 'outside.wav'), 'outside')
    # A configuration whose layouts each have one track playing a file and one playing the test signal
    $conf = {
        param([System.Collections.Specialized.OrderedDictionary]$FileMap, [object[]]$ScenarioList, [object[]]$NegativeList = @())
        $layouts = [ordered]@{ plain = [ordered]@{ tracks = @([ordered]@{ name = 'Tone'; source = $true }) } }
        foreach ($k in $FileMap.get_Keys()) { $layouts[$k] = [ordered]@{ tracks = @([ordered]@{ name = 'File'; source = $true; file = $FileMap[$k] }, [ordered]@{ name = 'Tone'; source = $true }) } }
        $raw = [ordered]@{ schema = 1; name = 'sources'; plugins = [ordered]@{ gain = [ordered]@{ bundle = 'G.vst3' } }; layouts = $layouts; scenarios = $ScenarioList; negative = $NegativeList }
        $r = Test-HarnessConfigData -Raw (ConvertFrom-HarnessJson (ConvertTo-HarnessJsonText -Value $raw))
        if (@($r.Problems).Count) { throw "the configuration of this case has problems: $($r.Problems -join '; ')" }
        $r.Config | Add-Member -NotePropertyName ConfigDir -NotePropertyValue $dir -PassThru
    }
    $render = { param([string]$ScenarioId, [string]$LayoutId, [hashtable]$More = @{}) $s = [ordered]@{ id = $ScenarioId; kind = 'render'; layout = $LayoutId }; foreach ($k in $More.get_Keys()) { $s[$k] = $More[$k] }; $s }
    $all = { param($c) @($c.Scenarios) + @($c.Negative) }
    $good = & $conf ([ordered]@{ f16 = 'audio/v16.wav'; f24 = 'audio/v24.wav'; f32 = './audio/x/../f32.wav'; again = 'audio/V24.wav'; unused = 'audio/missing.wav' }) @(
        (& $render 's16' 'f16' @{ sr = 44100; mono = $true }), (& $render 's24' 'f24'), (& $render 's32' 'f32' @{ mono = $true }), (& $render 'twice' 'again'), (& $render 'other' 'unused'))
    $picked = @($good.Scenarios | Where-Object { $_.id -cne 'other' })
    $checked = try { Read-HarnessSourceFiles -Config $good -Scenarios $picked } catch { $_.Exception.Message }
    $sha = { param([string]$FileLeaf) (Get-FileHash -LiteralPath (Join-Path $audio $FileLeaf) -Algorithm SHA256).Hash.ToLowerInvariant() }
    $ok = $checked -is [System.Collections.IDictionary]
    & $add "sources: the files of the picked scenarios are checked: path relative to the configuration with forward slashes, full SHA-256, frames, channels, rate, format ($(if ($ok) { @($checked.get_Keys()) -join ', ' } else { $checked }))" $false (
        $ok -and (@($checked.get_Keys()) -join ',') -ceq 'audio/v16.wav,audio/v24.wav,audio/f32.wav' -and $checked['audio/v16.wav'].Sha256 -ceq (& $sha 'v16.wav') -and $checked['audio/v16.wav'].Frames -eq 1000 -and
        $checked['audio/v16.wav'].Channels -eq 1 -and $checked['audio/v16.wav'].Rate -eq 44100 -and $checked['audio/v16.wav'].Format -ceq 'pcm16' -and $checked['audio/v24.wav'].Channels -eq 2 -and $checked['audio/v24.wav'].Format -ceq 'pcm24' -and
        $checked['audio/f32.wav'].Format -ceq 'float32' -and $checked['audio/f32.wav'].Path -ceq (Join-Path $audio 'f32.wav'))
    & $add 'sources: one file named two ways (other case, ./ and ..) is one file; a file only a scenario that was not picked names is not read' $false ($ok -and $checked.get_Count() -eq 3)
    $fact = $ok ? (ConvertTo-HarnessSourceFact $checked['audio/v24.wav']) : $null
    & $add 'sources: the result lists a file by its relative path, sha256 (64 hex), frames, channels, sampleRate and format' $false (
        $null -ne $fact -and (@($fact.get_Keys()) -join ',') -ceq 'path,sha256,frames,channels,sampleRate,format' -and $fact.path -ceq 'audio/v24.wav' -and $fact.sha256 -cmatch '^[0-9a-f]{64}$' -and $fact.sampleRate -eq 48000)
    $badConf = & $conf ([ordered]@{ p32 = 'audio/p32.wav'; f64 = 'audio/f64.wav'; three = 'audio/three.wav'; empty = 'audio/empty.wav'; long = 'audio/long.wav'; text = 'audio/text.wav'; gone = 'audio/gone.wav'; out = '../outside.wav'; abs = (Join-Path $audio 'v16.wav') }) @(
        (& $render 'a' 'p32'), (& $render 'b' 'f64'), (& $render 'c' 'three'), (& $render 'd' 'empty'), (& $render 'e' 'long' @{ sr = 8000 }), (& $render 'f' 'text'), (& $render 'g' 'gone'), (& $render 'h' 'out'), (& $render 'i' 'abs'), (& $render 'j' 'p32'))
    $msg = try { $null = Read-HarnessSourceFiles -Config $badConf -Scenarios (& $all $badConf); 'accepted' } catch { $_.Exception.Message }
    & $add "sources: every problem is one usage error, each file named once however many scenarios use it ($msg)" $true ($msg -clike 'USAGE: sources: 9 problem(s): *')
    foreach ($p in @(
            @('a pcm32 file', 'source audio/p32.wav is pcm32: only pcm16, pcm24 and float32 are accepted'), @('a float64 file', 'source audio/f64.wav is float64: only pcm16'),
            @('a file of 3 channels', 'source audio/three.wav has 3 channels: 1 or 2 are accepted'), @('a file without samples', 'source audio/empty.wav holds no samples'),
            @('a file longer than 600 s', 'source audio/long.wav is longer than 600 s'), @('a file that is not a WAV', 'source audio/text.wav cannot be used: not a RIFF/WAVE file'),
            @('a file that is not there', 'source audio/gone.wav cannot be used: source file not found'), @('a path that leaves the directory of the configuration', "source ../outside.wav cannot be used: source path '../outside.wav' leaves the directory"),
            @('an absolute path', 'cannot be used: source path * must be relative to the configuration file'))) {
        & $add "sources: $($p[0]) is refused before REAPER starts" $true ($msg -clike "*$($p[1])*")
    }
    $rates = & $conf ([ordered]@{ f16 = 'audio/v16.wav'; f24 = 'audio/v24.wav' }) @(
        (& $render 'r48' 'f16'), (& $render 'vs' 'plain' @{ sr = 48000; compare = [ordered]@{ layout = 'f16' } }), (& $render 'm' 'f16' @{ matrix = [ordered]@{ sr = @(44100, 48000) } }),
        (& $render 'mono' 'f24' @{ mono = $true }), (& $render 'fine' 'f16' @{ sr = 44100 }), [ordered]@{ id = 'dev'; kind = 'device'; layout = 'f16' }) @(
        [ordered]@{ id = 'neg'; kind = 'render'; layout = 'f16'; expect = 'FAIL'; expectDetail = 'x' })
    $msg = try { $null = Read-HarnessSourceFiles -Config $rates -Scenarios (& $all $rates); 'accepted' } catch { $_.Exception.Message }
    & $add "sources: a scenario at another rate than its file is refused, nothing is resampled ($msg)" $true ($msg -clike '*r48: source audio/v16.wav is at 44100 Hz and the scenario runs at 48000 Hz: nothing is resampled*')
    & $add 'sources: so is a scenario whose compared layout plays the file' $true ($msg -clike '*; vs: source audio/v16.wav is at 44100 Hz*')
    & $add 'sources: a matrix is checked per rate: only the expanded scenario at the other rate is refused' $true ($msg -clike '*; m-48000: source audio/v16.wav*' -and $msg -cnotlike '*m-44100:*')
    & $add 'sources: a file of two channels in a mono render is refused, nothing is mixed down' $true ($msg -clike '*mono: source audio/v24.wav has two channels and the scenario renders one (mono): nothing is mixed down*')
    & $add 'sources: other kinds that play the file are checked too (device), and negative cases of the configuration' $true ($msg -clike '*; dev: source audio/v16.wav is at 44100 Hz*' -and $msg -clike '*; neg: source audio/v16.wav is at 44100 Hz*')
    & $add 'sources: a scenario at the rate of its file is fine (one problem per refused scenario, no more)' $false ($msg -clike 'USAGE: sources: 6 problem(s): *' -and $msg -cnotlike '*fine:*')
    # Item lengths: the product with the rate must not fall short of the frames (REAPER may cut the fraction off)
    $short = 0; $wrong = [Collections.Generic.List[string]]::new()
    foreach ($itemRate in 8000, 11025, 22050, 44100, 48000, 88200, 96000, 192000) {
        for ($n = 1; $n -le 2000; $n++) {
            if (($n / [double]$itemRate) * $itemRate -lt $n) { $short++ }
            $l = Get-HarnessItemLength $n $itemRate
            if ($l * $itemRate -lt $n -or [Math]::Floor($l * $itemRate) -ne $n) { $wrong.Add("$n/$itemRate") }
        }
    }
    & $add "item length: 1 to 2000 frames at 8 rates: frames x rate is never short of the frames ($short of them are as frames / rate; wrong: $(@($wrong | Select-Object -First 5) -join ', '))" $true ($short -gt 0 -and $wrong.Count -eq 0)
    & $add 'item length: exact where the quotient is exact (4 s at 48000)' $false ((Get-HarnessItemLength 192000 48000) -eq 4.0 -and (Get-HarnessItemLength 13 44100) * 44100 -ge 13)
    # Each round: one copy per content in the work directory, checked against the hash taken before the start
    $work = Join-Path $Tmp 'sources-work'
    $null = New-Item -ItemType Directory -Force -Path $work
    $ctx = @{ Work = $work; Files = [Collections.Generic.List[string]]::new(); SourceCopies = @{}; Config = $good; Kinds = @{}; Api = $null }
    if ($ok) { Copy-HarnessSourceFiles -Ctx $ctx -Sources $checked }
    $copies = @(Get-ChildItem -LiteralPath $work -Filter '_source-*.wav')
    $c24 = $ctx.SourceCopies['audio/v24.wav']
    & $add "source copies: one copy per file in the work directory, named by its hash, the same bytes, registered for cleanup ($(@($copies | ForEach-Object Name) -join ', '))" $false (
        $copies.Count -eq 3 -and $null -ne $c24 -and (Split-Path -Leaf $c24.Path) -ceq "_source-$((& $sha 'v24.wav').Substring(0, 12)).wav" -and (Get-FileHash -LiteralPath $c24.Path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq (& $sha 'v24.wav') -and
        @($copies | Where-Object { $_.FullName -notin $ctx.Files }).Count -eq 0 -and $null -eq $c24.Why -and $c24.Length -eq $checked['audio/v24.wav'].Length -and $ctx.Files.Count -eq 3)
    & $add 'source copies: a track gets the copy, never the file in the directory of the configuration' $false (
        $null -ne $c24 -and (Get-HarnessSourceCopy -Ctx $ctx -File 'audio/V24.wav').Path -ceq $c24.Path -and $null -eq (Get-HarnessSourceGap -Ctx $ctx -Scenario @($good.Scenarios | Where-Object id -ceq 's24')[0]))
    $chg = & $conf ([ordered]@{ chg = 'audio/chg.wav'; f16 = 'audio/v16.wav' }) @((& $render 'uses' 'chg'), (& $render 'other' 'f16' @{ sr = 44100 }))
    Copy-Item -LiteralPath (Join-Path $audio 'v24.wav') -Destination (Join-Path $audio 'chg.wav')
    $chgFiles = Read-HarnessSourceFiles -Config $chg -Scenarios @($chg.Scenarios)
    & $wav 'chg.wav' 48000 2 'pcm24' 1201
    $work2 = Join-Path $Tmp 'sources-work2'
    $null = New-Item -ItemType Directory -Force -Path $work2
    $newCtx = { param($w) @{ Work = $w; Files = [Collections.Generic.List[string]]::new(); SourceCopies = @{}; Config = $chg; Kinds = @{}; Api = $null } }
    $ctx2 = & $newCtx $work2
    Copy-HarnessSourceFiles -Ctx $ctx2 -Sources $chgFiles
    $uses = @($chg.Scenarios | Where-Object id -ceq 'uses')[0]
    & $add 'source copies: a file changed after it was checked: its scenarios cannot use it' $true (
        (Get-HarnessSourceGap -Ctx $ctx2 -Scenario $uses) -ceq 'source file audio/chg.wav changed since it was checked' -and $(try { $null = Get-HarnessSourceCopy -Ctx $ctx2 -File 'audio/chg.wav'; $false } catch { $_.Exception.Message -clike '*changed since it was checked*' }))
    & $add 'source copies: the other scenarios still can' $false ($null -eq (Get-HarnessSourceGap -Ctx $ctx2 -Scenario @($chg.Scenarios | Where-Object id -ceq 'other')[0]))
    $o = Invoke-HarnessScenario -Ctx $ctx2 -Scenario $uses
    & $add "source copies: such a scenario is INCOMPLETE with that reason, and nothing of it runs ($($o.Detail))" $true ($o.Status -ceq 'INCOMPLETE' -and $o.Detail -ceq 'source file audio/chg.wav changed since it was checked' -and -not (Test-Path -LiteralPath (Join-Path $work2 'uses.rpp')))
    Remove-Item -LiteralPath (Join-Path $audio 'chg.wav')
    $ctx3 = & $newCtx (Join-Path $Tmp 'sources-work3')
    $null = New-Item -ItemType Directory -Force -Path $ctx3.Work
    Copy-HarnessSourceFiles -Ctx $ctx3 -Sources $chgFiles
    & $add 'source copies: a file gone after it was checked cannot be used either' $true ((Get-HarnessSourceGap -Ctx $ctx3 -Scenario $uses) -clike 'source file audio/chg.wav could not be copied: *')
    $ctx4 = & $newCtx $work2
    & $add 'source copies: a file no check before the start has seen is never used' $true (
        (Get-HarnessSourceGap -Ctx $ctx4 -Scenario $uses) -ceq 'source file audio/chg.wav was not checked before the start' -and $(try { $null = Get-HarnessSourceCopy -Ctx $ctx4 -File 'audio/chg.wav'; $false } catch { $_.Exception.Message -clike '*was not checked before the start*' }))
    & $add 'source copies: a copy that failed its check is not left under the name of the content that was checked, nor kept for cleanup' $true (
        -not (Test-Path -LiteralPath (Join-Path $work2 "_source-$($chgFiles['audio/chg.wav'].Sha256.Substring(0, 12)).wav")) -and -not $ctx2.Files.Contains($ctx2.SourceCopies['audio/chg.wav'].Path) -and
        $ctx2.SourceCopies['audio/v16.wav'].Path -cin $ctx2.Files -and (Test-Path -LiteralPath $ctx2.SourceCopies['audio/v16.wav'].Path))
    # Header and hash are two reads of the file: a header that is not the one of the bytes hashed (the file was written over
    # in between) shows in the copy, whose header is read again
    $f16 = $checked['audio/v16.wav']
    $stale = [Collections.Specialized.OrderedDictionary]::new()
    $stale['audio/v16.wav'] = [pscustomobject]@{ Rel = $f16.Rel; Path = $f16.Path; Sha256 = $f16.Sha256; Frames = $f16.Frames + 1; Channels = $f16.Channels; Rate = $f16.Rate; Format = $f16.Format; Length = $f16.Length }
    $ctx5 = & $newCtx (Join-Path $Tmp 'sources-work5')
    $null = New-Item -ItemType Directory -Force -Path $ctx5.Work
    Copy-HarnessSourceFiles -Ctx $ctx5 -Sources $stale
    & $add 'source copies: the same bytes with another header than the one checked before the start (written over between the two reads) are not used either' $true (
        $ctx5.SourceCopies['audio/v16.wav'].Why -ceq 'source file audio/v16.wav changed since it was checked' -and @(Get-ChildItem -LiteralPath $ctx5.Work).Count -eq 0 -and $ctx5.Files.Count -eq 0)
    # A copy whose hash cannot be taken right after it was written (a scanner holding it): only the scenarios that use that
    # file cannot run; the call does not throw (it runs outside the round's error handling) and the other files are copied
    $heldName = "_source-$($f16.Sha256.Substring(0, 12)).wav"
    $held = { param([string]$Path) if ((Split-Path -Leaf $Path) -ceq $heldName) { throw 'the file is in use by another process' }; (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }.GetNewClosure()
    $ctx8 = @{ Work = (Join-Path $Tmp 'sources-work8'); Files = [Collections.Generic.List[string]]::new(); SourceCopies = @{}; Config = $good; Kinds = @{}; Api = $null }
    $null = New-Item -ItemType Directory -Force -Path $ctx8.Work
    $heldThrew = try { Invoke-WithModuleStub 'Copy-HarnessSourceFiles' 'Get-HarnessSha256' $held { Copy-HarnessSourceFiles -Ctx $ctx8 -Sources $checked }; '' } catch { $_.Exception.Message }
    & $add "source copies: a copy that cannot be read back makes only its own scenarios INCOMPLETE, the round goes on ($heldThrew)" $true (
        $heldThrew -ceq '' -and $ctx8.SourceCopies['audio/v16.wav'].Why -ceq 'source file audio/v16.wav could not be read back: the file is in use by another process' -and
        -not (Test-Path -LiteralPath (Join-Path $ctx8.Work $heldName)) -and -not $ctx8.Files.Contains((Join-Path $ctx8.Work $heldName)) -and
        $null -eq $ctx8.SourceCopies['audio/v24.wav'].Why -and $null -eq (Get-HarnessSourceGap -Ctx $ctx8 -Scenario @($good.Scenarios | Where-Object id -ceq 's24')[0]) -and $ctx8.Files.Count -eq 2)
    # Two names of one content share one copy: when the check of the second name fails (here its read of the copy), the
    # copy the first name made and checked stays, and only the second name's scenarios cannot run
    foreach ($n in 'pairC.wav', 'pairD.wav') { Copy-Item -LiteralPath (Join-Path $audio 'v16.wav') -Destination (Join-Path $audio $n) }
    $pair = & $conf ([ordered]@{ pc = 'audio/pairC.wav'; pd = 'audio/pairD.wav' }) @((& $render 'uc' 'pc' @{ sr = 44100 }), (& $render 'ud' 'pd' @{ sr = 44100 }))
    $pairFiles = Read-HarnessSourceFiles -Config $pair -Scenarios @($pair.Scenarios)
    $pairKeys = @($pairFiles.get_Keys())
    $sharedName = "_source-$($f16.Sha256.Substring(0, 12)).wav"
    $sharedReads = [ref]0
    $second = { param([string]$Path) if ((Split-Path -Leaf $Path) -ceq $sharedName) { $sharedReads.Value++; if ($sharedReads.Value -ge 2) { throw 'the file is in use by another process' } }; (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }.GetNewClosure()
    $ctx9 = @{ Work = (Join-Path $Tmp 'sources-work9'); Files = [Collections.Generic.List[string]]::new(); SourceCopies = @{}; Config = $pair; Kinds = @{}; Api = $null }
    $null = New-Item -ItemType Directory -Force -Path $ctx9.Work
    Invoke-WithModuleStub 'Copy-HarnessSourceFiles' 'Get-HarnessSha256' $second { Copy-HarnessSourceFiles -Ctx $ctx9 -Sources $pairFiles }
    $first = $ctx9.SourceCopies[$pairKeys[0]]; $later = $ctx9.SourceCopies[$pairKeys[1]]
    $firstSc = @($pair.Scenarios | Where-Object { (Get-HarnessScenarioSourceKeys $pair $_) -ccontains $pairKeys[0] })[0]
    & $add "source copies: a shared copy stays for the name that made and checked it when the other name's check fails ($($later.Why))" $true (
        $sharedReads.Value -eq 2 -and $pairKeys.Count -eq 2 -and $null -eq $first.Why -and (Test-Path -LiteralPath $first.Path) -and $ctx9.Files.Contains($first.Path) -and $ctx9.Files.Count -eq 1 -and
        $later.Path -ceq $first.Path -and $later.Why -ceq "source file $($pairKeys[1]) could not be read back: the file is in use by another process" -and $null -eq (Get-HarnessSourceGap -Ctx $ctx9 -Scenario $firstSc))
    # The bytes of a shared copy that are not the checked ones any more (another hash on the second name's read) are wrong
    # for every name that plays them: the copy goes, and so does the first name's use of it
    $swapReads = [ref]0
    $swapped = { param([string]$Path) if ((Split-Path -Leaf $Path) -ceq $sharedName) { $swapReads.Value++; if ($swapReads.Value -ge 2) { return ('0' * 64) } }; (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }.GetNewClosure()
    $ctx10 = @{ Work = (Join-Path $Tmp 'sources-work10'); Files = [Collections.Generic.List[string]]::new(); SourceCopies = @{}; Config = $pair; Kinds = @{}; Api = $null }
    $null = New-Item -ItemType Directory -Force -Path $ctx10.Work
    Invoke-WithModuleStub 'Copy-HarnessSourceFiles' 'Get-HarnessSha256' $swapped { Copy-HarnessSourceFiles -Ctx $ctx10 -Sources $pairFiles }
    $first10 = $ctx10.SourceCopies[$pairKeys[0]]; $later10 = $ctx10.SourceCopies[$pairKeys[1]]
    & $add "source copies: a shared copy whose bytes are not the checked ones any more is taken from every name that plays it ($($first10.Why); $($later10.Why))" $true (
        $swapReads.Value -eq 2 -and $first10.Why -ceq "the copy of source file $($pairKeys[0]) changed after it was checked" -and $later10.Why -ceq "the copy of source file $($pairKeys[1]) changed after it was checked" -and
        -not (Test-Path -LiteralPath $first10.Path) -and $ctx10.Files.Count -eq 0 -and (Get-HarnessSourceGap -Ctx $ctx10 -Scenario $firstSc) -ceq $first10.Why)
    # A third name of that content, after the copy was taken away from the first two, makes and checks a copy of its own
    foreach ($n in 'trioE.wav', 'trioF.wav', 'trioG.wav') { Copy-Item -LiteralPath (Join-Path $audio 'v16.wav') -Destination (Join-Path $audio $n) }
    $trio = & $conf ([ordered]@{ te = 'audio/trioE.wav'; tf = 'audio/trioF.wav'; tg = 'audio/trioG.wav' }) @((& $render 'ue' 'te' @{ sr = 44100 }), (& $render 'uf' 'tf' @{ sr = 44100 }), (& $render 'ug' 'tg' @{ sr = 44100 }))
    $trioFiles = Read-HarnessSourceFiles -Config $trio -Scenarios @($trio.Scenarios)
    $trioKeys = @($trioFiles.get_Keys())
    $trioReads = [ref]0
    $swapOnce = { param([string]$Path) if ((Split-Path -Leaf $Path) -ceq $sharedName) { $trioReads.Value++; if ($trioReads.Value -eq 2) { return ('0' * 64) } }; (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }.GetNewClosure()
    $ctx11 = @{ Work = (Join-Path $Tmp 'sources-work11'); Files = [Collections.Generic.List[string]]::new(); SourceCopies = @{}; Config = $trio; Kinds = @{}; Api = $null }
    $null = New-Item -ItemType Directory -Force -Path $ctx11.Work
    Invoke-WithModuleStub 'Copy-HarnessSourceFiles' 'Get-HarnessSha256' $swapOnce { Copy-HarnessSourceFiles -Ctx $ctx11 -Sources $trioFiles }
    $trioCopies = @($trioKeys | ForEach-Object { $ctx11.SourceCopies[$_] })
    $trioScenario = { param([string]$Key) @($trio.Scenarios | Where-Object { (Get-HarnessScenarioSourceKeys $trio $_) -ccontains $Key })[0] }
    & $add "source copies: after a shared copy was taken away, a later name of that content makes and checks its own ($(@($trioCopies | ForEach-Object { if ($_.Why) { $_.Why } else { 'ok' } }) -join '; '))" $false (
        $trioReads.Value -eq 3 -and $trioKeys.Count -eq 3 -and $trioCopies[0].Why -ceq "the copy of source file $($trioKeys[0]) changed after it was checked" -and
        $trioCopies[1].Why -ceq "the copy of source file $($trioKeys[1]) changed after it was checked" -and $null -eq $trioCopies[2].Why -and (Test-Path -LiteralPath $trioCopies[2].Path) -and
        $ctx11.Files.Count -eq 1 -and $ctx11.Files.Contains($trioCopies[2].Path) -and $null -eq (Get-HarnessSourceGap -Ctx $ctx11 -Scenario (& $trioScenario $trioKeys[2])) -and
        $null -ne (Get-HarnessSourceGap -Ctx $ctx11 -Scenario (& $trioScenario $trioKeys[0])))
    # Before the start, header and hash are two reads of the file: a file that cannot be read for its hash is one more problem
    # of the one usage error, not an error of its own
    $lockedSource = { param([string]$Path) if ((Split-Path -Leaf $Path) -ceq 'v16.wav') { throw 'the file is in use by another process' }; (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    $lockedMsg = try { $null = Invoke-WithModuleStub 'Read-HarnessSourceFiles' 'Get-HarnessSha256' $lockedSource { Read-HarnessSourceFiles -Config $good -Scenarios $picked }; 'accepted' } catch { $_.Exception.Message }
    & $add "sources: a file that cannot be read for its hash after its header is one more problem of the usage error ($lockedMsg)" $true (
        $lockedMsg -clike 'USAGE: sources: *' -and $lockedMsg -clike '*source audio/v16.wav cannot be used: the file is in use by another process*')
    # Two names of one content share one copy; when the first of them changed, the second still makes it
    foreach ($n in 'twinA.wav', 'twinB.wav') { Copy-Item -LiteralPath (Join-Path $audio 'v16.wav') -Destination (Join-Path $audio $n) }
    $twins = & $conf ([ordered]@{ ta = 'audio/twinA.wav'; tb = 'audio/twinB.wav' }) @((& $render 'ua' 'ta' @{ sr = 44100 }), (& $render 'ub' 'tb' @{ sr = 44100 }))
    $twinFiles = Read-HarnessSourceFiles -Config $twins -Scenarios @($twins.Scenarios)
    & $wav 'twinA.wav' 44100 1 'pcm16' 999
    $ctx6 = @{ Work = (Join-Path $Tmp 'sources-work6'); Files = [Collections.Generic.List[string]]::new(); SourceCopies = @{}; Config = $twins; Kinds = @{}; Api = $null }
    $null = New-Item -ItemType Directory -Force -Path $ctx6.Work
    Copy-HarnessSourceFiles -Ctx $ctx6 -Sources $twinFiles
    $tb = $ctx6.SourceCopies['audio/twinB.wav']
    & $add 'source copies: two names of one content share a copy; when the first has changed since the check, the second still gets its own' $false (
        $ctx6.SourceCopies['audio/twinA.wav'].Why -ceq 'source file audio/twinA.wav changed since it was checked' -and $null -eq $tb.Why -and (Test-Path -LiteralPath $tb.Path) -and
        (Get-FileHash -LiteralPath $tb.Path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $twinFiles['audio/twinB.wav'].Sha256 -and $ctx6.Files.Count -eq 1)
    # A read-only file of the configuration: its copy can be written over and deleted like any work file
    $ro = Join-Path $audio 'ro.wav'
    Copy-Item -LiteralPath (Join-Path $audio 'v24.wav') -Destination $ro
    [IO.File]::SetAttributes($ro, [IO.FileAttributes]::ReadOnly)
    $ctx7 = @{ Work = (Join-Path $Tmp 'sources-work7'); Files = [Collections.Generic.List[string]]::new(); SourceCopies = @{}; Config = $null; Kinds = @{}; Api = $null }
    $null = New-Item -ItemType Directory -Force -Path $ctx7.Work
    try {
        $roConf = & $conf ([ordered]@{ ro = 'audio/ro.wav' }) @((& $render 'r' 'ro'))
        $ctx7.Config = $roConf
        Copy-HarnessSourceFiles -Ctx $ctx7 -Sources (Read-HarnessSourceFiles -Config $roConf -Scenarios @($roConf.Scenarios))
        $roCopy = $ctx7.SourceCopies['audio/ro.wav'].Path
        $roAttributes = [IO.File]::GetAttributes($roCopy)
    } finally {
        [IO.File]::SetAttributes($ro, [IO.FileAttributes]::Normal)
        foreach ($c in @(Get-ChildItem -LiteralPath $ctx7.Work -File)) { [IO.File]::SetAttributes($c.FullName, [IO.FileAttributes]::Normal) }
    }
    & $add 'source copies: the copy of a read-only file is not read-only, so the cleanup of a green round deletes it' $false (
        $null -eq $ctx7.SourceCopies['audio/ro.wav'].Why -and -not ($roAttributes -band [IO.FileAttributes]::ReadOnly))
    # 600 s is the most a file may be: exactly 600 s is fine, one frame more is not
    & $wav 'edge.wav' 8000 1 'pcm16' (600 * 8000); & $wav 'over.wav' 8000 1 'pcm16' (600 * 8000 + 1)
    $edges = & $conf ([ordered]@{ edge = 'audio/edge.wav'; over = 'audio/over.wav' }) @((& $render 'at' 'edge' @{ sr = 8000 }), (& $render 'past' 'over' @{ sr = 8000 }))
    $msg = try { $null = Read-HarnessSourceFiles -Config $edges -Scenarios @($edges.Scenarios); 'accepted' } catch { $_.Exception.Message }
    & $add "sources: a file of exactly 600 s is accepted, one frame more is refused ($msg)" $true ($msg -ceq 'USAGE: sources: 1 problem(s): source audio/over.wav is longer than 600 s')
    $cases
}

# ---------------------------------------------------------------- kept renders
function Get-RenderCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $root = Join-Path $Tmp 'kept-renders'
    $put = { param([string]$FileRel, [string]$FileText) $p = Join-Path $root $FileRel; $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p); [IO.File]::WriteAllText($p, $FileText) }
    $c1 = '0123456789abcdef0123456789abcdef01234567'
    $c2 = 'fedcba9876543210fedcba9876543210fedcba98'
    # The commit of the harness, read from .git without running git
    & $put 'detached/.git/HEAD' "$c1`n"
    & $put 'loose/.git/HEAD' "ref: refs/heads/main`n"; & $put 'loose/.git/refs/heads/main' "$c2`n"
    & $put 'packed/.git/HEAD' "ref: refs/heads/feat/x`n"
    & $put 'packed/.git/packed-refs' "# pack-refs with: peeled fully-peeled sorted`n$c1 refs/heads/other`n$c2 refs/heads/feat/x`n^$c1`n"
    & $put 'main/.git/HEAD' "ref: refs/heads/main`n"; & $put 'main/.git/refs/heads/topic' "$c1`n"
    & $put 'main/.git/worktrees/w/HEAD' "ref: refs/heads/topic`n"; & $put 'main/.git/worktrees/w/commondir' "../..`n"
    & $put 'wt/.git' "gitdir: $(Join-Path $root 'main/.git/worktrees/w')`n"
    & $put 'wt-rel/.git' "gitdir: ../main/.git/worktrees/w`n"
    $commit = { param([string]$DirRel) Get-HarnessGitCommit (Join-Path $root $DirRel) }
    & $add 'tool commit: a detached HEAD, a branch as a loose ref and a branch only in packed-refs are read without running git' $false (
        (& $commit 'detached') -ceq $c1 -and (& $commit 'loose') -ceq $c2 -and (& $commit 'packed') -ceq $c2)
    & $add 'tool commit: a worktree (.git is a gitdir: file, absolute or relative) finds its branch through commondir' $false ((& $commit 'wt') -ceq $c1 -and (& $commit 'wt-rel') -ceq $c1)
    & $put 'g-head/.git/HEAD' "not a ref`n"
    & $put 'g-upper/.git/HEAD' "$($c1.ToUpperInvariant())`n"
    & $put 'g-short/.git/HEAD' "$($c1.Substring(1))`n"
    & $put 'g-noref/.git/HEAD' "ref: refs/heads/gone`n"
    & $put 'g-escape/.git/HEAD' "ref: refs/../../../detached/.git/HEAD`n"
    & $put 'g-badref/.git/HEAD' "ref: refs/heads/main`n"; & $put 'g-badref/.git/refs/heads/main' "$($c1.Substring(2)) and more`n"
    & $put 'g-badpack/.git/HEAD' "ref: refs/heads/main`n"; & $put 'g-badpack/.git/packed-refs' "$($c1.ToUpperInvariant()) refs/heads/main`n"
    & $put 'g-file/.git' "nonsense`n"
    & $put 'g-gone/.git' "gitdir: ../nowhere/.git`n"
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'g-none')
    $got = @(foreach ($g in 'g-head', 'g-upper', 'g-short', 'g-noref', 'g-escape', 'g-badref', 'g-badpack', 'g-file', 'g-gone', 'g-none') { try { $v = & $commit $g; if ($null -ne $v) { "${g}: $v" } } catch { "${g} threw" } })
    & $add "tool commit: anything unexpected gives null, never an error or a path ($($got -join ', '))" $true ($got.Count -eq 0)
    $tv = Get-HarnessToolVersion
    & $add "tool version: one constant, and the commit of this checkout or null ($($tv.version), $($tv.commit))" $false (
        $tv.version -ceq '0.1.0' -and ($null -eq $tv.commit -or $tv.commit -cmatch '^[0-9a-f]{40}$') -and $tv.commit -ceq (Get-HarnessGitCommit $RepoRoot))

    # Moving one file: only under the result directory, never over another file
    $res = Join-Path $root 'results'
    $null = New-Item -ItemType Directory -Force -Path $res
    $w1 = Join-Path $root 'w1.wav'; [IO.File]::WriteAllText($w1, 'first')
    $dest = Join-Path $res 'renders/s/run1/a.wav'
    $m1 = Move-HarnessKeptFile -From $w1 -To $dest -ResultDir $res
    & $add 'keep: a render moves to its place under the result directory, the directories made on the way' $false ($null -eq $m1 -and -not (Test-Path -LiteralPath $w1) -and [IO.File]::ReadAllText($dest) -ceq 'first')
    $w2 = Join-Path $root 'w2.wav'; [IO.File]::WriteAllText($w2, 'second')
    $m2 = Move-HarnessKeptFile -From $w2 -To $dest -ResultDir $res
    & $add "keep: a file already at the place is never overwritten: the reason names it, both files stay as they were ($m2)" $true (
        $m2 -ceq 'a.wav is there already and is never overwritten' -and [IO.File]::ReadAllText($dest) -ceq 'first' -and [IO.File]::ReadAllText($w2) -ceq 'second')
    $m3 = Move-HarnessKeptFile -From $w2 -To (Join-Path $res '../escaped.wav') -ResultDir $res
    $elsewhere = Join-Path $root 'elsewhere'
    $null = New-Item -ItemType Directory -Force -Path $elsewhere
    $link = Join-Path $res 'renders/linked'
    $null = New-Item -ItemType Junction -Path $link -Target $elsewhere
    try { $m4 = Move-HarnessKeptFile -From $w2 -To (Join-Path $link 'run1/b.wav') -ResultDir $res } finally { [IO.Directory]::Delete($link) } # removes the link only
    & $add "keep: a place outside the result directory, by its path or through a junction, is refused and nothing moves ($m3; $m4)" $true (
        $m3 -ceq 'escaped.wav would not be under the result directory' -and $m4 -ceq 'b.wav would not be under the result directory' -and (Test-Path -LiteralPath $w2) -and
        -not (Test-Path -LiteralPath (Join-Path $root 'escaped.wav')) -and @(Get-ChildItem -LiteralPath $elsewhere -Recurse).Count -eq 0)

    # What a kept file is said to be
    $kf = Join-Path $root 'facts.wav'
    [HarnessWav]::Write($kf, 48000, 2, 'float32', $false, [double[]]@(0.5, -0.25, [double]::NaN, 0, [double]::PositiveInfinity, [double]::NegativeInfinity))
    $f = Get-HarnessKeptFileFacts $kf 'run1/facts.wav'
    $silent = Join-Path $root 'silent.wav'
    [HarnessWav]::Write($silent, 44100, 1, 'pcm16', $false, [double[]]::new(10))
    $sf = Get-HarnessKeptFileFacts $silent 'run1/silent.wav'
    $nf = Get-HarnessKeptFileFacts (Join-Path $root 'not-there.wav') ''
    & $add 'keep: a kept file is described by its header and its samples: peak over the finite samples, NaN and Inf counted; silence has no peak; nothing kept, nothing known' $false (
        $f.path -ceq 'run1/facts.wav' -and $f.sha256 -ceq (Get-FileHash -LiteralPath $kf -Algorithm SHA256).Hash.ToLowerInvariant() -and $f.frames -eq 3 -and $f.channels -eq 2 -and $f.sampleRate -eq 48000 -and
        $f.format -ceq 'float32' -and [Math]::Abs($f.peakDb - 20 * [Math]::Log10(0.5)) -lt 1e-5 -and $f.nanCount -eq 1 -and $f.infCount -eq 2 -and
        $null -eq $sf.peakDb -and $sf.nanCount -eq 0 -and $sf.infCount -eq 0 -and $sf.frames -eq 10 -and $sf.format -ceq 'pcm16' -and @($nf.get_Values() | Where-Object { $null -ne $_ }).Count -eq 0)

    # One scenario kept: with no render, with its render and stem, and by a run of the same second
    $raw = [ordered]@{
        schema = 1; name = 'keep'; plugins = [ordered]@{ gain = [ordered]@{ bundle = 'G.vst3' } }
        layouts = [ordered]@{ one = [ordered]@{ tracks = @([ordered]@{ name = 'Tone'; source = $true; fx = @([ordered]@{ plugin = 'gain' }) }) } }
        scenarios = @([ordered]@{ id = 'gone'; kind = 'render'; layout = 'one'; keep = $true; stems = @('Tone'); matrix = [ordered]@{ block = @(256) } })
    }
    $cr = Test-HarnessConfigData -Raw (ConvertFrom-HarnessJson (ConvertTo-HarnessJsonText -Value $raw))
    $cfg = $cr.Config | Add-Member -NotePropertyName ConfigDir -NotePropertyValue $root -PassThru
    $work = Join-Path $root 'work'
    $null = New-Item -ItemType Directory -Force -Path $work
    $ctx = New-HarnessContext -ReaperExe 'stand-in' -WorkDir $work -Driver 'x' -Config $cfg -Locks @('Local\x')
    $sc = @($cfg.Scenarios)[0]
    $stamp = '20260101-000000'
    $keep = New-HarnessKeep -ResultDir $res -Stamp $stamp -Run ([ordered]@{ reaper = '7.0'; toolVersion = '0.1.0' })
    $manifest = Join-Path $res "renders/$stamp/manifest.jsonl"
    $k1 = Save-HarnessKeptRender -Keep $keep -Ctx $ctx -Scenario $sc -Round 1 -Status 'FAIL' -Detail 'the render failed'
    $l1 = @([IO.File]::ReadAllLines($manifest))
    $e1 = ConvertFrom-HarnessJson $l1[0]
    & $add 'keep: no render file: nothing moves, the status stays, and the manifest gets its line at once, saying how the scenario ended and the id it was written with' $false (
        $e1['scenario'] -ceq 'gone-256' -and $e1['baseScenario'] -ceq 'gone' -and $e1['render']['block'] -eq 256 -and $k1.Status -ceq 'FAIL' -and $k1.Detail -ceq 'the render failed' -and $l1.Count -eq 1 -and $e1['status'] -ceq 'FAIL' -and $e1['detail'] -ceq 'the render failed' -and $e1['round'] -eq 1 -and
        $null -eq $e1['output']['path'] -and $e1['stems'][0]['track'] -ceq 'Tone' -and $null -eq $e1['stems'][0]['path'] -and $e1['reaper'] -ceq '7.0' -and
        @(Get-ChildItem -LiteralPath (Join-Path $res "renders/$stamp") -Recurse -File).Count -eq 1)
    $mk = { foreach ($n in 'gone-256-stem-Master.wav', 'gone-256-stem-Tone.wav', '_dry-48000-2.wav') { $p = Join-Path $work $n; [HarnessWav]::Write($p, 48000, 2, 'float32', $false, [double[]]@(0.25, 0.25)); if (-not $ctx.Files.Contains($p)) { $ctx.Files.Add($p) } } }
    & $mk
    $k2 = Save-HarnessKeptRender -Keep $keep -Ctx $ctx -Scenario $sc -Round 2 -Status 'PASS' -Detail 'ok'
    $l2 = @([IO.File]::ReadAllLines($manifest))
    $e2 = ConvertFrom-HarnessJson $l2[1]
    $keptMaster = Join-Path $res "renders/$stamp/run2/gone-256.wav"
    & $add 'keep: the master of a render with stems is kept as run<k>/<id>.wav, its stems as run<k>/<id>-stem-<track>.wav; they leave the files a green round deletes, a reference stays' $false (
        $k2.Status -ceq 'PASS' -and (Test-Path -LiteralPath $keptMaster) -and (Test-Path -LiteralPath (Join-Path $res "renders/$stamp/run2/gone-256-stem-Tone.wav")) -and
        -not (Test-Path -LiteralPath (Join-Path $work 'gone-256-stem-Master.wav')) -and $ctx.Files.Count -eq 1 -and $ctx.Files[0] -clike '*_dry-48000-2.wav' -and (Test-Path -LiteralPath $ctx.Files[0]) -and
        $l2.Count -eq 2 -and $e2['round'] -eq 2 -and $e2['output']['path'] -ceq 'run2/gone-256.wav' -and $e2['output']['sha256'] -ceq (Get-FileHash -LiteralPath $keptMaster -Algorithm SHA256).Hash.ToLowerInvariant() -and
        $e2['stems'][0]['path'] -ceq 'run2/gone-256-stem-Tone.wav')
    $rowFacts = ConvertTo-HarnessKeptFacts $k2.Record $keep.Rel
    & $add 'keep: the row repeats the line with its paths relative to the result directory, the line itself unchanged' $false (
        $rowFacts['output']['path'] -ceq "renders/$stamp/run2/gone-256.wav" -and $rowFacts['stems'][0]['path'] -ceq "renders/$stamp/run2/gone-256-stem-Tone.wav" -and $k2.Record['output']['path'] -ceq 'run2/gone-256.wav')
    & $mk
    $again = New-HarnessKeep -ResultDir $res -Stamp $stamp
    $k3 = Save-HarnessKeptRender -Keep $again -Ctx $ctx -Scenario $sc -Round 1 -Status 'PASS'
    $k4 = Save-HarnessKeptRender -Keep $again -Ctx $ctx -Scenario $sc -Round 1 -Status 'FAIL'
    & $add "keep: a run that finds the manifest of its second there already keeps nothing and writes no line: INCOMPLETE, a FAIL stays FAIL ($($k3.Detail))" $true (
        $k3.Status -ceq 'INCOMPLETE' -and $k3.Detail -clike "; not kept: renders/$stamp/manifest.jsonl is there already*" -and $k4.Status -ceq 'FAIL' -and $k4.Detail -clike '*not kept: *' -and
        @([IO.File]::ReadAllLines($manifest)).Count -eq 2 -and (Test-Path -LiteralPath (Join-Path $work 'gone-256-stem-Master.wav')) -and -not (Test-Path -LiteralPath (Join-Path $res "renders/$stamp/run1/gone-256.wav")) -and $ctx.Files.Count -eq 3)

    # renders/ leading out of the result directory through a junction: the directory of the run is checked before anything
    # is made in it, so nothing (no directory, no manifest, no render) gets there
    $linkedRes = Join-Path $root 'results-linked'
    $outside = Join-Path $root 'renders-elsewhere'
    $null = New-Item -ItemType Directory -Force -Path $linkedRes, $outside
    $null = New-Item -ItemType Junction -Path (Join-Path $linkedRes 'renders') -Target $outside
    try {
        & $mk
        $kl = Save-HarnessKeptRender -Keep (New-HarnessKeep -ResultDir $linkedRes -Stamp $stamp) -Ctx $ctx -Scenario $sc -Round 1 -Status 'PASS' -Detail 'ok'
        $leftOutside = @(Get-ChildItem -LiteralPath $outside -Recurse -Force).Count
    } finally { [IO.Directory]::Delete((Join-Path $linkedRes 'renders')) } # removes the link only
    & $add "keep: renders/ leading out of the result directory through a junction: nothing is made there, nothing moves, no line is written, INCOMPLETE ($($kl.Detail))" $true (
        $kl.Status -ceq 'INCOMPLETE' -and $kl.Detail -ceq "ok; not kept: renders/$stamp would not be under the result directory" -and $leftOutside -eq 0 -and
        (Test-Path -LiteralPath (Join-Path $work 'gone-256-stem-Master.wav')) -and $null -ne $kl.Record -and $null -eq $kl.Record['output']['path'])
    # Junctions in a circle: a real path that cannot be read proves nothing. At the claim nothing of the run is kept, also
    # by the scenarios after it; at one place that file stays where it is and the line is still written.
    $circle = {
        param([string]$LinkA, [string]$LinkB)
        $null = New-Item -ItemType Directory -Force -Path $LinkB
        $null = New-Item -ItemType Junction -Path $LinkA -Target $LinkB
        [IO.Directory]::Delete($LinkB)
        $null = New-Item -ItemType Junction -Path $LinkB -Target $LinkA
    }
    $loopRes = Join-Path $root 'results-loop'
    & $circle (Join-Path $loopRes 'renders') (Join-Path $loopRes 'loop')
    try {
        $loopKeep = New-HarnessKeep -ResultDir $loopRes -Stamp $stamp
        $kc = @(foreach ($n in 1, 2) { Save-HarnessKeptRender -Keep $loopKeep -Ctx $ctx -Scenario $sc -Round $n -Status 'PASS' -Detail 'ok' })
    } finally { foreach ($j in 'renders', 'loop') { [IO.Directory]::Delete((Join-Path $loopRes $j)) } }
    & $add "keep: renders/ whose real path cannot be read (junctions in a circle) is refused for the whole run: INCOMPLETE, a line for none ($(Hide-HarnessPaths $kc[0].Detail))" $true (
        @($kc | Where-Object { $_.Status -cne 'INCOMPLETE' -or $_.Detail -cnotlike "ok; not kept: renders/$stamp cannot be shown to be under the result directory: *" }).Count -eq 0 -and
        (Test-Path -LiteralPath (Join-Path $work 'gone-256-stem-Master.wav')) -and $kc.Count -eq 2)
    $runLoop = Join-Path $res "renders/$stamp/run7"
    & $circle $runLoop (Join-Path $res "renders/$stamp/loop7")
    try { & $mk; $kr = Save-HarnessKeptRender -Keep $keep -Ctx $ctx -Scenario $sc -Round 7 -Status 'PASS' -Detail 'ok' }
    finally { foreach ($j in $runLoop, (Join-Path $res "renders/$stamp/loop7")) { [IO.Directory]::Delete($j) } }
    $lr = @([IO.File]::ReadAllLines($manifest))
    & $add "keep: a place whose real path cannot be read is refused like one outside, and the line is still written ($(Hide-HarnessPaths $kr.Detail))" $true (
        $kr.Status -ceq 'INCOMPLETE' -and $kr.Detail -clike 'ok; not kept: gone-256.wav cannot be shown to be under the result directory: *; gone-256-stem-Tone.wav cannot be shown to be under the result directory: *' -and
        $lr.Count -eq 3 -and (ConvertFrom-HarnessJson $lr[2])['round'] -eq 7 -and (Test-Path -LiteralPath (Join-Path $work 'gone-256-stem-Master.wav')))
    # A kept file whose hash cannot be taken (a scanner holding it right after the move): its line is still written, the
    # stems after it are still kept, and the row is INCOMPLETE with the reason
    & $mk
    $holding = { param([string]$Path) if ($Path -clike '*run3?gone-256.wav') { throw 'the file is in use by another process' }; (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    $kh = Invoke-WithModuleStub 'Save-HarnessKeptRender' 'Get-HarnessSha256' $holding { Save-HarnessKeptRender -Keep $keep -Ctx $ctx -Scenario $sc -Round 3 -Status 'PASS' -Detail 'ok' }
    $lh = @([IO.File]::ReadAllLines($manifest))
    $eh = ConvertFrom-HarnessJson $lh[-1]
    & $add "keep: a kept file that cannot be read keeps its line and the stems after it: INCOMPLETE with the reason ($($kh.Detail))" $true (
        $kh.Status -ceq 'INCOMPLETE' -and $kh.Detail -ceq 'ok; kept, but gone-256.wav could not be read: the file is in use by another process' -and $lh.Count -eq 4 -and $eh['round'] -eq 3 -and $eh['status'] -ceq 'INCOMPLETE' -and
        $eh['output']['path'] -ceq 'run3/gone-256.wav' -and $null -eq $eh['output']['sha256'] -and $null -eq $eh['output']['frames'] -and $eh['stems'][0]['path'] -ceq 'run3/gone-256-stem-Tone.wav' -and
        $eh['stems'][0]['sha256'] -cmatch '^[0-9a-f]{64}$' -and (Test-Path -LiteralPath (Join-Path $res "renders/$stamp/run3/gone-256.wav")) -and -not (Test-Path -LiteralPath (Join-Path $work 'gone-256-stem-Tone.wav')))
    # Local paths: an exception text in the detail, a name a plugin reported. The line is masked as a whole, and the row's
    # copy of it with it
    & $mk
    $gainVariant = $cfg.Layouts['one'].Tracks[0].Fx[0].Variant
    $ctx.LearnReads[$gainVariant] = [pscustomobject]@{ Name = 'VST3: G (D:\Plug-ins\G.vst3)'; Pdc = '0'; Params = [ordered]@{}; Sr = 48000; Block = 512 }
    $km = Save-HarnessKeptRender -Keep $keep -Ctx $ctx -Scenario $sc -Round 4 -Status 'PASS' -Detail "ok; it threw: Could not find a part of the path 'C:\audio work\x.wav'."
    $ctx.LearnReads.Remove($gainVariant)
    $lm = @([IO.File]::ReadAllLines($manifest))[-1]
    $em = ConvertFrom-HarnessJson $lm
    $rowCopy = ConvertTo-HarnessJsonText -Value (ConvertTo-HarnessKeptFacts $km.Record $keep.Rel)
    & $add "keep: a local path in a detail or in a name a plugin reported is masked in the manifest line and in the row's copy of it ($($em['detail']); $($em['fx'][0]['name']))" $true (
        $em['round'] -eq 4 -and $lm -cnotmatch '[A-Za-z]:[\\/]' -and $rowCopy -cnotmatch '[A-Za-z]:[\\/]' -and $em['detail'] -ceq "ok; it threw: Could not find a part of the path '<path>'." -and $em['fx'][0]['name'] -clike 'VST3: G (<path>*' -and
        $km.Record['detail'] -ceq $em['detail'])
    # A line a write that failed left unfinished stays as it is, on a line of its own; the next one starts after it
    [IO.File]::AppendAllText($manifest, '{"schema":1,"cut')
    & $mk
    $kn = Save-HarnessKeptRender -Keep $keep -Ctx $ctx -Scenario $sc -Round 5 -Status 'PASS' -Detail 'ok'
    $ln = @([IO.File]::ReadAllLines($manifest))
    & $add 'keep: a line an earlier write left unfinished stays on a line of its own, and the next line starts after it' $false (
        $kn.Status -ceq 'PASS' -and $ln.Count -eq 7 -and $ln[5] -ceq '{"schema":1,"cut' -and $(try { (ConvertFrom-HarnessJson $ln[6])['round'] -eq 5 } catch { $false }))
    # What was kept but cannot be described makes a PASS INCOMPLETE (above); a FAIL stays FAIL, and says so
    & $mk
    $holdingSix = { param([string]$Path) if ($Path -clike '*run6?gone-256.wav') { throw 'the file is in use by another process' }; (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    $keptFail = Invoke-WithModuleStub 'Save-HarnessKeptRender' 'Get-HarnessSha256' $holdingSix { Save-HarnessKeptRender -Keep $keep -Ctx $ctx -Scenario $sc -Round 6 -Status 'FAIL' -Detail 'differs' }
    & $add "keep: a FAIL whose kept file cannot be read stays FAIL, its detail saying what was not read ($($keptFail.Detail))" $true (
        $keptFail.Status -ceq 'FAIL' -and $keptFail.Detail -ceq 'differs; kept, but gone-256.wav could not be read: the file is in use by another process')
    $cases
}

# ---------------------------------------------------------------- plugin states
function Get-StateCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $cid = '5A1B2C3D4E5F60718293A4B5C6D7E8F9'
    $hdr = { param($rename = '""', $name = 'VST3: Fixture Gain (Fixture Audio)', $c = $cid) "<VST `"$name`" `"Fixture Gain.vst3`" 0 $rename 1234567890{$c} `"`"" }
    $vst = { param($body, $h = (& $hdr)) "      BYPASS 0 0 0`n      $h`n        $body`n      >`n      FLOATPOS 0 0 0 0`n      FXID {X}`n" }
    $js = "      BYPASS 0 0 0`n      <JS loudness_meter `"`"`n        0 0 -`n      >`n"
    $track = { param([string]$NameLine, [string]$Chain, [string]$Extra = '') "  <TRACK {G}`n    $NameLine`n    VOLPAN 1 0 -1 -1 1`n$Extra    <FXCHAIN`n      SHOW 0`n$Chain    >`n  >`n" }
    $proj = { param([string[]]$Parts) "<REAPER_PROJECT 0.1 `"7.82/win64`" 1`n  RIPPLE 0`n" + ($Parts -join '') + ">`n" }
    $pick = { param($text, $name, $n) Get-HarnessTemplateFxBlock -Text $text -Track $name -Fx $n }
    # Templates: the n-th FX of the one track of that name
    $t1 = & $proj @((& $track 'NAME Lead' ($js + (& $vst 'B2'))), (& $track 'NAME "Lead vocal"' (& $vst 'LV')))
    $b = & $pick $t1 'Lead' 2
    & $add 'template: FX 2 of the track is taken (FX are counted like REAPER counts them, a JSFX included); an unquoted name is matched' $false ($b.Problem -eq '' -and $b.Lines.Count -eq 3 -and $b.Lines[0] -ceq (& $hdr) -and $b.Lines[1] -ceq 'B2')
    & $add 'template: a quoted track name with a space is matched exactly' $false ((& $pick $t1 'Lead vocal' 1).Lines[1] -ceq 'LV')
    & $add 'template: an FX that is not a VST3 plugin is a problem' $true ((& $pick $t1 'Lead' 1).Problem -ceq "FX 1 of track 'Lead' is a JS block, not a VST3 plugin")
    & $add 'template: an FX number beyond the chain is a problem' $true ((& $pick $t1 'Lead' 3).Problem -ceq "track 'Lead' has 2 FX, not 3")
    & $add 'template: a track name matches whole, case and all' $true ((& $pick $t1 'lead' 1).Problem -ceq "has no track named 'lead'")
    $t2 = & $proj @((& $track 'NAME Lead' (& $vst 'A')), (& $track 'NAME Lead' (& $vst 'B')))
    & $add 'template: two tracks of that name make the state ambiguous: a problem' $true ((& $pick $t2 'Lead' 1).Problem -ceq "has 2 tracks named 'Lead'; the state is ambiguous")
    $t3 = & $proj @((& $track 'NAME Other' (& $vst 'O') "    <ITEM`n      NAME Lead`n      <SOURCE WAVE`n        FILE `"x.wav`"`n      >`n    >`n"))
    & $add 'template: the name of an item on another track is not a track name' $true ((& $pick $t3 'Lead' 1).Problem -ceq "has no track named 'Lead'")
    $t4 = & $proj @((& $track 'NAME Lead' ("      BYPASS 0 0 0`n      <CONTAINER Container `"`"`n" + (& $vst 'INSIDE') + "      >`n" + (& $vst 'AFTER'))))
    & $add 'template: a container counts as one FX; the plugin after it is FX 2, not one inside it' $false ((& $pick $t4 'Lead' 2).Lines[1] -ceq 'AFTER' -and (& $pick $t4 'Lead' 1).Problem -like '*is a CONTAINER block*')
    # State files: exactly one plugin block at the top level (FX chain files have BYPASS, FLOATPOS, FXID, WAK around it)
    $chainFile = "BYPASS 0 0 0`n$(& $hdr)`n  S`n>`nFLOATPOS 0 0 0 0`nFXID {X}`nWAK 0 0`n"
    $sf = Get-HarnessStateFileBlock $chainFile
    & $add 'state file: an FX chain file with one plugin gives its block' $false ($sf.Problem -eq '' -and ($sf.Lines -join '|') -ceq "$(& $hdr)|S|>")
    & $add 'state file: two plugin blocks are a problem' $true ((Get-HarnessStateFileBlock ($chainFile + $chainFile)).Problem -like 'holds 2 plugin blocks at its top level, expected 1*')
    & $add 'state file: the plugin data alone, without its block, is refused' $true ((Get-HarnessStateFileBlock "AAAAQUJDRA==`nRUZHSA==`n").Problem -like 'holds 0 plugin blocks*')
    & $add 'state file: a JSFX block is not a VST3 state' $true ((Get-HarnessStateFileBlock "<JS a.jsfx `"`"`n  0`n>`n").Problem -ceq 'holds a JS block, not a VST3 plugin')
    & $add 'state file: a block that is not closed is a problem' $true ((Get-HarnessStateFileBlock "$(& $hdr)`n  S`n").Problem -ceq 'has a block that is not closed')
    & $add 'state file: a closing line without a block is a problem' $true ((Get-HarnessStateFileBlock ">`n$chainFile").Problem -ceq 'has a ">" without a block')
    # The block header: a custom FX name is emptied (it would change the name REAPER shows); the rest stays
    $h1 = Read-HarnessStateHeader @((& $hdr '"Loud one"'), 'S', '>')
    & $add 'state header: a custom FX name is emptied; name, class ID and the rest of the block are kept' $false ($h1.Problem -eq '' -and $h1.Lines[0] -ceq (& $hdr) -and $h1.Lines[1] -ceq 'S' -and $h1.Name -ceq 'VST3: Fixture Gain (Fixture Audio)' -and $h1.Cid -ceq $cid)
    & $add 'state header: a custom name holding a double quote (REAPER quotes it with '') is emptied too' $false ((Read-HarnessStateHeader @((& $hdr "'say `"hi`"'"), 'S', '>')).Lines[0] -ceq (& $hdr))
    & $add 'state header: a block without a custom name is kept as it is' $false ((Read-HarnessStateHeader @((& $hdr), 'S', '>')).Lines[0] -ceq (& $hdr))
    & $add 'state header: a VST2 block is not a VST3 state' $true ((Read-HarnessStateHeader @((& $hdr '""' 'VST: Old (Vendor)'), 'S', '>')).Problem -like '*not a VST3 plugin block*')
    $info = [pscustomobject]@{ Name = 'Fixture Gain'; Vendor = 'Fixture Audio'; Cid = $cid }
    & $add 'state header: the block of the plugin described by moduleinfo matches' $false ((Test-HarnessStateHeader -State $h1 -Info $info) -eq '')
    & $add 'state header: the block of another plugin (name) does not match' $true ((Test-HarnessStateHeader -State $h1 -Info ([pscustomobject]@{ Name = 'Fixture Bus'; Vendor = 'Fixture Audio'; Cid = $cid })) -like "the block is of 'VST3: Fixture Gain (Fixture Audio)', the plugin is 'VST3: Fixture Bus (Fixture Audio)'")
    & $add 'state header: a block with another class ID does not match' $true ((Test-HarnessStateHeader -State $h1 -Info ([pscustomobject]@{ Name = 'Fixture Gain'; Vendor = 'Fixture Audio'; Cid = '0123456789ABCDEF0123456789ABCDEF' })) -like '*class ID*')
    $sha = Get-HarnessBlockSha @('a', 'b')
    & $add 'state hash: sha256 of the block lines; any change of a line changes it' $false ($sha -cmatch '^[0-9a-f]{64}$' -and $sha -ceq (Get-HarnessBlockSha @('a', 'b')) -and $sha -cne (Get-HarnessBlockSha @('a', 'c')))
    # The states of the fixture configuration
    $configFile = Join-Path $RepoRoot 'tests/fixtures/config.json'
    $kinds = (Import-HarnessExtensions (Read-HarnessConfigExtensions $configFile)).Kinds
    $read = { param([scriptblock]$Edit = { param($c) }) $c = Read-HarnessConfig -Path $configFile -Kinds $kinds; & $Edit $c; Read-HarnessStates -Config $c }
    $st = & $read
    & $add 'states: the fixture template block (track Lead, FX 1) and the state file block (custom name emptied) are read, each with a 12-digit hash' $false (
        (@($st.get_Keys()) -join ',') -ceq 'gain@quiet,gain@loud' -and $st['gain@quiet'].Lines[1] -ceq 'FAKESTATE VHJpbT0wLjI1Ow==' -and $st['gain@loud'].Lines[0] -ceq (& $hdr) -and
        $st['gain@loud'].Lines[1] -ceq 'FAKESTATE VHJpbT0xOw==' -and $st['gain@quiet'].Sha -cmatch '^[0-9a-f]{12}$' -and $st['gain@quiet'].Sha -cne $st['gain@loud'].Sha -and $st['gain@loud'].Cid -ceq $cid)
    & $add 'states: a template state keeps the name of the track it came from (the learn project names its track so); a state file has none' $false (
        $st['gain@quiet'].Track -ceq 'Lead' -and $st['gain@loud'].Track -ceq '')
    $msg = { param([scriptblock]$Edit) try { $null = & $read $Edit; '' } catch { $_.Exception.Message } }
    $out = & $msg { param($c) $c.Plugins['gain'].States['quiet'].Template = '../config.json' }
    & $add "states: a path outside the configuration's directory is a usage error ($out)" $true ($out -like 'USAGE: states: *plugins.gain.states.quiet*')
    $out = & $msg { param($c) $c.Plugins['gain'].States['loud'].StateFile = 'states/none.RfxChain' }
    & $add "states: a missing file is a usage error ($out)" $true ($out -like 'USAGE: states: *plugins.gain.states.loud*')
    $out = & $msg { param($c) $c.Plugins['gain'].States['quiet'].Track = 'Nobody'; $c.Plugins['gain'].States['loud'].StateFile = 'states/template.rpp' }
    & $add "states: every problem is listed at once; a problem names file, track and FX number, never the content ($out)" $true (
        $out -like "USAGE: states: 2 problem(s): *template.rpp has no track named 'Nobody'*template.rpp holds 0 plugin blocks*" -and $out -notmatch 'FAKESTATE|Lead backup')
    # A state file that is there but cannot be read (held open by another program without sharing)
    $held = Join-Path $Tmp 'held-states'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $held 'states')
    foreach ($f in 'template.rpp', 'loud.RfxChain') { Copy-Item -LiteralPath (Join-Path $RepoRoot "tests/fixtures/states/$f") -Destination (Join-Path $held 'states') }
    $lock = [IO.File]::Open((Join-Path $held 'states/loud.RfxChain'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { $out = & $msg { param($c) $c.ConfigDir = $held } } finally { $lock.Dispose() }
    & $add "states: a file that cannot be read is a usage error naming the file only, not the path the exception text holds ($out)" $true (
        $out -ceq 'USAGE: states: 1 problem(s): plugins.gain.states.loud: loud.RfxChain cannot be read (IOException)')
    $gainInfo = Read-HarnessModuleInfo (Join-Path $RepoRoot 'tests/fixtures/plugins/Fixture Gain.vst3')
    $busInfo = Read-HarnessModuleInfo (Join-Path $RepoRoot 'tests/fixtures/plugins/Fixture Bus.vst3')
    & $add 'states: blocks of the plugin they are configured for pass the identity check' $false ($(try { Assert-HarnessStateIdentity -States $st -Infos ([ordered]@{ gain = $gainInfo; bus = $busInfo }); $true } catch { $false }))
    & $add 'states: a block of another plugin is a usage error naming the state' $true (Test-Usage { Assert-HarnessStateIdentity -States $st -Infos ([ordered]@{ gain = $busInfo }) } '*plugins.gain.states.quiet: the block is of*plugins.gain.states.loud*')
    & $add 'states: a plugin the preflight could not read is left to the preflight' $false ($(try { Assert-HarnessStateIdentity -States $st -Infos ([ordered]@{ bus = $busInfo }); $true } catch { $false }))
    $cases
}

# ---------------------------------------------------------------- extensions
function Get-ExtensionCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $dir = Join-Path $Tmp 'ext-config'
    $null = New-Item -ItemType Directory -Path (Join-Path $dir 'ext')
    $outside = Join-Path $Tmp 'ext-outside'
    $null = New-Item -ItemType Directory -Path $outside
    Set-Content -LiteralPath (Join-Path $outside 'evil.psm1') -Value 'Set-StrictMode -Version Latest'
    $link = Join-Path $dir 'ext\linked'
    $null = New-Item -ItemType Junction -Path $link -Target $outside
    try {
        Set-Content -LiteralPath (Join-Path $dir 'ext\ok.lua') -Value "-- harness-steps: ok_step`nreturn {}"
        $res = { param($rel) Resolve-HarnessExtensionPath -ConfigDir $dir -Relative $rel }
        & $add 'extension path: a file inside the configuration directory resolves to its real path' $false ((& $res 'ext/ok.lua') -ceq (Join-Path $dir 'ext\ok.lua'))
        & $add 'extension path: an absolute path is a usage error' $true (Test-Usage { & $res (Join-Path $outside 'evil.psm1') } '*must be relative*')
        & $add 'extension path: a drive-relative path is a usage error' $true (Test-Usage { & $res 'C:evil.psm1' } '*must be relative*')
        & $add 'extension path: .. leading out of the directory is a usage error' $true (Test-Usage { & $res '../ext-outside/evil.psm1' } '*leaves the directory*')
        & $add 'extension path: a junction inside the directory pointing out of it is a usage error (real paths compared)' $true (Test-Usage { & $res 'ext/linked/evil.psm1' } '*leaves the directory*')
        & $add 'extension path: a missing file is a usage error' $true (Test-Usage { & $res 'ext/none.psm1' } '*not found*')
    } finally { [IO.Directory]::Delete($link) }
    $luaFile = { param($name, $body) $p = Join-Path $dir "ext\$name"; Set-Content -LiteralPath $p -Value $body; $p }
    & $add 'Lua steps: the harness-steps line names the steps' $false (((Get-HarnessLuaSteps (& $luaFile 'two.lua' "-- comment`n-- harness-steps: a_one, b2`nreturn {}")) -join ',') -ceq 'a_one,b2')
    & $add 'Lua steps: no harness-steps line is a usage error' $true (Test-Usage { Get-HarnessLuaSteps (& $luaFile 'none.lua' 'return {}') } '*harness-steps*')
    & $add 'Lua steps: a step name outside the pattern is a usage error' $true (Test-Usage { Get-HarnessLuaSteps (& $luaFile 'bad.lua' '-- harness-steps: Bad-Name') } '*step name*')
    $valid = { @{ Name = 'demo'; Kinds = @{ 'demo-kind' = @{ Validate = { }; Run = { } } } } }
    $reg = { param($r, [string[]]$Taken = @('render'), [string[]]$Names = @()) @(Test-HarnessRegistration -Registration $r -Source 'x.psm1' -Taken $Taken -TakenNames $Names) }
    & $add 'registration: a valid registration has no problems' $false ((& $reg (& $valid)).Count -eq 0 -and (& $reg @{ Name = 'pre'; Preflight = { } }).Count -eq 0)
    & $add 'registration: kinds named keys and values are two kinds, not the members of the Kinds table' $false ((& $reg @{ Name = 'odd'; Kinds = @{ keys = @{ Validate = { }; Run = { } }; values = @{ Validate = { }; Run = { } } } }).Count -eq 0)
    $badRegs = @(
        @{ L = 'not a hashtable'; R = 'text'; M = 'must return a hashtable' }
        @{ L = 'an unknown key'; R = ((& $valid) + @{ Extra = 1 }); M = "unknown key 'Extra'" }
        @{ L = 'a name outside the pattern'; R = @{ Name = 'Demo'; Preflight = { } }; M = 'Name must match' }
        @{ L = 'neither kinds nor preflight'; R = @{ Name = 'demo' }; M = 'neither Kinds nor Preflight' }
        @{ L = 'a built-in kind name'; R = @{ Name = 'demo'; Kinds = @{ render = @{ Validate = { }; Run = { } } } }; M = "kind 'render' is already defined" }
        @{ L = 'a kind without Run'; R = @{ Name = 'demo'; Kinds = @{ 'demo-kind' = @{ Validate = { } } } }; M = 'needs Run' }
        @{ L = 'a Run that is not a script block'; R = @{ Name = 'demo'; Kinds = @{ 'demo-kind' = @{ Validate = { }; Run = 'x' } } }; M = 'needs Run' }
        @{ L = 'a Preflight that is not a script block'; R = @{ Name = 'demo'; Preflight = 'x' }; M = 'Preflight must be a script block' }
    )
    foreach ($b in $badRegs) { & $add "registration: $($b.L) is a problem" $true (@((& $reg $b.R) -match [regex]::Escape($b.M)).Count -gt 0) }
    & $add 'registration: an extension name registered before is a problem' $true (@((& $reg (& $valid) @('render') @('demo')) -match 'already registered').Count -eq 1)
    # Whole imports from small configurations
    $import = {
        param([string[]]$Modules = @(), [string[]]$Lua = @())
        Import-HarnessExtensions ([pscustomobject]@{ Modules = $Modules; Lua = $Lua; ConfigDir = $dir })
    }
    Set-Content -LiteralPath (Join-Path $dir 'ext\NoRegister.psm1') -Value "Set-StrictMode -Version Latest`nfunction Get-Nothing { }`nExport-ModuleMember -Function Get-Nothing"
    Set-Content -LiteralPath (Join-Path $dir 'ext\Guard.psm1') -Value 'Set-StrictMode -Version Latest'
    Set-Content -LiteralPath (Join-Path $dir 'ext\Throws.psm1') -Value "Set-StrictMode -Version Latest`nfunction Register-HarnessExtension { throw 'no' }`nExport-ModuleMember -Function Register-HarnessExtension"
    Set-Content -LiteralPath (Join-Path $dir 'ext\Clash.psm1') -Value "Set-StrictMode -Version Latest`nfunction Register-HarnessExtension { @{ Name = 'clash'; Kinds = @{ 'fixture-count' = @{ Validate = { }; Run = { } } } } }`nExport-ModuleMember -Function Register-HarnessExtension"
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests/fixtures/ext/FixtureExtension.psm1') -Destination (Join-Path $dir 'ext\FixtureExtension.psm1')
    & $add 'import: a module that does not export Register-HarnessExtension is a usage error' $true (Test-Usage { & $import @('ext/NoRegister.psm1') } '*does not export Register-HarnessExtension*')
    & $add "import: a module with the name of one of the harness's own modules is a usage error" $true (Test-Usage { & $import @('ext/Guard.psm1') } "*harness's own modules*")
    & $add 'import: a registration function that throws is a usage error' $true (Test-Usage { & $import @('ext/Throws.psm1') } '*threw*')
    & $add 'import: two extensions registering the same kind is a usage error' $true (Test-Usage { & $import @('ext/FixtureExtension.psm1', 'ext/Clash.psm1') } "*kind 'fixture-count' is already defined*")
    & $add 'import: a Lua step with a built-in name is a usage error' $true (Test-Usage { & $import @() @((Split-Path -Leaf (& $luaFile 'learn.lua' '-- harness-steps: learn')) | ForEach-Object { "ext/$_" }) } "*Lua step 'learn'*already defined*")
    # Every step of the driver and every module of the harness is taken, not just the one named above
    $driverSteps = @([regex]::Matches([IO.File]::ReadAllText((Join-Path $RepoRoot 'lua/driver.lua')), '(?m)^function steps\.(\w+)\(') | ForEach-Object { $_.Groups[1].Value })
    $stepsLet = @(foreach ($builtIn in $driverSteps) {
            $leaf = Split-Path -Leaf (& $luaFile "taken-$builtIn.lua" "-- harness-steps: $builtIn")
            if (-not (Test-Usage { & $import @() @("ext/$leaf") } "*Lua step '$builtIn'*already defined*")) { $builtIn }
        })
    & $add "import: every step of the driver is taken ($($driverSteps -join ', '); let through: $($stepsLet -join ', '))" $true ($driverSteps.Count -ge 7 -and $stepsLet.Count -eq 0)
    $ownNames = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Filter '*.psm1' | ForEach-Object { $_.BaseName })
    $modulesLet = @(foreach ($own in $ownNames) {
            Set-Content -LiteralPath (Join-Path $dir "ext\$own.psm1") -Value 'Set-StrictMode -Version Latest'
            if (-not (Test-Usage { & $import @("ext/$own.psm1") } "*harness's own modules*")) { $own }
        })
    & $add "import: every module of the harness is taken ($($ownNames.Count) of them; let through: $($modulesLet -join ', '))" $true ($ownNames.Count -ge 15 -and $modulesLet.Count -eq 0)
    $null = & $luaFile 'dup.lua' '-- harness-steps: ok_step'
    & $add 'import: two Lua files declaring the same step is a usage error' $true (Test-Usage { & $import @() @('ext/ok.lua', 'ext/dup.lua') } "*Lua step 'ok_step'*already defined*")
    $good = & $import @('ext/FixtureExtension.psm1') @('ext/ok.lua')
    & $add 'import: the fixture extension and a Lua file give the kind, the preflight, the step and the real Lua path' $false ($good.Kinds.ContainsKey('fixture-count') -and $good.Kinds['fixture-count'].Extension -ceq 'fixture' -and $good.Preflight.Count -eq 1 -and ($good.LuaSteps -join ',') -ceq 'ok_step' -and $good.Lua[0] -ceq (Join-Path $dir 'ext\ok.lua'))
    # The Lua driver checks the same at run time: a step an extension file returns that it did not declare, or that
    # the driver already has, makes the job fail (the stand-in cannot run Lua; this checks the driver's text)
    $driver = [IO.File]::ReadAllText((Join-Path $RepoRoot 'lua/driver.lua'))
    & $add 'Lua driver: it loads the extension files of the job and refuses a step name that is already taken' $false ($driver -match 'extensions' -and $driver -match 'already')
    $cases
}

# ---------------------------------------------------------------- the worked example
# examples/scvb is what docs/INTEGRATING.md walks plugin projects through, and docs/validation records its rows, so
# it is read here as a run reads it, without REAPER: its extension registers, the configuration validates with the
# rows the notes count, and the five states come out of the template, each the plugin it is meant for and from the
# track the routing layout names the same way. The preflight check itself is not run: its answer depends on what
# else runs on the machine.
function Get-ExampleCases([string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $exampleFile = Join-Path $RepoRoot 'examples/scvb/reaper-harness.json'
    $exampleExt = Import-HarnessExtensions (Read-HarnessConfigExtensions $exampleFile)
    & $add 'example: the SCVB preflight module registers one preflight check and no kinds' $false (($exampleExt.Modules -join ',') -ceq 'scvb-preflight' -and $exampleExt.Preflight.Count -eq 1 -and $exampleExt.Kinds.get_Count() -eq 0)
    $exampleConf = Read-HarnessConfig -Path $exampleFile -Kinds $exampleExt.Kinds # a problem is a usage error, which fails the group
    & $add 'example: the SCVB configuration validates, with the 47 scenario rows and 2 negative cases its validation notes count' $false ($exampleConf.Scenarios.Count -eq 47 -and $exampleConf.Negative.Count -eq 2)
    $exampleStates = Read-HarnessStates -Config $exampleConf
    $wantStates = [ordered]@{
        'input@ch1'       = @('VST3: SCVB Input (Synchain)', 'ABCDEF019182FAEB536E636853637669', 'Vox 1')
        'input@ch2'       = @('VST3: SCVB Input (Synchain)', 'ABCDEF019182FAEB536E636853637669', 'Vox 2')
        'input@ch3'       = @('VST3: SCVB Input (Synchain)', 'ABCDEF019182FAEB536E636853637669', 'Vox 3')
        'output@group-8'  = @('VST3: SCVB Output (Synchain)', 'ABCDEF019182FAEB536E63685363766F', 'Bus')
        'monitor@group-8' = @('VST3: SCVB Monitor (Synchain)', 'ABCDEF019182FAEB536E63685363766D', 'Bus')
    }
    $stateKeys = @($exampleStates.get_Keys())
    $wrongStates = @($wantStates.get_Keys() | Where-Object { -not $exampleStates.Contains($_) -or $exampleStates[$_].Name -cne $wantStates[$_][0] -or $exampleStates[$_].Cid -cne $wantStates[$_][1] -or $exampleStates[$_].Track -cne $wantStates[$_][2] })
    & $add 'example: the five states come out of routing-template.rpp, each block the plugin it is configured for, from its track' $false (($stateKeys -join ',') -ceq (@($wantStates.get_Keys()) -join ',') -and $wrongStates.Count -eq 0)
    $routingNames = @($exampleConf.Layouts['routing'].Tracks | ForEach-Object { $_.Name })
    & $add 'example: the routing layout names its tracks as the template does' $false (($routingNames -join ',') -ceq 'Bus,Vox 1,Vox 2,Vox 3')
    $fsvFile = Join-Path $RepoRoot 'examples/file-source-variants/reaper-harness.json'
    $fsvText = [IO.File]::ReadAllText($fsvFile)
    $fsvConf = Read-HarnessConfig -Path $fsvFile # a problem is a usage error, which fails the group
    $fsvRows = @($fsvConf.Scenarios)
    $fsvVariants = @($fsvRows | Where-Object { $_.baseId -ceq 'verb' })
    & $add "example: the file-source configuration validates: one plugin on a track that plays a file, five variants compared with dry and their residual reported, a reported repeat, a render with a tail ($(@($fsvRows | ForEach-Object { $_.id }) -join ', '))" $false (
        @($fsvConf.Plugins.get_Keys()).Count -eq 1 -and $fsvConf.Layouts['voice'].Tracks[0].File -ceq 'sources/voice.wav' -and $fsvVariants.Count -eq 5 -and
        @($fsvVariants | Where-Object { $_.compare.Kind -cne 'dry' -or $_.maxDiffDb -cne 'report' }).Count -eq 0 -and
        @($fsvRows | Where-Object { $_.compare.Kind -ceq 'repeat' -and $_.maxDiffDb -ceq 'report' }).Count -eq 1 -and @($fsvRows | Where-Object { $_.tailFrames -eq 144000 }).Count -eq 1)
    $fsvSchemaOk = try { Test-Json -Json $fsvText -Schema ([IO.File]::ReadAllText((Join-Path $RepoRoot 'schema/config.schema.json'))) -ErrorAction Stop } catch { $false }
    & $add 'example: the file-source configuration names a placeholder plugin and no local path, and the schema accepts it' $false (
        $fsvText -cmatch '"bundle": "My Reverb\.vst3"' -and $fsvText -cnotmatch '[A-Za-z]:[\\/]' -and $fsvSchemaOk)
    $cases
}

# ---------------------------------------------------------------- transport states
function Get-TransportCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    # A state as the configuration gives it, and what the driver reports for it: by default armed, monitoring on,
    # stopped, a stereo feed with different channels in each of 10 blocks
    $state = {
        param([hashtable]$Expect, [string]$Transport = 'stop', [bool]$Arm = $true, [string]$Monitor = 'on')
        $x = ($null -eq $Expect) ? $null : [pscustomobject]@{ Called = $Expect['called']; Input = $Expect['input']; Channels = $Expect['channels']; Monitoring = $Expect['monitoring'] }
        [pscustomobject]@{ Name = 's'; Transport = $Transport; Arm = $Arm; Monitor = $Monitor; Samples = 4800; Windows = $null; Report = [ordered]@{}; Expect = $x }
    }
    $row = {
        param([hashtable]$Set = @{})
        $v = [ordered]@{ clock = 10; clock_samples = 5120; blocks = 10; samples = 5120; silent = 0; signal = 10; left = 10; right = 10; equal = 0; fed = 10; fed_samples = 5120; playstate = 0; arm = 1; monitor = 1; monitoring = 1 }
        foreach ($k in $Set.get_Keys()) { $v[$k] = $Set[$k] }
        [pscustomobject]$v
    }
    $judge = { param($Expect, [hashtable]$Set = @{}, [string]$Transport = 'stop', [bool]$Arm = $true, [string]$Monitor = 'on') Test-HarnessTransportState -State (& $state $Expect $Transport $Arm $Monitor) -Row (& $row $Set) }
    $quiet = @{ silent = 10; signal = 0; left = 0; right = 0 }
    $idle = @{ blocks = 0; samples = 0; silent = 0; signal = 0; left = 0; right = 0 }
    $ok = & $judge @{ called = $true; input = 'signal'; channels = 'different'; monitoring = $true }
    & $add "transport: armed, monitoring on, a stereo feed in every block: PASS, and the line says what was seen ($($ok.Line))" $false (
        $ok.Status -ceq 'PASS' -and $ok.Line -ceq 's: blocks=10/10 silent=0 signal=10 left=10 right=10 same=0 transport=stop monitoring=1' -and @($ok.Problems).Count -eq 0)
    $fails = @(
        @{ L = 'called, and the chain ran in no block'; X = @{ called = $true }; S = $idle; W = 'not called (0 blocks while the device ran 10)' }
        @{ L = 'not called, and the chain ran'; X = @{ called = $false }; S = @{ blocks = 3 }; W = 'called in 3 blocks' }
        @{ L = 'silent, with signal in some blocks'; X = @{ input = 'silent' }; S = @{ silent = 8; signal = 2; left = 2; right = 2 }; W = 'signal in 2 of 10 blocks' }
        @{ L = 'a signal, with a silent block'; X = @{ input = 'signal' }; S = @{ silent = 1; signal = 9; left = 9; right = 9 }; W = 'silent in 1 of 10 blocks' }
        @{ L = 'an input expected of a chain that never ran'; X = @{ input = 'silent' }; S = $idle; W = 'not called, so it has no input' }
        @{ L = 'left only, with signal on the right'; X = @{ channels = 'left' }; S = @{ right = 3 }; W = 'signal on the right in 3 of 10 blocks' }
        @{ L = 'left only, the left missing in some blocks'; X = @{ channels = 'left' }; S = @{ left = 7; right = 0 }; W = 'no signal on the left in 3 of 10 blocks with signal' }
        @{ L = 'left only, no signal at all'; X = @{ channels = 'left' }; S = $quiet; W = 'no signal' }
        @{ L = 'the same on both, differing in some blocks'; X = @{ channels = 'same' }; S = @{ equal = 8 }; W = 'left and right differ in 2 of 10 blocks with signal' }
        @{ L = 'the same on both, no signal'; X = @{ channels = 'same' }; S = $quiet; W = 'no signal' }
        @{ L = 'different, the left missing in a block'; X = @{ channels = 'different' }; S = @{ left = 9 }; W = 'no signal on the left in 1 of 10 blocks with signal' }
        @{ L = 'different, the right missing in a block'; X = @{ channels = 'different' }; S = @{ right = 9 }; W = 'no signal on the right in 1 of 10 blocks with signal' }
        @{ L = 'different, the same on both in a block'; X = @{ channels = 'different' }; S = @{ equal = 1 }; W = 'left and right are the same in 1 of 10 blocks with signal' }
        @{ L = 'different, no signal'; X = @{ channels = 'different' }; S = $quiet; W = 'no signal' }
        @{ L = 'monitoring expected, and not in effect'; X = @{ monitoring = $true }; S = @{ monitoring = 0 }; W = 'monitoring in effect reads 0, expected 1' }
        @{ L = 'no monitoring expected, and in effect'; X = @{ monitoring = $false }; S = @{}; W = 'monitoring in effect reads 1, expected 0' }
    )
    foreach ($c in $fails) {
        $j = & $judge $c.X $c.S
        & $add "transport: $($c.L) is FAIL: $($c.W) ($($j.Line))" $true ($j.Status -ceq 'FAIL' -and $j.Line.EndsWith("; failed: $($c.W)", [StringComparison]::Ordinal) -and (@($j.Problems) -join '|') -ceq $c.W)
    }
    $passes = @(
        @{ L = 'called false, and the chain never ran'; X = @{ called = $false }; S = $idle }
        @{ L = 'called, silent in every block, no monitoring'; X = @{ called = $true; input = 'silent'; monitoring = $false }; S = $quiet + @{ monitoring = 0 } }
        @{ L = 'left only'; X = @{ channels = 'left' }; S = @{ right = 0 } }
        @{ L = 'a signal, the same on both'; X = @{ input = 'signal'; channels = 'same' }; S = @{ equal = 10 } }
    )
    foreach ($c in $passes) {
        $j = & $judge $c.X $c.S
        & $add "transport: $($c.L) is PASS ($($j.Line))" $false ($j.Status -ceq 'PASS' -and @($j.Problems).Count -eq 0 -and $j.Line -cnotmatch 'failed|no evidence')
    }
    $two = & $judge @{ called = $true; input = 'signal'; monitoring = $true } ($idle + @{ monitoring = 0 })
    & $add "transport: every failed criterion is listed in order; a chain that never ran is not blamed for its input as well ($($two.Line))" $true (
        $two.Status -ceq 'FAIL' -and $two.Line.EndsWith('; failed: not called (0 blocks while the device ran 10); monitoring in effect reads 0, expected 1', [StringComparison]::Ordinal))
    # Numbers that describe another state than the one asked for are no evidence: INCOMPLETE, even where the expectation fails
    $gaps = @(
        @{ L = 'a device that ran less than the window'; S = @{ clock_samples = 4000 }; W = 'the device ran 4000 of 4800 samples' }
        @{ L = 'the transport reading play when stop was asked for'; S = @{ playstate = 1 }; W = 'the transport reads play, expected stop' }
        @{ L = 'the transport reading the record bit'; S = @{ playstate = 5 }; W = 'the transport reads 5, expected stop' }
        @{ L = 'arm reading off'; S = @{ arm = 0 }; W = 'arm reads 0, expected 1' }
        @{ L = 'the monitoring mode reading auto when on was asked for'; S = @{ monitor = 2 }; W = 'monitoring mode reads 2, expected 1' }
    )
    foreach ($c in $gaps) {
        $j = & $judge @{ called = $false } $c.S
        & $add "transport: $($c.L) is INCOMPLETE, not FAIL ($($j.Line))" $true ($j.Status -ceq 'INCOMPLETE' -and $j.Line.EndsWith("; no evidence: $($c.W)", [StringComparison]::Ordinal))
    }
    $unseen = Test-HarnessTransportState -State (& $state @{ called = $true }) -Row $null
    & $add 'transport: a state the driver did not report is INCOMPLETE (not observed)' $true ($unseen.Status -ceq 'INCOMPLETE' -and $unseen.Line -ceq 's: not observed')
    # The feed in the window of an armed state: a silent input proves nothing when the feed played nothing
    $feedIdle = @{ fed = 0; fed_samples = 0; silent = 10; signal = 0; left = 0; right = 0 }
    $noFeedBlocks = '; no evidence: the feed played no block in the window although the track is armed'
    $idleSilent = Test-HarnessTransportState -State (& $state @{ input = 'silent' }) -Row (& $row $feedIdle) -HasFeed
    & $add "transport: armed with a feed that played nothing is INCOMPLETE, even where 'silent' holds ($($idleSilent.Line))" $true ($idleSilent.Status -ceq 'INCOMPLETE' -and $idleSilent.Line.EndsWith($noFeedBlocks, [StringComparison]::Ordinal))
    $idleRecorded = Test-HarnessTransportState -State (& $state $null) -Row (& $row $feedIdle) -HasFeed
    & $add 'transport: armed with a feed that played nothing is INCOMPLETE in a state without expectations too' $true ($idleRecorded.Status -ceq 'INCOMPLETE' -and $idleRecorded.Line.EndsWith($noFeedBlocks, [StringComparison]::Ordinal))
    $emptyCalls = Test-HarnessTransportState -State (& $state @{ input = 'silent' }) -Row (& $row @{ fed = 3; fed_samples = 0; silent = 10; signal = 0; left = 0; right = 0 }) -HasFeed
    & $add 'transport: armed with a feed that was called without samples is INCOMPLETE' $true ($emptyCalls.Status -ceq 'INCOMPLETE' -and $emptyCalls.Line.EndsWith($noFeedBlocks, [StringComparison]::Ordinal))
    & $add 'transport: armed with a feed that played is judged as usual' $false ((Test-HarnessTransportState -State (& $state @{ input = 'silent' }) -Row (& $row @{ silent = 10; signal = 0; left = 0; right = 0 }) -HasFeed).Status -ceq 'PASS')
    & $add 'transport: not armed, the feed is not expected to play' $false ((Test-HarnessTransportState -State (& $state @{ called = $true } 'stop' $false 'off') -Row (& $row @{ fed = 0; fed_samples = 0; arm = 0; monitor = 0 }) -HasFeed).Status -ceq 'PASS')
    & $add 'transport: armed in a scenario without a feed, nothing is expected to play' $false ((Test-HarnessTransportState -State (& $state @{ input = 'silent' }) -Row (& $row $feedIdle)).Status -ceq 'PASS')
    $rec = & $judge $null $idle
    & $add 'transport: a state without expectations is recorded, never judged' $false ($rec.Status -ceq 'recorded' -and @($rec.Problems).Count -eq 0 -and $rec.Line -cnotmatch 'failed')
    & $add 'transport: paused, playing, auto monitoring and unarmed read back as asked' $false (
        (& $judge @{ called = $true } @{ playstate = 2 } 'pause').Status -ceq 'PASS' -and (& $judge @{ called = $true } @{ playstate = 1 } 'play').Status -ceq 'PASS' -and
        (& $judge @{ called = $true } @{ monitor = 2 } 'stop' $true 'auto').Status -ceq 'PASS' -and (& $judge @{ called = $true } @{ arm = 0; monitor = 0 } 'stop' $false 'off').Status -ceq 'PASS')
    # The numbers as the driver writes them
    $facts = @{}
    foreach ($k in 'clock', 'clock_samples', 'blocks', 'samples', 'silent', 'signal', 'left', 'right', 'equal', 'fed', 'fed_samples', 'playstate', 'arm', 'monitor', 'monitoring') { $facts["st2_$k"] = '7.0' }
    $r2 = Read-HarnessTransportRow $facts 2
    & $add 'transport: the numbers of state n are read from st<n>_ (Lua may write whole numbers as 7.0)' $false ($null -ne $r2 -and $r2.blocks -eq 7 -and $r2.monitoring -eq 7 -and $null -eq (Read-HarnessTransportRow $facts 1))
    foreach ($badValue in $null, 'seven', 'NaN', 'inf', '-nan(ind)') {
        $f2 = $facts.Clone()
        if ($null -eq $badValue) { $f2.Remove('st2_equal') } else { $f2['st2_equal'] = $badValue }
        $rowRead = try { Read-HarnessTransportRow $f2 2 } catch { "threw: $($_.Exception.Message)" }
        & $add "transport: a state with a number $(($null -eq $badValue) ? 'missing' : "reading '$badValue'") is not observed" $true ($null -eq $rowRead)
    }
    foreach ($fedField in 'fed', 'fed_samples') {
        $f3 = $facts.Clone(); $f3.Remove("st2_$fedField")
        & $add "transport: a state without $fedField is not observed" $true ($null -eq (Read-HarnessTransportRow $f3 2))
    }
    # The setup the driver reports
    $idents = @{ 'harness-block-probe' = 'reaper-harness/harness-block-probe.jsfx'; 'harness-feed' = 'reaper-harness/harness-feed.jsfx' }
    $fed = [pscustomobject]@{ sr = 48000; states = @([pscustomobject]@{ Arm = $false }, [pscustomobject]@{ Arm = $true }); feed = [pscustomobject]@{ FileChannels = 2 } }
    $setup = {
        param([hashtable]$Set = @{}, [string[]]$Drop = @(), $Scen = $fed)
        $f = @{ probe_ident = $idents['harness-block-probe']; probe_idx = '0'; probe_fx_count = '3'; clock_ident = $idents['harness-block-probe']; record_path = 'ok'; states_done = '2'
            feed_ident = $idents['harness-feed']; feed_handle = '1'; feed_channels = '2'; feed_rate = '48000' }
        foreach ($k in $Set.get_Keys()) { $f[$k] = $Set[$k] }
        foreach ($k in $Drop) { $f.Remove($k) }
        @(Test-HarnessTransportSetup -Facts $f -Scenario $Scen -Idents $idents -FxCount 2)
    }
    & $add 'transport setup: the probes of the harness first in the chain and on the clock, the record path, every state, the feed opened at the rate: no problem' $false ((& $setup).Count -eq 0)
    $setupBad = @(
        @{ L = 'a probe that is not the copy of the harness'; S = @{ probe_ident = 'other/probe.jsfx' }; W = "not the harness's own first in its chain" }
        @{ L = 'the probe not first in the chain'; S = @{ probe_idx = '1' }; W = "not the harness's own first in its chain" }
        @{ L = 'a chain that does not hold the probe'; S = @{ probe_fx_count = '2' }; W = 'the tested track has 2 FX with the probe, expected 3' }
        @{ L = 'a clock track without the probe'; S = @{ clock_ident = '' }; W = 'the clock track has no block probe' }
        @{ L = 'a record path that could not be set'; S = @{ record_path = 'failed' }; W = 'the record path of the project could not be set' }
        @{ L = 'a state not observed'; S = @{ states_done = '1' }; W = '1 of 2 states were observed' }
        @{ L = 'a feed that is not the copy of the harness'; S = @{ feed_ident = 'other/feed.jsfx' }; W = "the feed of the input chain is not the harness's own" }
        @{ L = 'a feed that reported nothing'; D = @('feed_handle'); W = 'the feed reported nothing' }
        @{ L = 'a feed that could not open its file'; S = @{ feed_handle = '-1' }; W = 'the feed could not open its source' }
        @{ L = 'a feed handle below -2'; S = @{ feed_handle = '-3' }; W = 'the feed could not open its source' }
        @{ L = 'a feed that never ran although a state arms the track'; S = @{ feed_handle = '-2'; feed_channels = '0'; feed_rate = '0' }; W = 'the feed never ran although a state arms the track' }
        @{ L = 'a feed that opened another channel count'; S = @{ feed_channels = '1' }; W = 'with 1 channels, expected 2' }
        @{ L = 'a feed that opened another rate'; S = @{ feed_rate = '44100' }; W = 'at 44100 Hz, expected 48000' }
    )
    foreach ($c in $setupBad) {
        $found = & $setup ($c['S'] ?? @{}) ($c['D'] ?? @())
        & $add "transport setup: $($c.L) leaves no evidence ($($found -join ' | '))" $true ($found.Count -eq 1 -and $found[0] -clike "*$($c.W)*")
    }
    $neverArmed = [pscustomobject]@{ sr = 48000; states = @([pscustomobject]@{ Arm = $false }, [pscustomobject]@{ Arm = $false }); feed = [pscustomobject]@{ FileChannels = 2 } }
    & $add 'transport setup: a feed that never ran (-2) is no problem when no state arms the track' $false ((& $setup @{ feed_handle = '-2'; feed_channels = '0'; feed_rate = '0' } @() $neverArmed).Count -eq 0)
    & $add 'transport setup: without a feed its facts are not asked for' $false ((& $setup @{} @('feed_ident', 'feed_handle', 'feed_channels', 'feed_rate') ([pscustomobject]@{ sr = 48000; states = @(1, 2); feed = $null })).Count -eq 0)
    # The time the step gets: the driver's own deadlines (3 n / sr + 10 s a wait, two waits a state) come first
    $timed = [pscustomobject]@{ sr = 48000; settleSamples = 4800; states = @([pscustomobject]@{ Samples = 4800; Windows = $null }, [pscustomobject]@{ Samples = 9600; Windows = $null }) }
    $timedDefault = [pscustomobject]@{ sr = 48000; settleSamples = $null; states = $timed.states }
    & $add 'transport timeout: luaTimeoutSec, the settle times and windows three times over, and 20 s a state' $false ([Math]::Abs((Get-HarnessTransportTimeout -Scenario $timed -LuaTimeoutSec 60) - 101.5) -lt 1e-9)
    & $add 'transport timeout: without a settle time it counts 5 s a state' $false ([Math]::Abs((Get-HarnessTransportTimeout -Scenario $timedDefault -LuaTimeoutSec 60) - 130.9) -lt 1e-9)
    # The job of the driver, from the fixture configuration
    $cfgFile = Join-Path $RepoRoot 'tests/fixtures/config.json'
    $cfgExt = Import-HarnessExtensions (Read-HarnessConfigExtensions $cfgFile)
    $conf = Read-HarnessConfig -Path $cfgFile -Kinds $cfgExt.Kinds
    $ms = @($conf.Scenarios | Where-Object id -ceq 'monitor-states')[0]
    $tools = @{ 'harness-block-probe' = 'JS:p'; 'harness-feed' = 'JS:f' }
    $job = Get-HarnessTransportJob -Scenario $ms -Layout $conf.Layouts[$ms.layout] -Tools $tools -RecordDir 'R'
    $codes = @($job.states | ForEach-Object { "$($_.name)/$($_.transport)/$($_.arm)/$($_.monitor)/$($_.samples)" }) -join ','
    & $add "transport job: the tested track by index, the probe and the feed by name, the feed mode, the settle time, each state as numbers ($codes)" $false (
        $job.track -eq 0 -and $job.probe -ceq 'JS:p' -and $job.feed -ceq 'JS:f' -and $job.feedMode -eq 2 -and $job.settle -eq 240000 -and $job.sr -eq 48000 -and $job.recordDir -ceq 'R' -and
        $codes -ceq 'stopped-unarmed/stop/0/0/4800,stopped-armed-on/stop/1/1/4800,playing-auto/play/1/2/4800,paused-unarmed/pause/0/0/4800')
    $leftOnly = @($conf.Scenarios | Where-Object { $_.id -like 'monitor-stopped-off-*' })[0]
    & $add 'transport job: the feed mode of left only is 0' $false ((Get-HarnessTransportJob -Scenario $leftOnly -Layout $conf.Layouts[$leftOnly.layout] -Tools $tools -RecordDir 'R').feedMode -eq 0)
    $plain = [pscustomobject]@{ track = $ms.track; sr = 44100; settleSamples = $null; feed = $null; states = $ms.states }
    $job2 = Get-HarnessTransportJob -Scenario $plain -Layout $conf.Layouts[$ms.layout] -Tools $tools -RecordDir 'R'
    & $add 'transport job: without a feed or a settle time the job has neither (the driver then waits for run FX after stopping plus half a second)' $false (-not $job2.Contains('feed') -and -not $job2.Contains('feedMode') -and -not $job2.Contains('settle') -and $job2.sr -eq 44100)
    $ghost = [pscustomobject]@{ track = 'Ghost'; sr = 48000; settleSamples = $null; feed = $null; states = $ms.states }
    & $add 'transport job: a tested track that is not in the layout throws' $true $(try { $null = Get-HarnessTransportJob -Scenario $ghost -Layout $conf.Layouts[$ms.layout] -Tools $tools -RecordDir 'R'; $false } catch { $_.Exception.Message -clike "*'Ghost' is not in the layout*" })
    # What the configuration makes of transport scenarios
    & $add 'configuration: a transport scenario on a one-track layout tests that track; feed and settle time as given; Run FX when stopped on unless turned off; a state without expect has none' $false (
        $ms.track -ceq 'Voice' -and $ms.feed.Channels -ceq 'different' -and $ms.feed.Wav -ceq '' -and $ms.settleSamples -eq 240000 -and $ms.host.RunFxWhenStopped -and @($ms.states).Count -eq 4 -and
        $null -eq $ms.states[3].Expect -and $ms.states[1].Expect.Channels -ceq 'different' -and $ms.states[0].Expect.Called -eq $true -and $null -eq $ms.states[2].Expect.Called)
    $offRows = @($conf.Scenarios | Where-Object { $_.id -like 'monitor-stopped-off-*' })
    & $add "configuration: the block matrix of a transport scenario gives one scenario per block size, each with its settings ($(@($offRows | ForEach-Object { $_.id }) -join ', '))" $false (
        $offRows.Count -eq 2 -and (@($offRows | ForEach-Object { $_.block }) -join ',') -ceq '64,1024' -and @($offRows | Where-Object { $_.host.RunFxWhenStopped -or $_.feed.Channels -cne 'left' }).Count -eq 0)
    $raw = ConvertFrom-HarnessJson ([IO.File]::ReadAllText($cfgFile))
    $msRaw = @($raw['scenarios'] | Where-Object { $_['id'] -ceq 'monitor-states' })[0]
    $msRaw.Remove('settleSamples'); $msRaw['feed'] = [ordered]@{}; $msRaw['states'][0].Remove('samples'); $msRaw['sr'] = 44100
    $res = Test-HarnessConfigData -Raw $raw -Kinds $cfgExt.Kinds
    $d = $res.Config ? @($res.Config.Scenarios | Where-Object id -ceq 'monitor-states')[0] : $null
    & $add "configuration: a window defaults to 2 seconds at the scenario rate; an empty feed is the test signal with different channels; no settle time unless given ($(@($res.Problems) -join ' | '))" $false (
        @($res.Problems).Count -eq 0 -and $d.states[0].Samples -eq 88200 -and $d.feed.Channels -ceq 'different' -and $null -eq $d.settleSamples)
    $msRaw.Remove('feed')
    $res = Test-HarnessConfigData -Raw $raw -Kinds $cfgExt.Kinds
    & $add 'configuration: a transport scenario without a feed has none (its tested track gets no input)' $false (@($res.Problems).Count -eq 0 -and $null -eq @($res.Config.Scenarios | Where-Object id -ceq 'monitor-states')[0].feed)
    $chainLayout = $conf.Layouts['chain']
    $withItems = New-HarnessProjectText -Layout $chainLayout -SourceWav 'S.wav' -RenderDir 'D' -RenderName 'N' -NoFx
    $noItems = New-HarnessProjectText -Layout $chainLayout -SourceWav 'S.wav' -RenderDir 'D' -RenderName 'N' -NoFx -NoItems
    & $add 'project: the transport kind gets its tracks without items (an item would make REAPER run an unarmed track while playing)' $true ($withItems -cmatch '<ITEM' -and $noItems -cnotmatch '<ITEM')
    # Run FX when stopped in the private ini, and read back
    & $add 'Run FX when stopped: bit 0 of runallonstop set or cleared, the other bits kept; no readable value counts as REAPER''s default 1' $false (
        (Get-HarnessRunAllOnStop '6' $true) -eq 7 -and (Get-HarnessRunAllOnStop '7' $false) -eq 6 -and (Get-HarnessRunAllOnStop $null $true) -eq 1 -and (Get-HarnessRunAllOnStop '' $false) -eq 0 -and (Get-HarnessRunAllOnStop 'x' $true) -eq 1)
    $rb = { param($Reads, $Asked) @(Test-HarnessHostReadback -Facts @{ dev_bsize = '512'; dev_srate = '48000'; cfg_workrender = '1'; cfg_runallonstop = $Reads } -Block 512 -Sr 48000 -AnticipativeFx $true -RunFxWhenStopped $Asked) }
    & $add 'readback: Run FX when stopped reading as asked is no problem' $false ((& $rb '1' $true).Count -eq 0 -and (& $rb '6' $false).Count -eq 0)
    & $add 'readback: Run FX when stopped reading the other way is a problem' $true (((& $rb '0' $true) -join '') -ceq 'Run FX when stopped reads off, expected on' -and ((& $rb '3' $false) -join '') -ceq 'Run FX when stopped reads on, expected off')
    & $add 'readback: a runallonstop that cannot be read is a problem' $true (((& $rb 'unavailable' $true) -join '') -ceq "runallonstop reads 'unavailable'")
    $notAsked = Test-HarnessHostReadback -Facts @{ dev_bsize = '512'; dev_srate = '48000'; cfg_workrender = '1' } -Block 512 -Sr 48000 -AnticipativeFx $true
    & $add 'readback: when not asked for, runallonstop is not looked at' $false (@($notAsked).Count -eq 0)
    # Feed files of the configuration
    $feedDir = Join-Path $Tmp 'feed cfg'
    $null = New-Item -ItemType Directory -Path (Join-Path $feedDir 'feeds')
    $wav = { param([string]$WavName, [int]$WavRate, [int]$Channels, [int]$Frames) [HarnessWav]::Write((Join-Path $feedDir "feeds/$WavName"), $WavRate, $Channels, 'float32', $false, [double[]](, 0.25 * ($Frames * $Channels))) }
    $frameFile = { param([string]$WavName, [double[]]$Frame) [HarnessWav]::Write((Join-Path $feedDir "feeds/$WavName"), 48000, $Frame.Count, 'float32', $false, [double[]](1..480 | ForEach-Object { $Frame })) }
    & $frameFile 'zero.wav' @(0.0, 0.0); & $frameFile 'mono-zero.wav' @(, 0.0); & $frameFile 'left-zero.wav' @(0.0, 0.25); & $frameFile 'right-zero.wav' @(0.25, 0.0); & $frameFile 'left-nan.wav' @([double]::NaN, 0.25); & $frameFile 'left-inf.wav' @([double]::PositiveInfinity, 0.25)
    & $wav 'stereo.wav' 48000 2 480; & $wav 'mono.wav' 48000 1 480; & $wav 'slow.wav' 44100 2 480; & $wav 'three.wav' 48000 3 480; & $wav 'empty.wav' 48000 2 0
    [IO.File]::WriteAllText((Join-Path $feedDir 'feeds/text.wav'), 'not a wav file')
    [IO.File]::WriteAllText((Join-Path $Tmp 'outside.wav'), 'x')
    $feedOf = { param([string]$RelPath, [string]$Channels = 'different') [pscustomobject]@{ id = 'fs'; kind = 'transport'; sr = 48000; feed = [pscustomobject]@{ Wav = $RelPath; Channels = $Channels; File = ''; Sha256 = ''; FileChannels = 2 } } }
    $feedConf = { param([object[]]$List) [pscustomobject]@{ ConfigDir = $feedDir; Scenarios = $List; Negative = @() } }
    $stereo = & $feedOf 'feeds/stereo.wav'; $mono = & $feedOf 'feeds/mono.wav' 'left'; $signal = & $feedOf ''
    # A refusal leaves the fields empty, and the case below goes red
    try { Read-HarnessFeeds -Config (& $feedConf @($stereo, $mono, $signal, [pscustomobject]@{ id = 'r'; kind = 'render' })) } catch { $null = $_ }
    & $add 'feeds: a stereo and a mono file at the rate are read: path, hash prefix and channel count filled in; a feed without a file and other kinds are left alone' $false (
        $stereo.feed.File -clike '*stereo.wav' -and (Test-Path -LiteralPath $stereo.feed.File) -and $stereo.feed.Sha256 -cmatch '^[0-9a-f]{12}$' -and $stereo.feed.FileChannels -eq 2 -and $mono.feed.FileChannels -eq 1 -and $signal.feed.File -ceq '')
    $feedBad = @(
        @{ L = 'a file at another rate (nothing is resampled)'; R = 'feeds/slow.wav'; C = 'different'; W = '*is at 44100 Hz and the scenario runs at 48000 Hz: nothing is resampled*' }
        @{ L = 'a mono file for different channels'; R = 'feeds/mono.wav'; C = 'different'; W = '*has one channel: channels "different" needs two*' }
        @{ L = 'a file of 3 channels'; R = 'feeds/three.wav'; C = 'same'; W = '*has 3 channels: 1 or 2 are accepted*' }
        @{ L = 'a file without samples'; R = 'feeds/empty.wav'; C = 'different'; W = '*holds no samples*' }
        @{ L = 'a file of nothing but zeros'; R = 'feeds/zero.wav'; C = 'same'; W = '*feeds/zero.wav has a peak of 0 on channel 1: a silent feed proves nothing*' }
        @{ L = 'a mono file of nothing but zeros'; R = 'feeds/mono-zero.wav'; C = 'left'; W = '*has a peak of 0 on channel 1*' }
        @{ L = 'a silent first channel for left only'; R = 'feeds/left-zero.wav'; C = 'left'; W = '*has a peak of 0 on channel 1*' }
        @{ L = 'a silent first channel for different channels'; R = 'feeds/left-zero.wav'; C = 'different'; W = '*has a peak of 0 on channel 1*' }
        @{ L = 'a silent second channel for different channels'; R = 'feeds/right-zero.wav'; C = 'different'; W = '*has a peak of 0 on channel 2*' }
        @{ L = 'a first channel of nothing but NaN (no finite peak)'; R = 'feeds/left-nan.wav'; C = 'same'; W = '*has a peak of 0 on channel 1*' }
        @{ L = 'a first channel of nothing but infinities (no finite peak)'; R = 'feeds/left-inf.wav'; C = 'same'; W = '*has a peak of 0 on channel 1*' }
        @{ L = 'a file that is not a WAV'; R = 'feeds/text.wav'; C = 'different'; W = '*feeds/text.wav cannot be read*' }
        @{ L = 'a file that is not there'; R = 'feeds/none.wav'; C = 'different'; W = '*feed file not found: feeds/none.wav*' }
        @{ L = 'a path that leaves the directory of the configuration'; R = '../outside.wav'; C = 'different'; W = '*leaves the directory of the configuration file*' }
        @{ L = 'an absolute path'; R = 'D:\feeds\x.wav'; C = 'different'; W = '*must be relative to the configuration file*' }
    )
    foreach ($c in $feedBad) {
        & $add "feeds: $($c.L) is a usage error before REAPER starts" $true (Test-Usage { Read-HarnessFeeds -Config (& $feedConf @(& $feedOf $c.R $c.C)) } "USAGE: feeds: 1 problem(s): fs: $($c.W)")
    }
    & $add 'feeds: a silent second channel is fine where only the first is played' $false ($(try { Read-HarnessFeeds -Config (& $feedConf @((& $feedOf 'feeds/right-zero.wav' 'left'), (& $feedOf 'feeds/right-zero.wav' 'same'))); $true } catch { $false }))
    & $add 'feeds: every problem is listed at once' $true (Test-Usage { Read-HarnessFeeds -Config (& $feedConf @((& $feedOf 'feeds/slow.wav'), (& $feedOf 'feeds/none.wav'))) } 'USAGE: feeds: 2 problem(s): *resampled*; *not found*')
    # The built-in negative case: what REAPER does with Run FX when stopped off and an armed, fed track
    $probeNeg = @(Get-HarnessBuiltinNegatives -Transport)[-1]
    $negLine = {
        param($RowOne, $RowTwo)
        @((Test-HarnessTransportState -State $probeNeg.states[0] -Row $RowOne), (Test-HarnessTransportState -State $probeNeg.states[1] -Row $RowTwo) | ForEach-Object { $_.Line }) -join ' | '
    }
    $long = @{ clock = 94; clock_samples = 48128 }
    $unarmedIdle = & $row ($long + $idle + @{ arm = 0; monitor = 0; monitoring = 0 })
    $unarmedRan = & $row ($long + @{ blocks = 94; samples = 48128; silent = 94; signal = 0; left = 0; right = 0; arm = 0; monitor = 0; monitoring = 0 })
    $armedFed = & $row ($long + @{ blocks = 94; samples = 48128; signal = 94; left = 94; right = 94 })
    $armedQuiet = & $row ($long + @{ blocks = 94; samples = 48128; silent = 94; signal = 0; left = 0; right = 0 })
    & $add 'built-in transport negative: only with the transport switch, last, and with its own id' $false (
        'neg-transport-probe' -cnotin @(Get-HarnessBuiltinNegatives | ForEach-Object { $_.id }) -and $probeNeg.id -ceq 'neg-transport-probe' -and $probeNeg.kind -ceq 'transport' -and -not $probeNeg.host.RunFxWhenStopped -and $null -ne $probeNeg.feed)
    & $add "built-in transport negative: the unarmed chain not called and the armed one fed match its reason ($(& $negLine $unarmedIdle $armedFed))" $false ((& $negLine $unarmedIdle $armedFed) -cmatch $probeNeg.expectDetail)
    & $add 'built-in transport negative: an unarmed chain that ran (the setting not applied) does not match' $true ((& $negLine $unarmedRan $armedFed) -cnotmatch $probeNeg.expectDetail)
    & $add 'built-in transport negative: an armed track that got no feed does not match' $true ((& $negLine $unarmedIdle $armedQuiet) -cnotmatch $probeNeg.expectDetail)
    $noTransport = ConvertFrom-HarnessJson ([IO.File]::ReadAllText($cfgFile))
    $noTransport['scenarios'] = @($noTransport['scenarios'] | Where-Object { $_['kind'] -cne 'transport' })
    $noTransport['negative'] = @($noTransport['negative'] | Where-Object { $_['kind'] -cne 'transport' })
    $pickedNo = Select-HarnessScenarios -Config (Test-HarnessConfigData -Raw $noTransport -Kinds $cfgExt.Kinds).Config
    & $add 'selection: a configuration without a transport scenario does not get the built-in transport negative' $true ('neg-transport-probe' -cnotin @($pickedNo.Negative | ForEach-Object { $_.id }) -and @($pickedNo.Negative).Count -eq 11)
    # The licence reminder retry, with the guarded launch replaced by a list of outcomes
    $queue = [Collections.Generic.Queue[object]]::new()
    $calls = @{ N = 0 }
    $fakeLaunch = { $calls.N++; $queue.Dequeue() }.GetNewClosure() # the named arguments of the call land in $args
    $swap = { param([scriptblock]$Replacement) & (@(Get-Module Scenarios)[0]) { param($b) $was = ${function:Invoke-HarnessLaunchOnce}; Set-Item function:script:Invoke-HarnessLaunchOnce $b; $was } $Replacement }
    $res = { param([string]$Status, [string]$Modal = '', [bool]$Still = $false) [pscustomobject]@{ Status = $Status; Modal = $Modal; StillRunning = $Still } }
    $retry = {
        param([object[]]$Results, [string[]]$Outputs = @())
        $queue.Clear(); foreach ($x in $Results) { $queue.Enqueue($x) }; $calls.N = 0
        $ctx = [pscustomobject]@{ Retries = [Collections.Generic.List[object]]::new() }
        $run = Invoke-HarnessLaunch -Ctx $ctx -HostArgs @{} -Label 'step-x' -Outputs $Outputs
        [pscustomobject]@{ Run = $run; Calls = $calls.N; Retries = @($ctx.Retries) }
    }
    $was = & $swap $fakeLaunch
    try {
        $leftOver = Join-Path $Tmp 'retry-a.wav'; Set-Content -LiteralPath $leftOver -Value 'left by the first launch'
        $a = & $retry @((& $res Modal license-nag), (& $res Exited)) @($leftOver, (Join-Path $Tmp 'retry-none.wav'))
        & $add 'retry: a launch ended by the licence reminder is started once more, after its outputs are deleted, and the retry is listed' $false (
            $a.Run.Status -ceq 'Exited' -and $a.Calls -eq 2 -and $a.Retries.Count -eq 1 -and $a.Retries[0].Label -ceq 'step-x' -and $a.Retries[0].Reason -ceq 'license-nag' -and -not (Test-Path -LiteralPath $leftOver))
        $b = & $retry @((& $res Modal license-nag), (& $res Modal license-nag))
        & $add 'retry: only once: a second reminder ends the launch as stuck (Modal license-nag)' $true ($b.Run.Status -ceq 'Modal' -and $b.Run.Modal -ceq 'license-nag' -and $b.Calls -eq 2 -and $b.Retries.Count -eq 1)
        $c = & $retry @((& $res Modal license-nag $true), (& $res Exited))
        & $add 'retry: never after a process that could not be ended' $true ($c.Calls -eq 1 -and $c.Retries.Count -eq 0 -and $c.Run.StillRunning)
        foreach ($other in @((& $res Modal unknown-dialog), (& $res Modal reaper-error), (& $res Timeout), (& $res Killed), (& $res LockBusy), (& $res SkipMarker), (& $res Exited))) {
            $o = & $retry @($other, (& $res Exited))
            & $add "retry: a launch that ended $($other.Status)$($other.Modal ? " ($($other.Modal))" : '') is not started again" $true ($o.Calls -eq 1 -and $o.Retries.Count -eq 0 -and $o.Run.Status -ceq $other.Status)
        }
        $locked = Join-Path $Tmp 'retry-locked.wav'; Set-Content -LiteralPath $locked -Value 'x'
        $hold = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try { $e = & $retry @((& $res Modal license-nag), (& $res Exited)) @($locked) } finally { $hold.Dispose() }
        & $add 'retry: an output of the first launch that cannot be deleted means no retry (it would be read as the second one''s)' $true ($e.Calls -eq 1 -and $e.Retries.Count -eq 0 -and $e.Run.Status -ceq 'Modal')
    } finally { $null = & $swap $was }
    $cases
}

# ---------------------------------------------------------------- plugin reports and windows
function Get-ReportCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    # A condition that looks into what may be missing: missing is false, not a group that throws
    $holds = { param([scriptblock]$Condition) try { [bool](& $Condition) } catch { $false } }
    # The variable that tells a plugin where to write: never one that Windows, a runtime, REAPER or WebView2 reads
    & $add 'report variable: a name of the plugin''s own is accepted' $false ($null -eq (Test-HarnessReportEnvName 'FIXTURE_REPORT_JSON'))
    $refused = 'APPDATA', 'LOCALAPPDATA', 'USERPROFILE', 'PATH', 'TEMP', 'TMP', 'SYSTEMROOT', 'COMSPEC', 'PSMODULEPATH', 'WEBVIEW2_USER_DATA_FOLDER', 'REAPER_HARNESS_JOB', 'COR_PROFILER',
        'CORECLR_PROFILER', 'COMPLUS_X', 'DOTNET_STARTUP_HOOKS', 'POWERSHELL_X', 'VST3_PATH', 'JUCE_X', 'fixture_report', 'AB', '1ABC'
    $let = @($refused | Where-Object { $null -eq (Test-HarnessReportEnvName $_) })
    & $add "report variable: system, runtime, REAPER and WebView2 names, lower case and short names are refused (let through: $($let -join ', '))" $true ($let.Count -eq 0)
    & $add 'report variable: the reason names the prefix' $true ((Test-HarnessReportEnvName 'WEBVIEW2_X') -clike "*starts with WEBVIEW2_*")
    # What REAPER loads reads some too: ReaScript's Python and Lua, Qt in a plugin; and the Unix-style home and temp
    $loaded = @(
        @{ L = 'PYTHON names (ReaScript''s Python reads PYTHONHOME and PYTHONPATH)'; N = 'PYTHONHOME', 'PYTHONPATH', 'PYTHONSTARTUP'; W = 'PYTHON' }
        @{ L = 'LUA_ names (Lua reads LUA_PATH and LUA_CPATH)'; N = 'LUA_PATH', 'LUA_CPATH', 'LUA_INIT'; W = 'LUA_' }
        @{ L = 'QT_ names (Qt loads plugins from QT_PLUGIN_PATH)'; N = 'QT_PLUGIN_PATH', 'QT_QPA_PLATFORM'; W = 'QT_' }
        @{ L = 'HOME'; N = @('HOME'); W = '' }
        @{ L = 'TMPDIR'; N = @('TMPDIR'); W = '' }
    )
    foreach ($c in $loaded) {
        $why = @(foreach ($n in $c.N) { [string](Test-HarnessReportEnvName $n) })
        & $add "report variable: refused, $($c.L) ($($why -join ' | '))" $true ($why.Count -eq $c.N.Count -and @($why | Where-Object { -not $_ -or ($c.W -and $_ -cnotlike "*starts with $($c.W),*") }).Count -eq 0)
    }
    # The plan of one step: only plugins of the layout that declare a report
    $rep = { param($Env, [string[]]$Fields, $PidField = 'pid') [pscustomobject]@{ Env = $Env; Fields = $Fields; PidField = $PidField; PeriodMs = 250 } }
    $plugins = [ordered]@{ rec = [pscustomobject]@{ Report = (& $rep 'REC_JSON' @('blocks', 'opens')) }; mon = [pscustomobject]@{ Report = $null }; spare = [pscustomobject]@{ Report = (& $rep 'SPARE_JSON' @('x') '') } }
    $layout = [pscustomobject]@{ Tracks = @([pscustomobject]@{ Name = 'Voice'; Fx = @([pscustomobject]@{ Plugin = 'mon' }, [pscustomobject]@{ Plugin = 'rec' }) }) }
    $plan = Get-HarnessReportPlan -Plugins $plugins -Layout $layout -Work $Tmp -Name 'sc'
    & $add 'report plan: only the plugins of the layout that declare a report, each with a file of this step in the work directory' $false (
        $plan.Count -eq 1 -and $plan[0].Plugin -ceq 'rec' -and $plan[0].Path -ceq (Join-Path $Tmp 'sc.report-rec.json') -and $plan[0].Copy -ceq (Join-Path $Tmp 'sc.report-rec.copy-'))
    $vars = Get-HarnessReportEnvironment $plan
    $jobRows = @(ConvertTo-HarnessReportJob $plan)
    & $add 'report plan: the variable names that file; the driver gets the file, the prefix of the copies and the period in seconds' $false (
        $vars.Count -eq 1 -and $vars['REC_JSON'] -ceq $plan[0].Path -and $jobRows.Count -eq 1 -and $jobRows[0].path -ceq $plan[0].Path -and $jobRows[0].copy -ceq $plan[0].Copy -and $jobRows[0].period -eq 0.25)
    $none = Get-HarnessReportPlan -Plugins $plugins -Layout ([pscustomobject]@{ Tracks = @([pscustomobject]@{ Name = 'A'; Fx = @([pscustomobject]@{ Plugin = 'mon' }) }) }) -Work $Tmp -Name 'sc'
    & $add 'report plan: a layout without a reporting plugin sets no variable' $true ($none.Count -eq 0 -and (Get-HarnessReportEnvironment $none).Count -eq 0)
    # One copy, checked
    $copy = Join-Path $Tmp 'report-copy.json'
    $readCopy = { param([string]$Json) [IO.File]::WriteAllText($copy, $Json); Read-HarnessReportCopy -Path $copy -Fields 'blocks', 'opens' -PidField 'pid' -ProcessId 4242 }
    $good = & $readCopy '{"schema":1,"pid":4242,"blocks":120,"opens":2.5,"name":"x","flag":true}'
    & $add 'report copy: the declared fields as numbers, nothing else of the file' $false ($null -eq $good.Problem -and (@($good.Numbers.get_Keys()) -join ',') -ceq 'blocks,opens' -and $good.Numbers['blocks'] -eq 120 -and $good.Numbers['opens'] -eq 2.5)
    $badCopies = @(
        @{ L = 'a copy that is not JSON'; B = 'not json'; W = 'it is not JSON' }
        @{ L = 'a key twice'; B = '{"pid":4242,"blocks":1,"blocks":2,"opens":1}'; W = 'it is not JSON' }
        @{ L = 'a JSON array'; B = '[1,2]'; W = 'it is not a JSON object' }
        @{ L = 'a pid that is a string'; B = '{"pid":"4242","blocks":1,"opens":1}'; W = 'its pid is not an integer' }
        @{ L = 'no pid'; B = '{"blocks":1,"opens":1}'; W = 'its pid is not an integer' }
        @{ L = 'the pid of another process'; B = '{"pid":4243,"blocks":1,"opens":1}'; W = 'it was written by process 4243, not by the REAPER of this step (4242)' }
        @{ L = 'a declared field missing'; B = '{"pid":4242,"blocks":1}'; W = 'it has no field opens' }
        @{ L = 'a declared field null'; B = '{"pid":4242,"blocks":null,"opens":1}'; W = 'it has no field blocks' }
        @{ L = 'a field that is a string'; B = '{"pid":4242,"blocks":"1","opens":1}'; W = 'its field blocks is not a number' }
        @{ L = 'a field that is true'; B = '{"pid":4242,"blocks":true,"opens":1}'; W = 'its field blocks is not a number' }
        @{ L = 'a field too large for a number'; B = '{"pid":4242,"blocks":1e999,"opens":1}'; W = 'its field blocks is not a number' }
        @{ L = 'a copy over 64 KiB'; B = ('{"pid":4242,"blocks":1,"opens":1,"pad":"' + ('x' * 65536) + '"}'); W = 'it is larger than 65536 bytes' }
    )
    foreach ($c in $badCopies) {
        $got = & $readCopy $c.B
        & $add "report copy: $($c.L) is no evidence ($($got.Problem))" $true ($null -eq $got.Numbers -and $got.Problem -ceq $c.W)
    }
    [IO.File]::WriteAllText($copy, '{"blocks":1}')
    $noPid = Read-HarnessReportCopy -Path $copy -Fields 'blocks' -ProcessId 4242
    & $add 'report copy: without a pid field the writer is not asked for' $false ($null -eq $noPid.Problem -and $noPid.Numbers['blocks'] -eq 1)
    # Reading k of a plan, from the driver's word on it
    $reading = { param([hashtable]$Said) (Read-HarnessReportReading -Facts $Said -Plan $plan -K 3 -ProcessId 4242)['rec'] }
    $copyFile = "$($plan[0].Copy)3.json"
    [IO.File]::WriteAllText($copyFile, '{"pid":4242,"blocks":7,"opens":0}')
    $fresh = @(foreach ($st in 'changed', 'quiet') { $got = (& $reading @{ rep1_3 = $st }); $got.Numbers ? $got.Numbers['blocks'] : "none: $($got.Problem)" })
    & $add "report reading: a changed or a quiet reading is read from its copy ($($fresh -join ', '))" $false (($fresh -join ',') -ceq '7,7')
    $words = @(
        @{ S = 'missing'; W = 'the plugin wrote no report (REC_JSON)' }; @{ S = 'toolarge'; W = 'its report is larger than 65536 bytes' }
        @{ S = 'stale'; W = 'no fresh report could be read in time' }; @{ S = 'busy'; W = 'its report kept changing where it had to stay the same: the plugin was still being run' }
        @{ S = 'Changed'; W = 'the driver took no reading' }; @{ S = $null; W = 'the driver took no reading' }
    )
    foreach ($w in $words) {
        $got = & $reading ($w.S ? @{ rep1_3 = $w.S } : @{})
        & $add "report reading: the driver's '$($w.S)' is no evidence ($($got.Problem)), whatever copy there is" $true ($null -eq $got.Numbers -and $got.Problem -ceq $w.W)
    }
    Remove-Item -LiteralPath $copyFile
    & $add 'report reading: a fresh reading without its copy is no evidence' $true ((& $reading @{ rep1_3 = 'changed' }).Problem -ceq 'no copy of it was made')
    # Criteria against two readings
    $val = { param([double]$BlockCount, [double]$OpenCount) [ordered]@{ rec = [pscustomobject]@{ Numbers = [ordered]@{ blocks = $BlockCount; opens = $OpenCount }; Problem = $null } } }
    $bound = { param($Exact = $null, $Min = $null, $Max = $null) [pscustomobject]@{ Exact = $Exact; Min = $Min; Max = $Max } }
    $crit = [ordered]@{ rec = [ordered]@{ opens = [pscustomobject]@{ Delta = (& $bound 20); Value = $null }; blocks = [pscustomobject]@{ Delta = (& $bound -Min 1); Value = (& $bound -Max 1000) } } }
    $okCrit = Test-HarnessReportCriteria -Criteria $crit -Start (& $val 100 3) -End (& $val 150 23)
    & $add "report criteria: a delta and a range met; what was seen is said ($($okCrit.Text))" $false (
        $okCrit.Gaps.Count -eq 0 -and $okCrit.Problems.Count -eq 0 -and $okCrit.Text -ceq 'rec.opens=23 (+20) rec.blocks=150 (+50)' -and $okCrit.Facts['rec']['blocks'].delta -eq 50 -and $okCrit.Facts['rec']['opens'].start -eq 3)
    $critBad = @(
        @{ L = 'a delta one short'; E = (& $val 150 22); W = 'rec.opens grew by 19, expected 20' }
        @{ L = 'a delta one over'; E = (& $val 150 24); W = 'rec.opens grew by 21, expected 20' }
        @{ L = 'a delta under its minimum'; E = (& $val 100 23); W = 'rec.blocks grew by 0, expected 1..' }
        @{ L = 'a value over its maximum'; E = (& $val 1001 23); W = 'rec.blocks is 1001, expected ..1000' }
    )
    foreach ($c in $critBad) {
        $got = Test-HarnessReportCriteria -Criteria $crit -Start (& $val 100 3) -End $c.E
        & $add "report criteria: $($c.L) fails ($($got.Problems -join ' | '))" $true ($got.Gaps.Count -eq 0 -and $got.Problems.Count -eq 1 -and $got.Problems[0] -ceq $c.W)
    }
    $gapStart = [ordered]@{ rec = [pscustomobject]@{ Numbers = $null; Problem = 'no fresh report could be read in time' } }
    $gapped = Test-HarnessReportCriteria -Criteria $crit -Start $gapStart -End (& $val 150 23)
    & $add "report criteria: a reading that is no evidence leaves the plugin unjudged ($($gapped.Gaps -join ' | '))" $true (
        $gapped.Problems.Count -eq 0 -and $gapped.Gaps.Count -eq 1 -and $gapped.Gaps[0] -ceq 'the report of rec is no evidence: no fresh report could be read in time')
    $unjudged = Test-HarnessReportCriteria -Start (& $val 1 2) -End (& $val 5 2)
    & $add 'report criteria: without criteria the fields are recorded and nothing is judged' $false ($unjudged.Problems.Count -eq 0 -and $unjudged.Text -ceq '' -and $unjudged.Facts['rec']['blocks'].delta -eq 4)
    # A transport state with windows and report criteria
    $st = { param($Windows = $null, $Judged = [ordered]@{}, $Expect = $null) [pscustomobject]@{ Name = 's'; Transport = 'play'; Arm = $false; Monitor = 'off'; Samples = 4800; Windows = $Windows; Report = $Judged; Expect = $Expect } }
    $rowOf = {
        param([hashtable]$Set = @{})
        $v = [ordered]@{ clock = 10; clock_samples = 5120; blocks = 10; samples = 5120; silent = 10; signal = 0; left = 0; right = 0; equal = 0; fed = 0; fed_samples = 0; playstate = 1; arm = 0; monitor = 0; monitoring = 0; win_open = 20; win_closed = 20 }
        foreach ($k in $Set.get_Keys()) { $v[$k] = $Set[$k] }
        [pscustomobject]$v
    }
    $win = [pscustomobject]@{ Plugin = 'rec'; Count = 20; MaxBlockDiff = 4; Fx = 1 }
    $okWin = Test-HarnessTransportState -State (& $st $win) -Row (& $rowOf)
    & $add "windows: 20 of 20 opened and closed, the chain ran with the device: PASS ($($okWin.Line))" $false ($okWin.Status -ceq 'PASS' -and $okWin.Line -clike '* windows=20/20 of 20')
    & $add 'windows: a chain 4 blocks behind the device is within the tolerance' $false ((Test-HarnessTransportState -State (& $st $win) -Row (& $rowOf @{ blocks = 6 })).Status -ceq 'PASS')
    $calledNot = [pscustomobject]@{ Called = $false; Input = $null; Channels = $null; Monitoring = $null }
    & $add 'windows: a state whose chain must not run is not held to the device''s blocks' $false ((Test-HarnessTransportState -State (& $st $win -Expect $calledNot) -Row (& $rowOf @{ blocks = 0 })).Status -ceq 'PASS')
    $winBad = @(
        @{ L = 'a window that opened 19 times'; S = @{ win_open = 19 }; W = 'the window of rec opened 19 of 20 times' }
        @{ L = 'a window that closed 18 times'; S = @{ win_closed = 18 }; W = 'the window of rec closed 18 of 20 times' }
        @{ L = 'a chain 5 blocks behind'; S = @{ blocks = 5 }; W = 'the chain ran 5 blocks and the device 10 while the window opened and closed, more than 4 apart' }
        @{ L = 'a chain 5 blocks ahead'; S = @{ blocks = 15 }; W = 'the chain ran 15 blocks and the device 10 while the window opened and closed, more than 4 apart' }
    )
    foreach ($c in $winBad) {
        $got = Test-HarnessTransportState -State (& $st $win) -Row (& $rowOf $c.S)
        & $add "windows: $($c.L) fails ($($got.Line))" $true ($got.Status -ceq 'FAIL' -and @($got.Problems).Count -eq 1 -and $got.Problems[0] -ceq $c.W)
    }
    $noCount = Test-HarnessTransportState -State (& $st $win) -Row (& $rowOf @{ win_open = $null })
    & $add 'windows: no window counts from the driver is no evidence' $true ($noCount.Status -ceq 'INCOMPLETE' -and $noCount.Line -clike '*no evidence: the driver reported no window counts')
    $readings = { param($Start, $End) @{ Start = $Start; End = $End } }
    $repOk = Test-HarnessTransportState -State (& $st $win $crit) -Row (& $rowOf) -Readings (& $readings (& $val 100 3) (& $val 150 23))
    & $add "state report: criteria met with the windows: PASS, the line says what the plugin reported ($($repOk.Line))" $false ($repOk.Status -ceq 'PASS' -and $repOk.Line -clike '* windows=20/20 of 20 report rec.opens=23 (+20) rec.blocks=150 (+50)')
    $repBad = Test-HarnessTransportState -State (& $st $win $crit) -Row (& $rowOf) -Readings (& $readings (& $val 100 3) (& $val 150 22))
    & $add 'state report: a criterion not met fails the state' $true ($repBad.Status -ceq 'FAIL' -and $repBad.Problems -ccontains 'rec.opens grew by 19, expected 20')
    $repGap = Test-HarnessTransportState -State (& $st $win $crit) -Row (& $rowOf) -Readings (& $readings $gapStart (& $val 150 23))
    & $add 'state report: a reading that is no evidence makes the state INCOMPLETE' $true ($repGap.Status -ceq 'INCOMPLETE' -and $repGap.Problems -ccontains 'the report of rec is no evidence: no fresh report could be read in time')
    $repNone = Test-HarnessTransportState -State (& $st $null $crit ([pscustomobject]@{ Called = $null; Input = $null; Channels = $null; Monitoring = $null })) -Row (& $rowOf)
    & $add 'state report: criteria without readings are no evidence' $true ($repNone.Status -ceq 'INCOMPLETE' -and $repNone.Problems -ccontains 'no report was read')
    $older = [pscustomobject]@{ Name = 's'; Transport = 'play'; Arm = $false; Monitor = 'off'; Samples = 4800; Expect = [pscustomobject]@{ Called = $true; Input = $null; Channels = $null; Monitoring = $null } }
    & $add 'transport state: a state without Windows and Report (an older caller''s or an extension''s) is judged, with readings or without, and nothing throws' $false (& $holds {
            (Test-HarnessTransportState -State $older -Row (& $rowOf)).Status -ceq 'PASS' -and (Test-HarnessTransportState -State $older -Row (& $rowOf) -Readings (& $readings (& $val 100 3) (& $val 150 23))).Status -ceq 'PASS' })
    # "Inform plug-ins of offline rendering state": bit 8 of vstfullstate, the other bits kept
    & $add 'offline-state preference: only bit 8 changes; without a key it starts from what REAPER reads then (49989, on)' $false (
        (Get-HarnessVstFullState '49989' $false) -eq 49733 -and (Get-HarnessVstFullState '49733' $true) -eq 49989 -and (Get-HarnessVstFullState '49989' $true) -eq 49989 -and (Get-HarnessVstFullState '0' $true) -eq 256 -and
        (Get-HarnessVstFullState $null $false) -eq 49733 -and (Get-HarnessVstFullState '' $true) -eq 49989 -and (Get-HarnessVstFullState 'x' $true) -eq 49989)
    $vsRead = { param($Reads, $Asked) @(Test-HarnessHostReadback -Facts @{ dev_bsize = '512'; dev_srate = '48000'; cfg_workrender = '1'; cfg_vstfullstate = $Reads } -Block 512 -Sr 48000 -AnticipativeFx $true -InformOfflineState $Asked) }
    & $add 'offline-state preference: the bit that was asked for reads back' $false ((& $vsRead '49989' $true).Count -eq 0 -and (& $vsRead '49733' $false).Count -eq 0)
    & $add 'offline-state preference: another bit reads as a problem, in both directions' $true (
        ((& $vsRead '49733' $true) -join ';') -ceq 'Inform plug-ins of offline rendering state reads off, expected on' -and ((& $vsRead '49989' $false) -join ';') -ceq 'Inform plug-ins of offline rendering state reads on, expected off')
    & $add 'offline-state preference: an unreadable value is a problem' $true (((& $vsRead 'unavailable' $true) -join ';') -ceq "vstfullstate reads 'unavailable'")
    & $add 'offline-state preference: not asked for, it is not looked at' $false ((Test-HarnessHostReadback -Facts @{ dev_bsize = '512'; dev_srate = '48000'; cfg_workrender = '1' } -Block 512 -Sr 48000 -AnticipativeFx $true).Count -eq 0)
    # What a render left: the same check for both ways of rendering
    $wavFile = Join-Path $Tmp 'gap.wav'; $stemFile = Join-Path $Tmp 'gap-stem.wav'
    & $add 'render files: no file is a gap, whatever else is there' $true ((Get-HarnessRenderGap $wavFile) -ceq 'the render produced no file')
    [IO.File]::WriteAllText($wavFile, 'x')
    & $add 'render files: a stem that is not there is a gap, and it is named' $true ((Get-HarnessRenderGap $wavFile @($stemFile)) -ceq 'the render produced no stem file gap-stem.wav')
    [IO.File]::WriteAllText($stemFile, 'x')
    & $add 'render files: all of them there is no gap' $false ($null -eq (Get-HarnessRenderGap $wavFile @($stemFile)))
    # With a tail every file must have exactly the frames asked for
    $gapWav = { param([string]$GapLeaf, [int]$GapFrames) $p = Join-Path $Tmp $GapLeaf; [HarnessWav]::Write($p, 48000, 2, 'float32', $false, [double[]]::new(2 * $GapFrames)); $p }
    $gapMaster = & $gapWav 'gap-m.wav' 10; $gapStem = & $gapWav 'gap-s.wav' 10; $gapShort = & $gapWav 'gap-short.wav' 9
    & $add 'render files: with a tail, files of exactly the frames asked for are no gap' $false ($null -eq (Get-HarnessRenderGap $gapMaster @($gapStem) 10))
    & $add 'render files: with a tail, a master one frame short is a gap, named with its frames' $true ((Get-HarnessRenderGap $gapShort @($gapStem) 10) -ceq 'the render gap-short.wav has 9 frames, not 10: the tail was not rendered as asked')
    & $add 'render files: with a tail, a stem one frame short is a gap, and it is named' $true ((Get-HarnessRenderGap $gapMaster @($gapStem, $gapShort) 10) -ceq 'the render gap-short.wav has 9 frames, not 10: the tail was not rendered as asked')
    & $add 'render files: with a tail, a file whose header cannot be read is a gap; without one no header is read' $true (
        (Get-HarnessRenderGap $wavFile @() 10) -clike 'the render gap.wav cannot be read: WAV: *' -and $null -eq (Get-HarnessRenderGap $wavFile @($stemFile) 0))
    # The time the step gets, and what the driver is told
    $timed = [pscustomobject]@{ sr = 48000; settleSamples = 4800; states = @([pscustomobject]@{ Samples = 4800; Windows = $win }, [pscustomobject]@{ Samples = 9600; Windows = $null }) }
    & $add 'transport timeout: 20 s more for every window opened and closed, 60 s a state with reports' $false (
        [Math]::Abs((Get-HarnessTransportTimeout -Scenario $timed -LuaTimeoutSec 60) - 501.5) -lt 1e-9 -and [Math]::Abs((Get-HarnessTransportTimeout -Scenario $timed -LuaTimeoutSec 60 -Reports) - 621.5) -lt 1e-9)
    # What a configuration makes of reports and windows
    $cfgText = @'
{ "schema": 1, "name": "t",
  "plugins": { "rec": { "bundle": "R.vst3", "report": { "env": "REC_PROBE_JSON", "fields": ["blocksRealtime", "editorOpens"], "pid": "pid", "periodMs": 250 } }, "mon": { "bundle": "M.vst3" } },
  "layouts": { "one": { "tracks": [ { "name": "Voice", "source": true, "fx": [ { "plugin": "mon" }, { "plugin": "rec" } ] } ] } },
  "scenarios": [
    { "id": "t1", "kind": "transport", "layout": "one", "states": [
      { "name": "p", "transport": "play", "arm": false, "monitor": "off", "windows": { "plugin": "rec", "count": 20 }, "expect": { "report": { "rec": { "editorOpens": { "delta": 20 }, "blocksRealtime": { "delta": { "min": 1 } } } } } },
      { "name": "q", "transport": "play", "arm": false, "monitor": "off", "windows": { "plugin": "mon", "count": 3, "maxBlockDiff": 9 } } ] },
    { "id": "r1", "kind": "render", "layout": "one", "host": { "runFxWhenStopped": false, "informOfflineState": false }, "report": { "rec": { "blocksRealtime": { "value": 0 } } } } ] }
'@
    $cfgRes = Test-HarnessConfigData -Raw (ConvertFrom-HarnessJson $cfgText)
    $t1 = $cfgRes.Config ? $cfgRes.Config.Scenarios[0] : $null
    & $add "configuration: windows by the plugin's place on the tested track, tolerance 4 unless given; criteria per plugin and field; a state with windows only is judged ($(@($cfgRes.Problems) -join ' | '))" $false (& $holds {
            @($cfgRes.Problems).Count -eq 0 -and $t1.states[0].Windows.Fx -eq 1 -and $t1.states[0].Windows.MaxBlockDiff -eq 4 -and $t1.states[1].Windows.Fx -eq 0 -and $t1.states[1].Windows.MaxBlockDiff -eq 9 -and
            $cfgRes.Config.Plugins['rec'].Report.PeriodMs -eq 250 })
    & $add 'configuration: the criteria of a state are kept per plugin and field' $false (& $holds {
            $t1.states[0].Report['rec']['editorOpens'].Delta.Exact -eq 20 -and $t1.states[0].Report['rec']['blocksRealtime'].Delta.Min -eq 1 -and $null -eq $t1.states[0].Report['rec']['blocksRealtime'].Value })
    & $add 'configuration: the criteria of a render are kept per plugin and field' $false (& $holds { $cfgRes.Config.Scenarios[1].report['rec']['blocksRealtime'].Value.Exact -eq 0 })
    & $add 'configuration: the offline-state preference is on unless a scenario turns it off' $false ($t1.host.InformOfflineState -eq $true -and $cfgRes.Config.Scenarios[1].host.InformOfflineState -eq $false)
    $noPeriod = Test-HarnessConfigData -Raw (ConvertFrom-HarnessJson $cfgText.Replace(', "periodMs": 250', ''))
    & $add 'configuration: a report writes every 500 ms unless it says otherwise' $false (@($noPeriod.Problems).Count -eq 0 -and $noPeriod.Config.Plugins['rec'].Report.PeriodMs -eq 500)
    $upTo = Test-HarnessConfigData -Raw (ConvertFrom-HarnessJson $cfgText.Replace('{ "min": 1 }', '{ "max": 7 }'))
    & $add 'configuration: a range with only a maximum keeps it' $false (& $holds { @($upTo.Problems).Count -eq 0 -and $upTo.Config.Scenarios[0].states[0].Report['rec']['blocksRealtime'].Delta.Max -eq 7 -and $null -eq $upTo.Config.Scenarios[0].states[0].Report['rec']['blocksRealtime'].Delta.Min })
    $onlyWindows = Test-HarnessConfigData -Raw (ConvertFrom-HarnessJson $cfgText.Replace(', "expect": { "report": { "rec": { "editorOpens": { "delta": 20 }, "blocksRealtime": { "delta": { "min": 1 } } } } }', ''))
    & $add "configuration: a scenario whose states have windows and no expect judges something ($(@($onlyWindows.Problems) -join ' | '))" $false (@($onlyWindows.Problems).Count -eq 0)
    if ($t1) {
        $job = Get-HarnessTransportJob -Scenario $t1 -Layout $cfgRes.Config.Layouts['one'] -Tools @{ 'harness-block-probe' = 'JS:p'; 'harness-feed' = 'JS:f' } -RecordDir 'R'
        & $add 'transport job: the window''s FX counts the block probe in front of the chain' $false ($job.states[0].windows.fx -eq 2 -and $job.states[0].windows.count -eq 20 -and $job.states[1].windows.fx -eq 1)
    }
    $cfgBad = @(
        @{ L = 'a report variable REAPER reads'; F = '"REC_PROBE_JSON"'; T = '"REAPER_X"'; W = "config.plugins.rec.report.env: 'REAPER_X' starts with REAPER_*" }
        @{ L = 'the same variable for two plugins'; F = '"bundle": "M.vst3" }'; T = '"bundle": "M.vst3", "report": { "env": "REC_PROBE_JSON", "fields": ["a"] } }'; W = "config.plugins.mon.report.env: 'REC_PROBE_JSON' is the report variable of rec too" }
        @{ L = 'a field the report does not declare'; F = '"editorOpens": { "delta": 20 }'; T = '"nope": { "delta": 20 }'; W = "*.expect.report.rec.nope: 'nope' is not one of the report's fields" }
        @{ L = 'a criterion with neither delta nor value'; F = '"editorOpens": { "delta": 20 }'; T = '"editorOpens": { }'; W = '*.expect.report.rec.editorOpens: needs delta or value' }
        @{ L = 'a range with neither end'; F = '{ "min": 1 }'; T = '{ }'; W = '*.expect.report.rec.blocksRealtime.delta: needs min or max' }
        @{ L = 'a range upside down'; F = '{ "min": 1 }'; T = '{ "min": 5, "max": 1 }'; W = '*.expect.report.rec.blocksRealtime.delta: min is above max' }
        @{ L = 'criteria of a plugin without a report'; F = '"report": { "rec": { "blocksRealtime": { "value": 0 } } }'; T = '"report": { "mon": { "x": { "value": 0 } } }'; W = "config.scenarios[[]1[]].report.mon: plugin 'mon' declares no report" }
        @{ L = 'a judged plugin twice in the layout'; F = '{ "plugin": "rec" } ]'; T = '{ "plugin": "rec" }, { "plugin": "rec" } ]'; W = "*.expect.report.rec: the layout uses 'rec' 2 times; a judged report needs exactly one instance"; N = 3 }
        @{ L = 'a judged render with Run FX when stopped on'; F = '"runFxWhenStopped": false, '; T = ''; W = 'config.scenarios[[]1[]].report: judging a render by a report needs host.runFxWhenStopped false: *' }
        @{ L = 'a window of a plugin that is not on the tested track'; F = '"plugin": "mon", "count": 3'; T = '"plugin": "ghost", "count": 3'; W = "*.windows.plugin: 'ghost' is on the tested track 0 times; its window needs exactly one" }
        @{ L = 'a repeat that reports its residual and judges plugin reports'; F = '"report": { "rec": { "blocksRealtime": { "value": 0 } } }'; T = '"report": { "rec": { "blocksRealtime": { "value": 0 } } }, "compare": "repeat", "maxDiffDb": "report"'; W = 'config.scenarios[[]1[]].report: a repeat that reports its residual cannot judge plugin reports as well*' }
        @{ L = 'a repeat with a stem that reports its residual and plugin reports judged'; F = '"report": { "rec": { "blocksRealtime": { "value": 0 } } }'; T = '"report": { "rec": { "blocksRealtime": { "value": 0 } } }, "compare": "repeat", "stems": [ { "track": "Voice", "maxDiffDb": "report" } ]'; W = 'config.scenarios[[]1[]].report: a repeat that reports its residual cannot judge plugin reports as well*' }
        @{ L = 'a window of a plugin twice on the tested track'; F = '{ "plugin": "mon" },'; T = '{ "plugin": "mon" }, { "plugin": "mon" },'; W = "*.windows.plugin: 'mon' is on the tested track 2 times; its window needs exactly one" }
    )
    foreach ($c in $cfgBad) {
        if (-not $cfgText.Contains($c.F)) { & $add "configuration: $($c.L) (the sample to change is gone)" $true $false; continue }
        $res = Test-HarnessConfigData -Raw (ConvertFrom-HarnessJson ($cfgText.Replace($c.F, $c.T)))
        & $add "configuration: $($c.L) is refused ($(@($res.Problems) -join ' | '))" $true (@($res.Problems).Count -eq ($c['N'] ?? 1) -and @($res.Problems | Where-Object { $_ -clike $c.W }).Count -eq 1)
    }
    foreach ($fine in '"compare": "repeat"', '"maxDiffDb": "report"') {
        $res = Test-HarnessConfigData -Raw (ConvertFrom-HarnessJson ($cfgText.Replace('"report": { "rec": { "blocksRealtime": { "value": 0 } } }', '"report": { "rec": { "blocksRealtime": { "value": 0 } } }, ' + $fine)))
        & $add "configuration: plugin reports go with a repeat that judges its residual, and with a residual reported against dry ($fine$(@($res.Problems | ForEach-Object { ": $_" }) -join ''))" $false (@($res.Problems).Count -eq 0)
    }
    # The schema refuses the empty objects the validator refuses, so that an editor does not pass what a run will not
    $schemaText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'schema/config.schema.json'))
    $agree = { param([string]$Json, [bool]$Accepted) $schemaOk = try { Test-Json -Json $Json -Schema $schemaText -ErrorAction Stop } catch { $false }; $schemaOk -eq $Accepted }
    & $add 'schema: Test-Json accepts the configuration with reports and windows, like the validator' $false (& $agree $cfgText $true)
    $empties = @(
        @{ L = 'an empty range'; F = '{ "min": 1 }'; T = '{ }' }
        @{ L = 'an empty criterion'; F = '"editorOpens": { "delta": 20 }'; T = '"editorOpens": { }' }
        @{ L = 'an empty expectation of a state'; F = '"expect": { "report": { "rec": { "editorOpens": { "delta": 20 }, "blocksRealtime": { "delta": { "min": 1 } } } } }'; T = '"expect": { }' }
    )
    foreach ($c in $empties) {
        $emptyJson = $cfgText.Replace($c.F, $c.T)
        $res = Test-HarnessConfigData -Raw (ConvertFrom-HarnessJson $emptyJson)
        & $add "schema: Test-Json rejects $($c.L), like the validator ($(@($res.Problems) -join ' | '))" $true ($emptyJson -cne $cfgText -and @($res.Problems).Count -eq 1 -and (& $agree $emptyJson $false))
    }
    $cases
}

# ---------------------------------------------------------------- wiring
function Get-WiringCases([string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    # Commands called inside a function, from the syntax tree (not from text)
    $callsIn = {
        param($file, $functionName)
        $parsed = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $fn = $parsed.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
        @($fn.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { [pscustomobject]@{ Name = $_.GetCommandName(); At = $_.Extent.StartOffset } })
    }
    $at = { param($calls, $name) @($calls | Where-Object { $_.Name -eq $name } | ForEach-Object { $_.At }) }
    $suite = & $callsIn (Join-Path $RepoRoot 'src/Suite.psm1') 'Invoke-HarnessSuite'
    & $add 'wiring: Invoke-HarnessSuite judges negative rows through Invoke-HarnessNegativeRow (outcome and reason), never runs guards or compares outcomes itself' $false ('Invoke-HarnessNegativeRow' -in $suite.Name -and 'Invoke-HarnessGuardNegative' -notin $suite.Name -and 'Get-HarnessNegativeVerdict' -notin $suite.Name)
    & $add 'wiring: Invoke-HarnessSuite pins the configuration directory before anything else, and runs the preflight before installing plugins' $false ($suite[0].Name -eq 'Initialize-HarnessCfg' -and (& $at $suite 'Get-HarnessPreflight')[0] -lt (& $at $suite 'Install-HarnessPlugins')[0])
    & $add 'wiring: Invoke-HarnessSuite reads the states with the configuration and checks them against moduleinfo after the preflight, before installing anything' $false (
        (& $at $suite 'Read-HarnessStates')[0] -lt (& $at $suite 'Get-HarnessPreflight')[0] -and (& $at $suite 'Get-HarnessPreflight')[0] -lt (& $at $suite 'Assert-HarnessStateIdentity')[0] -and
        (& $at $suite 'Assert-HarnessStateIdentity')[0] -lt (& $at $suite 'Install-HarnessPlugins')[0] -and (& $at $suite 'Assert-HarnessStateIdentity')[0] -lt (& $at $suite 'Install-HarnessJsfx')[0])
    & $add 'wiring: Invoke-HarnessSuite lists the default resource directory before and after every round' $false (@(& $at $suite 'Get-HarnessDefaultCfgSnapshot').Count -eq 2 -and 'Compare-HarnessDefaultCfgSnapshot' -in $suite.Name)
    # A parameter listing is read in the one learn launch of a guarded round, and nowhere else: the listing and the
    # learn launch are called only by Invoke-HarnessSuite, between its two listings of the default resource directory;
    # run.ps1 and doctor.ps1 start nothing themselves
    $callers = { param([string[]]$Names) @(foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Filter '*.psm1') + @(Get-Item (Join-Path $RepoRoot 'run.ps1'), (Join-Path $RepoRoot 'doctor.ps1'))) {
                $tree = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
                foreach ($c in $tree.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in $Names }, $true)) {
                    $fn = $c.Parent
                    while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
                    "$($c.GetCommandName())<-$($f.Name):$($fn ? $fn.Name : 'top')"
                }
            }) }
    $listCallers = & $callers @('Get-HarnessParamListing', 'Invoke-HarnessLearn')
    $snaps = & $at $suite 'Get-HarnessDefaultCfgSnapshot'
    $inRound = @(foreach ($n in 'Get-HarnessParamListing', 'Invoke-HarnessLearn') { foreach ($pos in (& $at $suite $n)) { $pos -gt $snaps[0] -and $pos -lt $snaps[1] } })
    & $add "wiring: the listing and the learn launch are called only by Invoke-HarnessSuite, inside the round ($(@($listCallers | Sort-Object -Unique) -join ', '))" $false (
        (@($listCallers | Sort-Object -Unique) -join ',') -ceq 'Get-HarnessParamListing<-Suite.psm1:Invoke-HarnessSuite,Invoke-HarnessLearn<-Suite.psm1:Invoke-HarnessSuite' -and
        $snaps.Count -eq 2 -and $inRound.Count -eq 3 -and $inRound -notcontains $false)
    # The block hash of a kept render's manifest and of a listing is computed in one place, so the two cannot drift apart
    $shaCallers = @(& $callers @('Get-HarnessBlockTextSha') | Sort-Object -Unique)
    $ownHash = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Filter '*.psm1' | Where-Object { $_.Name -cne 'Rpp.psm1' -and [IO.File]::ReadAllText($_.FullName) -cmatch 'HashData\([^\r\n]*Get-HarnessBlockText\b' } | ForEach-Object { $_.Name })
    & $add "wiring: a kept render's manifest and a listing take the block hash from one helper, Get-HarnessBlockTextSha ($($shaCallers -join ', '))" $false (
        ($shaCallers -join ',') -ceq 'Get-HarnessBlockTextSha<-Learn.psm1:Get-HarnessParamListing,Get-HarnessBlockTextSha<-Renders.psm1:Get-HarnessFxFacts' -and $ownHash.Count -eq 0)
    $scriptStarts = & $callers @('Invoke-HarnessLuaStep', 'Invoke-HarnessLaunch', 'Invoke-HarnessLaunchOnce', 'Invoke-HarnessHost', 'Invoke-HarnessLearn')
    & $add "wiring: run.ps1 and doctor.ps1 start no REAPER and no step themselves ($(@($scriptStarts | Where-Object { $_ -cmatch '<-(run|doctor)\.ps1:' }) -join ', '))" $false (
        @($scriptStarts | Where-Object { $_ -cmatch '<-(run|doctor)\.ps1:' }).Count -eq 0)
    $launch = & $callsIn (Join-Path $RepoRoot 'src/Scenarios.psm1') 'Invoke-HarnessLaunchOnce'
    & $add 'wiring: every launch takes the GUI locks before starting REAPER and checks the skip marker again while holding them' $false (
        (& $at $launch 'Enter-HarnessLocks')[0] -lt (& $at $launch 'Invoke-HarnessHost')[0] -and @(& $at $launch 'Get-HarnessSkipMarkerHit').Count -eq 2 -and (& $at $launch 'Get-HarnessSkipMarkerHit')[1] -lt (& $at $launch 'Invoke-HarnessHost')[0])
    # The retry of a launch goes through all of that again: it calls the guarded launch, never the host or the locks itself,
    # and no other code calls the guarded launch or the host
    $retry = & $callsIn (Join-Path $RepoRoot 'src/Scenarios.psm1') 'Invoke-HarnessLaunch'
    $hostCallers = @(foreach ($m in (Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Filter '*.psm1')) {
            $tree = [System.Management.Automation.Language.Parser]::ParseFile($m.FullName, [ref]$null, [ref]$null)
            foreach ($c in $tree.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in 'Invoke-HarnessHost', 'Invoke-HarnessLaunchOnce' }, $true)) {
                $fn = $c.Parent
                while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
                "$($c.GetCommandName())<-$($fn ? $fn.Name : 'top')"
            }
        })
    & $add "wiring: a retried launch starts REAPER only through the guarded launch, at most twice; nothing else calls it or the host ($($hostCallers -join ', '))" $false (
        @(& $at $retry 'Invoke-HarnessLaunchOnce').Count -eq 2 -and 'Invoke-HarnessHost' -notin $retry.Name -and 'Enter-HarnessLocks' -notin $retry.Name -and
        (@($hostCallers | Sort-Object) -join ',') -ceq 'Invoke-HarnessHost<-Invoke-HarnessLaunchOnce,Invoke-HarnessLaunchOnce<-Invoke-HarnessLaunch,Invoke-HarnessLaunchOnce<-Invoke-HarnessLaunch')
    # The learn project and the check of what REAPER saved must agree on the track names, so both get the same list
    $learnAst = ([System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'src/Learn.psm1'), [ref]$null, [ref]$null)).Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-HarnessLearn' }, $true)
    $namesArg = {
        param([string]$Command)
        @($learnAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $Command }, $true) | ForEach-Object {
                $el = $_.CommandElements
                for ($i = 1; $i -lt $el.Count - 1; $i++) { if ($el[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $el[$i].ParameterName -eq 'TrackNames') { [string]$el[$i + 1].Extent.Text } }
            })
    }
    $learnCalls = & $callsIn (Join-Path $RepoRoot 'src/Learn.psm1') 'Invoke-HarnessLearn'
    & $add 'wiring: Invoke-HarnessLearn names the learn tracks once and gives the same names to the learn project and to the check of the saved one' $false (
        @(& $at $learnCalls 'Get-HarnessLearnTrackNames').Count -eq 1 -and (& $at $learnCalls 'Get-HarnessLearnTrackNames')[0] -lt (& $at $learnCalls 'New-HarnessLearnProjectText')[0] -and
        ((& $namesArg 'New-HarnessLearnProjectText') -join ',') -ceq '$learnNames' -and ((& $namesArg 'Test-HarnessLearnReport') -join ',') -ceq '$learnNames')
    # expectPdc is an integer or the word "report", and its type says which: an equality with the word would only hold
    # because PowerShell takes a word that does not convert to an integer as unequal, so no source compares with it.
    # The one exception is maxDiffDb: criteria built by hand (an extension's Judge) are not validated, so only the exact
    # word may mean a reported residual, and Test-HarnessResidualReported compares it, after testing its type
    $wordHelper = 'Test-HarnessResidualReported'
    $reportWord = @(foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Filter '*.psm1')) {
            $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $fileAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$node.Operator -cin 'Ieq', 'Ceq', 'Ine', 'Cne' -and
                    @(@($node.Left, $node.Right) | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -ceq 'report' }).Count -gt 0
                }, $true) | Where-Object {
                    $up = $_.Parent
                    while ($up -and $up -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $up = $up.Parent }
                    -not ($f.Name -ceq 'Config.psm1' -and $up -and $up.Name -ceq $wordHelper)
                } | ForEach-Object { "$($f.Name): $($_.Extent.Text)" }
        })
    $fxReportAst = ([System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'src/Scenarios.psm1'), [ref]$null, [ref]$null)).Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-HarnessFxReport' }, $true)
    $typeTests = @($fxReportAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$node.Operator -cin 'Is', 'IsNot' -and $node.Right.Extent.Text -ceq '[string]' }, $true))
    $wordAst = ([System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'src/Config.psm1'), [ref]$null, [ref]$null)).Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $wordHelper }, $true)
    $wordBody = $wordAst ? $wordAst.Body.Extent.Text : ''
    & $add "wiring: whether a latency is only reported is told by the type of expectPdc (Test-HarnessFxReport tests it); no source compares with the word 'report' but $wordHelper, which tests the type first and then the exact word ($($reportWord -join ' | '))" $false (
        $reportWord.Count -eq 0 -and $typeTests.Count -eq 1 -and $wordBody -cmatch "^\{ \`$\w+\.maxDiffDb -is \[string\] -and \`$\w+\.maxDiffDb -ceq 'report' \}`$")
    $hostCalls = & $callsIn (Join-Path $RepoRoot 'src/Host.psm1') 'Invoke-HarnessHost'
    & $add 'wiring: Invoke-HarnessHost builds the command line from Get-HarnessCfgArgument (which checks the directory again)' $false ('Get-HarnessCfgArgument' -in $hostCalls.Name)
    # REAPER cannot run here, so only the text of the driver can be looked at: the sampler waits for this mark, and with
    # warmup 0 the loop never gets to write it
    $driverText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'lua/driver.lua'))
    & $add 'wiring: with warmup 0 the driver writes the warm-up mark before the first cycle' $true ($driverText -cmatch '(?s)if job\.warmup == 0 then[^\n]*\n\s*touch\(job\.warmMark\).*?for i = 1, job\.cycles do')
    & $add 'wiring: with warm-up cycles the driver writes the mark after the last of them' $true ($driverText -cmatch '(?s)for i = 1, job\.cycles do.*?if i == job\.warmup then\s*touch\(job\.warmMark\)')
    # The transport step may toggle arming, monitoring and the transport, and must never record
    $actions = @([regex]::Matches($driverText, 'Main_OnCommand\w*\s*\(\s*(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    & $add "driver: the only actions it calls are File: Quit (40004), File: New project (40023) and Render with the project's settings, auto-close (42230) ($($actions -join ', '))" $true (($actions -join ',') -ceq '40004,40023,42230')
    & $add 'driver: the render action is called in the render step only, between the two readings' $true ($driverText -cmatch '(?s)function steps\.render\(\).*readReports\(1, true\)\s+reaper\.Main_OnCommand\(42230, 0\)\s+readReports\(2\)\s+end' -and @([regex]::Matches($driverText, '42230, 0')).Count -eq 1)
    & $add 'driver: the render step reports the preference, and takes its first reading after run FX after stopping is over' $true ($driverText -cmatch '(?s)function steps\.render\(\).*put\("cfg_vstfullstate", config\("vstfullstate"\)\)\s+wait\(\(\(tonumber\(config\("runafterstop"\)\) or 4000\) \+ 500\) / 1000\)\s+readReports\(1, true\)')
    & $add 'driver: a reading ends with a change, or after four write periods without one; a turn counts at most 100 ms; 30 s is the limit; settled, a change starts the four periods again' $true (
        $driverText -cmatch 'loop - since\[j\] >= 4 \* r\.period' -and $driverText -cmatch 'math\.min\(now - last, 0\.1\)' -and $driverText -cmatch 'local deadline = last \+ 30\b' -and
        $driverText -cmatch 'if settled then base\[j\], since\[j\], moved\[j\] = \{ t, s \}, loop, true else got\[j\] = \{ t, s, "changed" \} end')
    & $add 'driver: a turn in which a report that was there is missing (being replaced) is skipped before either way of reading looks at it' $true (
        $driverText -cmatch 'local t, s = readCapped\(r\.path\)\s+if s == "missing" and base\[j\]\[2\] == "ok" then\s+--[^\n]*\n\s+elseif t ~= base\[j\]\[1\] or s ~= base\[j\]\[2\] then\s+if settled then')
    $readBody = [regex]::Match($driverText, '(?s)\nlocal function readReports\(k, settled, check\)\r?\n.*?\r?\nend\r?\n').Value
    & $add 'driver: a reading runs the check it is handed after every turn of the message loop' $true (
        $readBody -cmatch 'coroutine\.yield\(\)\r?\n\s*if check then check\(\) end\r?\n' -and @([regex]::Matches($readBody, 'coroutine\.yield\(\)')).Count -eq 1)
    & $add 'driver: a window opens and closes as often as asked, the editor gets ten turns of the message loop, and every wait for it checks the record bit' $true (
        $driverText -cmatch 'for _ = 1, w\.count do' -and $driverText -cmatch 'for _ = 1, 10 do coroutine\.yield\(\) noRecord\(\) end' -and $driverText -cmatch 'noRecord\(\)\s+if reaper\.time_precise\(\) > limit then return false end')
    # Every project with plugins and every read-back carries the preference: a scenario cannot lose it on the way (the
    # dry reference has no plugin to tell)
    $scenarioTree = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'src/Scenarios.psm1'), [ref]$null, [ref]$null)
    $hostCalls = { param($name) @($scenarioTree.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq $name }, $true)) }
    $hasPreference = { param($call) @($call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ceq 'InformOfflineState' }).Count -eq 1 }
    $projects = & $hostCalls 'New-HarnessRun'
    $readBacks = & $hostCalls 'Test-HarnessHostReadback'
    & $add "wiring: every project with plugins and every read-back passes the offline-state preference ($($projects.Count) and $($readBacks.Count))" $true (
        $projects.Count -ge 7 -and @($projects | Where-Object { $_.Extent.Text -cnotlike '* -NoFx*' -and -not (& $hasPreference $_) }).Count -eq 0 -and $readBacks.Count -ge 3 -and @($readBacks | Where-Object { -not (& $hasPreference $_) }).Count -eq 0)
    & $add 'driver: every report reading of a state is taken: 2n-1 after the settle time, 2n after the window' $true ($driverText -cmatch '(?s)put\(p \.\. "settled".*?readReports\(2 \* n - 1, false, noRecord\).*?local c0, t0, f0 = snap.*?local c1, t1, f1 = snap.*?readReports\(2 \* n, false, noRecord\)')
    & $add 'driver: a window is checked with TrackFX_GetFloatingWindow, opened with 3 and closed with 2, and closed once more at the end' $true (
        $driverText -cmatch 'TrackFX_GetFloatingWindow\(tested, w\.fx\) ~= nil' -and $driverText -cmatch 'TrackFX_Show\(tested, w\.fx, 3\)' -and @([regex]::Matches($driverText, 'TrackFX_Show\(tested, w\.fx, 2\)')).Count -eq 2)
    & $add 'driver: a report is read with a cap of 64 KiB, the same as the module''s' $true ($driverText -cmatch 'REPORT_MAX = 65536\b' -and $driverText -cmatch 'f:read\(REPORT_MAX \+ 1\)' -and ([IO.File]::ReadAllText((Join-Path $RepoRoot 'src/Report.psm1'))) -cmatch 'MaxBytes = 65536\b')
    & $add 'driver: no record call of any kind, and no action looked up by name' $true ($driverText -cnotmatch 'OnRecord|CSurf_|Main_OnCommandEx|NamedCommandLookup|Record\w*Button')
    # The transport step alone: it ends at the first "end" that is not indented
    $transportStep = [regex]::Match($driverText, '(?s)(?<=\n)function steps\.transport\(\)\r?\n.*?\r?\nend\r?\n').Value
    # The body of waitSamples alone (it ends at the first "end" of its own indentation): a later wait that checks the
    # record bit must not stand in for it
    $waitBody = [regex]::Match($transportStep, '(?s)\n( *)local function waitSamples\(n\)\r?\n.*?\r?\n\1end\r?\n').Value
    # Every loop of the transport step that gives up a turn checks the record bit in lines of its own (the lines of a loop
    # inside it are that loop's), no turn is given up outside a loop, and every reading the step takes gets the check
    $stepLines = $transportStep -split '\r?\n'
    $loops = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $stepLines.Count; $i++) {
        $m = [regex]::Match($stepLines[$i], '^( *)(?:for|while)\b.*\bdo\b(.*)$')
        if (-not $m.Success) { continue }
        $to = $i
        if ($m.Groups[2].Value -cnotmatch '\bend\s*$') { $to = $i + 1; while ($to -lt $stepLines.Count -and $stepLines[$to] -cne "$($m.Groups[1].Value)end") { $to++ } }
        $loops.Add([pscustomobject]@{ From = $i; To = $to })
    }
    $ownText = { param($l) @(for ($i = $l.From; $i -le $l.To; $i++) { if (-not @($loops | Where-Object { $_.From -gt $l.From -and $_.To -le $l.To -and $i -ge $_.From -and $i -le $_.To }).Count) { $stepLines[$i] } }) -join "`n" }
    $yielding = @($loops | Where-Object { (& $ownText $_).Contains('coroutine.yield()') })
    $unchecked = @($yielding | Where-Object { -not (& $ownText $_).Contains('noRecord()') } | ForEach-Object { $stepLines[$_.From].Trim() })
    $loose = @(for ($i = 0; $i -lt $stepLines.Count; $i++) { if ($stepLines[$i].Contains('coroutine.yield()') -and -not @($loops | Where-Object { $i -ge $_.From -and $i -le $_.To }).Count) { $stepLines[$i].Trim() } })
    & $add "driver: every loop of the transport step that gives up a turn checks the record bit in its own lines ($($yielding.Count) loops; unchecked: $($unchecked -join ' | '); outside a loop: $($loose -join ' | '))" $true (
        $yielding.Count -ge 4 -and $unchecked.Count -eq 0 -and $loose.Count -eq 0 -and $transportStep -cnotmatch '\brepeat\b')
    $stepReads = @([regex]::Matches($transportStep, 'readReports\(([^()]*)\)') | ForEach-Object { $_.Groups[1].Value })
    & $add "driver: every reading the transport step takes is handed the record check ($($stepReads -join ' | '))" $true ($stepReads.Count -eq 2 -and @($stepReads | Where-Object { $_ -cnotmatch ', noRecord$' }).Count -eq 0)
    $recModes = @([regex]::Matches($driverText, '"I_RECMODE",\s*(-?\d+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    & $add "driver: the transport step disables recording on its tracks (record mode 2 only: $($recModes -join ', ')), sets the record path before it arms anything, and every wait checks the record bit" $true (
        $transportStep.StartsWith('function steps.transport()', [StringComparison]::Ordinal) -and ($recModes -join ',') -ceq '2' -and
        $transportStep.IndexOf('"RECORD_PATH", job.recordDir, true') -gt 0 -and $transportStep.IndexOf('"RECORD_PATH", job.recordDir, true') -lt $transportStep.IndexOf('"I_RECARM"') -and
        $waitBody -cmatch 'while [^\n]*\n\s*noRecord\(\)' -and $transportStep -cmatch 'GetPlayState\(\) & 4 ~= 0')
    $pathStop = $transportStep.IndexOf('if not pathOk then error(')
    & $add 'driver: a record path that does not read back is reported and stops the step before anything is armed or the transport is touched' $true (
        $transportStep -cmatch 'local pathOk = setOk and path == job\.recordDir\r?\n\s*put\("record_path", pathOk and "ok" or "failed"\)' -and
        $pathStop -gt $transportStep.IndexOf('put("record_path"') -and $pathStop -lt $transportStep.IndexOf('"I_RECARM"') -and $pathStop -lt $transportStep.IndexOf('OnPlayButton') -and
        $pathStop -lt $transportStep.IndexOf('InsertTrackAtIndex'))
    # The tool JSFX and the driver agree on the shared memory and on the feed file the harness installs
    $probeText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'jsfx/harness-block-probe.jsfx'))
    $feedText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'jsfx/harness-feed.jsfx'))
    $pluginsText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'src/Plugins.psm1'))
    & $add 'tool JSFX: the probe, the feed and the driver share gmem ReaperHarness, 16 values a slot (clock 0, tested track 1, feed 2)' $false (
        $probeText -cmatch '(?m)^options:gmem=ReaperHarness\r?$' -and $feedText -cmatch '(?m)^options:gmem=ReaperHarness\r?$' -and $probeText -cmatch 'base = floor\(slider1 \+ 0\.5\) \* 16;' -and $feedText -cmatch 'base = floor\(slider1 \+ 0\.5\) \* 16;' -and
        $transportStep -cmatch 'gmem_attach\("ReaperHarness"\)' -and $transportStep -cmatch 'local CLOCK, TESTED, FEED = 0, 16, 32')
    $transportCalls = & $callsIn (Join-Path $RepoRoot 'src/Scenarios.psm1') 'Invoke-HarnessTransportScenario'
    & $add 'wiring: the transport scenario gives the Lua step the time Get-HarnessTransportTimeout works out' $true (
        'Get-HarnessTransportTimeout' -in $transportCalls.Name -and ([IO.File]::ReadAllText((Join-Path $RepoRoot 'src/Scenarios.psm1'))) -cmatch 'Step transport -Job \$Job -TimeoutSec \(Get-HarnessTransportTimeout ')
    & $add 'driver: every state reports the blocks and frames the feed played in its window' $true (
        $transportStep -cmatch 'f0 = snap\(CLOCK\), snap\(TESTED\), snap\(FEED\)' -and $transportStep -cmatch 'f1 = snap\(CLOCK\), snap\(TESTED\), snap\(FEED\)' -and
        $transportStep -cmatch 'put\(p \.\. "fed", int\(f1\[0\] - f0\[0\]\)\)' -and $transportStep -cmatch 'put\(p \.\. "fed_samples", int\(f1\[1\] - f0\[1\]\)\)')
    & $add 'tool JSFX: the feed starts its file over as often as a block needs (a file can be shorter than a block), and a read that yields less than a frame ends that' $true (
        $feedText -cmatch '(?s)more = nch;\s*while \(frames < samplesblock && more >= nch\) \(\s*file_rewind\(h\);\s*file_riff\(h, nch, fsr\);\s*more = file_mem\(')
    # A generation around the counts: the driver takes them only when no write was under way (the block itself cannot run here)
    $genStep = 'gen \+= 1;\s*gmem\[base \+ 10\] = gen;\s*'
    & $add 'tool JSFX: the block probe writes all its counts inside a generation (slot value 10, odd meanwhile)' $true (
        $probeText -cmatch "(?s)i === n \? \(\s*$($genStep)gmem\[base \+ 0\] \+= 1;.*gmem\[base \+ 2\] \+= 1;\s*\);\s*$($genStep)\);\s*`$" -and $probeText -cmatch '(?m)^gen = 0;\r?$')
    & $add 'tool JSFX: the feed writes its blocks and frames inside a generation (slot value 10, odd meanwhile)' $true (
        $feedText -cmatch "$($genStep)gmem\[base \+ 0\] \+= 1;\s*gmem\[base \+ 1\] \+= frames;\s*$genStep" -and $feedText -cmatch '(?m)^gen = 0;\r?$')
    & $add 'driver: a reading counts only with an even generation, the same before and after, and the tries are bounded' $true (
        $transportStep -cmatch 'local SNAP_TRIES = \d{1,4} ' -and
        $transportStep -cmatch '(?s)local function snap\(base\)\s*for _ = 1, SNAP_TRIES do\s*local g = reaper\.gmem_read\(base \+ 10\)\s*if g % 2 == 0 then\s*local v = \{\}\s*for i = 0, 15 do v\[i\] = reaper\.gmem_read\(base \+ i\) end\s*if reaper\.gmem_read\(base \+ 10\) == g then return v end\s*end\s*end\s*end')
    & $add 'driver: a state without a clean reading of all three slots, before and after, reports none of its counts' $true (
        $transportStep -cmatch '(?s)if c0 and t0 and f0 and c1 and t1 and f1 then\s*put\(p \.\. "clock", .*?put\(p \.\. "fed_samples", [^\n]*\n\s*end\s*put\(p \.\. "playstate"')
    $probeSampleAt = $probeText.IndexOf('@sample')
    $probeBlockAt = $probeText.IndexOf('@block')
    & $add 'tool JSFX: the block probe counts a block when its last sample has gone through, together with its silent and signal counts' $true (
        $probeBlockAt -gt 0 -and $probeSampleAt -gt $probeBlockAt -and $probeText.Substring($probeBlockAt, $probeSampleAt - $probeBlockAt) -cnotmatch 'gmem\[base \+ [0-6]\]' -and
        $probeText.Substring($probeSampleAt) -cmatch 'i === n \? \(\s*gen \+= 1;\s*gmem\[base \+ 10\] = gen;\s*gmem\[base \+ 0\] \+= 1;\s*gmem\[base \+ 1\] \+= n;\s*lsig \|\| rsig \? \(')
    & $add 'tool JSFX: the file the feed opens is the one the harness installs (Data\reaper-harness\feed.wav of the private directory)' $false (
        $feedText -cmatch 'file_open\("reaper-harness/feed\.wav"\)' -and $pluginsText -cmatch "Get-HarnessPrivateSubdir 'Data\\reaper-harness'\) 'feed\.wav'")
    & $add 'wiring: Invoke-HarnessSuite reads the feed files with the states, before the preflight and before installing anything' $false (
        'Read-HarnessFeeds' -in $suite.Name -and 'Install-HarnessToolJsfx' -in $suite.Name -and (& $at $suite 'Read-HarnessFeeds')[0] -gt (& $at $suite 'Read-HarnessStates')[0] -and (& $at $suite 'Read-HarnessFeeds')[0] -lt (& $at $suite 'Get-HarnessPreflight')[0] -and
        (& $at $suite 'Install-HarnessToolJsfx')[0] -gt (& $at $suite 'Assert-HarnessStateIdentity')[0])
    $sourcesAt = @(& $at $suite 'Read-HarnessSourceFiles')
    & $add 'wiring: Invoke-HarnessSuite reads the source files once, after picking the scenarios and reading the feeds, before the preflight, the plugin install and the scan shield' $false (
        $sourcesAt.Count -eq 1 -and $sourcesAt[0] -gt (& $at $suite 'Select-HarnessScenarios')[0] -and $sourcesAt[0] -gt (& $at $suite 'Read-HarnessFeeds')[0] -and
        $sourcesAt[0] -lt (& $at $suite 'Get-HarnessPreflight')[0] -and $sourcesAt[0] -lt (& $at $suite 'Install-HarnessPlugins')[0] -and $sourcesAt[0] -lt (& $at $suite 'Update-HarnessScanCache')[0])
    $suiteText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'src/Suite.psm1'))
    & $add 'wiring: the manifest names the configuration by the hash of the bytes Read-HarnessConfig parsed; Invoke-HarnessSuite hashes no file of its own' $false (
        'Get-HarnessSha256' -notin $suite.Name -and $suiteText -cmatch 'config = \[ordered\]@\{ name = \(Split-Path -Leaf \$Config\); sha256 = \$conf\.FileSha256 \}')
    # Below 7.4 the real path resolution meets members that do not exist; both entry points say so up front
    foreach ($script in 'run.ps1', 'doctor.ps1') {
        $wanted = ([System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $script), [ref]$null, [ref]$null)).ScriptRequirements.RequiredPSVersion
        & $add "wiring: $script requires PowerShell 7.4 (the minimum the README states)" $false ($wanted -eq [version]'7.4')
    }
    $self = & $callsIn (Join-Path $PSScriptRoot 'SelfTest.psm1') 'Invoke-HarnessSelfTest'
    $clearAt = @(& $at $self 'Clear-HarnessSelftestSubst')
    $makeAt = @(& $at $self 'New-HarnessTempDir')
    & $add 'wiring: the self-test clears subst residue before it creates its scratch directory' $false ($clearAt.Count -eq 1 -and $makeAt.Count -eq 1 -and $clearAt[0] -lt $makeAt[0])
    # Every source file starts with the licence identifier
    $noSpdx = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.lua' | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and -not (@(Get-Content -LiteralPath $_.FullName -TotalCount 5) -match 'SPDX-License-Identifier: MIT') } | ForEach-Object { $_.Name })
    & $add "licence: every script names its SPDX licence in its first lines ($($noSpdx -join ', '))" $false ($noSpdx.Count -eq 0)
    $cases
}

# ---------------------------------------------------------------- child process
function Get-ChildCases([string]$Tmp, [string]$RepoRoot, [string[]]$ExtraGuiLock) {
    # A space in the pinned directory, and a space and an apostrophe in the work directory: real paths have them, and the
    # command lines of the launch and of the stand-ins have to survive them
    $cfgA = Join-Path $Tmp 'child cfg a'; $cfgB = Join-Path $Tmp 'child-cfg-b'
    $null = New-HarnessCfgDir $cfgA; $null = New-HarnessCfgDir $cfgB
    $work = Join-Path $Tmp "child work o'brien"; $null = New-Item -ItemType Directory -Path $work
    $run = Invoke-Native -Exe (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'SelfTestChild.ps1'),
        '-RepoRoot', $RepoRoot, '-CfgA', $cfgA, '-CfgB', $cfgB, '-Work', $work, '-ExtraLocks', ($ExtraGuiLock -join ';'))
    $cases = New-CaseList
    foreach ($line in ($run.Out -split "`r?`n")) {
        $f = $line -split "`t", 4
        if ($f.Count -eq 4 -and $f[0] -eq 'RESULT') { $cases.Add([pscustomobject]@{ Label = $f[3]; Bad = ($f[1] -eq '1'); Passed = ($f[2] -eq '1') }) }
    }
    if ($run.Exit -ne 0 -or $cases.Count -eq 0) { $cases.Add([pscustomobject]@{ Label = "the child self-test failed (exit code $($run.Exit)): $(($run.Err + $run.Out).Trim() -replace '\s+', ' ')"; Bad = $false; Passed = $false }) }
    # A child that stops early with exit code 0 (an exit in the wrong place) must not look green: its last statement
    # prints a case, and the parent has to see it, with or without a desktop.
    $reachedEnd = @($cases | Where-Object { $_.Label -ceq 'child: reached its last statement' }).Count
    $cases.Add([pscustomobject]@{ Label = "child: the child process ran to its last statement (seen: $reachedEnd)"; Bad = $false; Passed = ($reachedEnd -eq 1) })
    # The real message box cases may only be missing where this session really has no desktop, and then the child has
    # to say so: a run that left them out by mistake must not look green
    $dialogs = @($cases | Where-Object { $_.Label -like 'dialog:*' }).Count
    $skipLines = @($cases | Where-Object { $_.Label -clike '(no interactive desktop in this session:*' }).Count
    $desktop = [Environment]::UserInteractive
    $cases.Add([pscustomobject]@{ Label = "child: the real message box cases ran whenever this session has a desktop; without one the child said they did not run (desktop: $desktop, cases: $dialogs, skip lines: $skipLines)"; Bad = $false; Passed = ($desktop ? $dialogs -ge 5 : $skipLines -eq 1) })
    $cases
}

# ---------------------------------------------------------------- summary
# A case whose precondition this machine lacks says so in its label with these words, which makes it countable: the
# summary line gives the number, and on GitHub Actions a warning annotation repeats it, so a green run that proved less
# than usual shows on the run's page and not only deep in its log.
$script:NotRunWords = 'run for real'
function Get-NotRunCount([object[]]$CaseList) { @($CaseList | Where-Object { $_.Label -clike "*$($script:NotRunWords)*" }).Count }
function Get-NotRunWarning([int]$NotRun, [string]$ActionsFlag) {
    if ($NotRun -lt 1 -or -not $ActionsFlag) { return $null }
    "::warning::reaper-harness self-test: $NotRun case line(s) did not $($script:NotRunWords) on this runner; search the log for '$($script:NotRunWords)'"
}

function Get-SummaryCases {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $sample = @(
        [pscustomobject]@{ Label = "first (this volume has no 8.3 short names; not $($script:NotRunWords))" }
        [pscustomobject]@{ Label = "(no subst drive could be made: the cases did not $($script:NotRunWords))" }
        [pscustomobject]@{ Label = 'an ordinary case that ran' }
    )
    & $add 'summary: only the cases whose label says they did not really run are counted' $false ((Get-NotRunCount $sample) -eq 2 -and (Get-NotRunCount @()) -eq 0)
    & $add 'summary: on GitHub Actions the count also goes out as a warning annotation, at the start of its line' $false ((Get-NotRunWarning -NotRun 2 -ActionsFlag 'true') -cmatch '^::warning::.* 2 case line')
    & $add 'summary: no warning outside GitHub Actions, and none when everything ran' $true ($null -eq (Get-NotRunWarning -NotRun 2 -ActionsFlag '') -and $null -eq (Get-NotRunWarning -NotRun 0 -ActionsFlag 'true'))
    $cases
}

function Invoke-HarnessSelfTest {
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$CollisionSample = '', [string[]]$ExtraGuiLock = @())
    $null = Get-HarnessGuiLockSet -Extra $ExtraGuiLock # a bad name is a usage error before anything starts
    $before = Get-HarnessDefaultCfgSnapshot
    # A self-test ended hard leaves subst letters pointing at deleted scratch directories: cleaned first (only those
    # pointing at scratch directories of the self-test; any other mapping is left alone), reported on the console
    foreach ($stale in (Clear-HarnessSelftestSubst)) {
        Write-Host ('  cleared a subst mapping left by an earlier self-test {0}: -> {1}{2}' -f $stale.Letter, $stale.Target, ($stale.Cleared ? '' : ' (could not be cleared)'))
    }
    $scratch = New-HarnessTempDir -Prefix $script:ScratchPrefix
    $savedRoaming = $env:APPDATA
    $cases = New-CaseList
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $fakeRoam = Join-Path $scratch 'Roaming-Fake-AppData'
        $null = New-Item -ItemType Directory -Path (Join-Path $fakeRoam 'REAPER')
        $env:APPDATA = $fakeRoam # from here on every "default resource directory" is the fake one; the child inherits it
        $groups = @(
            { Get-GuardCases $scratch $RepoRoot }, { Get-SubstResidueCases $scratch }, { Get-IniCases }, { Get-SnapshotCases $scratch }, { Get-LintCases $scratch $RepoRoot $CollisionSample },
            { Get-HostCases }, { Get-WavCases $scratch }, { Get-VerdictCases $scratch $RepoRoot }, { Get-ConfigCases $scratch $RepoRoot }, { Get-ProjectCases $scratch $RepoRoot }, { Get-SourceCases $scratch }, { Get-RenderCases $scratch $RepoRoot },
            { Get-PluginCases $scratch $RepoRoot }, { Get-LearnCases $scratch $RepoRoot }, { Get-VariantCases $scratch $RepoRoot }, { Get-ListingCases $scratch $RepoRoot }, { Get-StateCases $scratch $RepoRoot }, { Get-ExtensionCases $scratch $RepoRoot }, { Get-TransportCases $scratch $RepoRoot }, { Get-ReportCases $scratch $RepoRoot }, { Get-ExampleCases $RepoRoot }, { Get-WiringCases $RepoRoot }, { Get-SummaryCases },
            { Get-ChildCases $scratch $RepoRoot $ExtraGuiLock }
        )
        foreach ($group in $groups) {
            try { foreach ($c in (& $group)) { $cases.Add($c) } }
            catch { $cases.Add([pscustomobject]@{ Label = "a group of cases threw ($group): $($_.Exception.Message -replace '\s+', ' ') at $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"; Bad = $false; Passed = $false }) }
        }
    } finally {
        $env:APPDATA = $savedRoaming
        $why = Remove-HarnessTempDir -Path $scratch -WaitSeconds 10
        if ($why) { Write-Host "  the scratch directory was not removed: $why" }
    }
    $after = Get-HarnessDefaultCfgSnapshot
    $cmp = Compare-HarnessDefaultCfgSnapshot -Before $before -After $after
    $cases.Add([pscustomobject]@{ Label = "the real default resource directory is unchanged after the self-test ($($cmp.Count) entries, $($cmp.Unreadable.Count) unreadable)"; Bad = $false; Passed = $cmp.Same })
    $badCount = 0; $goodCount = 0; $red = 0
    foreach ($c in $cases) {
        if ($c.Bad) { $badCount++ } else { $goodCount++ }
        if (-not $c.Passed) { $red++ }
        Write-Host ('  [{0}] {1}{2}' -f ($c.Passed ? 'PASS' : 'FAIL'), ($c.Bad ? 'negative: ' : ''), $c.Label)
    }
    $notRunCount = Get-NotRunCount $cases
    Write-Host ('reaper-harness self-test: {0} ({1} negative, {2} positive, {3} failed, {4} not run for real, {5:N0} s)' -f ($red -eq 0 ? 'passed' : 'FAILED'), $badCount, $goodCount, $red, $notRunCount, $sw.Elapsed.TotalSeconds)
    $warning = Get-NotRunWarning -NotRun $notRunCount -ActionsFlag $env:GITHUB_ACTIONS
    if ($warning) { Write-Host $warning }
    $red -eq 0 ? 0 : 1
}

Export-ModuleMember -Function Invoke-HarnessSelfTest, Clear-HarnessSelftestSubst
