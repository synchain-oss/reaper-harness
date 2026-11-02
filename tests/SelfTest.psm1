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
foreach ($m in 'Guard', 'Host', 'Locks', 'Json', 'Wav', 'Config', 'Rpp', 'Plugins', 'Scenarios', 'Learn', 'Extensions', 'States', 'Suite') { Import-Module (Join-Path $script:Src "$m.psm1") -ErrorAction Stop }
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
    & $add 'file identity: the 8.3 short name and the long name are the same' $false ((-not $hasShort) -or ((Get-HarnessFileIdentity $short) -ceq (Get-HarnessFileIdentity $defaultDir)))
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
        } finally { & subst.exe "${letter}:" /d 2>&1 | Out-Null }
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
            & subst.exe "${slot}:" /d 2>&1 | Out-Null # only the mapping made here
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
        foreach ($name in $Files.get_Keys()) { [IO.File]::WriteAllText((Join-Path $dir $name), $Files[$name]) }
        try { Test-HarnessScriptLint -Paths $dir } finally { foreach ($name in $Files.get_Keys()) { Remove-Item -LiteralPath (Join-Path $dir $name) }; Remove-Item -LiteralPath $dir }
    }
    $hostOk = @{ 'Host.psm1' = "$strict`n`$a = '$word'`n" }
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
    & $add 'lint: the configuration file argument literal outside Host.psm1 is red' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$b = '$word'`n" })) -match 'may only be built in Host')
    & $add 'lint: no configuration file argument literal at all is red' $true ((& $lint @{ 'x.ps1' = "$strict`n" }) -match 'exactly once')
    & $add 'lint: the configuration file argument literal twice is red' $true ((& $lint @{ 'Host.psm1' = "$strict`n`$a = '$word'`n`$b = '$word'`n" }) -match 'exactly once')
    & $add 'lint: mentioning it in a comment does not count' $false ((& $lint @{ 'Host.psm1' = "$strict`n# $word`n`$a = '$word'`n" }).Count -eq 0)
    & $add 'lint: a file other than Guard.psm1 or the self-test mentioning APPDATA is red' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$p = `$env:APPDATA`n" })) -match 'APPDATA')
    & $add 'lint: LOCALAPPDATA (a different directory) is not taken for APPDATA' $false ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$p = `$env:LOCALAPPDATA`n" })).Count -eq 0)
    $cr = [string][char]13; $esc = [string][char]27
    & $add 'lint: a CR not at a line end inside a script is red (invisible in editors; swallowed, it changes a regex)' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$r = '(;|${cr}?`$)'`n" })) -match 'control character')
    & $add 'lint: another C0 control character (ESC) inside a script is red' $true ((& $lint ($hostOk + @{ 'x.ps1' = "$strict`n`$r = 'a${esc}b'`n" })) -match 'control character')
    & $add 'lint: control characters in .lua and .json files are red too' $true (((& $lint ($hostOk + @{ 'x.lua' = "local a = 'b${esc}c'`n" })) -match 'control character') -and ((& $lint ($hostOk + @{ 'x.json' = "{ `"a`": `"b${esc}c`" }`n" })) -match 'control character'))
    & $add 'lint: CRLF line ends and TAB are not control characters' $false ((& $lint @{ 'Host.psm1' = "$strict${cr}`n`t`$a = '$word'${cr}`n" }).Count -eq 0)
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
    & $add 'dialog: the evaluation licence reminder is never clicked away; stuck, and named' $true (($nag = & $v '#32770' $true 'About REAPER v7.82/win64 rev 1 (Oct') -and $nag.Action -eq 'Fatal' -and $nag.Name -eq 'license-nag')
    foreach ($pair in @(@('Project Load Warning', 'project-load-warning'), @('REAPER Error', 'reaper-error'), @('Select files to save or delete', 'record-save-prompt'), @('REAPER', 'no-audio-device'), @('Brand New Box', 'unknown-dialog'))) {
        $r = & $v '#32770' $true $pair[0]
        & $add "dialog: '$($pair[0])' counts as stuck ($($pair[1]))" $true ($r.Action -eq 'Fatal' -and $r.Name -eq $pair[1])
    }
    & $add 'dialog: an invisible dialog is ignored' $false ((& $v '#32770' $false 'REAPER Error').Action -eq 'Ignore')
    & $add 'dialog: the main window and other non-dialogs are ignored' $false ((& $v 'REAPERwnd' $true 'REAPER v7').Action -eq 'Ignore')
    & $add 'paths in dialog titles are masked' $false ((ConvertTo-HarnessSafeTitle 'Error in D:\scratch\proj.rpp now') -notmatch 'scratch')
    & $add 'drive paths and UNC paths in result text are masked' $false ((Hide-HarnessPaths 'a D:\scratch\y.wav b \\host\share\z c E:/fwd/x') -notmatch 'scratch|host|fwd')
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
    $cutData = Join-Path $Tmp 'cut-data.wav'; [IO.File]::WriteAllBytes($cutData, $bytes[0..(44 + 8 * 100 - 1)])
    $cd = & $cmp $cutData
    & $add 'WAV: a file cut off inside its data (100 whole frames left) is INCOMPLETE, not a shorter render' $true ($cd.Status -eq 'INCOMPLETE' -and $cd.Detail -like '*WAV: data chunk is truncated*')
    $partial = [byte[]]$bytes.Clone(); [BitConverter]::GetBytes([uint32](8 * $n - 4)).CopyTo($partial, 40)
    $pf = Join-Path $Tmp 'partial-frame.wav'; [IO.File]::WriteAllBytes($pf, $partial)
    $pr = & $cmp $pf
    & $add 'WAV: a data chunk that ends inside a frame is INCOMPLETE' $true ($pr.Status -eq 'INCOMPLETE' -and $pr.Detail -like '*WAV: data chunk does not hold whole frames*')
    # A streaming writer's placeholder length 0xFFFFFFFF: the data runs to the end of the file (whole frames), not cut off
    $open = [byte[]]$bytes.Clone(); [BitConverter]::GetBytes([uint32]::MaxValue).CopyTo($open, 40)
    $of = Join-Path $Tmp 'open-length.wav'; [IO.File]::WriteAllBytes($of, [byte[]]($open + [byte[]](1, 2, 3)))
    & $add 'WAV: a data length of 0xFFFFFFFF (length unknown) reads to the end of the file; a partial last frame is dropped' $false ((& $cmp $of).Detail -cmatch '^identical=yes lag=0 ')
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
    & $add 'configuration: the fixture configuration is valid; the matrix expands to four scenarios' $false ($conf.Name -eq 'fixture' -and @($conf.Scenarios).Count -eq 20 -and @($conf.Scenarios | Where-Object { $_.id -like 'chain-*-4*' }).Count -eq 4)
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
    & $add 'selection: without -Only every scenario and negative case (own and built-in) is picked' $false ($picked.Positive.Count -eq 20 -and $picked.Negative.Count -eq 11)
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
        @(Get-HarnessBuiltinNegatives | Where-Object { Test-HarnessNeedsLearn $_ }).Count -eq 0)
    # The schema file is generated from the validator: it must be current, and Test-Json must agree with the validator
    $schemaFile = Join-Path $RepoRoot 'schema/config.schema.json'
    $schemaText = [IO.File]::ReadAllText($schemaFile)
    & $add 'schema: schema/config.schema.json is what run.ps1 -WriteSchema generates now (regenerate it after changing Config.psm1)' $false ($schemaText -ceq (ConvertTo-HarnessJsonSchema))
    $agree = { param([string]$Json, [bool]$Accepted) $schemaOk = try { Test-Json -Json $Json -Schema $schemaText -ErrorAction Stop } catch { $false }; $schemaOk -eq $Accepted }
    & $add 'schema: Test-Json accepts the fixture configuration, like the validator' $false (& $agree $text $true)
    $structural = @($mutations | Where-Object { $_.L -in 'an unknown key at the top', 'an unknown key in a scenario', 'schema 2', 'a string where a number belongs', 'a sample rate out of range', 'a scenario id that breaks the pattern', 'an unknown expected outcome', 'a negative case without expectDetail',
            'a state with both a template and a state file', 'a template state without the FX number', 'an unknown JSFX', 'an unknown send mode', 'a pan out of range', 'a range of one number', 'a range of three numbers', 'savereopen with 0 cycles', 'an unknown host setting' })
    $disagree = @(foreach ($mu in $structural) {
            $raw = ConvertFrom-HarnessJson $text
            & $mu.E $raw
            if (-not (& $agree (ConvertTo-HarnessJsonText -Value $raw) $false)) { $mu.L }
        })
    & $add "schema: Test-Json rejects the structural mutations the validator rejects ($($disagree -join ', '))" $true ($structural.Count -eq 17 -and $disagree.Count -eq 0)
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
    & $add 'project: with stems each file is named after its track, REAPER renders master and stems, only the stem tracks are selected' $false (
        $rt -match 'RENDER_PATTERN "N-\$track"' -and $rt -match 'RENDER_STEMS 1' -and (@([regex]::Matches($rt, 'SEL (\d)') | ForEach-Object { $_.Groups[1].Value }) -join '') -ceq '1001')
    & $add 'project: without stems one file named as asked, no stem render, no track selected' $false ($text -match 'RENDER_PATTERN "N"' -and $text -notmatch 'RENDER_STEMS' -and $text -notmatch 'SEL 1')
    $lp = New-HarnessLearnProjectText -Variants @([pscustomobject]@{ Key = 'gain|'; State = '' }, [pscustomobject]@{ Key = 'gain@quiet|'; State = 'quiet' }) -States @{ 'gain@quiet|' = @('<VST "q"', 'Q', '>') }
    & $add 'learn project: an empty track per variant, the state block already on the track of a named state' $false ($lp -match '(?s)NAME "learn-1"\n    NCHAN 2\n  >\n  <TRACK\n    NAME "learn-2"\n    NCHAN 2\n    <FXCHAIN\n      BYPASS 0 0 0\n      <VST "q"\n      Q\n      >\n    >')
    & $add 'learn project: a named state without its block is an error' $true ($(try { $null = New-HarnessLearnProjectText -Variants @([pscustomobject]@{ Key = 'k'; State = 's' }); $false } catch { $true }))
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
    $changed = $reopen.Clone(); $changed['after2_t0_fx0_param1'] = '0.6'
    $missing = $reopen.Clone(); $missing.Remove('after3_tracks')
    & $add 'savereopen: a value changed on the second of 3 reopens, or missing after the third, is a problem naming the reopen' $true (
        ((Test-HarnessReopenFacts -Facts $changed -Cycles 3) -join ';') -ceq "t0_fx0_param1 changed on reopen 2 of 3: '0.5' -> '0.6'" -and
        ((Test-HarnessReopenFacts -Facts $missing -Cycles 3) -join ';') -ceq "tracks changed on reopen 3 of 3: '1' -> ''" -and (Test-HarnessReopenFacts -Facts $changed -Cycles 1).Count -eq 0)
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
    & $add 'learn report: a plugin that could not be added (index -1) is a failure naming it' $true (@((& $mut { param($r) $r.fx2_idx = '-1' }).Fail -match '^bus could not be added').Count -eq 1)
    & $add 'learn report: another plugin matched the name (TrackFX_AddByName is loose) is a failure' $true (@((& $mut { param($r) $r.fx1_name = 'VST3: Fixture Gain Pro (Fixture Audio)' }).Fail -match 'another plugin matched').Count -eq 1)
    & $add 'learn report: an offline FX is a failure' $true (@((& $mut { param($r) $r.fx2_offline = 'true' }).Fail -match 'offline').Count -eq 1)
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
    & $add 'state proof: state FX missing from the saved project are problems' $true (@((Test-HarnessStateProof -Layout $spLayout -Blocks $spBlocks -States $spStates -Saved (Get-HarnessFxBlocks "<REAPER_PROJECT`n>`n")).Problems -match 'not in the saved project').Count -eq 2)
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
    $msg = { param([scriptblock]$Edit) try { $null = & $read $Edit; '' } catch { $_.Exception.Message } }
    $out = & $msg { param($c) $c.Plugins['gain'].States['quiet'].Template = '../config.json' }
    & $add "states: a path outside the configuration's directory is a usage error ($out)" $true ($out -like 'USAGE: states: *plugins.gain.states.quiet*')
    $out = & $msg { param($c) $c.Plugins['gain'].States['loud'].StateFile = 'states/none.RfxChain' }
    & $add "states: a missing file is a usage error ($out)" $true ($out -like 'USAGE: states: *plugins.gain.states.loud*')
    $out = & $msg { param($c) $c.Plugins['gain'].States['quiet'].Track = 'Nobody'; $c.Plugins['gain'].States['loud'].StateFile = 'states/template.rpp' }
    & $add "states: every problem is listed at once; a problem names file, track and FX number, never the content ($out)" $true (
        $out -like "USAGE: states: 2 problem(s): *template.rpp has no track named 'Nobody'*template.rpp holds 0 plugin blocks*" -and $out -notmatch 'FAKESTATE|Lead backup')
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
    & $add 'wiring: Invoke-HarnessSuite reads the states with the configuration and checks them against moduleinfo after the preflight, before installing anything' $false (
        (& $at $suite 'Read-HarnessStates')[0] -lt (& $at $suite 'Get-HarnessPreflight')[0] -and (& $at $suite 'Get-HarnessPreflight')[0] -lt (& $at $suite 'Assert-HarnessStateIdentity')[0] -and
        (& $at $suite 'Assert-HarnessStateIdentity')[0] -lt (& $at $suite 'Install-HarnessPlugins')[0] -and (& $at $suite 'Assert-HarnessStateIdentity')[0] -lt (& $at $suite 'Install-HarnessJsfx')[0])
    & $add 'wiring: Invoke-HarnessSuite lists the default resource directory before and after every round' $false (@(& $at $suite 'Get-HarnessDefaultCfgSnapshot').Count -eq 2 -and 'Compare-HarnessDefaultCfgSnapshot' -in $suite.Name)
    $launch = & $callsIn (Join-Path $RepoRoot 'src/Scenarios.psm1') 'Invoke-HarnessLaunch'
    & $add 'wiring: every launch takes the GUI locks before starting REAPER and checks the skip marker again while holding them' $false (
        (& $at $launch 'Enter-HarnessLocks')[0] -lt (& $at $launch 'Invoke-HarnessHost')[0] -and @(& $at $launch 'Get-HarnessSkipMarkerHit').Count -eq 2 -and (& $at $launch 'Get-HarnessSkipMarkerHit')[1] -lt (& $at $launch 'Invoke-HarnessHost')[0])
    $hostCalls = & $callsIn (Join-Path $RepoRoot 'src/Host.psm1') 'Invoke-HarnessHost'
    & $add 'wiring: Invoke-HarnessHost builds the command line from Get-HarnessCfgArgument (which checks the directory again)' $false ('Get-HarnessCfgArgument' -in $hostCalls.Name)
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
    $cfgA = Join-Path $Tmp 'child-cfg-a'; $cfgB = Join-Path $Tmp 'child-cfg-b'
    $null = New-HarnessCfgDir $cfgA; $null = New-HarnessCfgDir $cfgB
    $work = Join-Path $Tmp 'child-work'; $null = New-Item -ItemType Directory -Path $work
    $run = Invoke-Native -Exe (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'SelfTestChild.ps1'),
        '-RepoRoot', $RepoRoot, '-CfgA', $cfgA, '-CfgB', $cfgB, '-Work', $work, '-ExtraLocks', ($ExtraGuiLock -join ';'))
    $cases = New-CaseList
    foreach ($line in ($run.Out -split "`r?`n")) {
        $f = $line -split "`t", 4
        if ($f.Count -eq 4 -and $f[0] -eq 'RESULT') { $cases.Add([pscustomobject]@{ Label = $f[3]; Bad = ($f[1] -eq '1'); Passed = ($f[2] -eq '1') }) }
    }
    if ($run.Exit -ne 0 -or $cases.Count -eq 0) { $cases.Add([pscustomobject]@{ Label = "the child self-test failed (exit code $($run.Exit)): $(($run.Err + $run.Out).Trim() -replace '\s+', ' ')"; Bad = $false; Passed = $false }) }
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
            { Get-PluginCases $scratch $RepoRoot }, { Get-LearnCases $scratch $RepoRoot }, { Get-StateCases $scratch $RepoRoot }, { Get-ExtensionCases $scratch $RepoRoot }, { Get-WiringCases $RepoRoot },
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
    $cases.Add([pscustomobject]@{ Label = "the real default resource directory is unchanged after the self-test ($($cmp.Count) entries)"; Bad = $false; Passed = $cmp.Same })
    $badCount = 0; $goodCount = 0; $red = 0
    foreach ($c in $cases) {
        if ($c.Bad) { $badCount++ } else { $goodCount++ }
        if (-not $c.Passed) { $red++ }
        Write-Host ('  [{0}] {1}{2}' -f ($c.Passed ? 'PASS' : 'FAIL'), ($c.Bad ? 'negative: ' : ''), $c.Label)
    }
    Write-Host ('reaper-harness self-test: {0} ({1} negative, {2} positive, {3} failed, {4:N0} s)' -f ($red -eq 0 ? 'passed' : 'FAILED'), $badCount, $goodCount, $red, $sw.Elapsed.TotalSeconds)
    $red -eq 0 ? 0 : 1
}

Export-ModuleMember -Function Invoke-HarnessSelfTest, Clear-HarnessSelftestSubst
