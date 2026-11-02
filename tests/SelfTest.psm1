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
foreach ($m in 'Guard', 'Host', 'Locks', 'Json', 'Wav', 'Config', 'Rpp', 'Plugins', 'Scenarios', 'Learn', 'Extensions', 'Suite') { Import-Module (Join-Path $script:Src "$m.psm1") -ErrorAction Stop }
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
    $noFrames = { param([hashtable]$Set, [hashtable]$Criteria = @{}) (Get-HarnessCompareVerdict -Facts (New-Facts $Set) @Criteria).Status }
    & $add 'compare verdict: no frames on both sides is INCOMPLETE, with or without criteria' $true ((& $noFrames @{ FramesA = 0; FramesB = 0 }) -eq 'INCOMPLETE' -and (& $noFrames @{ FramesA = 0; FramesB = 0 } @{ MaxDiffDb = -120 }) -eq 'INCOMPLETE' -and (& $noFrames @{ FramesA = 0; FramesB = 0 } @{ NotSilent = $true }) -eq 'INCOMPLETE')
    & $add 'compare verdict: no frames on either one side is INCOMPLETE' $true ((& $noFrames @{ FramesA = 0; Identical = $false }) -eq 'INCOMPLETE' -and (& $noFrames @{ FramesB = 0; Identical = $false }) -eq 'INCOMPLETE')
    & $add 'compare verdict: no frames goes before every other criterion (different rates are not FAIL then)' $true ((& $noFrames @{ FramesA = 0; FramesB = 0; Comparable = $false; RateB = 44100; Identical = $false }) -eq 'INCOMPLETE')
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
    # The test signal is deterministic: the same seed gives the same bytes
    $s1 = Join-Path $Tmp 'sig1.wav'; $s2 = Join-Path $Tmp 'sig2.wav'; $s3 = Join-Path $Tmp 'sig3.wav'
    New-HarnessSignalFile -Path $s1 -Seconds 0.2 -Seed 7; New-HarnessSignalFile -Path $s2 -Seconds 0.2 -Seed 7; New-HarnessSignalFile -Path $s3 -Seconds 0.2 -Seed 8
    & $add 'signal: the same seed gives the same file, another seed another one' $false ((Get-FileHash $s1).Hash -ceq (Get-FileHash $s2).Hash -and (Get-FileHash $s1).Hash -cne (Get-FileHash $s3).Hash)
    $cases
}

function Get-VerdictCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    & $add 'summary: INCOMPLETE is not PASS' $true ((Get-HarnessWorstStatus @('PASS', 'INCOMPLETE')) -eq 'INCOMPLETE')
    & $add 'summary: FAIL beats INCOMPLETE' $true ((Get-HarnessWorstStatus @('INCOMPLETE', 'FAIL', 'PASS')) -eq 'FAIL')
    & $add 'summary: only all SKIPPED is SKIPPED; mixed with PASS it is INCOMPLETE' $false ((Get-HarnessWorstStatus @('SKIPPED', 'SKIPPED')) -eq 'SKIPPED' -and (Get-HarnessWorstStatus @('PASS', 'SKIPPED')) -eq 'INCOMPLETE')
    & $add 'summary: an empty list (nothing ran) is never PASS' $true ((Get-HarnessWorstStatus @()) -eq 'INCOMPLETE' -and (Get-HarnessWorstStatus $null) -eq 'INCOMPLETE')
    & $add 'round: a round without any rows is not PASS' $true ((Get-HarnessRunVerdict -RowStatuses @() -CfgUnchanged $true -Residual 0) -eq 'INCOMPLETE')
    & $add 'round: all rows green but the default resource directory changed is FAIL' $true ((Get-HarnessRunVerdict -RowStatuses @('PASS', 'PASS') -CfgUnchanged $false -Residual 0) -eq 'FAIL')
    & $add 'round: all rows green but a reaper.exe left after the round is FAIL' $true ((Get-HarnessRunVerdict -RowStatuses @('PASS') -CfgUnchanged $true -Residual 1) -eq 'FAIL')
    & $add 'round: all green, directory unchanged, nothing left: PASS' $false ((Get-HarnessRunVerdict -RowStatuses @('PASS', 'PASS') -CfgUnchanged $true -Residual 0) -eq 'PASS')
    & $add 'rounds: a changed default resource directory stops all further rounds' $true ((Get-HarnessRoundStop -CfgUnchanged $false) -ne '' -and (Get-HarnessRoundStop -CfgUnchanged $true) -eq '')
    # Negative rows need both the outcome and the reason. The outcome alone can be reached without the case running:
    # with the GUI lock busy REAPER is not started, and a watchdog case is INCOMPLETE then too, without any watchdog
    $negs = @{}
    foreach ($neg in (Get-HarnessBuiltinNegatives)) { $negs[$neg.id] = $neg }
    $verdict = { param($id, $observed, $detail) Get-HarnessNegativeVerdict -Expect $negs[$id].expect -ExpectDetail $negs[$id].expectDetail -Observed $observed -Detail $detail }
    $hang = { param($state, $exitCode = 0) $w = Get-HarnessHostFailure ([pscustomobject]@{ Status = $state; Seconds = 8.2; ExitCode = $exitCode; Modal = 'license-nag'; Windows = @('license-nag') }); "$w; the process has ended and the GUI locks are free" } # the shape the hang kind builds
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
    $cases
}

# ---------------------------------------------------------------- configuration and schema
function Get-ConfigCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $configFile = Join-Path $RepoRoot 'tests/fixtures/config.json'
    $extensions = Import-HarnessExtensions (Read-HarnessConfigExtensions $configFile)
    $conf = Read-HarnessConfig -Path $configFile -Kinds $extensions.Kinds
    & $add 'configuration: the fixture configuration is valid; the matrix expands to four scenarios' $false ($conf.Name -eq 'fixture' -and @($conf.Scenarios).Count -eq 12 -and @($conf.Scenarios | Where-Object { $_.id -like 'chain-*-4*' }).Count -eq 4)
    $text = [IO.File]::ReadAllText($configFile)
    $problems = {
        param([scriptblock]$Edit)
        $raw = ConvertFrom-HarnessJson $text
        & $Edit $raw
        @((Test-HarnessConfigData -Raw $raw -Kinds $extensions.Kinds).Problems)
    }
    $scenario = { param($raw, $id) @($raw['scenarios'] | Where-Object { $_['id'] -eq $id })[0] }
    $mutations = @(
        @{ L = 'an unknown key at the top'; E = { param($c) $c['surprise'] = 1 }; M = "unknown key 'surprise'" }
        @{ L = 'an unknown key in a scenario'; E = { param($c) (& $scenario $c 'bus')['speed'] = 2 }; M = "unknown key 'speed'" }
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
        @{ L = 'an unknown expected outcome'; E = { param($c) $c['negative'][0]['expect'] = 'MAYBE' }; M = 'expect' }
        @{ L = 'a matrix in a negative case'; E = { param($c) $c['negative'][0]['matrix'] = [ordered]@{ sr = @(48000) } }; M = 'matrix' }
        @{ L = 'an axis both in the matrix and given directly'; E = { param($c) (& $scenario $c 'chain')['sr'] = 48000 }; M = 'both directly and in matrix' }
        @{ L = 'a negative id that clashes with a built-in one'; E = { param($c) $c['negative'][0]['id'] = 'neg-timeout' }; M = 'neg-timeout' }
        @{ L = 'an extension kind with a bad field (its own Validate)'; E = { param($c) (& $scenario $c 'ext-count')['count'] = 99 }; M = 'count' }
    )
    foreach ($mu in $mutations) {
        $found = & $problems $mu.E
        & $add "configuration: $($mu.L) is a problem ($($found -join ' | '))" $true (@($found | Where-Object { $_ -match [regex]::Escape($mu.M) }).Count -gt 0)
    }
    & $add 'configuration: every problem is listed at once, not just the first' $true (@(& $problems { param($c) $c['surprise'] = 1; $c['signal']['seconds'] = 'long' }).Count -ge 2)
    $badFile = Join-Path $Tmp 'config-bad.json'
    [IO.File]::WriteAllText($badFile, $text.Replace('"schema": 1,', '"schema": 1, "surprise": true,').Replace('"ext/', '"../fixtures/ext/'))
    & $add 'configuration: Read-HarnessConfig throws USAGE: with the problems' $true (Test-Usage { Read-HarnessConfig -Path $badFile -Kinds $extensions.Kinds } "*unknown key 'surprise'*")
    [IO.File]::WriteAllText($badFile, '{ "schema": 1, ')
    & $add 'configuration: a file that is not JSON is a usage error' $true (Test-Usage { Read-HarnessConfig -Path $badFile })
    & $add 'configuration: a missing file is a usage error' $true (Test-Usage { Read-HarnessConfig -Path (Join-Path $Tmp 'none.json') } '*not found*')
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
    & $add 'JSON: keys named Count, Keys and Values are written back as they were read' $false ((ConvertTo-HarnessJsonText -Value (ConvertFrom-HarnessJson $jsonText)) -ceq $jsonText)
    # Selection
    $picked = Select-HarnessScenarios -Config $conf
    & $add 'selection: without -Only every scenario and negative case (own and built-in) is picked' $false ($picked.Positive.Count -eq 12 -and $picked.Negative.Count -eq 9)
    $one = Select-HarnessScenarios -Config $conf -Only '^chain-offline-48000$' -NoNegative
    & $add 'selection: -Only picks one scenario; -NoNegative leaves the negative cases out' $false ($one.Positive.Count -eq 1 -and $one.Negative.Count -eq 0)
    & $add 'selection: -Only picking nothing is a usage error' $true (Test-Usage { Select-HarnessScenarios -Config $conf -Only '^no-such-scenario$' } '*picked no scenario*')
    & $add 'selection: -Only picking only a negative case together with -NoNegative is a usage error' $true (Test-Usage { Select-HarnessScenarios -Config $conf -Only '^neg-timeout$' -NoNegative } '*-NoNegative*')
    & $add 'selection: an -Only that is not a valid regex is a usage error' $true (Test-Usage { Select-HarnessScenarios -Config $conf -Only '(' } '*not a valid regex*')
    & $add 'learning: needed by every scenario with a configured layout, by instances and by extension kinds; never by built-in negative cases' $false (
        (Test-HarnessNeedsLearn @($conf.Scenarios)[0]) -and (Test-HarnessNeedsLearn (@($conf.Scenarios) | Where-Object id -eq 'instances')) -and (Test-HarnessNeedsLearn (@($conf.Scenarios) | Where-Object id -eq 'ext-count')) -and
        @(Get-HarnessBuiltinNegatives | Where-Object { Test-HarnessNeedsLearn $_ }).Count -eq 0)
    # The schema file is generated from the validator: it must be current, and Test-Json must agree with the validator
    $schemaFile = Join-Path $RepoRoot 'schema/config.schema.json'
    $schemaText = [IO.File]::ReadAllText($schemaFile)
    & $add 'schema: schema/config.schema.json is what run.ps1 -WriteSchema generates now (regenerate it after changing Config.psm1)' $false ($schemaText -ceq (ConvertTo-HarnessJsonSchema))
    $agree = { param([string]$Json, [bool]$Accepted) $schemaOk = try { Test-Json -Json $Json -Schema $schemaText -ErrorAction Stop } catch { $false }; $schemaOk -eq $Accepted }
    & $add 'schema: Test-Json accepts the fixture configuration, like the validator' $false (& $agree $text $true)
    $structural = @($mutations | Where-Object { $_.L -in 'an unknown key at the top', 'an unknown key in a scenario', 'schema 2', 'a string where a number belongs', 'a sample rate out of range', 'a scenario id that breaks the pattern', 'an unknown expected outcome', 'a negative case without expectDetail' })
    $disagree = @(foreach ($mu in $structural) {
            $raw = ConvertFrom-HarnessJson $text
            & $mu.E $raw
            if (-not (& $agree (ConvertTo-HarnessJsonText -Value $raw) $false)) { $mu.L }
        })
    & $add "schema: Test-Json rejects the structural mutations the validator rejects ($($disagree -join ', '))" $true ($structural.Count -eq 8 -and $disagree.Count -eq 0)
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
    $cases
}

function Get-PluginCases([string]$Tmp, [string]$RepoRoot) {
    $cases = New-CaseList
    $add = { param($Label, $Bad, $Passed) $cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = [bool]$Passed }) }
    $fixtures = Join-Path $RepoRoot 'tests/fixtures/plugins'
    $gain = Read-HarnessModuleInfo (Join-Path $fixtures 'Fixture Gain.vst3')
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
    & $add "learning: one default variant per plugin first, then each distinct parameter set once ($($keys -join ', '))" $false ($keys[0] -ceq 'gain|' -and $keys[1] -ceq 'bus|' -and $keys.Count -eq 4 -and @($keys | Select-Object -Unique).Count -eq 4)
    $fi = Split-HarnessFxIdent 'C:\x\plugins\A.vst3\Contents\x86_64-win\A.vst3<1234567890{5a1b2c3d4e5f60718293a4b5c6d7e8f9'
    & $add 'fx_ident: path and upper-case class ID (REAPER writes no closing brace); a closing brace or negative uid is fine too; anything else gives nothing' $false (
        $fi.Path -ceq 'C:\x\plugins\A.vst3\Contents\x86_64-win\A.vst3' -and $fi.Cid -ceq '5A1B2C3D4E5F60718293A4B5C6D7E8F9' -and (Split-HarnessFxIdent 'p<-5{5A1B2C3D4E5F60718293A4B5C6D7E8F9}').Path -ceq 'p' -and
        (Split-HarnessFxIdent 'some.dll').Path -eq '' -and (Split-HarnessFxIdent '').Cid -eq '')
    & $add 'parameters: a normalized value within 1e-6 is the same; further off is not; with a display text the text decides' $false (
        $null -eq (Test-HarnessParamValue '0.500000400' '' @{ Normalized = 0.5; Display = $null }) -and (Test-HarnessParamValue '0.500002' '' @{ Normalized = 0.5; Display = $null }) -like 'reads*' -and
        $null -eq (Test-HarnessParamValue '0.3' '0.25' @{ Normalized = 0.25; Display = '0.25' }) -and (Test-HarnessParamValue '0.25' '0.3' @{ Normalized = 0.25; Display = '0.25' }) -like 'shows*' -and
        (Test-HarnessParamValue 'missing' '' @{ Normalized = 0.5; Display = $null }) -eq 'no such parameter')
    # A report as the driver writes it, and a saved project, for two variants
    $installed = @{
        gain = [pscustomobject]@{ Binary = 'P:\plugins\Fixture Gain.vst3\Contents\x86_64-win\Fixture Gain.vst3'; Info = [pscustomobject]@{ Name = 'Fixture Gain'; Vendor = 'Fixture Audio'; Cid = '5A1B2C3D4E5F60718293A4B5C6D7E8F9' } }
        bus  = [pscustomobject]@{ Binary = 'P:\plugins\Fixture Bus.vst3\Contents\x86_64-win\Fixture Bus.vst3'; Info = [pscustomobject]@{ Name = 'Fixture Bus'; Vendor = 'Fixture Audio'; Cid = '0123456789ABCDEF0123456789ABCDEF' } }
    }
    $vs = @([pscustomobject]@{ Key = 'gain|g'; Plugin = 'gain'; Params = [ordered]@{ Gain = [pscustomobject]@{ Normalized = 0.5; Display = $null } } }, [pscustomobject]@{ Key = 'bus|'; Plugin = 'bus'; Params = [ordered]@{} })
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
    & $add 'learn report: a plugin that could not be added (index -1) is a failure naming it' $true (@((& $mut { param($r) $r.fx2_idx = '-1' }).Fail -match '^bus could not be added').Count -eq 1)
    & $add 'learn report: another plugin matched the name (TrackFX_AddByName is loose) is a failure' $true (@((& $mut { param($r) $r.fx1_name = 'VST3: Fixture Gain Pro (Fixture Audio)' }).Fail -match 'another plugin matched').Count -eq 1)
    & $add 'learn report: an offline FX is a failure' $true (@((& $mut { param($r) $r.fx2_offline = 'true' }).Fail -match 'offline').Count -eq 1)
    & $add 'learn report: fx_ident naming a binary outside the private directory is foreign (the private copy is not what was tested)' $true (@((& $mut { param($r) $r.fx1_ident = 'S:\VST3\Fixture Gain.vst3\Contents\x86_64-win\Fixture Gain.vst3<1{5A1B2C3D4E5F60718293A4B5C6D7E8F9' }).Foreign).Count -eq 1)
    & $add 'learn report: a class ID in fx_ident other than the one in moduleinfo.json is a failure' $true (@((& $mut { param($r) $r.fx2_ident = "$($installed.bus.Binary)<1{FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" }).Fail -match 'class ID in fx_ident').Count -eq 1)
    & $add 'learn report: a parameter that reads back differently is a failure' $true (@((& $mut { param($r) $r.fx1_p1 = '0.25' }).Fail -match "parameter 'Gain'").Count -eq 1)
    & $add 'learn report: a saved block with another class ID is a failure' $true (@((& $check (& $report) (& $savedOf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')).Fail -match 'saved block has class ID').Count -eq 1)
    & $add 'learn report: two blocks on a learn track is a failure (which one would be the plugin?)' $true (@((& $check (& $report) (& $savedOf '5A1B2C3D4E5F60718293A4B5C6D7E8F9' 2)).Fail -match 'has 2 plugin blocks').Count -eq 1)
    & $add 'learn report: no saved project at all is a failure for every variant' $true ((& $check (& $report) $null).Fail.Count -eq 2)
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
    & $add 'wiring: Invoke-HarnessSuite lists the default resource directory before and after every round' $false (@(& $at $suite 'Get-HarnessDefaultCfgSnapshot').Count -eq 2 -and 'Compare-HarnessDefaultCfgSnapshot' -in $suite.Name)
    $launch = & $callsIn (Join-Path $RepoRoot 'src/Scenarios.psm1') 'Invoke-HarnessLaunch'
    & $add 'wiring: every launch takes the GUI locks before starting REAPER and checks the skip marker again while holding them' $false (
        (& $at $launch 'Enter-HarnessLocks')[0] -lt (& $at $launch 'Invoke-HarnessHost')[0] -and @(& $at $launch 'Get-HarnessSkipMarkerHit').Count -eq 2 -and (& $at $launch 'Get-HarnessSkipMarkerHit')[1] -lt (& $at $launch 'Invoke-HarnessHost')[0])
    $hostCalls = & $callsIn (Join-Path $RepoRoot 'src/Host.psm1') 'Invoke-HarnessHost'
    & $add 'wiring: Invoke-HarnessHost builds the command line from Get-HarnessCfgArgument (which checks the directory again)' $false ('Get-HarnessCfgArgument' -in $hostCalls.Name)
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
            { Get-HostCases }, { Get-WavCases $scratch }, { Get-VerdictCases $scratch $RepoRoot }, { Get-ConfigCases $scratch $RepoRoot }, { Get-ProjectCases $scratch $RepoRoot },
            { Get-PluginCases $scratch $RepoRoot }, { Get-LearnCases $scratch $RepoRoot }, { Get-ExtensionCases $scratch $RepoRoot }, { Get-WiringCases $RepoRoot }, { Get-SummaryCases },
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
