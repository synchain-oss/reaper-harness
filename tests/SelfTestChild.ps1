#Requires -Version 7
# SPDX-License-Identifier: MIT
#
# The child-process part of the self-test (called by SelfTest.psm1): Initialize-HarnessCfg pins the configuration
# directory into the process for good, so these cases get a process of their own. Stand-ins replace REAPER: a
# sleeping pwsh, a pwsh that shows a dialog with a given title, and tests/FakeReaper.psm1 for the end-to-end case.
# They check the watchdog, the dialog handling, the locks, the entry guards, the plugin install and scan shield, and
# one whole suite run. Output: one line per case, RESULT<TAB>bad<TAB>passed<TAB>label. The parent replaced APPDATA
# with a fake one; this process inherits it. The system VST3 directories are replaced here with fakes, too.
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$CfgA,
    [Parameter(Mandatory)][string]$CfgB,
    [Parameter(Mandatory)][string]$Work,
    [string]$ExtraLocks = '' # full mutex names separated by ';', taken in addition to the default for the dialog cases
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) # the parent decodes UTF-8

$src = Join-Path $RepoRoot 'src'
foreach ($m in 'Guard', 'Host', 'Locks', 'Json', 'Wav', 'Config', 'Rpp', 'Plugins', 'Transport', 'Capture', 'Sources', 'Probe', 'Scenarios', 'Learn', 'Extensions', 'States', 'Renders', 'Suite') { Import-Module (Join-Path $src "$m.psm1") -ErrorAction Stop }
Import-Module (Join-Path $RepoRoot 'tests/FakeReaper.psm1') -ErrorAction Stop

function Write-Case([string]$Label, [bool]$Bad, [bool]$Passed) { Write-Output ("RESULT`t{0}`t{1}`t{2}" -f [int]$Bad, [int]$Passed, $Label) }
function Test-Throws([scriptblock]$Action, [string]$Like = '*') { try { $null = & $Action; $false } catch { $_.Exception.Message -like $Like } }
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $psi = [Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    [pscustomobject]@{ Exit = $p.ExitCode; Out = $so.Result; Err = $se.Result }
}
# Puts a variable of this process back as it was: a .NET method gets $null as '', which would leave it set, but empty
function Restore-ChildEnvVariable([string]$VarName, $WasValue) {
    if ($null -eq $WasValue) { Remove-Item -LiteralPath "Env:$VarName" -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($VarName, [string]$WasValue) }
}

$pwshExe = (Get-Process -Id $PID).Path
$flag = '-cfg' + 'file'
$gone = { param($ProcessId) $null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) }
$extra = @($ExtraLocks -split ';' | Where-Object { $_ })
# Fake system VST3 directories (REAPER's own additions to the plugin path): the shield scans these, not the machine's
$env:COMMONPROGRAMFILES = Join-Path $Work 'fake-common'
$env:LOCALAPPDATA = Join-Path $Work 'fake-local'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $env:COMMONPROGRAMFILES 'VST3'), (Join-Path $env:LOCALAPPDATA 'Programs\Common\VST3')

# Stand-in: replaces the start info Host prepared with another command and remembers the original arguments
# (GetNewClosure keeps only the variables of the current scope: everything the block needs is copied into it first.)
function New-StandIn([string]$Command, [hashtable]$Seen) {
    $standInExe = $pwshExe
    { param($psi) $Seen.Args = @($psi.ArgumentList); $Seen.Called = $true; $psi.FileName = $standInExe; $psi.ArgumentList.Clear(); foreach ($part in '-NoProfile', '-Command', $Command) { $psi.ArgumentList.Add($part) }; [Diagnostics.Process]::Start($psi) }.GetNewClosure()
}
# On real machines Process.ExitTime occasionally reads FILETIME 0 (1601-01-01 UTC): a wrapper reporting that, the
# rest from the real process
function New-BadExitTimeProcess($Wrapped) {
    $w = [pscustomobject]@{ Real = $Wrapped }
    foreach ($member in 'Id', 'HasExited', 'ExitCode') { Add-Member -InputObject $w -MemberType ScriptProperty -Name $member -Value ([scriptblock]::Create("`$this.Real.$member")) }
    Add-Member -InputObject $w -MemberType ScriptProperty -Name ExitTime -Value { [DateTime]::FromFileTime(0) }
    Add-Member -InputObject $w -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $this.Real.WaitForExit($ms) }
    $w
}
function New-BadExitTimeStandIn([string]$Command) {
    $launch = New-StandIn $Command @{}
    $wrap = ${function:New-BadExitTimeProcess}
    { param($psi) & $wrap (& $launch $psi) }.GetNewClosure()
}
function New-BoxCommand([string]$Title, [string]$Buttons, [string]$OutFile) {
    "Add-Type -AssemblyName System.Windows.Forms; `$r = [System.Windows.Forms.MessageBox]::Show('x', '$($Title -replace "'", "''")', '$Buttons'); Set-Content -LiteralPath '$($OutFile -replace "'", "''")' -Value `$r"
}
# Replaces one command for the suite module only. This reaches what must not be made on the machine the self-test runs on
# (a reaper.exe of somebody else, a default resource directory that cannot be listed) with the real suite around it.
function Set-SuiteCommand([string]$Name, [scriptblock]$Stub) {
    & (Get-Module Suite) { param($n, $s) $was = (Get-Item "function:$n").ScriptBlock; Set-Item "function:script:$n" $s; $was } $Name $Stub
}
function Invoke-WithSuiteCommand([string]$Name, [scriptblock]$Stub, [scriptblock]$Action) {
    $was = Set-SuiteCommand $Name $Stub
    try { & $Action } finally { $null = Set-SuiteCommand $Name $was }
}
# A launcher that starts what the given one starts and remembers the process, so a case can end it when it is judged
function New-TrackedLauncher($Launcher, [hashtable]$Box) {
    { param($psi) $p = & $Launcher $psi; $Box.Pid = $p.Id; $p }.GetNewClosure()
}
# Waits until the process shows a visible dialog with this title, looking at the windows of that PID only
function Wait-BoxShown($Process, [string]$Title, [int]$Seconds) {
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until -and -not $Process.HasExited) {
        foreach ($row in [HarnessWin]::Windows([uint32]$Process.Id)) {
            $cols = $row -split "`t", 4
            if ($cols[1] -eq '1' -and $cols[2] -ceq '#32770' -and $cols[3] -ceq $Title) { return $true }
        }
        Start-Sleep -Milliseconds 100
    }
    $false
}

# ---- pinning ----
# An ordinary tree below the top level: pinning walks it and has nothing to say
$plugin = Join-Path $CfgA 'plugins\Some Plugin.vst3\Contents\x86_64-win'
$null = New-Item -ItemType Directory -Force -Path $plugin
[IO.File]::WriteAllText((Join-Path $plugin 'Some Plugin.vst3'), 'x')
$pinned = Initialize-HarnessCfg $CfgA
Write-Case 'pin: Initialize pins the configuration directory; the value of the configuration file argument only comes from the constant, without quotes' $false ((Get-HarnessCfgArgument) -ceq $pinned.Ini)
Write-Case 'pin: another configuration directory after pinning is refused' $true (Test-Throws { $null = Initialize-HarnessCfg $CfgB } 'REFUSED:*')
Write-Case 'pin: the ini path constant cannot be assigned' $true (Test-Throws { & (Get-Module Guard) { $script:HarnessPinnedCfgIni = 'x' } })
Write-Case 'pin: assigning a same-name variable that differs only by case is a hard error too' $true (Test-Throws { & (Get-Module Guard) { Set-Variable -Name ('harnesspinned' + 'CFGINI') -Scope Script -Value 'x' } })
$lead = [byte[]](0x5B, 0x52, 0x45, 0x41, 0x50, 0x45, 0x52, 0x5D, 0x0A, 0x6E, 0x61, 0x6D, 0x65, 0x3D, 0xE4, 0xB8, 0xAD, 0xFF, 0x0A)
[IO.File]::WriteAllBytes($pinned.Ini, $lead)
$changed = Set-HarnessIniValue -Section audioconfig -Key mode -Value 4
$now = [IO.File]::ReadAllBytes($pinned.Ini)
Write-Case 'ini: after changing a key every original byte (non-ASCII included) is kept; only a section was appended' $false ($changed -and $now.Length -gt $lead.Length -and (-join $now[0..($lead.Length - 1)]) -ceq (-join $lead) -and [Text.Encoding]::Latin1.GetString($now[$lead.Length..($now.Length - 1)]) -ceq "[audioconfig]`nmode=4`n")
Write-Case 'ini: an unchanged value does not write the file' $false (-not (Set-HarnessIniValue -Section audioconfig -Key mode -Value 4))

# ---- watchdog (stand-in processes) ----
# Invoke-HarnessHost only starts while the default lock is held. These stand-ins show no window, so they hold a default
# lock of their own name and never wait for a real run; the dialog cases below go back to the real name and the real set.
$realGui = Get-HarnessDefaultGuiLock
$useDefaultLock = { param($Full) & (Get-Module Locks) { param($v) $script:DefaultGui = $v } $Full }
& $useDefaultLock "Local\ReaperHarness-selftest-$PID-standin"
$standInGui = Get-HarnessDefaultGuiLock
$standInLock = Enter-HarnessLocks -Names @($standInGui) -TimeoutSeconds 5 -Quiet
$seenA = @{ Called = $false }
$bystander = [Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]::new($pwshExe, '-NoProfile -Command Start-Sleep -Seconds 120'))
try {
    $run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 2 -Launcher (New-StandIn 'Start-Sleep -Seconds 60' $seenA)
    Write-Case 'watchdog: ended at the timeout, status Timeout' $true ($run.Status -eq 'Timeout' -and (& $gone $run.Pid))
    Write-Case 'watchdog: only the PID it started is ended; a bystander process is still alive' $false (-not $bystander.HasExited)
    Write-Case 'command line: -nosplash, -newinst and the configuration file argument of the private ini are one element each, the ini path with its space too' $false ($pinned.Ini.Contains(' ') -and ($seenA.Args -join "`n") -ceq (@('-nosplash', '-newinst', $flag, $pinned.Ini) -join "`n"))
} finally { if (-not $bystander.HasExited) { Stop-Process -Id $bystander.Id -Force } }
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -KillAfterSec 1.5 -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
Write-Case 'watchdog: ended at the kill point, status Killed, without waiting for the timeout' $true ($run.Status -eq 'Killed' -and $run.Seconds -lt 8 -and (& $gone $run.Pid))
Write-Case 'watchdog: a process that was ended does not count as still running' $false ($run.StillRunning -eq $false)
# A process the watchdog cannot end. Each stand-in here is ended by this self-test, as soon as its case has been judged.
$endStandIn = { param($ProcessId) Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue }
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -KillAfterSec 1 -Stopper { param($id) throw 'access denied' } -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
try { Write-Case 'watchdog: a stop that fails is not swallowed: StillRunning, and the process really is still there' $true ($run.Status -eq 'Killed' -and $run.StillRunning -eq $true -and -not (& $gone $run.Pid)) }
finally { & $endStandIn $run.Pid }
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -KillAfterSec 1 -Stopper { param($id) } -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
try { Write-Case 'watchdog: a stop that reports nothing but leaves the process alive: StillRunning (the wait timed out)' $true ($run.Status -eq 'Killed' -and $run.StillRunning -eq $true -and -not (& $gone $run.Pid)) }
finally { & $endStandIn $run.Pid }
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -KillAfterSec 1 -Stopper { param($id) Stop-Process -Id $id -Force; throw 'it had already gone' } -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
Write-Case 'watchdog: a stop that complains about a process that is gone is no failure: not StillRunning' $false ($run.Status -eq 'Killed' -and $run.StillRunning -eq $false -and (& $gone $run.Pid))
# Watching fails after the start: whatever broke, the process is not left behind, and only this function could end it
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -WatchModules 'X.vst3' -ModuleSampler { param($p) throw "the module list`nbroke" } -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
Write-Case 'watching fails: no exception, the process is ended by its PID, the status and the error say so, on one line' $true ($run.Status -ceq 'Error' -and $run.StillRunning -eq $false -and (& $gone $run.Pid) -and $run.Error -ceq 'the module list broke' -and $null -eq $run.ExitCode)
$errorMark = Join-Path $Work 'error-mark'
Set-Content -LiteralPath $errorMark -Value x
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -WatchFiles @{ warm = $errorMark } -Sampler { param($p) throw 'the counters broke' } -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
Write-Case 'watching fails: counters that cannot be read end the process too' $true ($run.Status -ceq 'Error' -and $run.StillRunning -eq $false -and (& $gone $run.Pid) -and $run.Error -ceq 'the counters broke')
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -WatchModules 'X.vst3' -ModuleSampler { param($p) throw 'the module list broke' } -Stopper { param($id) } -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
try { Write-Case 'watching fails and the process cannot be ended: StillRunning, like at a timeout' $true ($run.Status -ceq 'Error' -and $run.StillRunning -eq $true -and -not (& $gone $run.Pid)) }
finally { & $endStandIn $run.Pid }
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -KillAfterSec 1 -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
Write-Case 'watching fails: a launch where nothing broke has no error' $false ($run.Status -ceq 'Killed' -and $null -eq $run.Error)
# What a caller learns about the process it had started, also when it is still there
$startedRows = [Collections.Generic.List[object]]::new()
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -KillAfterSec 1 -Stopper { param($id) } -StartedList $startedRows -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
try {
    Write-Case 'started list: the process is listed with its PID and its start time right after the start' $true ($startedRows.Count -eq 1 -and $startedRows[0].Pid -eq $run.Pid -and $startedRows[0].StartUtc -is [datetime] -and $startedRows[0].StartUtc -ge $run.StartedUtc.AddSeconds(-5))
    Write-Case 'left over: a process of the list that is still alive is found' $true (@(Get-HarnessOwnProcessesLeft -Started $startedRows.ToArray()).Count -eq 1)
    $otherStart = [pscustomobject]@{ Pid = $run.Pid; StartUtc = $startedRows[0].StartUtc.AddSeconds(-1) }
    Write-Case 'left over: the same PID with another start time is not this process' $false (@(Get-HarnessOwnProcessesLeft -Started @($otherStart)).Count -eq 0)
} finally { & $endStandIn $run.Pid }
$until = (Get-Date).AddSeconds(10)
while (-not (& $gone $run.Pid) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 100 }
Write-Case 'left over: once it is gone it is not found any more' $false (@(Get-HarnessOwnProcessesLeft -Started $startedRows.ToArray()).Count -eq 0)
# The mark file appears after the process has exited (the stand-in waits for its process, then writes the mark):
# recorded as SampleLost with that reason
$quickMark = Join-Path $Work 'mark-after-exit.txt'
$quickLauncher = { param($psi) $psi.FileName = $pwshExe; $psi.ArgumentList.Clear(); foreach ($part in '-NoProfile', '-Command', 'exit 0') { $psi.ArgumentList.Add($part) }; $p = [Diagnostics.Process]::Start($psi); $p.WaitForExit(); Set-Content -LiteralPath $quickMark -Value x; $p }.GetNewClosure()
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -WatchFiles @{ loop = $quickMark } -Launcher $quickLauncher
Write-Case 'sampling: a mark that appears after the process exited is SampleLost, reported as "exited before the sample", not "missing"' $true ($run.Status -eq 'Exited' -and @($run.SampleLost) -contains 'loop' -and -not $run.Marks.Contains('loop') -and
    (Get-HarnessMarkProblem -Samples $run.Marks -LostAt @($run.SampleLost) -Need 'loop') -like '*exited before*')
$preMark = Join-Path $Work 'mark-present.txt'
Set-Content -LiteralPath $preMark -Value x
$exitedSampler = { param($p) [pscustomobject]@{ Exited = $true; Handles = $null; PrivateMB = $null; WorkingMB = $null } }
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -KillAfterSec 1.5 -WatchFiles @{ warm = $preMark } -Sampler $exitedSampler -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
Write-Case 'sampling: a sample taken when the process has exited is SampleLost, empty counters are not taken as a sample' $true ($run.Status -eq 'Killed' -and @($run.SampleLost) -contains 'warm' -and -not $run.Marks.Contains('warm') -and (& $gone $run.Pid))
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -Launcher (New-StandIn 'exit 3' @{})
Write-Case 'a process that exits by itself: status Exited, exit code recorded, not still running' $false ($run.Status -eq 'Exited' -and $run.ExitCode -eq 3 -and $run.StillRunning -eq $false)
Write-Case 'launch record: ExitedUtc is the exit the process reported, after the moment before the start, not later than now' $false (
    $run.ExitedUtc -ge $run.StartedUtc -and $run.ExitedUtc -le [DateTime]::UtcNow.AddSeconds(1) -and ($run.ExitedUtc - $run.StartedUtc).TotalSeconds -lt 20 -and $run.ExitedUtc.Kind -eq [DateTimeKind]::Utc)
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -KillAfterSec 1.5 -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
Write-Case 'launch record: an ended process has ExitedUtc too (after the end, not later than now)' $false ($run.Status -eq 'Killed' -and $run.ExitedUtc -gt $run.StartedUtc.AddSeconds(1) -and $run.ExitedUtc -le [DateTime]::UtcNow.AddSeconds(1))
$xs = [DateTime]::new(2026, 10, 26, 6, 0, 0, [DateTimeKind]::Utc); $xd = $xs.AddSeconds(20)
$xr = { param($rep) Resolve-HarnessExitedUtc -Reported $rep -NotBeforeUtc $xs -NoticedUtc $xd }
Write-Case 'exit time: a reported time within [before the start, noticed + 1 s] is used (both ends included)' $false (
    (& $xr $xs.AddSeconds(19.9)) -eq $xs.AddSeconds(19.9) -and (& $xr $xs) -eq $xs -and (& $xr $xd.AddSeconds(1)) -eq $xd.AddSeconds(1) -and (& $xr $xs.AddSeconds(19.9)).Kind -eq [DateTimeKind]::Utc)
Write-Case 'exit time: a reported FILETIME 0 (1601-01-01 UTC, seen on real machines) is not used; the moment the exit was noticed is' $true ((& $xr ([DateTime]::FromFileTime(0).ToUniversalTime())) -eq $xd)
Write-Case 'exit time: reported 1 ms before the start: not used' $true ((& $xr $xs.AddMilliseconds(-1)) -eq $xd)
Write-Case 'exit time: reported 1 ms after noticed + 1 s: not used' $true ((& $xr $xd.AddSeconds(1).AddMilliseconds(1)) -eq $xd)
Write-Case 'exit time: nothing reported: the moment the exit was noticed' $true ((& $xr $null) -eq $xd -and (& $xr $null).Kind -eq [DateTimeKind]::Utc)
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -Launcher (New-BadExitTimeStandIn 'exit 0')
Write-Case 'launch record: a process reporting the year 1601 (exited by itself): ExitedUtc is when the exit was noticed' $true ($run.Status -eq 'Exited' -and $run.ExitedUtc -ge $run.StartedUtc -and $run.ExitedUtc -le [DateTime]::UtcNow.AddSeconds(1) -and ($run.ExitedUtc - $run.StartedUtc).TotalSeconds -lt 20)
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -KillAfterSec 1.5 -Launcher (New-BadExitTimeStandIn 'Start-Sleep -Seconds 60')
Write-Case 'launch record: a process reporting the year 1601 (ended): ExitedUtc is when the exit was noticed' $true ($run.Status -eq 'Killed' -and $run.ExitedUtc -gt $run.StartedUtc.AddSeconds(1) -and $run.ExitedUtc -le [DateTime]::UtcNow.AddSeconds(1))
$seenB = @{ Called = $false }
$sentinelFile = Join-Path $pinned.Dir (Get-HarnessSentinel).Name
$sentinelText = Get-Content -LiteralPath $sentinelFile -Raw
Remove-Item -LiteralPath $sentinelFile
try { Write-Case 'checked again before every start: with the sentinel deleted the start is refused and the stand-in is never called' $true ((Test-Throws { $null = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -Launcher (New-StandIn 'exit 0' $seenB) } 'REFUSED:*sentinel*') -and -not $seenB.Called) }
finally { [IO.File]::WriteAllText($sentinelFile, $sentinelText) }
# What can appear after the pin: the top level is checked again before every start, the tree below it is not
$otherFile = Join-Path $Work 'other-name.ini'
[IO.File]::WriteAllText($otherFile, 'x')
$linkTo = { param($At) try { $null = New-Item -ItemType HardLink -Path $At -Target $otherFile -ErrorAction Stop; $true } catch { $false } }
$lateTop = Join-Path $pinned.Dir 'late.ini'
$lateTopMade = & $linkTo $lateTop
$noLink = $lateTopMade ? '' : ' (hard links cannot be made here; not run for real)'
$seenC = @{ Called = $false }
try { Write-Case "after the pin: a hard link that appears at the top level is refused at the next start and the stand-in is never called$noLink" $true ((-not $lateTopMade) -or ((Test-Throws { $null = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -Launcher (New-StandIn 'exit 0' $seenC) } 'REFUSED:*hard link*') -and -not $seenC.Called)) }
finally { if ($lateTopMade) { Remove-Item -LiteralPath $lateTop } }
Write-Case 'after the pin: with that hard link gone the check passes again' $false ((Get-HarnessCfgArgument) -ceq $pinned.Ini)
$lateSub = Join-Path $plugin 'late.dll'
$lateSubMade = & $linkTo $lateSub
try { Write-Case "after the pin: the tree below the top level is walked once, not again by the next check or by pinning the same directory again$noLink" $false ((-not $lateSubMade) -or ((Get-HarnessCfgArgument) -ceq $pinned.Ini -and (Initialize-HarnessCfg $CfgA).Ini -ceq $pinned.Ini)) }
finally { if ($lateSubMade) { Remove-Item -LiteralPath $lateSub } }
$sampled = @{ N = 0 }
$elsewhere = Join-Path $Work 'elsewhere\Some Plugin.vst3'
$kernel = Join-Path ([Environment]::SystemDirectory) 'kernel32.dll'
$fakeModules = { param($proc) $sampled.N++; @($elsewhere, (Join-Path $pinned.Dir 'plugins\X.vst3\Contents\x86_64-win\X.vst3'), $kernel) }.GetNewClosure()
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -KillAfterSec 1.5 -WatchModules 'X.vst3' -ModuleSampler $fakeModules -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
Write-Case 'modules: the watched binary is collected by file name with its full path; every loaded .vst3 / .clap is listed, other DLLs are not' $false (
    $sampled.N -gt 0 -and $run.ModuleScans -eq $sampled.N -and @($run.Modules['X.vst3']).Count -eq 1 -and @($run.PluginModules).Count -eq 2 -and -not (@($run.PluginModules) -match 'kernel32'))
# ---- what may start at all: the lock, checked here and not left to callers; there is no way around it with a Launcher
$refusedLock = {
    param($Candidate)
    $marks = @{ Called = $false }
    (Test-Throws { $null = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $Candidate -Launcher (New-StandIn 'exit 0' $marks) } 'REFUSED:*GUI lock*') -and -not $marks.Called
}
Write-Case 'lock: without a lock object the start is refused and the stand-in is never called' $true (& $refusedLock $null)
$otherName = "Local\ReaperHarness-selftest-$PID-other"
$otherOnly = Enter-HarnessLocks -Names @($otherName) -TimeoutSeconds 5 -Quiet
Write-Case 'lock: a lock object that does not hold the default lock is refused and the stand-in is never called' $true (& $refusedLock $otherOnly)
Exit-HarnessLocks $otherOnly
$released = Enter-HarnessLocks -Names @($standInGui) -TimeoutSeconds 5 -Quiet
Exit-HarnessLocks $released
Write-Case 'lock: a lock object already released is refused' $true (& $refusedLock $released)
Write-Case 'lock: an object that only names the default lock is refused (no mutex behind it, or nothing held at all)' $true ((& $refusedLock ([pscustomobject]@{ Names = @($standInGui); Held = @() })) -and (& $refusedLock ([pscustomobject]@{ Names = @($standInGui); Held = @([pscustomobject]@{ Name = $standInGui; Mutex = $null }) })) -and (& $refusedLock 'a string') -and (& $refusedLock @{ Held = @() }) -and (& $refusedLock ([pscustomobject]@{ Held = @('x') })))
$bothHeld = Enter-HarnessLocks -Names @($otherName, $standInGui) -TimeoutSeconds 5 -Quiet
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $bothHeld -TimeoutSec 30 -Launcher (New-StandIn 'exit 0' @{})
Exit-HarnessLocks $bothHeld
Write-Case 'lock: a set holding the default lock and an extra one starts' $false ($run.Status -eq 'Exited')
# ---- arguments: one element each, and nothing that could undo the guarded configuration file argument
$refusedArgs = {
    param([string[]]$Candidate, [string]$Like)
    $marks = @{ Called = $false }
    (Test-Throws { $null = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -ReaperArgs $Candidate -Launcher (New-StandIn 'exit 0' $marks) } $Like) -and -not $marks.Called
}
Write-Case 'arguments: a double quote in -ReaperArgs (a caller still quoting for itself) is refused before the start' $true (& $refusedArgs @('-renderproject', '"D:\my dir\a.rpp"') 'REFUSED:*double quote*')
Write-Case 'arguments: the configuration file switch again in -ReaperArgs is refused before the start, in any case and with blanks' $true ((& $refusedArgs @('x', $flag, 'D:\other\reaper.ini') 'REFUSED:*switch again*') -and (& $refusedArgs @($flag.ToUpperInvariant(), 'x') 'REFUSED:*switch again*') -and (& $refusedArgs @(" $flag ") 'REFUSED:*switch again*'))
$seenArgs = @{ Called = $false }
$lookAlike = "D:\my dir\notes$flag\a b.rpp"
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -ReaperArgs '-renderproject', $lookAlike -TimeoutSec 30 -Launcher (New-StandIn 'exit 0' $seenArgs)
Write-Case 'arguments: -ReaperArgs follow one element each; a path that only contains the word of the switch is not refused' $false ($run.Status -eq 'Exited' -and ($seenArgs.Args -join "`n") -ceq (@('-nosplash', '-newinst', $flag, $pinned.Ini, '-renderproject', $lookAlike) -join "`n"))
# What a real process receives: this stand-in keeps the arguments Host prepared and writes down what arrives
$echoDir = Join-Path $Work 'echo dir'
$null = New-Item -ItemType Directory -Path $echoDir
$echoScript = Join-Path $echoDir 'echo.ps1'
[IO.File]::WriteAllText($echoScript, '[IO.File]::WriteAllLines((Join-Path $PSScriptRoot "argv.txt"), [string[]]$args)')
$echoLauncher = { param($psi) $psi.FileName = $pwshExe; $psi.ArgumentList.Insert(0, '-NoProfile'); $psi.ArgumentList.Insert(1, '-File'); $psi.ArgumentList.Insert(2, $echoScript); [Diagnostics.Process]::Start($psi) }.GetNewClosure()
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -ReaperArgs '-renderproject', 'D:\my dir\a b.rpp' -TimeoutSec 30 -Launcher $echoLauncher
$received = try { @([IO.File]::ReadAllLines((Join-Path $echoDir 'argv.txt'))) } catch { @() }
Write-Case 'arguments: a real process receives the private ini and a path with spaces as one argument each' $false ($run.Status -eq 'Exited' -and ($received -join "`n") -ceq (@('-nosplash', '-newinst', $flag, $pinned.Ini, '-renderproject', 'D:\my dir\a b.rpp') -join "`n"))
# ---- the environment a launch inherits: the plugin variables of the configuration are taken out unless it sets them
$envSeen = @{}
$envLauncher = { param($psi) foreach ($n in 'EXAMPLE_PROBE_ONE', 'EXAMPLE_PROBE_TWO', 'EXAMPLE_PROBE_THREE') { $envSeen[$n] = $psi.Environment.ContainsKey($n) ? [string]$psi.Environment[$n] : $null }
    $psi.FileName = $pwshExe; $psi.ArgumentList.Clear(); foreach ($part in '-NoProfile', '-Command', 'exit 0') { $psi.ArgumentList.Add($part) }; [Diagnostics.Process]::Start($psi) }.GetNewClosure()
$envWas = @{}
foreach ($n in 'EXAMPLE_PROBE_ONE', 'EXAMPLE_PROBE_TWO', 'EXAMPLE_PROBE_THREE') { $envWas[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, "left in the shell: $n") }
try {
    $run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -Unset 'EXAMPLE_PROBE_ONE', 'EXAMPLE_PROBE_TWO' -Environment @{ EXAMPLE_PROBE_TWO = 'set by this launch' } -Launcher $envLauncher
} finally { foreach ($n in $envWas.get_Keys()) { Restore-ChildEnvVariable $n $envWas[$n] } }
Write-Case "environment: a name to unset is not inherited; one the launch sets has its value; any other is inherited as before ($($envSeen['EXAMPLE_PROBE_ONE']) | $($envSeen['EXAMPLE_PROBE_TWO']) | $($envSeen['EXAMPLE_PROBE_THREE']))" $true (
    $run.Status -eq 'Exited' -and $null -eq $envSeen['EXAMPLE_PROBE_ONE'] -and $envSeen['EXAMPLE_PROBE_TWO'] -ceq 'set by this launch' -and $envSeen['EXAMPLE_PROBE_THREE'] -ceq 'left in the shell: EXAMPLE_PROBE_THREE' -and
    $null -eq [Environment]::GetEnvironmentVariable('EXAMPLE_PROBE_ONE'))
# ---- the check of every launch's environment comes before anything is taken: a value outside the work directory starts nothing
$h3Lock = "Local\ReaperHarness-selftest-$PID-h3"
$seenH3 = @{ Called = $false }
$h3Work = Join-Path $Work 'h3-work'
$null = New-Item -ItemType Directory -Force -Path $h3Work
$h3Ctx = @{ Work = $h3Work; StillRunning = $null; SkipMarkers = @(); Locks = @($h3Lock); LockWaitSec = 5; Launcher = (New-StandIn 'exit 0' $seenH3); Installed = @{}; Started = [Collections.Generic.List[object]]::new()
    LaunchLog = [Collections.Generic.List[object]]::new(); Launches = 0; PluginEnvNames = @() }
$h3Why = try { $null = & (Get-Module Scenarios) { param($c, $h) Invoke-HarnessLaunchOnce -Ctx $c -HostArgs $h } $h3Ctx @{ Environment = @{ X_ONE = 'C:\elsewhere' } }; '' } catch { $_.Exception.Message }
Write-Case "launch environment: a value outside the work directory: REAPER is not started, the stand-in is never called and no lock is taken ($h3Why)" $true (
    $h3Why -clike 'REAPER was not started: the value of X_ONE is not a path inside the work directory' -and -not $seenH3.Called -and $h3Ctx.Launches -eq 0 -and $h3Ctx.Started.Count -eq 0 -and (Test-HarnessLockFree -FullName $h3Lock))
$h3Name = try { $null = & (Get-Module Scenarios) { param($c, $h) Invoke-HarnessLaunchOnce -Ctx $c -HostArgs $h } $h3Ctx @{ Environment = @{ COMSPEC = (Join-Path $h3Work 'x') } }; '' } catch { $_.Exception.Message }
Write-Case "launch environment: a denied name with a value in the work directory starts nothing either ($h3Name)" $true ($h3Name -clike "REAPER was not started: 'COMSPEC' is a variable Windows or a runtime reads; the harness may not set it" -and -not $seenH3.Called)
# ---- the capture service of a launch with shots: started with the process, stopped whatever ended the launch ----
Initialize-HarnessCapture
$shotRoot = Join-Path $Work 'host-shots'
$null = New-Item -ItemType Directory -Force -Path $shotRoot
$shotEntries = {
    param([string]$Tag, [int]$Count = 2)
    $d = Join-Path $shotRoot $Tag
    $null = New-Item -ItemType Directory -Force -Path $d
    @(for ($k = 1; $k -le $Count; $k++) { [pscustomobject]@{ Req = (Join-Path $d "s-$k.req"); Png = (Join-Path $d "s-$k.png"); Done = (Join-Path $d "s-$k.done"); Err = (Join-Path $d "s-$k.err") } })
}
# Whether either answer file of a shot comes within Ms
$answered = {
    param($Shot, [int]$ms)
    $until = [DateTime]::UtcNow.AddMilliseconds($ms)
    do { if ((Test-Path -LiteralPath $Shot.Done) -or (Test-Path -LiteralPath $Shot.Err)) { return $true }; Start-Sleep -Milliseconds 20 } while ([DateTime]::UtcNow -lt $until)
    $false
}
$quoted = { param([string]$text) "'" + ($text -replace "'", "''") + "'" }
$h1 = @(& $shotEntries 'h1')
$h1Mark = Join-Path $shotRoot 'h1.mark'
$h1Cmd = "[IO.File]::WriteAllText($(& $quoted $h1[0].Req), '1'); `$t = [Diagnostics.Stopwatch]::StartNew(); while (-not (Test-Path -LiteralPath $(& $quoted $h1[0].Err)) -and `$t.ElapsedMilliseconds -lt 2000) { Start-Sleep -Milliseconds 20 }; " +
    "[IO.File]::WriteAllText($(& $quoted $h1Mark), [string]`$t.ElapsedMilliseconds); Start-Sleep -Seconds 2"
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -Captures $h1 -Launcher (New-StandIn $h1Cmd @{})
$h1Answer = (Test-Path -LiteralPath $h1[0].Err) ? [IO.File]::ReadAllText($h1[0].Err) : ''
$h1Took = (Test-Path -LiteralPath $h1Mark) ? [IO.File]::ReadAllText($h1Mark) : ''
[IO.File]::WriteAllText($h1[1].Req, '1')
Write-Case "capture service: a request of the launched process is answered within 2 s (no plugin window: nowindow); once the host has returned the service has stopped and a later request gets no answer ($h1Took ms, $($h1Answer.Trim()))" $true (
    $run.Status -ceq 'Exited' -and $run.CaptureStopped -eq $true -and $h1Answer -ceq "reason=nowindow`n" -and $h1Took -cmatch '^\d+$' -and [int]$h1Took -lt 2000 -and -not (& $answered $h1[1] 1000) -and
    -not (Test-Path -LiteralPath $h1[0].Png))
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -TimeoutSec 30 -Launcher (New-StandIn 'exit 0' @{})
Write-Case 'capture service: a launch without shots has none (CaptureStopped is null)' $false ($run.Status -ceq 'Exited' -and $null -ne $run.PSObject.Properties['CaptureStopped'] -and $null -eq $run.CaptureStopped)
$stoppedBy = @(
    @{ L = 'a watch that fails (Error)'; A = @{ TimeoutSec = 30; WatchModules = 'X.vst3'; ModuleSampler = { param($p) throw 'the module list broke' } }; S = 'Error' }
    @{ L = 'the timeout'; A = @{ TimeoutSec = 2 }; S = 'Timeout' }
    @{ L = 'the kill point'; A = @{ TimeoutSec = 30; KillAfterSec = 1.5 }; S = 'Killed' }
)
foreach ($c in $stoppedBy) {
    $later = @(& $shotEntries "stop-$($c.S.ToLowerInvariant())" 1)
    $splat = $c.A
    $run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $standInLock -Captures $later -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{}) @splat
    [IO.File]::WriteAllText($later[0].Req, '1')
    Write-Case "capture service: $($c.L) stops it too: CaptureStopped, and a request after the launch gets no answer" $true ($run.Status -ceq $c.S -and $run.CaptureStopped -eq $true -and (& $gone $run.Pid) -and -not (& $answered $later[0] 1000))
}
# The service alone, on processes of this self-test: it leaves by itself once its process is gone, it answers only the
# process that started when the host saw it start, and it leaves its loop at its deadline
$serviceRule = & (Get-Module Host) { $script:PluginOnlyWindow }
$serviceOf = { param($proc, $Shots, [long]$started, [int]$DeadlineMs = 60000) [HarnessCapture]::new([uint32]$proc.Id, $started, $serviceRule, [string[]]@($Shots.Req), [string[]]@($Shots.Png), [string[]]@($Shots.Done), [string[]]@($Shots.Err), $DeadlineMs) }
$startOf = { param($proc) $proc.StartTime.ToUniversalTime().ToFileTimeUtc() }
$shortLived = [Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]::new($pwshExe, '-NoProfile -Command Start-Sleep -Milliseconds 300'))
$alone = @(& $shotEntries 'alone' 1)
$svc = & $serviceOf $shortLived $alone (& $startOf $shortLived)
$svc.Start()
$null = $shortLived.WaitForExit(20000)
Start-Sleep -Milliseconds 300
[IO.File]::WriteAllText($alone[0].Req, '1')
$aloneAnswered = & $answered $alone[0] 500
Write-Case 'capture service: it leaves by itself once its process has exited, unasked' $true (-not $aloneAnswered -and $svc.Stop(0))
$sleeper = [Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]::new($pwshExe, '-NoProfile -Command Start-Sleep -Seconds 30'))
try {
    $wrongStart = @(& $shotEntries 'wrong-start' 1)
    $svc = & $serviceOf $sleeper $wrongStart ((& $startOf $sleeper) + 10000000)
    $svc.Start()
    [IO.File]::WriteAllText($wrongStart[0].Req, '1')
    $wrongAnswered = & $answered $wrongStart[0] 1000
    $wrongLeft = $svc.Stop(0)
    $rightStart = @(& $shotEntries 'right-start' 1)
    $svc = & $serviceOf $sleeper $rightStart (& $startOf $sleeper)
    $svc.Start()
    [IO.File]::WriteAllText($rightStart[0].Req, '1')
    $rightAnswered = & $answered $rightStart[0] 2000
    $rightStopped = $svc.Stop(5000)
    Write-Case 'capture service: a process that did not start when the host saw it start is not the one it started: nothing is answered' $true (-not $wrongAnswered -and $wrongLeft -and $rightAnswered -and $rightStopped)
    $pastDeadline = @(& $shotEntries 'deadline' 1)
    $svc = & $serviceOf $sleeper $pastDeadline (& $startOf $sleeper) 300
    $svc.Start()
    Start-Sleep -Milliseconds 800
    [IO.File]::WriteAllText($pastDeadline[0].Req, '1')
    Write-Case 'capture service: it leaves its loop at its deadline, even while its process runs' $true (-not (& $answered $pastDeadline[0] 500) -and $svc.Stop(0))
} finally { if (-not $sleeper.HasExited) { Stop-Process -Id $sleeper.Id -Force } }
$h3Shot = try { $null = & (Get-Module Scenarios) { param($c, $h) Invoke-HarnessLaunchOnce -Ctx $c -HostArgs $h } $h3Ctx @{ Captures = @([pscustomobject]@{ Req = (Join-Path $h3Work 'a.req'); Png = (Join-Path $Work 'a.png'); Done = (Join-Path $h3Work 'a.done'); Err = (Join-Path $h3Work 'a.err') }) }; '' } catch { $_.Exception.Message }
Write-Case "launch shots: a shot file outside the work directory: REAPER is not started, the stand-in is never called and no lock is taken ($h3Shot)" $true (
    $h3Shot -ceq 'REAPER was not started: a shot file is not a path inside the work directory' -and -not $seenH3.Called -and $h3Ctx.Launches -eq 0 -and $h3Ctx.Started.Count -eq 0 -and (Test-HarnessLockFree -FullName $h3Lock))
Exit-HarnessLocks $standInLock
& $useDefaultLock $realGui
# The text of the message box command itself, with an apostrophe in the title and the path; real boxes come below
$boxErrors = $null; $boxTokens = $null
$boxAst = [System.Management.Automation.Language.Parser]::ParseInput((New-BoxCommand "it's a title" 'OK' "D:\o'brien\box.txt"), [ref]$boxTokens, [ref]$boxErrors)
$boxLiterals = @($boxAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
Write-Case 'box command: an apostrophe in the title or the path stays inside its string' $true ($boxErrors.Count -eq 0 -and "it's a title" -cin $boxLiterals -and "D:\o'brien\box.txt" -cin $boxLiterals)

# ---- dialogs (real message boxes, under the GUI locks like a real run) ----
# A message box needs a visible window station. In a session without one (a service, which is how some CI runners
# run) WinForms refuses to show it and the stand-in exits at once, so these cases could say nothing about the dialog
# handling. Then, and only then, they are reported as not run; the parent fails when they are missing although this
# session has a desktop. The window verdicts themselves are pure functions and run everywhere (Get-HostCases).
# Invoke-WithHarnessLocks is fine here because no REAPER is involved: every stand-in is gone when its case is judged.
$dialogCases = {
    param($guiLock)
    $outNo = Join-Path $Work 'box-no.txt'
    $run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $guiLock -TimeoutSec 30 -Launcher (New-StandIn (New-BoxCommand 'REAPER Query' 'YesNo' $outNo) @{})
    Write-Case 'dialog: REAPER Query is answered No, the process exits normally' $false ($run.Status -eq 'Exited' -and 'save-prompt' -in $run.Dismissed -and (Test-Path -LiteralPath $outNo) -and (Get-Content -LiteralPath $outNo -Raw).Trim() -eq 'No')
    $run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $guiLock -TimeoutSec 30 -Launcher (New-StandIn (New-BoxCommand 'Project Load Warning' 'OK' (Join-Path $Work 'box-warn.txt')) @{})
    Write-Case 'dialog: Project Load Warning counts as stuck, the process is ended, status Modal' $true ($run.Status -eq 'Modal' -and $run.Modal -eq 'project-load-warning' -and (& $gone $run.Pid))
    $run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $guiLock -TimeoutSec 30 -Launcher (New-StandIn (New-BoxCommand 'About REAPER v7.82 - evaluation' 'OK' (Join-Path $Work 'box-nag.txt')) @{})
    Write-Case 'dialog: the licence reminder is never clicked away; stuck as license-nag' $true ($run.Status -eq 'Modal' -and $run.Modal -eq 'license-nag' -and -not (Test-Path -LiteralPath (Join-Path $Work 'box-nag.txt')))
    $run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $guiLock -TimeoutSec 30 -Launcher (New-StandIn (New-BoxCommand 'Something New' 'OK' (Join-Path $Work 'box-new.txt')) @{})
    Write-Case 'dialog: a dialog never seen before counts as stuck too (unknown-dialog)' $true ($run.Status -eq 'Modal' -and $run.Modal -eq 'unknown-dialog')
    $outBy = Join-Path $Work 'box-bystander.txt'
    $boxCmd = New-BoxCommand 'REAPER Query' 'YesNo' $outBy
    $bystander = [Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]::new($pwshExe, "-NoProfile -Command `"$boxCmd`""))
    $bystanderLabel = "dialog: another process's REAPER Query is not clicked (only windows of the started PID are handled)"
    try {
        # Without the box on screen this case would prove nothing, so it is red when the box does not come up
        if (Wait-BoxShown $bystander 'REAPER Query' 30) {
            $run = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $guiLock -TimeoutSec 30 -KillAfterSec 3 -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
            Write-Case $bystanderLabel $false ($run.Status -eq 'Killed' -and @($run.Dismissed).Count -eq 0 -and -not $bystander.HasExited -and -not (Test-Path -LiteralPath $outBy))
        } else { Write-Case "$bystanderLabel; its box did not come up within 30 s" $false $false }
    } finally { if (-not $bystander.HasExited) { Stop-Process -Id $bystander.Id -Force } }
}
if ([Environment]::UserInteractive) { Invoke-WithHarnessLocks -Names (Get-HarnessGuiLockSet -Extra $extra) -TimeoutSeconds 1800 -ScriptBlock $dialogCases }
else { Write-Case '(no interactive desktop in this session: the real message box cases did not run for real)' $false $true }

# ---- shots of a real window (stand-ins with windows like REAPER's plugin window, under the GUI locks like a real run) ----
# Printing a window needs a desktop; without one these cases say they did not run, and the parent fails when they are
# missing although this session has one. Each stand-in (tests/FakeShots.ps1) shows its window without taking the focus
# and closes it once its mark file is there; every stand-in started here is ended before its block returns.
# A row, a fact or a file that is missing makes the case false, not the child stop: a condition that looks into a result
# or a file runs here
$holds = { param([scriptblock]$Condition) try { [bool](& $Condition) } catch { $false } }
$captureCases = {
    param($guiLock)
    $null = $guiLock
    $shotHome = Join-Path $Work 'real-shots'
    $null = New-Item -ItemType Directory -Force -Path $shotHome
    $fakeShots = Join-Path $RepoRoot 'tests/FakeShots.ps1'
    $rule = & (Get-Module Host) { $script:PluginOnlyWindow }
    $standIns = [Collections.Generic.List[object]]::new()
    $showOne = {
        param([string]$Tag, [string[]]$More = @(), [string]$Title = 'VST3: Fake Capture (Test) - Track 1 [1/1]')
        $psi = [Diagnostics.ProcessStartInfo]::new($pwshExe)
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $mark = Join-Path $shotHome "$Tag.close"
        foreach ($part in @('-NoProfile', '-NonInteractive', '-File', $fakeShots, '-Show', '-Until', $mark, '-Title', $Title) + $More) { $psi.ArgumentList.Add($part) }
        $p = [Diagnostics.Process]::Start($psi)
        $one = [pscustomobject]@{ Tag = $Tag; Proc = $p; Mark = $mark; Title = $Title; Started = $p.StartTime.ToUniversalTime().ToFileTimeUtc() }
        $standIns.Add($one)
        $one
    }
    # Its windows with that title, visible or not, once the stand-in has made them (at most 30 s)
    $windowsOf = {
        param($one, [int]$Want)
        $until = [DateTime]::UtcNow.AddSeconds(30)
        do {
            $rows = @([HarnessWin]::Windows([uint32]$one.Proc.Id) | Where-Object { ($_ -split "`t", 4)[3] -ceq $one.Title })
            if ($rows.Count -ge $Want) { return $rows.Count }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $until -and -not $one.Proc.HasExited)
        $rows.Count
    }
    $planIn = {
        param([string]$Tag, [int]$Count = 1)
        $d = Join-Path $shotHome $Tag
        $null = New-Item -ItemType Directory -Force -Path $d
        @(for ($k = 1; $k -le $Count; $k++) { [pscustomobject]@{ Req = (Join-Path $d "s-$k.req"); Png = (Join-Path $d "s-$k.png"); Done = (Join-Path $d "s-$k.done"); Err = (Join-Path $d "s-$k.err") } })
    }
    $serviceFor = { param([uint32]$ProcessId, [long]$started, $Shots) [HarnessCapture]::new($ProcessId, $started, $rule, [string[]]@($Shots.Req), [string[]]@($Shots.Png), [string[]]@($Shots.Done), [string[]]@($Shots.Err), 120000) }
    # The answer to one request: done (with the image) or err, as the harness reads it; '' when none came within 5 s
    $ask = {
        param($Service, $Shot)
        [IO.File]::WriteAllText($Shot.Req, '1')
        $until = [DateTime]::UtcNow.AddSeconds(5)
        do {
            if (Test-Path -LiteralPath $Shot.Done) { return 'done' }
            if (Test-Path -LiteralPath $Shot.Err) { return [IO.File]::ReadAllText($Shot.Err) }
            Start-Sleep -Milliseconds 20
        } while ([DateTime]::UtcNow -lt $until)
        ''
    }
    $quiet = { param($Shot, [int]$ms) Start-Sleep -Milliseconds $ms; -not (Test-Path -LiteralPath $Shot.Done) -and -not (Test-Path -LiteralPath $Shot.Err) -and -not (Test-Path -LiteralPath $Shot.Png) }
    # The PNG the service wrote, read back: chunks, sizes, every chunk's CRC, every row (filter 0, 3 bytes a pixel), and
    # with the view's top row: the stand-in's view colour (red 32, green 128, blue 224) inside the view and not above it
    $crcTable = [long[]]::new(256)
    for ($n = 0; $n -lt 256; $n++) { $c = [long]$n; for ($j = 0; $j -lt 8; $j++) { $c = ($c -band 1) ? ([long]3988292384 -bxor ($c -shr 1)) : ($c -shr 1) }; $crcTable[$n] = $c }
    $pngOk = {
        param([string]$path, [int]$w, [int]$h, [int]$ViewTop = -1)
        $b = [IO.File]::ReadAllBytes($path)
        $be = { param([int]$At) ([long]$b[$At] -shl 24) -bor ([long]$b[$At + 1] -shl 16) -bor ([long]$b[$At + 2] -shl 8) -bor [long]$b[$At + 3] }
        if ($b.Length -lt 57 -or [Convert]::ToHexString($b, 0, 8) -cne '89504E470D0A1A0A') { return $false }
        $types = [Collections.Generic.List[string]]::new(); $idat = [IO.MemoryStream]::new(); $pos = 8; $ihdrOk = $false; $crcBad = 0
        while ($pos + 12 -le $b.Length) {
            $len = & $be $pos; $type = [Text.Encoding]::ASCII.GetString($b, $pos + 4, 4)
            if ($pos + 12 + $len -gt $b.Length) { return $false }
            $types.Add($type)
            $c = [long]4294967295
            for ($i = $pos + 4; $i -lt $pos + 8 + $len; $i++) { $c = $crcTable[($c -bxor $b[$i]) -band 255] -bxor ($c -shr 8) }
            if (($c -bxor [long]4294967295) -ne (& $be ($pos + 8 + $len))) { $crcBad++ }
            if ($type -ceq 'IHDR') { $ihdrOk = (& $be ($pos + 8)) -eq $w -and (& $be ($pos + 12)) -eq $h -and $b[$pos + 16] -eq 8 -and $b[$pos + 17] -eq 2 }
            if ($type -ceq 'IDAT') { $idat.Write($b, $pos + 8, $len) }
            $pos += 12 + $len
        }
        $idat.Position = 0
        $raw = [IO.MemoryStream]::new()
        $z = [IO.Compression.ZLibStream]::new($idat, [IO.Compression.CompressionMode]::Decompress)
        try { $z.CopyTo($raw) } finally { $z.Dispose() }
        $rows = $raw.ToArray(); $stride = 1 + 3 * $w
        $filters = @(for ($y = 0; $y -lt $h; $y++) { if ($y * $stride -lt $rows.Length) { $rows[$y * $stride] } })
        $pixel = { param([int]$Col, [int]$Line) $where = $Line * $stride + 1 + 3 * $Col; ($where + 2 -lt $rows.Length) ? ('{0:X2}{1:X2}{2:X2}' -f $rows[$where], $rows[$where + 1], $rows[$where + 2]) : '' }
        $colours = $ViewTop -lt 0 -or ((& $pixel ($w / 2) ($ViewTop + 100)) -ceq '2080E0' -and (& $pixel ($w / 2) ($ViewTop / 2)) -cnotin '2080E0', '')
        $pos -eq $b.Length -and ($types -join ',') -ceq 'IHDR,IDAT,IEND' -and $ihdrOk -and $crcBad -eq 0 -and $rows.Length -eq $h * $stride -and @($filters | Where-Object { $_ -ne 0 }).Count -eq 0 -and $colours
    }
    try {
        $plain = & $showOne 'plain'
        $two = & $showOne 'two' @('-Two')
        $hidden = & $showOne 'hidden' @('-Hidden')
        $noWrap = & $showOne 'nowrap' @('-NoWrap')
        $chain = & $showOne 'chain' @() 'FX: Track 1'
        $named = & $showOne 'named' @() 'Fake VST3: x'
        $other = & $showOne 'other' @('-OtherClass')
        $wide = & $showOne 'wide' @('-Wide')
        $flat = & $showOne 'flat' @('-Flat')
        $shownCount = [ordered]@{}
        foreach ($s in $standIns) { $shownCount[$s.Tag] = & $windowsOf $s (($s.Tag -ceq 'two') ? 2 : 1) }
        Write-Case "capture: every stand-in shows its window(s) ($(@($shownCount.get_Keys() | ForEach-Object { "$_ $($shownCount[$_])" }) -join ', '))" $false (@($shownCount.get_Keys() | Where-Object { $shownCount[$_] -ne (($_ -ceq 'two') ? 2 : 1) }).Count -eq 0)

        # One plugin window of the process: the client area as a PNG, then the answer with its sizes and the view
        $r1 = & $planIn 'r1' 3
        $svc = & $serviceFor $plain.Proc.Id $plain.Started $r1
        $svc.Start()
        $a1 = & $ask $svc $r1[0]
        $answer1 = ($a1 -ceq 'done') ? (Read-HarnessShotAnswer -Path $r1[0].Done -Kind done) : $null
        $parts1 = @(Get-ChildItem -LiteralPath (Split-Path -Parent $r1[0].Png) -Filter '*.part' -Force)
        Write-Case "capture: one plugin window: a PNG of its 640 x 427 client area, top row first and red, green, blue in that order, then the answer with the view at 0,27 640 x 400 and the DPI; no .part left ($a1)" $true (& $holds {
            $null -ne $answer1 -and $answer1.Width -eq 640 -and $answer1.Height -eq 427 -and $null -ne $answer1.View -and $answer1.View.x -eq 0 -and $answer1.View.y -eq 27 -and $answer1.View.w -eq 640 -and
            $answer1.View.h -eq 400 -and $answer1.Dpi -ge 96 -and (Test-HarnessShotImage -Path $r1[0].Png -Answer $answer1) -and (& $pngOk $r1[0].Png 640 427 27) -and $parts1.Count -eq 0 -and
            ([IO.File]::GetLastWriteTimeUtc($r1[0].Done) -ge [IO.File]::GetLastWriteTimeUtc($r1[0].Png)) -and -not (Test-Path -LiteralPath $r1[0].Err) })
        # A request answered is never answered again; a request file of a name not in the plan is no request
        foreach ($f in $r1[0].Done, $r1[0].Png) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
        [IO.File]::WriteAllText($r1[0].Req, '2')
        $stray = Join-Path (Split-Path -Parent $r1[0].Png) 'stray-1.req'
        [IO.File]::WriteAllText($stray, '1')
        Write-Case 'capture: a request is answered once; a request file the plan does not name is not answered' $true (
            (& $quiet $r1[0] 800) -and @(Get-ChildItem -LiteralPath (Split-Path -Parent $r1[0].Png) -Filter 'stray-1.*' -Force).Count -eq 1)
        # An image already in place is never overwritten
        [IO.File]::WriteAllText($r1[1].Png, 'there first')
        $a7 = & $ask $svc $r1[1]
        Write-Case "capture: an image already in its place is never overwritten: exists ($($a7.Trim()))" $true ($a7 -ceq "reason=exists`n" -and [IO.File]::ReadAllText($r1[1].Png) -ceq 'there first' -and -not (Test-Path -LiteralPath $r1[1].Done))
        $a1b = & $ask $svc $r1[2]
        Write-Case 'capture: the service answers each request of its plan in turn' $false ($a1b -ceq 'done')
        $stop1 = $svc.Stop(5000)
        Write-Case 'capture: the service stops when asked' $false $stop1

        # A failure inside one answer is that answer's alone: the next request is answered all the same
        $r10 = & $planIn 'r10' 3
        $lost = Join-Path $shotHome 'r10-missing\deeper'
        $r10[0].Png = Join-Path $lost 's-1.png'
        $r10[1].Png = Join-Path $lost 's-2.png'; $r10[1].Err = Join-Path $lost 's-2.err'; $r10[1].Done = Join-Path $lost 's-2.done'
        $svc = & $serviceFor $plain.Proc.Id $plain.Started $r10
        $svc.Start()
        $a10 = & $ask $svc $r10[0]
        $a10b = & $ask $svc $r10[1]
        $a10c = & $ask $svc $r10[2]
        $null = $svc.Stop(5000)
        Write-Case "capture: an answer that fails is failed <exception>, one whose err file cannot be written is none, and the next request is answered all the same ($($a10.Trim()) | $a10b | $a10c)" $true (
            $a10 -ceq "reason=failed DirectoryNotFoundException`n" -and $a10b -ceq '' -and $a10c -ceq 'done' -and -not (Test-Path -LiteralPath $lost))

        # What is not one plugin window of that process is no shot
        $notShots = @(
            @{ L = 'two plugin windows'; S = $two; W = "reason=windows 2`n" }
            @{ L = 'a plugin window that is not visible'; S = $hidden; W = "reason=nowindow`n" }
            @{ L = 'an FX chain window'; S = $chain; W = "reason=nowindow`n" }
            @{ L = 'a title that only contains a format'; S = $named; W = "reason=nowindow`n" }
            @{ L = 'a window of another class'; S = $other; W = "reason=nowindow`n" }
            @{ L = 'a client area wider than 4096'; S = $wide; W = "reason=toolarge`n" }
            @{ L = 'a window without a client area'; S = $flat; W = "reason=empty`n" }
        )
        foreach ($c in $notShots) {
            $one = & $planIn "not-$($c.S.Tag)"
            $svc = & $serviceFor $c.S.Proc.Id $c.S.Started $one
            $svc.Start()
            $got = & $ask $svc $one[0]
            $null = $svc.Stop(5000)
            Write-Case "capture: $($c.L) is no shot ($($got.Trim()))" $true ($got -ceq $c.W -and -not (Test-Path -LiteralPath $one[0].Png))
        }
        # A shot directory that is a junction gets no answer of any kind, before any window is looked at: neither one
        # window, nor two, nor an image already there changes that, and nothing is written behind it. The service passes
        # those requests by (it answers each planned request at most once), so a later request of its plan in a plain
        # directory is answered all the same; written after the others had time to be seen, it is answered after them
        $behind = Join-Path $shotHome 'r11-behind'
        $null = New-Item -ItemType Directory -Force -Path $behind
        $linked = Join-Path $shotHome 'r11'
        $linkMade = try { $null = New-Item -ItemType Junction -Path $linked -Target $behind -ErrorAction Stop; $true } catch { $false }
        try {
            $r11 = @(foreach ($k in 1..3) { [pscustomobject]@{ Req = (Join-Path $linked "s-$k.req"); Png = (Join-Path $linked "s-$k.png"); Done = (Join-Path $linked "s-$k.done"); Err = (Join-Path $linked "s-$k.err") } })
            $after11 = @(& $planIn 'r11-plain' 2)
            [IO.File]::WriteAllText((Join-Path $behind 's-2.png'), 'there first')
            $svc = & $serviceFor $plain.Proc.Id $plain.Started @($r11[0], $r11[1], $after11[0])
            $svc.Start()
            foreach ($x in $r11[0], $r11[1]) { [IO.File]::WriteAllText($x.Req, '1') }
            Start-Sleep -Milliseconds 300
            $a11 = & $ask $svc $after11[0]
            $null = $svc.Stop(5000)
            $svc = & $serviceFor $two.Proc.Id $two.Started @($r11[2], $after11[1])
            $svc.Start()
            [IO.File]::WriteAllText($r11[2].Req, '1')
            Start-Sleep -Milliseconds 300
            $a11b = & $ask $svc $after11[1]
            $null = $svc.Stop(5000)
            $more11 = @(Get-ChildItem -LiteralPath $behind -Force | Where-Object { $_.Name -cnotmatch '\As-[123]\.req\z' -and $_.Name -cne 's-2.png' } | ForEach-Object { $_.Name })
            Write-Case "capture: a shot directory that is a junction gets no answer at all, before any window is looked at, and nothing is written behind it; a later request in a plain directory is answered ($($a11.Trim()) | $($a11b.Trim()); more: $($more11 -join ', '))" $true (
                $linkMade -and $a11 -ceq 'done' -and $a11b -ceq "reason=windows 2`n" -and $more11.Count -eq 0 -and @(Get-ChildItem -LiteralPath $behind -Filter 's-*.req' -Force).Count -eq 3 -and
                [IO.File]::ReadAllText((Join-Path $behind 's-2.png')) -ceq 'there first')
        } finally { if ($linkMade) { [IO.Directory]::Delete($linked) } }
        $r5 = & $planIn 'r5'
        $svc = & $serviceFor $noWrap.Proc.Id $noWrap.Started $r5
        $svc.Start()
        $a5 = & $ask $svc $r5[0]
        $null = $svc.Stop(5000)
        $answer5 = ($a5 -ceq 'done') ? (Read-HarnessShotAnswer -Path $r5[0].Done -Kind done) : $null
        Write-Case "capture: a plugin window without the view child is shot all the same, its view none ($a5)" $true (& $holds { $null -ne $answer5 -and $null -eq $answer5.View -and $answer5.Width -eq 640 -and (Test-HarnessShotImage -Path $r5[0].Png -Answer $answer5) })
        # Only windows of the PID it was given: a process without a window gets nowindow while another's is on screen
        $loneInfo = [Diagnostics.ProcessStartInfo]::new($pwshExe, '-NoProfile -Command Start-Sleep -Seconds 30')
        $loneInfo.CreateNoWindow = $true
        $lone = [Diagnostics.Process]::Start($loneInfo)
        try {
            $r3 = & $planIn 'r3'
            $svc = & $serviceFor $lone.Id $lone.StartTime.ToUniversalTime().ToFileTimeUtc() $r3
            $svc.Start()
            $a3 = & $ask $svc $r3[0]
            $null = $svc.Stop(5000)
            Write-Case "capture: only windows of the process it was given count: another process's plugin window is no shot of this one ($($a3.Trim()))" $true ($a3 -ceq "reason=nowindow`n" -and -not $plain.Proc.HasExited -and (& $windowsOf $plain 1) -eq 1)
        } finally { if (-not $lone.HasExited) { Stop-Process -Id $lone.Id -Force } }
        # Through the host, as a launch hands it over: the rule the host gives the service takes the plugin's window and
        # leaves an FX chain window of the same process alone, so the one plugin window is shot (not two windows)
        $viaHost = @(& $planIn 'via-host')
        $hostSpec = ConvertTo-Json -Compress -Depth 6 -InputObject ([ordered]@{ result = (Join-Path $shotHome 'via-host.txt'); window = $true; chain = $true
                shots = @([ordered]@{ n = 1; k = 1; at = 0; req = $viaHost[0].Req; done = $viaHost[0].Done; err = $viaHost[0].Err; name = 's-1.png' }) })
        $launchExe = $pwshExe
        $hostLaunch = { param($psi) $psi.FileName = $launchExe; $psi.ArgumentList.Clear(); foreach ($part in '-NoProfile', '-NonInteractive', '-File', $fakeShots) { $psi.ArgumentList.Add($part) }; $psi.Environment['FAKE_SHOTS'] = $hostSpec; [Diagnostics.Process]::Start($psi) }.GetNewClosure()
        $hostRun = Invoke-HarnessHost -ReaperExe 'stand-in' -Lock $guiLock -TimeoutSec 30 -Captures $viaHost -Launcher $hostLaunch
        $hostSaid = (Test-Path -LiteralPath $viaHost[0].Err) ? [IO.File]::ReadAllText($viaHost[0].Err).Trim() : ''
        Write-Case "capture: through the host, a plugin window next to an FX chain window of the same process is the one shot ($($hostRun.Status)$($hostSaid ? "; $hostSaid" : ''))" $true (& $holds {
                $hostRun.Status -ceq 'Exited' -and $hostRun.CaptureStopped -eq $true -and -not (Test-Path -LiteralPath $viaHost[0].Err) -and
                (Test-HarnessShotImage -Path $viaHost[0].Png -Answer (Read-HarnessShotAnswer -Path $viaHost[0].Done -Kind done)) })
    } finally {
        foreach ($s in $standIns) { [IO.File]::WriteAllText($s.Mark, '1') }
        foreach ($s in $standIns) { if (-not $s.Proc.WaitForExit(15000)) { Stop-Process -Id $s.Proc.Id -Force -ErrorAction SilentlyContinue } }
    }
    Write-Case 'capture: every stand-in window process has ended' $false (@($standIns | Where-Object { -not (& $gone $_.Proc.Id) }).Count -eq 0)
}
if ([Environment]::UserInteractive) { Invoke-WithHarnessLocks -Names (Get-HarnessGuiLockSet -Extra $extra) -TimeoutSeconds 1800 -ScriptBlock $captureCases }
else { Write-Case '(no interactive desktop in this session: the real capture cases did not run for real)' $false $true }

# ---- GUI locks (switched to names of this self-test, so a real run and the self-test never wait for each other) ----
& (Get-Module Locks) { $script:DefaultGui = "Local\ReaperHarness-selftest-$PID-gui" }
$gui = Get-HarnessDefaultGuiLock
$lockChild = { param($Command) Start-HarnessLockChild $Command }
$probe = "if (Enter-HarnessLocks -Names '$gui' -TimeoutSeconds 0 -Quiet) { exit 0 } else { exit 1 }"
$probeExit = { $p = & $lockChild $probe; $p.WaitForExit(); $p.ExitCode }.GetNewClosure()
# Ordinal order: 'A' < 'R' (of ReaperHarness) < 'b'; a culture-aware sort would put b-x before the default lock
$set = (Get-HarnessGuiLockSet -Extra 'Local\b-x', 'Local\A-y', 'Local\b-x') -join '|'
Write-Case 'locks: the lock set is the default plus extras, de-duplicated and in ordinal order; a bad name is a usage error' $true (
    $set -ceq "Local\A-y|$gui|Local\b-x" -and (Test-Throws { Get-HarnessGuiLockSet -Extra 'Global\x' } 'USAGE:*') -and (Test-Throws { Get-HarnessGuiLockSet -Extra 'Local\a b' } 'USAGE:*'))
Write-Case 'locks: a lock name is the whole text: a line end after it or anything before it makes it no lock name' $true (
    -not (Test-HarnessLockName "Local\x`n") -and -not (Test-HarnessLockName "Local\x`r`n") -and -not (Test-HarnessLockName 'xLocal\x') -and -not (Test-HarnessLockName "`nLocal\x") -and (Test-HarnessLockName 'Local\x.y_z-1') -and
    (Test-Throws { Get-HarnessGuiLockSet -Extra "Local\x`n" } 'USAGE:*'))
# Taking and releasing a set directly (what a caller does around Invoke-HarnessHost)
$freeLock = $gui.Replace('-gui', '-free')
$held = Enter-HarnessLocks -Names @($freeLock, $gui) -TimeoutSeconds 5 -Quiet
Write-Case 'locks: while this process holds the set, another process can take neither lock' $true ($null -ne $held -and -not (Test-HarnessLockFree -FullName $gui) -and -not (Test-HarnessLockFree -FullName $freeLock))
Exit-HarnessLocks $held
Write-Case 'locks: after Exit-HarnessLocks both are free again' $false ((Test-HarnessLockFree -FullName $gui) -and (Test-HarnessLockFree -FullName $freeLock))
Write-Case 'locks: Invoke-WithHarnessLocks hands the block the lock object it holds' $false (Invoke-WithHarnessLocks -Names @($gui) -TimeoutSeconds 5 { param($given) Test-HarnessLockHeld -Lock $given -Name $gui })
$blockThrew = Test-Throws { Invoke-WithHarnessLocks -Names @($gui) -TimeoutSeconds 5 { throw 'from inside the block' } } '*from inside the block*'
Write-Case 'locks: Invoke-WithHarnessLocks always releases, also when its block throws' $true ($blockThrew -and (Test-HarnessLockFree -FullName $gui))
Write-Case 'locks: Test-HarnessLockFree only takes a full Local\ name: anything else is a usage error before it reaches a command line' $true ((Test-Throws { Test-HarnessLockFree -FullName "Local\a'; exit 0; '" } 'USAGE:*') -and (Test-Throws { Test-HarnessLockFree -FullName 'Global\x' } 'USAGE:*'))
$holder = & $lockChild "if (-not (Enter-HarnessLocks -Names '$gui' -TimeoutSeconds 5 -Quiet)) { exit 2 }; Start-Sleep -Seconds 60"
try {
    $until = (Get-Date).AddSeconds(10)
    while ((Test-HarnessLockFree -FullName $gui) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 200 }
    $none = Enter-HarnessLocks -Names @($freeLock, $gui) -TimeoutSeconds 1 -Quiet
    Write-Case 'locks: one lock of the set busy elsewhere: nothing after the deadline, and the free one is released again (all or nothing)' $true ($null -eq $none -and (Test-HarnessLockFree -FullName $freeLock))
    $ran = @{ Ran = $false }
    Write-Case 'locks: Invoke-WithHarnessLocks with a busy lock throws a timeout and never runs its block' $true ((Test-Throws { Invoke-WithHarnessLocks -Names @($gui) -TimeoutSeconds 1 { $ran.Ran = $true } } '*waited more than*') -and -not $ran.Ran)
} finally { if (-not $holder.HasExited) { Stop-Process -Id $holder.Id -Force } }
$holder.WaitForExit()
$taken = Enter-HarnessLocks -Names @($gui) -TimeoutSeconds 5 -Quiet
Write-Case 'locks: a holder that was killed leaves the lock abandoned, and it is taken over, not stuck' $false ($null -ne $taken)
Exit-HarnessLocks $taken
$limits = [ordered]@{ renderTimeoutSec = 30.0; luaTimeoutSec = 30.0; learnTimeoutSec = 30.0; lockWaitSec = 20.0; lagSearch = 64; headSeconds = 2.0 }
$miniConfig = [pscustomobject]@{ Limits = $limits; Signal = [pscustomobject]@{ Seconds = 1.0 }; Plugins = [ordered]@{}; Layouts = [ordered]@{} }
$newCtx = { param([string[]]$LockSet) New-HarnessContext -ReaperExe 'stand-in' -WorkDir $Work -Driver 'x' -Config $miniConfig -Locks $LockSet }
$ctx = & $newCtx @($gui)
$during = @{}
$sleepIn = New-StandIn 'Start-Sleep -Seconds 60' @{}
$ctx.Launcher = { param($psi) $during.Exit = (& $probeExit); & $sleepIn $psi }.GetNewClosure()
$run = Invoke-HarnessLaunch -Ctx $ctx -HostArgs @{ TimeoutSec = 2 }
Write-Case 'locks: while REAPER runs another process cannot take the GUI lock' $true ($during.Exit -eq 1)
Write-Case 'locks: after the timeout the lock is released and the process is gone' $true ($run.Status -eq 'Timeout' -and (& $probeExit) -eq 0 -and (& $gone $run.Pid))
$ctx.Launcher = { param($psi) throw 'boom' }
Write-Case 'locks: released when the start throws' $true ((Test-Throws { $null = Invoke-HarnessLaunch -Ctx $ctx -HostArgs @{ TimeoutSec = 2 } } 'boom') -and (& $probeExit) -eq 0)
# The licence reminder as a real box: the launch is ended by its PID, its output deleted, and it is started once more
# through the locks (the decisions themselves are pure and run everywhere: Get-TransportCases)
if ([Environment]::UserInteractive) {
    $nagCount = @{ N = 0 }
    $nagLaunch = New-StandIn (New-BoxCommand 'About REAPER v7.82 - evaluation' 'OK' (Join-Path $Work 'box-nag-retry.txt')) @{}
    $quickLaunch = New-StandIn 'exit 0' @{}
    $ctx.Launcher = { param($psi) $nagCount.N++; ($nagCount.N -eq 1) ? (& $nagLaunch $psi) : (& $quickLaunch $psi) }.GetNewClosure()
    $leftOutput = Join-Path $Work 'retry-left.wav'
    Set-Content -LiteralPath $leftOutput -Value 'from the first launch'
    $launchesThen = $ctx.Launches
    $run = Invoke-HarnessLaunch -Ctx $ctx -HostArgs @{ TimeoutSec = 30 } -Label 'nag' -Outputs @($leftOutput)
    Write-Case 'retry: a real licence reminder box ends the launch; its output is deleted and it is started once more through the locks, and exits' $false (
        $run.Status -ceq 'Exited' -and $nagCount.N -eq 2 -and $ctx.Launches -eq $launchesThen + 2 -and @($ctx.Retries).Count -eq 1 -and @($ctx.Retries)[0].Reason -ceq 'license-nag' -and
        -not (Test-Path -LiteralPath $leftOutput) -and -not (Test-Path -LiteralPath (Join-Path $Work 'box-nag-retry.txt')) -and (& $probeExit) -eq 0)
} else { Write-Case '(no interactive desktop: the licence reminder retry with a real box did not run for real)' $false $true }
$negs = @{}
foreach ($n in (Get-HarnessBuiltinNegatives)) { $negs[$n.id] = $n }
$holder = & $lockChild "if (-not (Enter-HarnessLocks -Names '$gui' -TimeoutSeconds 5 -Quiet)) { exit 2 }; Start-Sleep -Seconds 60"
try {
    $until = (Get-Date).AddSeconds(10)
    while ((& $probeExit) -ne 1 -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 200 }
    $ctx.Launcher = New-StandIn 'exit 0' $during
    $during.Called = $false; $ctx.LockWaitSec = 1; $before = $ctx.Launches
    $run = Invoke-HarnessLaunch -Ctx $ctx -HostArgs @{ TimeoutSec = 5 }
    Write-Case 'locks: busy elsewhere, not taken in time: status LockBusy, never run without the lock' $true ($run.Status -eq 'LockBusy' -and -not $during.Called -and $ctx.Launches -eq $before -and (Get-HarnessHostFailure $run) -like 'the GUI locks were not available*')
    # An extra lock of the set that is busy blocks the start just the same (locks can only be added)
    $extraCtx = & $newCtx @($gui.Replace('-gui', '-free'), $gui)
    $extraCtx.LockWaitSec = 1; $extraCtx.Launcher = New-StandIn 'exit 0' $during; $during.Called = $false
    $run = Invoke-HarnessLaunch -Ctx $extraCtx -HostArgs @{ TimeoutSec = 5 }
    Write-Case 'locks: one busy lock of a larger set is enough to block the start (LockBusy), and the free one is released again' $true (
        $run.Status -eq 'LockBusy' -and -not $during.Called -and (Test-HarnessLockFree -FullName $gui.Replace('-gui', '-free')))
    $hangCtx = & $newCtx @($gui)
    $hangCtx.LockWaitSec = 1; $hangCtx.Launcher = New-StandIn 'exit 0' $during; $during.Called = $false
    $hang = Invoke-HarnessScenario -Ctx $hangCtx -Scenario ([pscustomobject]@{ id = 'hang-lockbusy'; kind = 'hang'; timeoutSec = 2; killAfterSec = 0 })
    Write-Case 'hang scenario while the lock is busy: INCOMPLETE naming the lock, not "the scenario threw"; REAPER not started' $true ($hang.Status -eq 'INCOMPLETE' -and $hang.Detail -like '*GUI locks were not available*' -and $hang.Detail -notlike '*threw*' -and -not $during.Called -and $hangCtx.Launches -eq 0)
    $rowTimeout = Invoke-HarnessNegativeRow -Context $hangCtx -Scenario $negs['neg-timeout'] -GuardParams @{} -TempRoot $Work
    $rowKilled = Invoke-HarnessNegativeRow -Context $hangCtx -Scenario $negs['neg-killed'] -GuardParams @{} -TempRoot $Work
    Write-Case 'built-in neg-timeout while the lock is busy: the row is INCOMPLETE (not PASS), says it was not verified, REAPER not started' $true ($rowTimeout.observed -eq 'INCOMPLETE' -and $rowTimeout.status -eq 'INCOMPLETE' -and $rowTimeout.detail -like '*not verified*' -and $hangCtx.Launches -eq 0)
    Write-Case 'built-in neg-killed while the lock is busy: the row is INCOMPLETE (not PASS)' $true ($rowKilled.observed -eq 'INCOMPLETE' -and $rowKilled.status -eq 'INCOMPLETE' -and $rowKilled.detail -like '*not verified*')
    Write-Case 'lock check: a lock held elsewhere is seen as not free from a child process' $true (-not (Test-HarnessLockFree -FullName $gui))
    # A context with other lock names uses them both for the start and for the check afterwards. The start needs the
    # default lock in that set, so the default is switched to one of them for this case: the one that is busy here is not it
    $otherDefault = $gui.Replace('-gui', '-other')
    & $useDefaultLock $otherDefault
    try {
        $injCtx = & $newCtx @($otherDefault)
        $injCtx.LockWaitSec = 5; $injCtx.Launcher = New-StandIn 'Start-Sleep -Seconds 60' @{}
        $quick = [pscustomobject]@{}; foreach ($p in $negs['neg-timeout'].PSObject.Properties) { $quick | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
        $quick.timeoutSec = 2.0
        $rowInj = Invoke-HarnessNegativeRow -Context $injCtx -Scenario $quick -GuardParams @{} -TempRoot $Work
        Write-Case 'watchdog negative: the lock names of the context are used for the start and the check, so a lock outside the set being busy does not matter' $false ($rowInj.status -eq 'PASS' -and $rowInj.detail -like 'timed out after *' -and $injCtx.Launches -eq 1)
    } finally { & $useDefaultLock $gui }
    $noDefaultCtx = & $newCtx @($otherDefault)
    $noDefaultCtx.LockWaitSec = 5; $during.Called = $false; $noDefaultCtx.Launcher = New-StandIn 'exit 0' $during
    Write-Case 'locks: a context whose set does not hold the default lock is refused by the host, whatever it holds; the stand-in is never called' $true ((Test-Throws { $null = Invoke-HarnessLaunch -Ctx $noDefaultCtx -HostArgs @{ TimeoutSec = 5 } } 'REFUSED:*GUI lock*') -and -not $during.Called -and (Test-HarnessLockFree -FullName $otherDefault))
} finally { if (-not $holder.HasExited) { $holder.Kill(); $holder.WaitForExit() } }

# The watchdog negatives triggered for real are PASS: the stand-in sleeps, timeout and kill end it (the built-in cases
# with shorter limits)
$genCtx = & $newCtx @($gui)
$genCtx.Launcher = New-StandIn 'Start-Sleep -Seconds 60' @{}
$copyNeg = { param($id, $field, $value) $c = [pscustomobject]@{}; foreach ($p in $negs[$id].PSObject.Properties) { $c | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }; $c.$field = $value; $c }
$genTimeout = Invoke-HarnessNegativeRow -Context $genCtx -Scenario (& $copyNeg 'neg-timeout' 'timeoutSec' 2.0) -GuardParams @{} -TempRoot $Work
$launchedOnce = $genCtx.Launches
$genKilled = Invoke-HarnessNegativeRow -Context $genCtx -Scenario (& $copyNeg 'neg-killed' 'killAfterSec' 1.5) -GuardParams @{} -TempRoot $Work
Write-Case 'neg-timeout triggered for real (ended at the timeout, process gone, locks free) is PASS' $false ($genTimeout.status -eq 'PASS' -and $genTimeout.observed -eq 'INCOMPLETE' -and $genTimeout.detail -like 'timed out after *' -and $launchedOnce -eq 1)
Write-Case 'neg-killed triggered for real (ended at the kill point) is PASS' $false ($genKilled.status -eq 'PASS' -and $genKilled.observed -eq 'INCOMPLETE' -and $genKilled.detail -like 'killed at the deadline *' -and $genCtx.Launches -eq 2)
$selfExit = & $newCtx @($gui)
$selfExit.Launcher = New-StandIn 'exit 3' @{}
$row = Invoke-HarnessNegativeRow -Context $selfExit -Scenario (& $copyNeg 'neg-timeout' 'timeoutSec' 5.0) -GuardParams @{} -TempRoot $Work
Write-Case 'neg-timeout where REAPER exits by itself (no watchdog involved) is not verified: INCOMPLETE' $true ($row.status -eq 'INCOMPLETE')

# ---- a process the watchdog could not end: the locks stay held and nothing starts next to it ----
# Each stand-in here is ended by this self-test once its case has been judged, and the locks kept for it are released,
# which a real run leaves to the end of its process.
$noStop = { param($id) throw 'access denied' }
$releaseKept = { foreach ($kept in @(& (Get-Module Scenarios) { $script:KeptLocks.ToArray(); $script:KeptLocks.Clear() })) { Exit-HarnessLocks $kept } }
$stuckCtx = & $newCtx @($gui)
$stuckCtx.Launcher = New-StandIn 'Start-Sleep -Seconds 60' @{}
$stuckCtx.Stopper = $noStop
$stuckRun = Invoke-HarnessLaunch -Ctx $stuckCtx -HostArgs @{ TimeoutSec = 30; KillAfterSec = 1 }
try {
    Write-Case 'still running: the launch reports it and the context records the process' $true ($stuckRun.Status -eq 'Killed' -and $stuckRun.StillRunning -eq $true -and -not (& $gone $stuckRun.Pid) -and $stuckCtx.StillRunning.Pid -eq $stuckRun.Pid)
    Write-Case 'still running: the GUI lock stays held after the launch: another process cannot take it' $true ((& $probeExit) -eq 1)
    Write-Case 'still running: the failure says the process could not be ended, not that it was' $true ((Get-HarnessHostFailure $stuckRun) -like 'the watchdog could not end process *' -and (Get-HarnessHostFailure $stuckRun) -notlike '*and was ended*')
    $seenLate = @{ Called = $false }
    $stuckCtx.Launcher = New-StandIn 'exit 0' $seenLate
    $late = Invoke-HarnessLaunch -Ctx $stuckCtx -HostArgs @{ TimeoutSec = 5 }
    Write-Case 'still running: the next launch does not start anything: status Blocked, not counted, with its own text' $true ($late.Status -ceq 'Blocked' -and $late.StillRunning -eq $false -and -not $seenLate.Called -and $stuckCtx.Launches -eq 1 -and (Get-HarnessHostFailure $late) -like 'an earlier REAPER*')
    $lateRender = Invoke-HarnessRender $stuckCtx (Join-Path $Work 'late.rpp') (Join-Path $Work 'late.wav')
    Write-Case 'still running: a render after it has that reason and starts nothing' $true ($lateRender.Why -like 'an earlier REAPER*' -and -not $seenLate.Called)
    $lateHang = Invoke-HarnessScenario -Ctx $stuckCtx -Scenario ([pscustomobject]@{ id = 'hang-blocked'; kind = 'hang'; timeoutSec = 2; killAfterSec = 0 })
    Write-Case 'still running: a hang scenario after it is INCOMPLETE, the watchdog could not be checked' $true ($lateHang.Status -ceq 'INCOMPLETE' -and $lateHang.Detail -like 'an earlier REAPER*could not be checked' -and -not $seenLate.Called)
} finally { & $endStandIn $stuckRun.Pid; & $releaseKept }
Write-Case 'still running: with the kept locks released the lock is free again (what the end of the process does in a real run)' $false ((& $probeExit) -eq 0)
# Watching fails, seen from the launch: ended and the locks free; not ended and the locks kept, like any other process
$brokenCtx = & $newCtx @($gui)
$brokenCtx.Installed = @{ a = [pscustomobject]@{ BinaryLeaf = 'X.vst3' } }
$brokenCtx.Launcher = New-StandIn 'Start-Sleep -Seconds 60' @{}
$brokenCtx.ModuleSampler = { param($p) throw 'the module list broke' }
$brokenRun = Invoke-HarnessLaunch -Ctx $brokenCtx -HostArgs @{ TimeoutSec = 30 }
Write-Case 'watching fails: the launch returns, its process is gone, the lock is free and nothing is noted against the context' $true ($brokenRun.Status -ceq 'Error' -and (& $gone $brokenRun.Pid) -and $null -eq $brokenCtx.StillRunning -and (& $probeExit) -eq 0)
Write-Case 'watching fails: the failure says what broke and that the process was ended' $true ((Get-HarnessHostFailure $brokenRun) -ceq 'watching the process failed and it was ended: the module list broke')
$brokenCtx.Stopper = $noStop
$brokenStuck = Invoke-HarnessLaunch -Ctx $brokenCtx -HostArgs @{ TimeoutSec = 30 }
try { Write-Case 'watching fails and the process cannot be ended: the lock stays held, the context notes it, the next launch is Blocked' $true ($brokenStuck.StillRunning -eq $true -and $brokenCtx.StillRunning.Pid -eq $brokenStuck.Pid -and (& $probeExit) -eq 1 -and (Invoke-HarnessLaunch -Ctx $brokenCtx -HostArgs @{ TimeoutSec = 5 }).Status -ceq 'Blocked') }
finally { & $endStandIn $brokenStuck.Pid; & $releaseKept }
# The hang scenario looks at its own process: a process with that number and another start time is not it. A stand-in that
# says it stopped at once, so no process gets ended here; the number is the one of this self-test, which stays alive.
$fakeProcess = { param($started) $p = [pscustomobject]@{ Id = $PID; HasExited = $false; ExitCode = 0; Started = $started }; Add-Member -InputObject $p -MemberType ScriptMethod -Name get_StartTime -Value { $this.Started }; Add-Member -InputObject $p -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }; $p }
$hangScenario = [pscustomobject]@{ id = 'hang-own'; kind = 'hang'; timeoutSec = 1; killAfterSec = 0 }
$reusedCtx = & $newCtx @($gui)
$reusedStand = & $fakeProcess ([datetime]'2001-01-01')
$reusedCtx.Launcher = { param($psi) $reusedStand }.GetNewClosure()
$reusedCtx.Stopper = { param($id) }
$o = Invoke-HarnessScenario -Ctx $reusedCtx -Scenario $hangScenario
Write-Case 'hang: the number alive with another start time was handed out again: not our process, no FAIL' $true ($o.Status -ceq 'INCOMPLETE' -and $o.Detail -clike '*the process has ended and the GUI locks are free')
$oursCtx = & $newCtx @($gui)
$oursStand = & $fakeProcess (Get-Process -Id $PID).StartTime
$oursCtx.Launcher = { param($psi) $oursStand }.GetNewClosure()
$oursCtx.Stopper = { param($id) }
$o = Invoke-HarnessScenario -Ctx $oursCtx -Scenario $hangScenario
Write-Case 'hang: the same number and the same start time though the launch says it is gone: FAIL' $true ($o.Status -ceq 'FAIL' -and $o.Detail -clike "process $PID is still alive")
# The same launch as the one a watchdog negative case is about
$stuckNeg = & $newCtx @($gui)
$stuckNeg.Launcher = New-StandIn 'Start-Sleep -Seconds 60' @{}
$stuckNeg.Stopper = $noStop
$stuckRow = Invoke-HarnessNegativeRow -Context $stuckNeg -Scenario (& $copyNeg 'neg-killed' 'killAfterSec' 1.0) -GuardParams @{} -TempRoot $Work
try { Write-Case 'still running: built-in neg-killed whose process could not be ended is not verified: the row is INCOMPLETE, never PASS or FAIL' $true ($stuckRow.observed -ceq 'INCOMPLETE' -and $stuckRow.status -ceq 'INCOMPLETE' -and $stuckRow.detail -clike '*does not match*so the case was not verified: the watchdog could not end process *' -and $stuckRow.detail -cnotlike '*not verified: killed at the deadline*') }
finally { & $endStandIn $stuckNeg.StillRunning.Pid; & $releaseKept }

# ---- entry guards ----
# Nothing from here on starts a REAPER. A reaper.exe of another session on this machine has nothing to do with these cases,
# so it must not add a reason or make them SKIPPED; the cases on what such a process does to a run set this command themselves.
$null = Set-SuiteCommand 'Get-HarnessReaperProcessIds' { }
$fixtures = Join-Path $RepoRoot 'tests/fixtures'
$configFile = Join-Path $fixtures 'config.json'
$suite = @{ CfgDir = $CfgA; Config = $configFile; PluginDir = (Join-Path $fixtures 'plugins'); ResultDir = (Join-Path $Work 'results'); ReaperExe = (Join-Path $Work 'no-reaper.exe') }
$marker = Join-Path $Work 'SKIP_MARKER'
Set-Content -LiteralPath $marker -Value x
try {
    $r = Invoke-HarnessSuite @suite -SkipMarker (Join-Path $Work 'not-there'), $marker
    Write-Case 'entry: with a skip marker present the whole suite is SKIPPED with that one reason and REAPER is never started' $true ($r.verdict -eq 'SKIPPED' -and $r.launches -eq 0 -and @($r.skipReasons).Count -eq 1 -and $r.skipReasons[0] -like 'skip marker present*')
} finally { Remove-Item -LiteralPath $marker }
$r = Invoke-HarnessSuite @suite -SkipMarker $marker
Write-Case 'entry: without REAPER the suite is SKIPPED with the reason, not PASS' $true ($r.verdict -eq 'SKIPPED' -and $r.launches -eq 0 -and ($r.skipReasons -match 'reaper.exe not found'))
$r = Invoke-HarnessSuite @suite -PluginDir (Join-Path $Work 'no-plugins')
Write-Case 'entry: a missing plugin directory is SKIPPED with the reason' $true ($r.verdict -eq 'SKIPPED' -and ($r.skipReasons -match 'plugin directory'))
$noSentinel = Join-Path $Work 'no-sentinel'
$null = New-Item -ItemType Directory -Path $noSentinel
Set-Content -LiteralPath (Join-Path $noSentinel 'reaper.ini') -Value '[REAPER]'
$other = $suite.Clone(); $other.CfgDir = $noSentinel
Write-Case 'entry: a configuration directory without sentinel is refused' $true (Test-Throws { $null = Invoke-HarnessSuite @other } 'REFUSED:*sentinel*')
$other = $suite.Clone(); $other.CfgDir = Get-HarnessDefaultCfgDir
Write-Case 'entry: the default resource directory as configuration directory is refused' $true (Test-Throws { $null = Invoke-HarnessSuite @other } 'REFUSED:*never touched*')
Remove-Item -LiteralPath (Join-Path $noSentinel 'reaper.ini'); Remove-Item -LiteralPath $noSentinel
Write-Case 'entry: -Only picking nothing is a usage error' $true (Test-Throws { $null = Invoke-HarnessSuite @suite -Only '^no-such-scenario$' } 'USAGE:*picked no scenario*')
Write-Case 'entry: -Repeat 0 is a usage error' $true (Test-Throws { $null = Invoke-HarnessSuite @suite -Repeat 0 } 'USAGE:*-Repeat*')
Write-Case 'entry: a -BuildLabel outside [0-9A-Za-z._-]{1,40} is a usage error' $true ((Test-Throws { $null = Invoke-HarnessSuite @suite -BuildLabel 'a/b' } 'USAGE:*-BuildLabel*') -and (Test-Throws { $null = Invoke-HarnessSuite @suite -BuildLabel ('x' * 41) } 'USAGE:*-BuildLabel*'))
Write-Case 'entry: an -ExtraGuiLock that is not a full Local\ name is a usage error' $true (Test-Throws { $null = Invoke-HarnessSuite @suite -ExtraGuiLock 'Other-gui' } 'USAGE:*-ExtraGuiLock*')
# Variants of the fixture configuration, written next to the scratch files (so its extension paths do not resolve; its
# state files are copied there, so a variant that gets as far as reading them finds them)
$writeVariant = {
    param([scriptblock]$Change)
    $raw = [IO.File]::ReadAllText($configFile) | ConvertFrom-Json -AsHashtable
    $raw.Remove('$schema')
    & $Change $raw
    $statesCopy = Join-Path $Work 'states'
    if (-not (Test-Path -LiteralPath $statesCopy)) { Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $configFile) 'states') -Destination $statesCopy -Recurse }
    $file = Join-Path $Work 'variant-config.json'
    [IO.File]::WriteAllText($file, ($raw | ConvertTo-Json -Depth 20))
    $v = $suite.Clone(); $v.Config = $file; $v
}
$variant = & $writeVariant { param($c) $c.extensions = @{ modules = @('../FixtureExtension.psm1') } }
Write-Case 'entry: an extension path that leaves the directory of the configuration file is a usage error before anything starts' $true (Test-Throws { $null = Invoke-HarnessSuite @variant } 'USAGE:*leaves the directory*')
$noExt = { param($c) $c.Remove('extensions'); $c.scenarios = @($c.scenarios | Where-Object { $_.kind -ne 'fixture-count' }); $c.negative = @($c.negative | Where-Object { $_.kind -ne 'fixture-count' }) }
$variant = & $writeVariant { param($c) & $noExt $c; $c.surprise = $true }
Write-Case 'entry: a configuration with an unknown key is a usage error' $true (Test-Throws { $null = Invoke-HarnessSuite @variant } "USAGE:*unknown key 'surprise'*")
$variant = & $writeVariant { param($c) & $noExt $c; $c.scenarios += @{ id = 'mystery'; kind = 'fixture-count'; count = 1 } }
Write-Case 'entry: a scenario kind no extension registered is a usage error' $true (Test-Throws { $null = Invoke-HarnessSuite @variant } '*USAGE:*fixture-count*')
$usageResults = Join-Path $Work 'usage-results'
$u = Invoke-Native -Exe $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'run.ps1'), '-Config', $configFile, '-CfgDir', $CfgA, '-PluginDir', $suite.PluginDir,
    '-ResultDir', $usageResults, '-Only', '^no-such-scenario$')
Write-Case 'entry script: -Only picking nothing exits 64 and writes no result file' $true ($u.Exit -eq 64 -and $u.Out -match 'USAGE:' -and -not (Test-Path -LiteralPath $usageResults))
$u = Invoke-Native -Exe $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'run.ps1'), '-Config', $configFile, '-CfgDir', $CfgA, '-PluginDir', $suite.PluginDir,
    '-ResultDir', $usageResults, '-ReaperExe', (Join-Path $Work 'no-reaper.exe'))
$written = @(Get-ChildItem -LiteralPath $usageResults -Filter '*.json' -ErrorAction SilentlyContinue)
Write-Case 'entry script: SKIPPED exits 3 and writes a result file named <time>-<config>-<label>.json' $false ($u.Exit -eq 3 -and $written.Count -eq 1 -and $written[0].Name -cmatch '^\d{8}-\d{6}-fixture-[0-9a-f]{12}-[0-9a-f]{12}\.json$')
$u = Invoke-Native -Exe $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'doctor.ps1'), '-CfgDir', $CfgA, '-Config', $configFile, '-PluginDir', $suite.PluginDir, '-ReaperExe', (Join-Path $Work 'no-reaper.exe'))
Write-Case 'doctor: the same preflight as run.ps1; something missing exits 3' $true ($u.Exit -eq 3 -and $u.Out -match 'reaper.exe not found')
$u = Invoke-Native -Exe $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'run.ps1'), '-Config', $configFile, '-CfgDir', $CfgA, '-PluginDir', $suite.PluginDir,
    '-ResultDir', $usageResults, '-ReaperExe', (Join-Path $Work 'no-reaper.exe'))
Write-Case 'entry script: the console names the result file, not the directory it is in' $true ($u.Exit -eq 3 -and $u.Out -cmatch 'result \d{8}-\d{6}-fixture-' -and $u.Out -cnotlike "*$usageResults*")
# A result directory that cannot exist: the run has no conclusion, which is not a FAIL
$notADir = Join-Path $Work 'result is a file'
Set-Content -LiteralPath $notADir -Value x
$u = Invoke-Native -Exe $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'run.ps1'), '-Config', $configFile, '-CfgDir', $CfgA, '-PluginDir', $suite.PluginDir,
    '-ResultDir', $notADir, '-ReaperExe', (Join-Path $Work 'no-reaper.exe'))
Write-Case 'entry script: no result file: a SKIPPED run is no conclusion: exit 2, it says so, and the console shows no path' $true ($u.Exit -eq 2 -and $u.Out -clike '*INCOMPLETE: the run ended SKIPPED but its result file could not be written: *' -and $u.Out -cnotlike "*$Work*" -and $u.Out -cnotlike '*is a file*')
# The verdict stands without its file: a FAIL stays a FAIL, anything else has no record and so no conclusion
$finish = {
    param($verdict, $dir)
    $lines = @(Complete-HarnessRun -Outcome ([pscustomobject]@{ verdict = $verdict; config = 'c'; buildLabel = 'b'; runs = @(); launches = 0; skipReasons = @() }) -ResultDir $dir 6>&1)
    [pscustomobject]@{ Exit = $lines[-1]; Text = (@($lines | Select-Object -SkipLast 1) -join "`n") }
}
$done = & $finish 'FAIL' $notADir
Write-Case 'no result file: a FAIL stays a FAIL: exit 1, it says so, and the console shows no path' $true ($done.Exit -eq 1 -and $done.Text -clike 'FAIL: the run ended FAIL but its result file could not be written: *' -and $done.Text -cnotlike "*$Work*" -and $done.Text -cnotlike '*is a file*')
$done = & $finish 'PASS' $notADir
Write-Case 'no result file: a PASS nobody can look up is no conclusion: exit 2' $true ($done.Exit -eq 2 -and $done.Text -clike 'INCOMPLETE: the run ended PASS but its result file could not be written: *')
$done = & $finish 'INCOMPLETE' $notADir
Write-Case 'no result file: an INCOMPLETE stays one: exit 2' $true ($done.Exit -eq 2 -and $done.Text -clike 'INCOMPLETE: the run ended INCOMPLETE but *')
$finishDir = Join-Path $Work 'finish'
$done = & $finish 'FAIL' $finishDir
$written = @(Get-ChildItem -LiteralPath $finishDir -Filter '*.json' -ErrorAction SilentlyContinue)
Write-Case 'result file written: the verdict decides the exit code, the file is named on the console' $true ($done.Exit -eq 1 -and $written.Count -eq 1 -and $done.Text -clike "reaper-harness FAIL  config c  build b  0 rounds  REAPER started 0 times  result $($written[0].Name)")
Write-Case 'result file written: a PASS exits 0' $true ((& $finish 'PASS' $finishDir).Exit -eq 0)
# The result directory is written during a run: never the default resource directory
$inDefault = Join-Path (Get-HarnessDefaultCfgDir) 'results-here'
$u = Invoke-Native -Exe $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'run.ps1'), '-Config', $configFile, '-CfgDir', $CfgA, '-PluginDir', $suite.PluginDir,
    '-ResultDir', $inDefault, '-ReaperExe', (Join-Path $Work 'no-reaper.exe'))
Write-Case 'entry script: a -ResultDir in the default resource directory exits 64 and creates nothing' $true ($u.Exit -eq 64 -and $u.Out -clike 'REFUSED:*-ResultDir*' -and -not (Test-Path -LiteralPath $inDefault))
# A usage error that repeats a path out of the configuration
$pathInConfig = & $writeVariant { param($c) $c.extensions = @{ modules = @('D:\my files\x.psm1'); lua = @() } }
$u = Invoke-Native -Exe $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'run.ps1'), '-Config', $pathInConfig.Config, '-CfgDir', $CfgA, '-PluginDir', $suite.PluginDir, '-ResultDir', $usageResults)
Write-Case 'entry script: a usage error exits 64 and the console shows no path' $true ($u.Exit -eq 64 -and $u.Out -clike "USAGE: extension path '<path>' must be relative*" -and $u.Out -cnotlike '*my files*')
$u = Invoke-Native -Exe $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'doctor.ps1'), '-Config', $pathInConfig.Config)
Write-Case 'doctor: a usage error exits 64 and the console shows no path' $true ($u.Exit -eq 64 -and $u.Out -clike "USAGE: extension path '<path>' must be relative*" -and $u.Out -cnotlike '*my files*')
# A parameter listing asked for wrongly through run.ps1: 64 before anything starts, so no result file and no work directory
# (each in a result directory of its own, so one that wrongly runs does not turn the next red)
$listArgs = { param([string]$ListResults) @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'run.ps1'), '-Config', $configFile, '-CfgDir', $CfgA, '-PluginDir', $suite.PluginDir, '-ResultDir', $ListResults, '-ReaperExe', (Join-Path $Work 'no-reaper.exe')) }
$listCase = 0
$listNames = Join-Path $Work 'list-names.txt'
[IO.File]::WriteAllText($listNames, "Gain`n")
$listWrong = [ordered]@{
    '-List foo'                                          = @('-List', 'foo')
    '-ListValues x'                                      = @('-List', 'params', '-ListPlugin', 'gain', '-ListParam', 'Gain', '-ListValues', 'x')
    '-ListParam with two plugins'                        = @('-List', 'params', '-ListPlugin', 'gain,bus', '-ListParam', 'Gain')
    '-ListParam with -ListParamFile'                     = @('-List', 'params', '-ListPlugin', 'gain', '-ListParam', 'Gain', '-ListParamFile', $listNames)
    '-ListPlugin without -List'                          = @('-ListPlugin', 'gain')
    '-Only with -List'                                   = @('-List', 'params', '-Only', 'x')
    '-Repeat 1 with -List'                               = @('-List', 'params', '-Repeat', '1')
    '-ListPlugin naming a plugin the configuration lacks' = @('-List', 'params', '-ListPlugin', 'nope')
}
foreach ($wrong in $listWrong.GetEnumerator()) {
    $listCase++
    $listUsage = Join-Path $Work "list-usage-$listCase"
    $u = Invoke-Native -Exe $pwshExe -Arguments ((& $listArgs $listUsage) + $wrong.Value)
    Write-Case "entry script: $($wrong.Key) exits 64 with USAGE, no result file and no work directory" $true ($u.Exit -eq 64 -and $u.Out -clike 'USAGE: *' -and -not (Test-Path -LiteralPath $listUsage))
}
$listUsage = Join-Path $Work 'list-usage-sweep'
$u = Invoke-Native -Exe $pwshExe -Arguments ((& $listArgs $listUsage) + @('-List', 'params', '-ListPlugin', 'gain', '-ListParam', 'Gain', '-ListValues', '0,0.5,1'))
$written = @(Get-ChildItem -LiteralPath $listUsage -Filter '*.json' -ErrorAction SilentlyContinue)
$skippedListing = try { (ConvertFrom-HarnessJson ([IO.File]::ReadAllText($written[0].FullName)))['listing'] } catch { $null }
Write-Case "entry script: -List params with a sweep given as run.ps1 options gets as far as the preflight: SKIPPED without reaper.exe, a result file named -list-params.json with an empty listing" $false (
    $u.Exit -eq 3 -and $written.Count -eq 1 -and $written[0].Name -cmatch '^\d{8}-\d{6}-fixture-[0-9a-f]{12}-list-params\.json$' -and
    $null -ne $skippedListing -and $skippedListing['kind'] -ceq 'params' -and ($skippedListing['values'] -join ',') -ceq '0,0.5,1' -and @($skippedListing['plugins']).Count -eq 0)
# A plugin binary somebody holds open: its hash cannot be read, in the preflight, before any result exists
$lockedBinary = @(Get-ChildItem -LiteralPath $suite.PluginDir -Recurse -File | Where-Object { $_.Extension -ceq '.vst3' })[0].FullName
$holder = [IO.File]::Open($lockedBinary, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
try {
    $u = Invoke-Native -Exe $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'doctor.ps1'), '-CfgDir', $CfgA, '-Config', $configFile, '-PluginDir', $suite.PluginDir, '-ReaperExe', $pwshExe)
    Write-Case 'doctor: an unexpected error exits 2, says so, and the console shows no path' $true ($u.Exit -eq 2 -and $u.Out -clike '*the check stopped on an unexpected error*' -and $u.Out -cnotlike "*$RepoRoot*" -and $u.Out -cnotlike '*Fixture*vst3*Contents*')
    $u = Invoke-Native -Exe $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'run.ps1'), '-Config', $configFile, '-CfgDir', $CfgA, '-PluginDir', $suite.PluginDir, '-ResultDir', $usageResults, '-ReaperExe', $pwshExe)
    Write-Case 'entry script: an unexpected error in the preflight exits 2 too' $true ($u.Exit -eq 2 -and $u.Out -clike 'INCOMPLETE: the run stopped on an unexpected error*' -and $u.Out -cnotlike "*$RepoRoot*")
} finally { $holder.Dispose() }
# The guard negative case neg-skip-marker uses its own new marker, whether or not the caller's parameters already carry one
$withKey = $suite.Clone(); $withKey.SkipMarker = @(Join-Path $Work 'caller-marker-that-is-not-there')
$guardRun = { param($callerParams) try { $g = Invoke-HarnessGuardNegative -Params $callerParams -Guard 'skip-marker' -TempRoot $Work -FirstScenario 'chain-offline-44100'; $g.Observed -ceq 'SKIPPED' -and $g.Detail -cmatch $negs['neg-skip-marker'].expectDetail } catch { $false } }
Write-Case 'guard negative neg-skip-marker: without a marker in the caller parameters it still uses its own new marker: SKIPPED, REAPER never started' $true (& $guardRun $suite)
Write-Case 'guard negative neg-skip-marker: with another (absent) marker already in the caller parameters it still uses its own' $true (& $guardRun $withKey)
$g = Invoke-HarnessGuardNegative -Params $suite -Guard 'sentinel-missing' -TempRoot $Work -FirstScenario 'x'
Write-Case 'guard negative neg-sentinel-missing: refused for the sentinel, and its reason matches the built-in expectDetail' $true ($g.Observed -ceq 'REFUSED' -and $g.Detail -cmatch $negs['neg-sentinel-missing'].expectDetail)
$g = Invoke-HarnessGuardNegative -Params $suite -Guard 'default-dir' -TempRoot $Work -FirstScenario 'x'
Write-Case 'guard negative neg-default-dir: refused as the default resource directory, and its reason matches the built-in expectDetail' $true ($g.Observed -ceq 'REFUSED' -and $g.Detail -cmatch $negs['neg-default-dir'].expectDetail)

# ---- plugin install, plugin path, scan shield ----
$conf = Read-HarnessConfig -Path $configFile -Kinds (Import-HarnessExtensions (Read-HarnessConfigExtensions $configFile)).Kinds
$rows = Install-HarnessPlugins -Plugins $conf.Plugins -PluginDir $suite.PluginDir
$srcSha = Get-HarnessSha256 (Join-Path $suite.PluginDir 'Fixture Gain.vst3\Contents\x86_64-win\Fixture Gain.vst3')
Write-Case 'install: each bundle is copied into the private plugins directory; the row has the private binary and its sha256' $false (
    $rows.Count -eq 2 -and $rows[0].Private -like "$($pinned.Dir)\plugins\*" -and (Test-Path -LiteralPath $rows[0].Binary) -and $rows[0].Sha256 -ceq $srcSha -and $rows[0].Info.Cid -ceq '5A1B2C3D4E5F60718293A4B5C6D7E8F9')
Set-Content -LiteralPath (Join-Path $rows[0].Private 'stale.txt') -Value x
$rows = Install-HarnessPlugins -Plugins $conf.Plugins -PluginDir $suite.PluginDir
Write-Case 'install: an older private copy is replaced as a whole (nothing of it is left)' $false (-not (Test-Path -LiteralPath (Join-Path $rows[0].Private 'stale.txt')))
$mine = Join-Path $Work 'mine'
$null = Set-HarnessIniValue -Section REAPER -Key vstpath64 -Value "$mine;%COMMONPROGRAMFILES%\VST3\"
$null = Set-HarnessPluginPath
$vst = [regex]::Match([IO.File]::ReadAllText($pinned.Ini), '(?m)^vstpath64=(.*)$').Groups[1].Value
Write-Case 'plugin path: the private plugins directory is written last, after the system VST3 directories; other entries are kept as written' $false ($vst -ceq "$mine;%COMMONPROGRAMFILES%\VST3\;%LOCALAPPDATA%\Programs\Common\VST3;$($pinned.Dir)\plugins")
Write-Case 'plugin path: writing it again changes nothing' $false (-not (Set-HarnessPluginPath))
$sys = Join-Path $env:COMMONPROGRAMFILES 'VST3'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $sys 'Vendor X\Other Synth.vst3\Contents\x86_64-win'), (Join-Path $sys 'Fixture Gain.vst3\Contents\x86_64-win'), (Join-Path $sys 'No Windows.vst3\Contents\Resources')
Set-Content -LiteralPath (Join-Path $sys 'Vendor X\Other Synth.vst3\Contents\x86_64-win\Other Synth.vst3') -Value x
Set-Content -LiteralPath (Join-Path $sys 'Fixture Gain.vst3\Contents\x86_64-win\Fixture Gain.vst3') -Value 'a release build of the same name'
Set-Content -LiteralPath (Join-Path $sys 'old-plugin.dll') -Value x
$cache = Join-Path $pinned.Dir 'reaper-vstplugins64.ini'
[IO.File]::WriteAllText($cache, "[vstcache]`r`nFixture_Gain.vst3=00112233445566778899,{5A1B},Fixture Gain`r`nFixture_Bus.vst3=0011223344556677`r`nkept_by_me.dll=0001020304050607`r`n[xvst3_compat]`r`nx=1`r`n")
$shield = Update-HarnessScanCache -Keep @($rows | ForEach-Object { $_.Bundle })
$text = [IO.File]::ReadAllText($cache)
Write-Case 'shield: system files without a current entry get an empty one; the configured bundles lose theirs (even when a system file shares the name)' $false (
    $shield.Added -eq 2 -and $shield.Removed -eq 2 -and $text -cmatch '(?m)^Other_Synth\.vst3=[0-9A-F]{16}\r?$' -and $text -cmatch '(?m)^old_plugin\.dll=[0-9A-F]{16}\r?$' -and
    $text -notmatch 'Fixture_Gain|Fixture_Bus' -and $text -cmatch 'kept_by_me\.dll=0001020304050607' -and $text -cmatch '\[xvst3_compat\]\r\nx=1' -and $text -notmatch 'No_Windows')
$again = Update-HarnessScanCache -Keep @($rows | ForEach-Object { $_.Bundle })
Write-Case 'shield: a second pass changes nothing' $false ($again.Added -eq 0 -and $again.Replaced -eq 0 -and $again.Removed -eq 0 -and [IO.File]::ReadAllText($cache) -ceq $text)

# ---- one whole suite run against the stand-in REAPER ----
$plugins = @{}
foreach ($row in $rows) { $plugins["VST3: $($row.Info.Name) ($($row.Info.Vendor))"] = @{ Bundle = $row.Bundle; Cid = $row.Info.Cid } }
$seenArgs = [Collections.Generic.List[string]]::new()
Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs }
$hooks = @{ Launcher = (Get-FakeReaperLauncher); ModuleSampler = (Get-FakeModuleSampler) }
$e2e = $suite.Clone(); $e2e.ReaperExe = $pwshExe; $e2e.ResultDir = Join-Path $Work 'e2e'
$r = Invoke-WithSuiteCommand 'Get-HarnessReaperProcessIds' { 4242 } { Invoke-HarnessSuite @e2e -SelfTestHooks $hooks }
Write-Case 'entry: a reaper.exe already running makes the whole suite SKIPPED with that reason, REAPER never started' $true ($r.verdict -ceq 'SKIPPED' -and $r.launches -eq 0 -and $seenArgs.Count -eq 0 -and @($r.skipReasons -match '^a reaper\.exe not started by this tool').Count -eq 1)

# A directory initialised before the version check was turned off has no verchk key: the launches write it
[IO.File]::WriteAllText($pinned.Ini, ([IO.File]::ReadAllText($pinned.Ini) -replace '(?m)^verchk=.*\r?\n', ''))
$verchkBefore = Get-HarnessIniValue -Section REAPER -Key verchk
$r = Invoke-HarnessSuite @e2e -SelfTestHooks $hooks
$rowsOut = @($r.runs[0].scenarios)
$notPass = @($rowsOut | Where-Object { $_.status -ne 'PASS' } | ForEach-Object { "$($_.id)=$($_.status): $($_.detail)" })
Write-Case "end to end: every row of the fixture configuration passes against the stand-in ($($notPass -join ' | '))" $false ($r.verdict -eq 'PASS' -and $notPass.Count -eq 0 -and $rowsOut.Count -eq 37)
Write-Case 'end to end: learn ran once, first, and proved the private copy; the module check over all launches passed' $false (
    $rowsOut[0].id -eq 'learn' -and $rowsOut[0].status -eq 'PASS' -and $rowsOut[0].facts.modules -eq 'Proven' -and $r.runs[0].moduleCheck.status -eq 'PASS' -and @($seenArgs | Where-Object { $_ -notmatch 'renderproject' }).Count -ge 5)
Write-Case 'end to end: every launch is counted and the default resource directory is unchanged' $false ($r.launches -eq $seenArgs.Count -and $r.runs[0].launches -eq $seenArgs.Count -and $r.runs[0].defaultCfgDir.unchanged -and $r.runs[0].reaperProcessesLeft -eq 0 -and $r.runs[0].stillRunning -eq $false)
# Every path went through the host as one argument, in a work directory with a space and an apostrophe in its name
$rendered = @($seenArgs | Where-Object { $_ -match '-renderproject' }).Count
Write-Case 'end to end: projects and the Lua driver reached the stand-in without quotes of their own' $false ($rendered -gt 0 -and @($seenArgs | Where-Object { $_.Contains('"') }).Count -eq 0)
$byId = @{}
foreach ($row in $rowsOut) { $byId[$row.id] = $row }
Write-Case 'end to end: both named states are learned from their blocks and listed with their hashes (result and learn row)' $false (
    @($r.states).Count -eq 2 -and (@($r.states | ForEach-Object { "$($_.plugin)@$($_.state)" }) -join ',') -ceq 'gain@quiet,gain@loud' -and @($r.states | Where-Object { $_.sha256 -cnotmatch '^[0-9a-f]{12}$' }).Count -eq 0 -and
    @($rowsOut[0].facts.states).Count -eq 2)
Write-Case 'end to end: device and savereopen (3 cycles) prove what each instance holds: the blocks saved back are the states it was given' $false (
    $byId['states-device'].detail -cmatch 'states saved back unchanged: gain quiet [0-9a-f]{12}, gain loud [0-9a-f]{12}$' -and
    $byId['states-reopen'].detail -cmatch '^FX state unchanged after 3 save and reopen cycles \(0 parameters\); states saved back unchanged: gain quiet [0-9a-f]{12}, gain loud [0-9a-f]{12};')
Write-Case 'end to end: two instances of one plugin with different states render differently (stems -6 and +6 dB against the dry tracks)' $false (
    $byId['states'].detail -cmatch '\| stem Quiet: identical=no lag=0 [^|]* rms=\S+/\S+ \| stem Loud: ' -and $byId['states'].detail -cmatch '\| stem Loud: identical=no lag=0 ')
Write-Case 'end to end: the routing render judges the master and each stem; the muted track is silent, the cue track off the master still has its stem' $false (
    $byId['routing'].detail -cmatch '^identical=no lag=0 ' -and $byId['routing'].detail -cmatch '\| stem Drums: identical=yes lag=0 ' -and $byId['routing'].detail -cmatch '\| stem Keys: frames=\d+ channels=2 .* rms=-inf,-inf( |$)' -and
    $byId['routing'].detail -cmatch '\| stem Cue: identical=yes ' -and $byId['routing-alone'].detail -cmatch '^frames=\d+ channels=2 rate=48000 format=float32 nonfinite=0 peak=\S+ rms=\S+ \| stem Cue: frames=')
Write-Case 'end to end: the JSFX is installed in the private Effects directory, listed with the plugins, and its delay is reported as PDC at block 2048 with anticipative FX off' $false (
    (Test-Path -LiteralPath (Join-Path $pinned.Dir 'Effects\reaper-harness\harness-pdc-delay.jsfx')) -and @($r.plugins | Where-Object { $_['name'] -ceq 'JS: reaper-harness PDC delay' -and $_['jsfx'] -ceq 'harness-pdc-delay' }).Count -eq 1 -and
    $byId['pdc-device'].detail -like 'block 2048 and rate 48000 read back, anticipative FX off; 2 FX report the configured latency*' -and $byId['pdc-unreported'].detail -cmatch '^identical=no lag=16 ')
Write-Case 'end to end: anticipative FX is written as bit 0 of workrender in the private ini and read back by the device step' $false (
    (Get-HarnessIniValue -Section REAPER -Key workrender) -in '16', '17' -and $byId['bus-device'].detail -like '*anticipative FX on;*')
Write-Case "end to end: the launches turn REAPER's version check off in the private ini, also in a directory initialised without it" $false (
    $null -eq $verchkBefore -and (Get-HarnessIniValue -Section REAPER -Key verchk) -ceq '0')
$msRow = $byId['monitor-states']
Write-Case 'end to end: the transport row reports every state as the stand-in measured it; the state without expectations is only recorded' $false (
    $msRow.detail -ceq ('stopped-unarmed: blocks=10/10 silent=10 signal=0 left=0 right=0 same=0 transport=stop monitoring=0 | ' +
        'stopped-armed-on: blocks=10/10 silent=0 signal=10 left=10 right=10 same=0 transport=stop monitoring=1 | ' +
        'playing-auto: blocks=10/10 silent=10 signal=0 left=0 right=0 same=0 transport=play monitoring=0 | ' +
        'paused-unarmed: blocks=0/10 silent=0 signal=0 left=0 right=0 same=0 transport=pause monitoring=0') -and
    @($msRow.facts.states).Count -eq 4 -and $msRow.facts.states[3].status -ceq 'recorded' -and $msRow.facts.states[1].status -ceq 'PASS' -and $msRow.facts.runFxWhenStopped -eq $true -and
    $msRow.facts.feed.source -ceq 'test signal' -and $msRow.facts.feed.channels -ceq 'different' -and $msRow.facts.settleSamples -eq 240000)
$offRows = @($rowsOut | Where-Object { $_.id -like 'monitor-stopped-off-*' })
Write-Case "end to end: with Run FX when stopped off the unarmed chain is not called, at each block size of the matrix ($(@($offRows | ForEach-Object { $_.id }) -join ', '))" $false (
    $offRows.Count -eq 2 -and @($offRows | Where-Object { $_.detail -cnotmatch '^unarmed: blocks=0/(75|5) [^|]* \| armed-on: blocks=(75|5)/(75|5) silent=0 signal=(75|5) left=(75|5) right=0 same=0 ' }).Count -eq 0 -and
    @($offRows | Where-Object { $_.facts.runFxWhenStopped -ne $false }).Count -eq 0)
Write-Case 'end to end: the built-in transport negative turned red for its reason, and so did the configured one' $false (
    $byId['neg-transport-probe'].observed -ceq 'FAIL' -and $byId['neg-transport-probe'].status -ceq 'PASS' -and $byId['neg-feed-is-not-same'].observed -ceq 'FAIL' -and $byId['neg-feed-is-not-same'].status -ceq 'PASS')
Write-Case 'end to end: the probe and the feed JSFX are installed in the private Effects directory and the feed file in its Data directory; they are tools, not listed with the plugins' $false (
    (Test-Path -LiteralPath (Join-Path $pinned.Dir 'Effects\reaper-harness\harness-block-probe.jsfx')) -and (Test-Path -LiteralPath (Join-Path $pinned.Dir 'Effects\reaper-harness\harness-feed.jsfx')) -and
    (Test-Path -LiteralPath (Join-Path $pinned.Dir 'Data\reaper-harness\feed.wav')) -and @($r.plugins | Where-Object { $_['jsfx'] -in 'harness-block-probe', 'harness-feed' }).Count -eq 0)
Write-Case 'end to end: renders judged by a number or bit for bit, stems included, carry no comparison and, without a tail, no tail; no line says reported' $false (
    @('routing', 'states', 'chain-repeat', 'bus' | Where-Object { $byId[$_].Contains('facts') -and $byId[$_]['facts'] -is [System.Collections.IDictionary] -and ($byId[$_]['facts'].Contains('comparison') -or $byId[$_]['facts'].Contains('tail')) }).Count -eq 0 -and
    @($rowsOut | Where-Object { $_.detail -clike '*; reported: *' }).Count -eq 0)
$path = Write-HarnessResult -Data $r -ResultDir $e2e.ResultDir
$json = [IO.File]::ReadAllText($path)
$back = ConvertFrom-HarnessJson $json
Write-Case 'result file: valid JSON with schema 1, the plugin hashes (12 hex digits) and no local path' $false (
    $back['schema'] -eq 1 -and $back['plugins'][0]['sha256'] -cmatch '^[0-9a-f]{12}$' -and $json -notmatch '[A-Za-z]:\\\\' -and (Split-Path -Leaf $path) -cmatch "-fixture-$($back['buildLabel'])\.json$")
Write-Case 'end to end: the work files of an all-green round are removed' $false (-not (Test-Path -LiteralPath (Join-Path $e2e.ResultDir 'work')) -or @(Get-ChildItem -LiteralPath (Join-Path $e2e.ResultDir 'work') -Recurse -File).Count -eq 0)
$extRow = @($rowsOut | Where-Object { $_.id -ceq 'ext-count' })[0]
Write-Case 'end to end: a local path in the facts of an extension is masked in the row and in the result file' $true ($extRow.facts.count -eq 3 -and $extRow.facts.workDir -ceq '<path>' -and $json -cnotlike '*brien*')
Write-Case 'result file: a run with nothing wrong has no error' $false ($back.Contains('error') -and $null -eq $back['error'] -and $null -eq $r.error)
Write-Case 'result file: a run that lists nothing has a listing of null' $false ($back.Contains('listing') -and $null -eq $back['listing'] -and $null -eq $r.listing)
Write-Case 'result file: each run lists the launches retried after the licence reminder (none here)' $false ($back['runs'][0].Contains('retries') -and @($back['runs'][0]['retries']).Count -eq 0)
# Only a JSFX, no plugin binary: learning does not ask the module list, which would have nothing to prove, and says so
$jsOnly = & $writeVariant { param($c) & $noExt $c; $c.plugins = @{ delay = $c.plugins['delay'] }; $c.layouts = @{ js = @{ tracks = @(@{ name = 'Voice'; source = $true; fx = @(@{ plugin = 'delay' }) }) } }; $c.scenarios = @(@{ id = 'js-only'; kind = 'render'; layout = 'js' }); $c.negative = @() }
$jsOnly.ReaperExe = $pwshExe; $jsOnly.ResultDir = $e2e.ResultDir
$r = Invoke-HarnessSuite @jsOnly -NoNegative -SelfTestHooks $hooks
$jsLearn = @($r.runs[0].scenarios)[0]
Write-Case 'end to end: a configuration of only a JSFX learns without a module proof: learn PASS, its facts say there was no plugin binary, the round PASS' $false (
    $r.verdict -ceq 'PASS' -and $jsLearn.id -ceq 'learn' -and $jsLearn.status -ceq 'PASS' -and $jsLearn.facts.modules -ceq 'NoBinary' -and $jsLearn.facts.binaries.get_Count() -eq 0 -and
    $jsLearn.detail -clike '*no plugin binary to check (only JSFX)*' -and $r.runs[0].moduleCheck.status -ceq 'PASS' -and $r.runs[0].moduleCheck.detail -clike 'no plugin binary to check*' -and @($r.plugins).Count -eq 1)

# ---- parameter variants, learning in batches, a latency that is only reported ----
# A scenario of four variants (the dry one, as written, a parameter changed, a state with a parameter on top), a compare
# variant of the dry one, and device, savereopen, transport and a kept render of a JSFX whose latency is only reported.
# Two variants a launch: the defaults in learn.1, then vary-dry (its gain and the delay), vary-g025 and vary-loud.
$gainG025 = 0.25
$trimLoud = @{ normalized = 0.75; display = '0.75' }
$varyChange = {
    param($c)
    & $noExt $c
    $c.limits.learnBatchSize = 2
    $c.limits.learnTimeoutSec = 45 # not luaTimeoutSec: each learn launch gets this one
    $c.plugins.delay.expectPdc = 'report'
    $c.layouts = [ordered]@{
        vary = [ordered]@{ tracks = @([ordered]@{ name = 'Voice'; source = $true; fx = @([ordered]@{ plugin = 'gain'; params = @{ Gain = 0.5 } }, [ordered]@{ plugin = 'delay' }) }) }
        p    = [ordered]@{ tracks = @([ordered]@{ name = 'Voice'; source = $true; fx = @([ordered]@{ plugin = 'delay' }) }) }
    }
    $c.scenarios = @(
        [ordered]@{ id = 'vary'; kind = 'render'; layout = 'vary'; compare = 'none'; keep = $true; variants = @(
                [ordered]@{ id = 'dry'; bypass = $true }, [ordered]@{ id = 'as-written' }, [ordered]@{ id = 'g025'; fx = @{ gain = @{ params = @{ Gain = $gainG025 } } } },
                [ordered]@{ id = 'loud'; fx = @{ gain = @{ state = 'loud'; params = @{ Trim = $trimLoud } } } }) },
        [ordered]@{ id = 'vary-cmp'; kind = 'render'; layout = 'vary'; compare = @{ block = 256 }; variants = @([ordered]@{ id = 'dry'; bypass = $true }, [ordered]@{ id = 'g025'; fx = @{ gain = @{ params = @{ Gain = $gainG025 } } } }) },
        [ordered]@{ id = 'p-device'; kind = 'device'; layout = 'p'; block = 2048; host = @{ anticipativeFx = $false } },
        [ordered]@{ id = 'p-reopen'; kind = 'savereopen'; layout = 'p' },
        [ordered]@{ id = 'p-transport'; kind = 'transport'; layout = 'p'; states = @([ordered]@{ name = 'on'; transport = 'stop'; arm = $true; monitor = 'on'; samples = 4800; expect = @{ called = $true } }) },
        [ordered]@{ id = 'p-kept'; kind = 'render'; layout = 'p'; compare = 'none'; keep = $true })
    $c.negative = @()
}
$varyCfg = & $writeVariant $varyChange
$varyCfg.ReaperExe = $pwshExe; $varyCfg.ResultDir = Join-Path $Work 'e2e-vary'
$rowOf = { param($Res, [string]$RowId) @($Res.runs[0].scenarios | Where-Object { $_.id -ceq $RowId })[0] }
$rowIds = { param($Res) @($Res.runs[0].scenarios | ForEach-Object { $_.id }) -join ',' }
$factOf = { param($OfRow, [string]$Name) ($OfRow -is [System.Collections.IDictionary] -and $OfRow.Contains('facts') -and $OfRow['facts'] -is [System.Collections.IDictionary] -and $OfRow['facts'].Contains($Name)) ? $OfRow['facts'][$Name] : $null }
# Every launch through the one launch path, its label recorded
$launchLabels = [Collections.Generic.List[string]]::new()
$learnSettings = [Collections.Generic.List[string]]::new() # per learn launch: label, timeout, rate/block of the private ini as it starts
$realLaunch = & (Get-Module Scenarios) { (Get-Item function:Invoke-HarnessLaunch).ScriptBlock }
$labelLaunch = {
    $labelAt = [array]::IndexOf($args, '-Label')
    $launchLabel = ($labelAt -ge 0) ? [string]$args[$labelAt + 1] : ''
    $launchLabels.Add($launchLabel)
    if ($launchLabel -clike 'learn*') {
        $hostAt = [array]::IndexOf($args, '-HostArgs')
        $learnSettings.Add("$launchLabel $($args[$hostAt + 1].TimeoutSec) s $(Get-HarnessIniValue -Section audioconfig -Key dummy_srate)/$(Get-HarnessIniValue -Section audioconfig -Key dummy_blocksize)")
    }
    & $realLaunch @args
}.GetNewClosure()
$null = & (Get-Module Scenarios) { param($s) Set-Item function:script:Invoke-HarnessLaunch $s } $labelLaunch
# The module list of a learn launch shows only the binaries of the plugins it added: each batch proves its own
Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; OwnModules = $true }
Set-HarnessAudioConfig -Sr 44100 -Block 1024
try { $r = Invoke-HarnessSuite @varyCfg -NoNegative -KeepWork -SelfTestHooks $hooks }
finally {
    $null = & (Get-Module Scenarios) { param($s) Set-Item function:script:Invoke-HarnessLaunch $s } $realLaunch
    Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs }
}
$varyRows = @($r.runs[0].scenarios)
$varyNotPass = @($varyRows | Where-Object { $_.status -cne 'PASS' } | ForEach-Object { "$($_.id)=$($_.status): $($_.detail)" })
$learnLabels = @($launchLabels | Where-Object { $_ -clike 'learn*' })
Write-Case "end to end: variants: one learn row a batch, learn.1 to learn.4, each PASS and one launch labelled as its row; every variant a row of its own, PASS ($(& $rowIds $r); $($varyNotPass -join ' | '))" $false (
    $r.verdict -ceq 'PASS' -and $varyNotPass.Count -eq 0 -and (& $rowIds $r) -ceq 'learn.1,learn.2,learn.3,learn.4,vary-dry,vary-as-written,vary-g025,vary-loud,vary-cmp-dry,vary-cmp-g025,p-device,p-reopen,p-transport,p-kept' -and
    ($learnLabels -join ',') -ceq 'learn.1,learn.2,learn.3,learn.4' -and $launchLabels.Count -eq $r.launches)
Write-Case "end to end: variants: each learn launch runs at 48000 Hz and block 512 whatever the ini said before, within learnTimeoutSec ($($learnSettings -join ', '))" $false (
    ($learnSettings -join ',') -ceq 'learn.1 45 s 48000/512,learn.2 45 s 48000/512,learn.3 45 s 48000/512,learn.4 45 s 48000/512')
Write-Case 'end to end: variants: the facts of a learn row: its batch of how many, the variants it learned, the module proof of its own plugins (a binary of another batch not seen is no gap)' $false (
    $varyRows[0].facts.batch -eq 1 -and $varyRows[0].facts.batches -eq 4 -and $varyRows[0].facts.variants -eq 3 -and $varyRows[0].facts.learned -eq 3 -and $varyRows[0].facts.modules -ceq 'Proven' -and
    $varyRows[0].facts.binaries.get_Count() -eq 2 -and $varyRows[1].facts.modules -ceq 'Proven' -and (@($varyRows[1].facts.binaries.get_Keys()) -join ',') -ceq 'Fixture Gain.vst3' -and
    $varyRows[2].facts.binaries.get_Count() -eq 1 -and $r.runs[0].moduleCheck.status -ceq 'PASS' -and
    $varyRows[2].facts.variants -eq 1 -and $varyRows[3].facts.variants -eq 2 -and @($varyRows[3].facts.states).Count -eq 1 -and $varyRows[3].facts.states[0].state -ceq 'loud' -and
    $varyRows[1].detail -clike '2 plugin variants learned; every tested binary loaded from the private copy*')
Write-Case 'end to end: variants: the row of a variant names it and the scenario as written' $false (
    (& $factOf (& $rowOf $r 'vary-g025') 'variant') -ceq 'g025' -and (& $factOf (& $rowOf $r 'vary-g025') 'baseScenario') -ceq 'vary' -and (& $factOf (& $rowOf $r 'vary-cmp-dry') 'variant') -ceq 'dry' -and
    (& $factOf (& $rowOf $r 'vary-cmp-dry') 'baseScenario') -ceq 'vary-cmp' -and $null -eq (& $factOf (& $rowOf $r 'p-device') 'variant'))
$g025Kept = & $factOf (& $rowOf $r 'vary-g025') 'kept'
Write-Case 'end to end: variants: a kept variant keeps its manifest line in the facts of its row, next to the variant and the scenario as written' $false (
    $g025Kept -is [System.Collections.IDictionary] -and $g025Kept['scenario'] -ceq 'vary-g025' -and $g025Kept['variant'] -ceq 'g025' -and $g025Kept['baseScenario'] -ceq 'vary' -and
    [string]$g025Kept['output']['path'] -clike 'renders/*/run1/vary-g025.wav' -and (& $factOf (& $rowOf $r 'vary-g025') 'baseScenario') -ceq 'vary')
$varyKeep = @(Get-ChildItem -LiteralPath (Join-Path $varyCfg.ResultDir 'renders') -Directory)[0].FullName
$varyEntries = @([IO.File]::ReadAllText((Join-Path $varyKeep 'manifest.jsonl')) -split "`n" | Where-Object { $_ } | ForEach-Object { ConvertFrom-HarnessJson $_ })
$varyEntry = { param([string]$EntryId) @($varyEntries | Where-Object { $_['scenario'] -ceq $EntryId })[0] }
$gainOf = { param([string]$EntryId) @((& $varyEntry $EntryId)['fx'])[0] }
$paramText = { param($Fx) @(@($Fx['params']) | ForEach-Object { "$($_['name'])=$($_['normalized'])/$($_['display'])/$($_['readDisplay'])" }) -join ';' }
$gainBlocks = @('vary-as-written', 'vary-g025', 'vary-loud' | ForEach-Object { (& $gainOf $_)['blockSha256'] })
Write-Case "end to end: variants: every variant is kept, the manifest naming its variant, the scenario as written, the layout, each FX as rendered with its parameters and display texts ($(& $paramText (& $gainOf 'vary-loud')))" $false (
    (@($varyEntries | ForEach-Object { $_['scenario'] }) -join ',') -ceq 'vary-dry,vary-as-written,vary-g025,vary-loud,p-kept' -and
    @($varyEntries | Where-Object { $_['scenario'] -clike 'vary-*' -and ($_['baseScenario'] -cne 'vary' -or $_['layout'] -cne 'vary' -or "vary-$($_['variant'])" -cne $_['scenario']) }).Count -eq 0 -and
    (& $paramText (& $gainOf 'vary-as-written')) -ceq 'Gain=0.5//0.50' -and (& $paramText (& $gainOf 'vary-g025')) -ceq 'Gain=0.25//0.25' -and (& $paramText (& $gainOf 'vary-loud')) -ceq 'Gain=0.5//0.50;Trim=0.75/0.75/0.75' -and @((& $gainOf 'vary-g025')['params'])[0].Contains('display') -and
    (& $gainOf 'vary-loud')['state'] -ceq 'loud' -and $null -eq (& $gainOf 'vary-g025')['state'] -and @($gainBlocks | Select-Object -Unique).Count -eq 3 -and
    (Test-Path -LiteralPath (Join-Path $varyKeep 'run1/vary-loud.wav')))
$varyWork = @(Get-ChildItem -LiteralPath (Join-Path $varyCfg.ResultDir 'work') -Directory)[-1].FullName
$bypassLines = { param([string]$Leaf) @([regex]::Matches([IO.File]::ReadAllText((Join-Path $varyWork $Leaf)), '(?m)^      BYPASS (\d) 0 0$') | ForEach-Object { $_.Groups[1].Value }) -join ',' }
$learnFilesMissing = @(foreach ($k in 1..4) { foreach ($learnLeaf in "_learn-$k.rpp", "_learn-$k-in.rpp", "_learn-$k.job.lua", "_learn-$k.result") { if (-not (Test-Path -LiteralPath (Join-Path $varyWork $learnLeaf))) { $learnLeaf } } })
Write-Case "end to end: variants: each learn launch has files of its own: _learn-<k>.rpp, _learn-<k>-in.rpp and the job and result of its step _learn-<k> (missing: $($learnFilesMissing -join ', '))" $false (
    $learnFilesMissing.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $varyWork 'learn.rpp')))
$gainBlockIn = { param([string]$Leaf) $tb = Get-HarnessFxBlocks ([IO.File]::ReadAllText((Join-Path $varyWork $Leaf))); ($tb.Contains('Voice') -and @($tb['Voice']).Count) ? (@($tb['Voice'])[0].Lines -join "`n") : "no block in $Leaf" }
Write-Case 'end to end: variants: a compare variant without a layout of its own renders the variant layout: the setting of the variant in both projects, not the layout as written' $false (
    (& $gainBlockIn 'vary-cmp-g025-variant.rpp') -ceq (& $gainBlockIn 'vary-cmp-g025.rpp') -and (& $gainBlockIn 'vary-cmp-g025.rpp') -ceq (& $gainBlockIn 'vary-g025.rpp') -and
    (& $gainBlockIn 'vary-cmp-g025-variant.rpp') -cne (& $gainBlockIn 'vary-as-written.rpp') -and (& $bypassLines 'vary-cmp-g025-variant.rpp') -ceq '0,0')
Write-Case "end to end: variants: the dry variant bypasses every FX, in its project, in both projects of its compare variant and in the manifest ($(& $bypassLines 'vary-dry.rpp'); $(& $bypassLines 'vary-cmp-dry-variant.rpp'))" $false (
    (& $bypassLines 'vary-dry.rpp') -ceq '1,1' -and (& $bypassLines 'vary-cmp-dry.rpp') -ceq '1,1' -and (& $bypassLines 'vary-cmp-dry-variant.rpp') -ceq '1,1' -and (& $bypassLines 'vary-as-written.rpp') -ceq '0,0' -and
    @((& $varyEntry 'vary-dry')['fx'] | Where-Object { $_['bypass'] -ne $true }).Count -eq 0 -and @((& $varyEntry 'vary-as-written')['fx'] | Where-Object { $_['bypass'] -ne $false }).Count -eq 0)
$pDev = & $rowOf $r 'p-device'
Write-Case "end to end: latency only reported: device PASS without comparing it, its facts list what the JSFX reported; savereopen, transport and the kept render too ($($pDev.detail))" $false (
    $pDev.detail -clike '*; 0 FX report the configured latency, 1 report it only;*' -and @($pDev.facts.pdc).Count -eq 1 -and $pDev.facts.pdc[0].pdc -eq 64 -and $pDev.facts.pdc[0].plugin -ceq 'delay' -and
    $pDev.facts.pdc[0].track -ceq 'Voice' -and (& $rowOf $r 'p-reopen').facts.pdc[0].pdc -eq 64 -and (& $rowOf $r 'p-transport').facts.pdc[0].pdc -eq 64 -and @((& $varyEntry 'p-kept')['fx'])[0]['pdc'] -eq 64)
# A display text the plugin does not show (learn.4 FAIL, the clean state alone committed all the same) and a learn launch
# that writes no result (learn.3): the batches after either still run, and only what needs their entries does not
$trimLoud = @{ normalized = 0.75; display = 'loud' }
$varyBad = & $writeVariant $varyChange
$varyBad.ReaperExe = $pwshExe; $varyBad.ResultDir = Join-Path $Work 'e2e-vary-bad'
Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; LearnNoResult = 3 }
try { $r = Invoke-HarnessSuite @varyBad -Only '^vary' -NoNegative -SelfTestHooks $hooks } finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
$trimLoud = @{ normalized = 0.75; display = '0.75' }
$varyCfg = & $writeVariant $varyChange # the file is shared: written again as it was
$varyCfg.ReaperExe = $pwshExe; $varyCfg.ResultDir = Join-Path $Work 'e2e-vary'
$badStatus = @($r.runs[0].scenarios | ForEach-Object { "$($_.id)=$($_.status)" }) -join ','
Write-Case "end to end: variants: a launch without a result is INCOMPLETE and a variant showing another text FAIL, the batches after them still learn; what needs their entries is not run, the rest PASS ($badStatus)" $true (
    $r.verdict -ceq 'FAIL' -and $badStatus -ceq 'learn.1=PASS,learn.2=PASS,learn.3=INCOMPLETE,learn.4=FAIL,vary-dry=PASS,vary-as-written=PASS,vary-g025=INCOMPLETE,vary-loud=INCOMPLETE,vary-cmp-dry=PASS,vary-cmp-g025=INCOMPLETE' -and
    (& $rowOf $r 'learn.3').detail -clike 'the learn launch failed: *' -and (& $rowOf $r 'learn.4').detail -clike "gain state loud (variant 2, first used by vary-loud) parameter 'Trim' shows '0.75', expected 'loud'*" -and
    (& $rowOf $r 'learn.4').facts.learned -eq 1 -and (& $rowOf $r 'vary-g025').detail -ceq 'not run: learning the plugin blocks it needs did not succeed (see the learn.3 row)' -and
    (& $rowOf $r 'vary-loud').detail -ceq 'not run: learning the plugin blocks it needs did not succeed (see the learn.4 row)' -and
    (& $factOf (& $rowOf $r 'vary-g025') 'variant') -ceq 'g025' -and (& $factOf (& $rowOf $r 'vary-g025') 'baseScenario') -ceq 'vary')
# -Only on an id after expansion: only what the picked variant needs is learned
$r = Invoke-HarnessSuite @varyCfg -Only '^vary-g025$' -NoNegative -SelfTestHooks $hooks -InformationVariable varyInfo
$plannedLine = @($varyInfo | ForEach-Object { [string]$_.MessageData } | Where-Object { $_ -clike '*picked (after matrix and variant expansion)*' })
Write-Case "end to end: variants: -Only one variant learns the defaults and what that variant needs, nothing else, and says so before the first launch ($(& $rowIds $r); $plannedLine)" $false (
    $r.verdict -ceq 'PASS' -and (& $rowIds $r) -ceq 'learn.1,learn.2,vary-g025' -and (& $rowOf $r 'learn.2').facts.variants -eq 2 -and
    ($plannedLine -join '|') -ceq '1 scenarios and 0 negative cases picked (after matrix and variant expansion); 5 plugin variants to learn in 2 launches per round')
$varyZero = & $writeVariant { param($c) & $varyChange $c; $c.plugins.delay.expectPdc = 0 }
$varyZero.ReaperExe = $pwshExe; $varyZero.ResultDir = Join-Path $Work 'e2e-vary-zero'
$r = Invoke-HarnessSuite @varyZero -Only '^p-device$' -NoNegative -SelfTestHooks $hooks
Write-Case "end to end: latency: the same device scenario with expectPdc 0 compares it, and 64 is a FAIL ($((& $rowOf $r 'p-device').detail))" $true (
    $r.verdict -ceq 'FAIL' -and (& $rowOf $r 'p-device').status -ceq 'FAIL' -and (& $rowOf $r 'p-device').detail -clike '*t0_fx0_pdc=64, expected 0*')
$varyCfg = & $writeVariant $varyChange # the file is shared: written again as it was
$varyCfg.ReaperExe = $pwshExe; $varyCfg.ResultDir = Join-Path $Work 'e2e-vary'
# The latency of a JSFX only reported, and not read: no evidence, in every kind that reads it; a transport state that
# fails stays FAIL all the same
$varyCfg = & $writeVariant { param($c) & $varyChange $c; $c.scenarios = @($c.scenarios) + @([ordered]@{ id = 'p-transport-bad'; kind = 'transport'; layout = 'p'; states = @([ordered]@{ name = 'on'; transport = 'stop'; arm = $true; monitor = 'on'; samples = 4800; expect = @{ called = $false } }) }) }
$varyCfg.ReaperExe = $pwshExe; $varyCfg.ResultDir = Join-Path $Work 'e2e-vary'
Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; PdcUnread = $true }
try { $r = Invoke-HarnessSuite @varyCfg -Only '^p-' -NoNegative -SelfTestHooks $hooks } finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
$unreadStatus = @($r.runs[0].scenarios | ForEach-Object { "$($_.id)=$($_.status)" }) -join ','
$unreadKept = @(Get-ChildItem -LiteralPath (Join-Path $varyCfg.ResultDir 'renders') -Directory | Sort-Object Name)[-1].FullName
$transportBad = & $rowOf $r 'p-transport-bad'
Write-Case "end to end: latency only reported but not read: a transport state that fails is still FAIL, with the reading that is missing in its detail and facts ($($transportBad.status): $($transportBad.detail))" $true (
    $transportBad.status -ceq 'FAIL' -and $transportBad.detail -clike '*called in*; no evidence: t0_fx0_pdc was not read (the latency of delay is only reported)' -and
    @(& $factOf $transportBad 'pdc')[0] -is [System.Collections.IDictionary] -and $null -eq @(& $factOf $transportBad 'pdc')[0]['pdc'] -and @(& $factOf $transportBad 'states').Count -eq 1)
Write-Case "end to end: latency only reported but not read: device, savereopen, transport and a kept render are INCOMPLETE, saying so; the render is kept all the same ($unreadStatus)" $true (
    $r.verdict -ceq 'FAIL' -and $unreadStatus -ceq 'learn.1=PASS,learn.2=PASS,p-device=INCOMPLETE,p-reopen=INCOMPLETE,p-transport=INCOMPLETE,p-kept=INCOMPLETE,p-transport-bad=FAIL' -and
    (& $rowOf $r 'p-device').detail -clike '*; no evidence: t0_fx0_pdc was not read (the latency of delay is only reported)' -and (& $rowOf $r 'p-reopen').detail -clike '*no evidence: before_t0_fx0_pdc was not read*' -and
    (& $rowOf $r 'p-transport').detail -clike '*t0_fx0_pdc was not read (the latency of delay is only reported)*' -and (& $rowOf $r 'p-device').facts.pdc[0].Contains('pdc') -and $null -eq (& $rowOf $r 'p-device').facts.pdc[0].pdc -and
    @(& $factOf (& $rowOf $r 'p-transport') 'pdc')[0] -is [System.Collections.IDictionary] -and @(& $factOf (& $rowOf $r 'p-transport') 'pdc')[0].Contains('pdc') -and
    $null -eq @(& $factOf (& $rowOf $r 'p-transport') 'pdc')[0]['pdc'] -and @(& $factOf (& $rowOf $r 'p-transport') 'pdc')[0]['plugin'] -ceq 'delay' -and
    (& $rowOf $r 'p-kept').detail -clike '*; kept, but the latency of delay on Voice was not read' -and (Test-Path -LiteralPath (Join-Path $unreadKept 'run1/p-kept.wav')))
$varyCfg = & $writeVariant $varyChange # the file is shared: written again as it was
$varyCfg.ReaperExe = $pwshExe; $varyCfg.ResultDir = Join-Path $Work 'e2e-vary'
# A configuration problem of a variant is a usage error before anything starts
$launchesBefore = $seenArgs.Count
$varyClash = & $writeVariant { param($c) & $varyChange $c; $c.layouts.vary.tracks[0].fx[0].params.Gain = @{ normalized = 0.5; display = '0.50' }; $c.scenarios[0].variants[2].fx.gain.params.Gain = @{ normalized = 0.5; display = 'other' } }
Write-Case 'end to end: a variant asking one learned setting to show two display texts is a usage error; REAPER is never started' $true (
    (Test-Throws { $null = Invoke-HarnessSuite @varyClash -SelfTestHooks $hooks } "USAGE:*plugin 'gain' parameter 'Gain' at 0.5 is asked to show both*") -and $seenArgs.Count -eq $launchesBefore)
# A learn launch a skip marker blocked (it appears once learn.1 is done): learning stops there, no later learn launch is
# started, and their rows say where it stopped
$varyCfg = & $writeVariant $varyChange # the file is shared: written again as it was
$varyCfg.ReaperExe = $pwshExe; $varyCfg.ResultDir = Join-Path $Work 'e2e-vary-stop'
$stopMarker = Join-Path $Work 'SKIP_AFTER_LEARN_1'
$markAfterFirst = { $labelAt = [array]::IndexOf($args, '-Label'); $launched = & $realLaunch @args; if ($labelAt -ge 0 -and [string]$args[$labelAt + 1] -ceq 'learn.1') { Set-Content -LiteralPath $stopMarker -Value x }; $launched }.GetNewClosure()
$launchesBefore = $seenArgs.Count
$null = & (Get-Module Scenarios) { param($s) Set-Item function:script:Invoke-HarnessLaunch $s } $markAfterFirst
try { $r = Invoke-HarnessSuite @varyCfg -Only '^vary' -NoNegative -SkipMarker $stopMarker -SelfTestHooks $hooks }
finally {
    $null = & (Get-Module Scenarios) { param($s) Set-Item function:script:Invoke-HarnessLaunch $s } $realLaunch
    Remove-Item -LiteralPath $stopMarker -ErrorAction SilentlyContinue
}
$stopStatus = @($r.runs[0].scenarios | Where-Object { $_.kind -ceq 'learn' } | ForEach-Object { "$($_.id)=$($_.status)" }) -join ','
Write-Case "end to end: variants: a learn launch a skip marker blocked stops learning: no later learn launch is started ($stopStatus; $((& $rowOf $r 'learn.3').detail))" $true (
    $stopStatus -ceq 'learn.1=PASS,learn.2=INCOMPLETE,learn.3=INCOMPLETE,learn.4=INCOMPLETE' -and (& $rowOf $r 'learn.2').detail -clike 'the learn launch failed: a skip marker appeared*' -and
    (& $rowOf $r 'learn.3').detail -ceq 'not run: learning stopped at the learn.2 row' -and (& $rowOf $r 'learn.4').detail -ceq 'not run: learning stopped at the learn.2 row' -and
    $seenArgs.Count -eq $launchesBefore + 1)
$factLine = { param($OfRow) @('batch', 'batches', 'variants', 'learned' | ForEach-Object { "$_=$(& $factOf $OfRow $_)" }) -join ' ' }
Write-Case "end to end: variants: the row of a learn launch not started has the facts of its batch, nothing learned ($(& $factLine (& $rowOf $r 'learn.3')))" $false (
    (& $factLine (& $rowOf $r 'learn.3')) -ceq 'batch=3 batches=4 variants=1 learned=0' -and (& $factLine (& $rowOf $r 'learn.4')) -ceq 'batch=4 batches=4 variants=2 learned=0')
# A learn batch that throws: its row says so, learning stops there, and nothing that needs learning runs
$varyCfg.ResultDir = Join-Path $Work 'e2e-vary-threw'
$r = Invoke-WithSuiteCommand 'Invoke-HarnessLearn' { throw 'stub learn threw' } { Invoke-HarnessSuite @varyCfg -Only '^vary-g025$' -NoNegative -SelfTestHooks $hooks }
Write-Case "end to end: variants: a learn batch that throws is one INCOMPLETE row, learning stops, and nothing that needs learning runs ($(@($r.runs[0].scenarios | ForEach-Object { "$($_.id): $($_.detail)" }) -join ' | '))" $true (
    (& $rowIds $r) -ceq 'learn.1,learn.2,vary-g025' -and (& $rowOf $r 'learn.1').status -ceq 'INCOMPLETE' -and (& $rowOf $r 'learn.1').detail -ceq 'learning threw: stub learn threw' -and
    (& $rowOf $r 'learn.2').detail -ceq 'not run: learning stopped at the learn.1 row' -and (& $rowOf $r 'vary-g025').detail -ceq 'not run: learning stopped on an error (see the learn.1 row)' -and
    (& $rowOf $r 'vary-g025').status -ceq 'INCOMPLETE')
Write-Case "end to end: variants: the row of a learn launch that threw, and of the one after it, have the facts of their batch ($(& $factLine (& $rowOf $r 'learn.1')); $(& $factLine (& $rowOf $r 'learn.2')))" $false (
    (& $factLine (& $rowOf $r 'learn.1')) -ceq 'batch=1 batches=2 variants=3 learned=0' -and (& $factLine (& $rowOf $r 'learn.2')) -ceq 'batch=2 batches=2 variants=2 learned=0')
# A launch whose module list never showed the binary of its plugin (learn.2) and a launch with an entry that failed
# (learn.3, its clean entry taken) do not stop learning: learn.4 still runs and passes, and what needs only entries that
# were taken runs (vary-g025 takes the delay from learn.2, a JSFX proven by fx_ident)
$trimLoud = @{ normalized = 0.75; display = 'loud' }
$varyOrder = & $writeVariant { param($c) & $varyChange $c; $vs = @($c.scenarios[0].variants); $c.scenarios[0].variants = @($vs[0], $vs[1], $vs[3], $vs[2]) }
$trimLoud = @{ normalized = 0.75; display = '0.75' }
$varyOrder.ReaperExe = $pwshExe; $varyOrder.ResultDir = Join-Path $Work 'e2e-vary-order'
Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; LearnNoModules = 2 }
try { $r = Invoke-HarnessSuite @varyOrder -Only '^vary-' -NoNegative -SelfTestHooks $hooks } finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
$orderStatus = @($r.runs[0].scenarios | ForEach-Object { "$($_.id)=$($_.status)" }) -join ','
Write-Case "end to end: variants: a batch with a binary never seen and a batch with a failed entry do not stop learning; the batch after them passes and what needs only its entries runs ($orderStatus)" $true (
    $orderStatus -ceq 'learn.1=PASS,learn.2=INCOMPLETE,learn.3=FAIL,learn.4=PASS,vary-dry=INCOMPLETE,vary-as-written=INCOMPLETE,vary-loud=INCOMPLETE,vary-g025=PASS,vary-cmp-dry=INCOMPLETE,vary-cmp-g025=PASS' -and
    (& $rowOf $r 'learn.2').detail -clike 'the module list never showed Fixture Gain.vst3 loaded*' -and (& $rowOf $r 'learn.3').detail -clike "*parameter 'Trim' shows '0.75', expected 'loud'*" -and
    (& $rowOf $r 'vary-dry').detail -ceq 'not run: learning the plugin blocks it needs did not succeed (see the learn.2 row)' -and
    (& $rowOf $r 'vary-loud').detail -ceq 'not run: learning the plugin blocks it needs did not succeed (see the learn.3 row)')
# A kind of an extension runs only when every learn row passed: a learn launch without a result, which stops nothing,
# keeps it from running all the same
$extGap = $e2e.Clone(); $extGap.ResultDir = Join-Path $Work 'e2e-ext-gap'
Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; LearnNoResult = 1 }
try { $r = Invoke-HarnessSuite @extGap -Only '^ext-count$' -NoNegative -SelfTestHooks $hooks } finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
Write-Case "end to end: a kind of an extension does not run when a learn row is not PASS, though learning did not stop ($(& $rowIds $r): $((& $rowOf $r 'ext-count').detail))" $true (
    (& $rowIds $r) -ceq 'learn,ext-count' -and (& $rowOf $r 'learn').status -ceq 'INCOMPLETE' -and (& $rowOf $r 'learn').detail -clike 'the learn launch failed: *' -and
    (& $rowOf $r 'ext-count').status -ceq 'INCOMPLETE' -and (& $rowOf $r 'ext-count').detail -ceq 'not run: learning did not pass in every batch, and a kind of an extension gets every block (see the learn row)')
$varyCfg = & $writeVariant $varyChange # the file is shared: written again as it was
$varyCfg.ReaperExe = $pwshExe
$varyCfg.ResultDir = Join-Path $Work 'e2e-vary'

# A WAV file of the configuration as the source of a track: checked before the start, copied into the work directory,
# its item as long as the file to the last frame; at another rate a usage error before REAPER starts
$srcDir = Join-Path $Work 'sources'
$null = New-Item -ItemType Directory -Force -Path $srcDir
$voiceFrames = 30000
while (($voiceFrames / 44100.0) * 44100 -ge $voiceFrames) { $voiceFrames++ } # a length frames / rate would cut short
$voiceWav = Join-Path $srcDir 'voice.wav'
[HarnessWav]::Write($voiceWav, 44100, 2, 'pcm24', $false, [HarnessWav]::Signal(44100, 2, $voiceFrames / 44100.0, 5, -12, 0, -20, 0))
$voiceSha = (Get-FileHash -LiteralPath $voiceWav -Algorithm SHA256).Hash.ToLowerInvariant()
$fileRate = 44100
$fileChange = {
    param($c)
    & $noExt $c
    $c.layouts.fileplay = [ordered]@{ tracks = @([ordered]@{ name = 'Voice'; source = $true; file = 'sources/voice.wav'; fx = @(@{ plugin = 'gain' }) }, [ordered]@{ name = 'Pad'; source = $true; signal = @{ seed = 3 } }) }
    $c.scenarios = @([ordered]@{ id = 'file-play'; kind = 'render'; layout = 'fileplay'; sr = $fileRate; stems = @('Voice', 'Pad') })
    $c.negative = @()
}
$fileCfg = & $writeVariant $fileChange
$fileCfg.ReaperExe = $pwshExe; $fileCfg.ResultDir = Join-Path $Work 'e2e-sources'
$r = Invoke-HarnessSuite @fileCfg -NoNegative -KeepWork -SelfTestHooks $hooks
$fileRow = @($r.runs[0].scenarios | Where-Object { $_.id -ceq 'file-play' })[0]
Write-Case "end to end: a track playing a WAV file of the configuration: PASS, and the render is as long as the file, to its last frame ($($fileRow.detail))" $false (
    $r.verdict -ceq 'PASS' -and $fileRow.status -ceq 'PASS' -and $fileRow.detail -clike "identical=yes lag=0 * frames=$voiceFrames/$voiceFrames *")
$fileWork = @(Get-ChildItem -LiteralPath (Join-Path $fileCfg.ResultDir 'work') -Directory)[-1].FullName
$fileRpp = [IO.File]::ReadAllText((Join-Path $fileWork 'file-play.rpp'))
$trackPart = { param([string]$ProjectText, [string]$TrackName) [regex]::Match($ProjectText, "(?s)  <TRACK\n    NAME `"$TrackName`"\n.*?\n  >\n").Value }
$voicePart = & $trackPart $fileRpp 'Voice'
$copyPath = Join-Path $fileWork "_source-$($voiceSha.Substring(0, 12)).wav"
$inv = [Globalization.CultureInfo]::InvariantCulture
# Paths as the project spells them (as given) against paths as a listing spells them (as on disk): equal ignoring case,
# like the file system
$samePath = { param([string]$PathA, [string]$PathB) [string]::Equals($PathA, $PathB, [StringComparison]::OrdinalIgnoreCase) }
Write-Case 'end to end: the project plays the checked copy in the work directory, never the file next to the configuration' $false (
    (& $samePath ([regex]::Match($voicePart, 'FILE "(.*)"').Groups[1].Value) $copyPath) -and (Get-FileHash -LiteralPath $copyPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $voiceSha -and
    @(Get-ChildItem -LiteralPath $fileWork -Filter '*.rpp' | Where-Object { [IO.File]::ReadAllText($_.FullName).Contains($srcDir, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0)
Write-Case 'end to end: the item of the file track is as long as the file, the item of the other track as long as the test signal' $false (
    $voicePart -cmatch "\n      LENGTH $([regex]::Escape((Get-HarnessItemLength $voiceFrames 44100).ToString('R', $inv)))\n" -and (& $trackPart $fileRpp 'Pad') -cmatch '\n      LENGTH 0\.5\n')
$src = @($r.sources)
Write-Case 'end to end: the result lists the source file: path relative to the configuration, full sha256, frames, channels, sampleRate, format' $false (
    $src.Count -eq 1 -and $src[0].path -ceq 'sources/voice.wav' -and $src[0].sha256 -ceq $voiceSha -and $src[0].frames -eq $voiceFrames -and $src[0].channels -eq 2 -and $src[0].sampleRate -eq 44100 -and $src[0].format -ceq 'pcm24')
Write-Case 'end to end: a run without keep makes no renders directory and names no manifest' $false (-not (Test-Path -LiteralPath (Join-Path $fileCfg.ResultDir 'renders')) -and $r.PSObject.Properties['manifest'] -and $null -eq $r.manifest)
# Kinds of extensions get the rule from NewRun: a file is never resampled or mixed down, whatever -Sr and -Channels they
# ask for (the handler throws, the row is INCOMPLETE). A project without items (transport) never asks for the copy.
$extConf = Read-HarnessConfig -Path $fileCfg.Config
$extWork = Join-Path $Work 'ext-newrun'
$null = New-Item -ItemType Directory -Force -Path $extWork
$newRunKind = @{ Run = {
        param($KindCtx, $KindScenario)
        $null = & $KindCtx.Api.NewRun -Ctx $KindCtx -Name $KindScenario.id -Layout (& $KindCtx.Api.Layout $KindCtx $KindScenario.layout) -Sr $KindScenario.raw['sr'] -Channels $KindScenario.raw['channels'] -NoFx
        & $KindCtx.Api.Outcome PASS 'project written'
    } }
$extCtx = New-HarnessContext -ReaperExe 'stand-in' -WorkDir $extWork -Driver 'x' -Config $extConf -Locks @('Local\x') -Kinds @{ 'x-newrun' = $newRunKind }
Copy-HarnessSourceFiles -Ctx $extCtx -Sources (Read-HarnessSourceFiles -Config $extConf -Scenarios @($extConf.Scenarios))
$extRun = { param([string]$RunId, [int]$RunSr, [int]$RunChannels) Invoke-HarnessScenario -Ctx $extCtx -Scenario ([pscustomobject]@{ id = $RunId; kind = 'x-newrun'; layout = 'fileplay'; raw = @{ sr = $RunSr; channels = $RunChannels } }) }
$at48k = & $extRun 'x-48k' 48000 2
$atMono = & $extRun 'x-mono' 44100 1
$atFile = & $extRun 'x-file' 44100 2
Write-Case "kinds of extensions: NewRun refuses a source file at another rate than the render: INCOMPLETE, no project written ($($at48k.Detail))" $true (
    $at48k.Status -ceq 'INCOMPLETE' -and $at48k.Detail -ceq 'the scenario threw: source sources/voice.wav is at 44100 Hz and the render runs at 48000 Hz: nothing is resampled' -and -not (Test-Path -LiteralPath (Join-Path $extWork 'x-48k.rpp')))
Write-Case "kinds of extensions: NewRun refuses a file of two channels in a render of one ($($atMono.Detail))" $true (
    $atMono.Status -ceq 'INCOMPLETE' -and $atMono.Detail -ceq 'the scenario threw: source sources/voice.wav has 2 channels and the render 1: nothing is mixed down' -and -not (Test-Path -LiteralPath (Join-Path $extWork 'x-mono.rpp')))
Write-Case "kinds of extensions: at the rate and the channels of the file NewRun writes the project, which plays the checked copy ($($atFile.Detail))" $false (
    $atFile.Status -ceq 'PASS' -and (Test-Path -LiteralPath (Join-Path $extWork 'x-file.rpp')) -and [IO.File]::ReadAllText((Join-Path $extWork 'x-file.rpp')).Contains($extCtx.SourceCopies['sources/voice.wav'].Path, [StringComparison]::OrdinalIgnoreCase))
$bareCtx = New-HarnessContext -ReaperExe 'stand-in' -WorkDir $extWork -Driver 'x' -Config $extConf -Locks @('Local\x')
$bare = try { New-HarnessRun -Ctx $bareCtx -Name 'x-noitems' -Layout $extConf.Layouts['fileplay'] -Sr 48000 -NoFx -NoItems } catch { $_.Exception.Message }
Write-Case "a project without items (the transport kind) never asks for the copy of a file in its layout, nor for its rate: nothing of it is played ($(if ($bare -is [string]) { $bare }))" $false (
    $bare -isnot [string] -and (Test-Path -LiteralPath $bare.Project) -and [IO.File]::ReadAllText($bare.Project) -cnotmatch '<SOURCE WAVE')
# A tail: every item is longer by it, to the frame, and plays its source once; the render must then be as long as the
# longest source and the tail. Without a tail, and in a project without items, none of it
$tailRun = New-HarnessRun -Ctx $extCtx -Name 'x-tail' -Layout $extConf.Layouts['fileplay'] -Sr 44100 -NoFx -TailFrames 4410
$tailText = [IO.File]::ReadAllText($tailRun.Project)
$untailedRun = New-HarnessRun -Ctx $extCtx -Name 'x-untailed' -Layout $extConf.Layouts['fileplay'] -Sr 44100 -NoFx
$itemlessRun = New-HarnessRun -Ctx $extCtx -Name 'x-itemless' -Layout $extConf.Layouts['fileplay'] -Sr 44100 -NoFx -NoItems -TailFrames 4410
Write-Case "a tail of 4410 frames at 44100 Hz: the item of the file is its frames and the tail long, the item of the signal 22050 frames and the tail, each with LOOP 0; the render must have the longer one ($($tailRun.Frames) frames)" $false (
    $tailRun.Frames -eq $voiceFrames + 4410 -and
    (& $trackPart $tailText 'Voice') -cmatch "\n      LENGTH $([regex]::Escape((Get-HarnessItemLength ($voiceFrames + 4410) 44100).ToString('R', $inv)))\n      LOOP 0\n" -and
    (& $trackPart $tailText 'Pad') -cmatch "\n      LENGTH $([regex]::Escape((Get-HarnessItemLength 26460 44100).ToString('R', $inv)))\n      LOOP 0\n" -and
    $untailedRun.Frames -eq 0 -and [IO.File]::ReadAllText($untailedRun.Project) -cnotmatch 'LOOP' -and $itemlessRun.Frames -eq 0 -and [IO.File]::ReadAllText($itemlessRun.Project) -cnotmatch 'LOOP')
$fileRate = 48000
$fileCfg = & $writeVariant $fileChange
$fileCfg.ReaperExe = $pwshExe; $fileCfg.ResultDir = Join-Path $Work 'e2e-sources'
$seenBefore = $seenArgs.Count
Write-Case 'end to end: a source file at another rate than its scenario is a usage error before REAPER starts' $true (
    (Test-Throws { $null = Invoke-HarnessSuite @fileCfg -NoNegative -SelfTestHooks $hooks } 'USAGE: sources: 1 problem(s): file-play: source sources/voice.wav is at 44100 Hz and the scenario runs at 48000 Hz: nothing is resampled') -and $seenArgs.Count -eq $seenBefore)

# Kept renders: whatever the verdict, a render with keep and its stems leave the work directory for renders/<stamp>/run<k>/,
# never over another file, each with its line in the manifest of the run
$nanWav = Join-Path $srcDir 'nan.wav'
$nanSamples = [HarnessWav]::Signal(44100, 1, 0.25, 9, -12, 0, -20, 0)
$nanSamples[100] = [double]::NaN; $nanSamples[201] = [double]::PositiveInfinity
[HarnessWav]::Write($nanWav, 44100, 1, 'float32', $false, $nanSamples)
$keepChange = {
    param($c)
    & $noExt $c
    $c.layouts.keepme = [ordered]@{ tracks = @(
            [ordered]@{ name = 'Voice'; source = $true; file = 'sources/voice.wav'; fx = @([ordered]@{ plugin = 'gain'; state = 'loud' }) },
            [ordered]@{ name = 'Pad'; source = $true; signal = @{ seed = 3 }; fx = @([ordered]@{ plugin = 'delay' }) }) }
    $c.layouts.nanplay = [ordered]@{ tracks = @([ordered]@{ name = 'Bad'; source = $true; file = 'sources/nan.wav' }) }
    $c.scenarios = @(
        [ordered]@{ id = 'kept'; kind = 'render'; layout = 'keepme'; sr = 44100; block = 256; stems = @('Voice'); bypass = @('gain'); host = @{ anticipativeFx = $false }; keep = $true },
        [ordered]@{ id = 'kept-nan'; kind = 'render'; layout = 'nanplay'; sr = 44100; mono = $true; keep = $true },
        [ordered]@{ id = 'twin'; kind = 'render'; layout = 'keepme'; sr = 44100; compare = 'none'; stems = @('Pad'); keep = $true },
        [ordered]@{ id = 'twin-stem-pad'; kind = 'render'; layout = 'keepme'; sr = 44100; compare = 'none'; keep = $true },
        [ordered]@{ id = 'plain'; kind = 'render'; layout = 'keepme'; sr = 44100; compare = 'none' })
    $c.negative = @()
}
$keepCfg = & $writeVariant $keepChange
$keepCfg.ReaperExe = $pwshExe; $keepCfg.ResultDir = Join-Path $Work 'e2e-keep'
$r = Invoke-HarnessSuite @keepCfg -NoNegative -KeepWork -SelfTestHooks $hooks
$keepRow = { param([string]$RowId) @($r.runs[0].scenarios | Where-Object { $_.id -ceq $RowId })[0] }
$keepDirs = @(Get-ChildItem -LiteralPath (Join-Path $keepCfg.ResultDir 'renders') -Directory)
$keepStamp = $keepDirs[0].Name
$keepManifest = Join-Path $keepDirs[0].FullName 'manifest.jsonl'
$manifestBytes = [IO.File]::ReadAllBytes($keepManifest)
$manifestLines = @([Text.UTF8Encoding]::new($false).GetString($manifestBytes) -split "`n" | Where-Object { $_ })
$entries = @($manifestLines | ForEach-Object { ConvertFrom-HarnessJson $_ })
$entryOf = { param([string]$EntryId) @($entries | Where-Object { $_['scenario'] -ceq $EntryId })[0] }
$keepWork = @(Get-ChildItem -LiteralPath (Join-Path $keepCfg.ResultDir 'work') -Directory)[-1].FullName
$hashOf = { param([string]$HashPath) (Get-FileHash -LiteralPath $HashPath -Algorithm SHA256).Hash.ToLowerInvariant() }
$keptAt = { param([string]$KeptLeaf) Join-Path $keepDirs[0].FullName "run1/$KeptLeaf" }
Write-Case "end to end: keep: a render with NaN and Inf samples is a FAIL row and the run goes on: every scenario ran, the verdict is FAIL ($((& $keepRow 'kept-nan').detail))" $true (
    $r.verdict -ceq 'FAIL' -and (& $keepRow 'kept-nan').status -ceq 'FAIL' -and @($r.runs[0].scenarios | Where-Object { $_.kind -ceq 'render' }).Count -eq 5 -and (& $keepRow 'kept').status -ceq 'PASS' -and (& $keepRow 'twin').status -ceq 'PASS' -and
    (& $keepRow 'plain').status -ceq 'PASS')
$nanEntry = & $entryOf 'kept-nan'
Write-Case 'end to end: keep: the render with NaN and Inf is kept all the same, its line counting them and its peak taken over the finite samples' $false (
    (Test-Path -LiteralPath (& $keptAt 'kept-nan.wav')) -and $nanEntry['status'] -ceq 'FAIL' -and $nanEntry['output']['path'] -ceq 'run1/kept-nan.wav' -and $nanEntry['output']['nanCount'] -ge 1 -and
    $nanEntry['output']['infCount'] -ge 1 -and $null -ne $nanEntry['output']['peakDb'] -and [double]::IsFinite($nanEntry['output']['peakDb']) -and $nanEntry['render']['channels'] -eq 1 -and $nanEntry['output']['channels'] -eq 1)
Write-Case "end to end: keep: one manifest per run, UTF-8 without BOM, one JSON object per line in the order the scenarios ran, only for scenarios with keep ($($entries.Count) lines)" $false (
    $manifestBytes[0] -ne 0xEF -and $manifestBytes[-1] -eq 10 -and $manifestLines.Count -eq 4 -and ((@($entries | ForEach-Object { $_['scenario'] })) -join ',') -ceq 'kept,kept-nan,twin,twin-stem-pad' -and
    @($entries | Where-Object { $_['schema'] -ne 1 -or $_['runStamp'] -cne $keepStamp -or $_['round'] -ne 1 }).Count -eq 0 -and (Split-Path -Leaf $keepWork) -ceq "$keepStamp-run1" -and
    $r.manifest -ceq "renders/$keepStamp/manifest.jsonl" -and $keepDirs.Count -eq 1)
$keptFiles = [string[]]@(Get-ChildItem -LiteralPath $keepDirs[0].FullName -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($keepDirs[0].FullName, $_.FullName) -replace '\\', '/' })
[Array]::Sort($keptFiles, [StringComparer]::Ordinal)
Write-Case "end to end: keep: the renders and stems moved out of the work directory, the projects and references stayed, a scenario without keep kept nothing ($($keptFiles -join ', '))" $false (
    ($keptFiles -join ',') -ceq 'manifest.jsonl,run1/kept-nan.wav,run1/kept-stem-Voice.wav,run1/kept.wav,run1/twin-stem-Pad.wav,run1/twin.wav' -and
    -not (Test-Path -LiteralPath (Join-Path $keepWork 'kept-stem-Master.wav')) -and -not (Test-Path -LiteralPath (Join-Path $keepWork 'kept-stem-Voice.wav')) -and
    (Test-Path -LiteralPath (Join-Path $keepWork 'kept.rpp')) -and (Test-Path -LiteralPath (Join-Path $keepWork 'plain.wav')) -and @(Get-ChildItem -LiteralPath $keepWork -Filter '_*.wav').Count -ge 2)
$kEntry = & $entryOf 'kept'
$kOut = $kEntry['output']; $kStems = @($kEntry['stems'])
$kWav = & $keptAt 'kept.wav'
$kHead = Read-HarnessWavHeader $kWav
$kScan = Get-HarnessWavScan $kWav
$kStemWav = & $keptAt 'kept-stem-Voice.wav'
Write-Case 'end to end: keep: the manifest describes the kept render and its stem: path relative to it, full sha256, frames, channels, rate, format, peak, NaN and Inf' $false (
    $kOut['path'] -ceq 'run1/kept.wav' -and $kOut['sha256'] -ceq (& $hashOf $kWav) -and $kOut['frames'] -eq $voiceFrames -and $kOut['frames'] -eq $kHead.Frames -and $kOut['channels'] -eq 2 -and
    $kOut['sampleRate'] -eq 44100 -and $kOut['format'] -ceq $kHead.Format -and [Math]::Abs($kOut['peakDb'] - 20 * [Math]::Log10($kScan.Peak)) -lt 1e-5 -and $kOut['nanCount'] -eq 0 -and $kOut['infCount'] -eq 0 -and
    $kStems.Count -eq 1 -and $kStems[0]['track'] -ceq 'Voice' -and $kStems[0]['path'] -ceq 'run1/kept-stem-Voice.wav' -and $kStems[0]['sha256'] -ceq (& $hashOf $kStemWav) -and $kStems[0]['frames'] -eq $voiceFrames)
$kRender = $kEntry['render']
Write-Case 'end to end: keep: the manifest names the scenario and how it was rendered: base id, no variant, layout, kind, status, detail, rate, block, mode, channels, host flags' $false (
    $kEntry['baseScenario'] -ceq 'kept' -and $kEntry.Contains('variant') -and $null -eq $kEntry['variant'] -and $kEntry['layout'] -ceq 'keepme' -and $kEntry['kind'] -ceq 'render' -and $kEntry['status'] -ceq 'PASS' -and
    $kEntry['detail'] -ceq (& $keepRow 'kept').detail -and $kRender['sr'] -eq 44100 -and $kRender['block'] -eq 256 -and $kRender['mode'] -ceq 'offline' -and $kRender['channels'] -eq 2 -and
    $kRender['host']['anticipativeFx'] -eq $false -and $kRender['host']['runFxWhenStopped'] -eq $true -and $kRender['host']['informOfflineState'] -eq $true)
$kSrc = @($kEntry['sources'])
Write-Case 'end to end: keep: the manifest lists what each source track played: the checked file, or the settings of its test signal' $false (
    $kSrc.Count -eq 2 -and $kSrc[0]['track'] -ceq 'Voice' -and $kSrc[0]['file']['path'] -ceq 'sources/voice.wav' -and $kSrc[0]['file']['sha256'] -ceq $voiceSha -and $kSrc[0]['file']['frames'] -eq $voiceFrames -and
    $kSrc[0]['file']['channels'] -eq 2 -and $kSrc[0]['file']['sampleRate'] -eq 44100 -and $kSrc[0]['file']['format'] -ceq 'pcm24' -and $null -eq $kSrc[0]['signal'] -and
    $kSrc[1]['track'] -ceq 'Pad' -and $null -eq $kSrc[1]['file'] -and $kSrc[1]['signal']['seconds'] -eq 0.5 -and $kSrc[1]['signal']['seed'] -eq 3 -and $kSrc[1]['signal']['noiseDb'] -eq -24 -and
    $kSrc[1]['signal']['sine']['hz'] -eq 440 -and $kSrc[1]['signal']['sine']['db'] -eq -30)
# The block of each FX exactly as the project holds it: the lines after its BYPASS line, up to the end of the chain
$keepRpp = [IO.File]::ReadAllText((Join-Path $keepWork 'kept.rpp'))
$blockSha = {
    param([string]$TrackName)
    $blockText = [regex]::Match((& $trackPart $keepRpp $TrackName), '(?s)\n      BYPASS \d 0 0\n(.*?\n)    >\n').Groups[1].Value
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($blockText))).ToLowerInvariant()
}
$kFx = @($kEntry['fx'])
$gainFx = $kFx[0]; $delayFx = $kFx[1]
$gainPlugin = @($r.plugins | Where-Object { $_.id -ceq 'gain' })[0]
$loudState = @($r.states | Where-Object { $_.plugin -ceq 'gain' -and $_.state -ceq 'loud' })[0]
Write-Case "end to end: keep: the manifest lists every FX as rendered: plugin, bundle, name REAPER showed, binary hash, bypass, state and its hash, the hash of its block in the project ($($gainFx['name']); $($gainFx['sha256']); $($gainFx['stateSha256']))" $false (
    $kFx.Count -eq 2 -and $gainFx['track'] -ceq 'Voice' -and $gainFx['index'] -eq 0 -and $gainFx['plugin'] -ceq 'gain' -and $gainFx['bundle'] -ceq 'Fixture Gain.vst3' -and $null -eq $gainFx['jsfx'] -and
    $gainFx['name'] -clike 'VST3: Fixture Gain*' -and $gainFx['sha256'] -cmatch '^[0-9a-f]{12}$' -and $gainFx['sha256'] -ceq $gainPlugin.sha256.Substring(0, 12) -and $gainFx['bypass'] -eq $true -and
    $gainFx['state'] -ceq 'loud' -and $gainFx['stateSha256'] -ceq $loudState.sha256 -and $gainFx['blockSha256'] -ceq (& $blockSha 'Voice') -and $gainFx['blockSha256'] -cmatch '^[0-9a-f]{64}$' -and
    @($gainFx['params']).Count -eq 0)
$delayParam = @($delayFx['params'])
Write-Case "end to end: keep: a JSFX in the manifest: its file, the parameters asked for and as REAPER read them back, its latency and the settings it was read at ($($delayFx['jsfx']); pdc $($delayFx['pdc']))" $false (
    $delayFx['track'] -ceq 'Pad' -and $delayFx['index'] -eq 0 -and $delayFx['plugin'] -ceq 'delay' -and $null -eq $delayFx['bundle'] -and $delayFx['jsfx'] -ceq 'harness-pdc-delay' -and $delayFx['bypass'] -eq $false -and
    $null -eq $delayFx['state'] -and $null -eq $delayFx['stateSha256'] -and $delayFx['sha256'] -cmatch '^[0-9a-f]{12}$' -and $delayFx['blockSha256'] -ceq (& $blockSha 'Pad') -and
    $delayParam.Count -eq 1 -and $delayParam[0]['name'] -ceq 'Delay (samples)' -and $delayParam[0]['normalized'] -eq 0.0078125 -and $delayParam[0]['readNormalized'] -ceq '0.007812500' -and $delayParam[0]['readDisplay'] -ceq '64.0' -and
    $delayFx['pdc'] -eq 64 -and $gainFx['pdc'] -eq 0 -and $delayFx['pdcReadAt']['sr'] -eq 48000 -and $delayFx['pdcReadAt']['block'] -eq 512)
Write-Case 'end to end: keep: a render without a tail and without a reported residual: tailSeconds 0, tailFrames 0 and no end level in its line, comparison null; each FX has the version of its plugin, null for a JSFX' $false (
    $kRender['tailSeconds'] -eq 0 -and $kRender['tailFrames'] -eq 0 -and $kRender.Contains('endPeakDb') -and $null -eq $kRender['endPeakDb'] -and $kEntry.Contains('comparison') -and $null -eq $kEntry['comparison'] -and
    $gainFx['version'] -ceq '1.0.0' -and $delayFx.Contains('version') -and $null -eq $delayFx['version'])
Write-Case 'end to end: keep: every line names the REAPER, the harness version and commit, the build label, and the configuration file with its full sha256' $false (
    @($entries | Where-Object { $_['reaper'] -cne $r.reaper -or $_['toolVersion'] -cne '0.1.0' -or $_['toolCommit'] -cne $r.toolCommit -or $_['buildLabel'] -cne $r.buildLabel -or
            $_['config']['name'] -cne 'variant-config.json' -or $_['config']['sha256'] -cne (& $hashOf $keepCfg.Config) }).Count -eq 0 -and $r.toolVersion -ceq '0.1.0' -and $r.PSObject.Properties['toolCommit'])
$kFacts = (& $keepRow 'kept').facts['kept']
Write-Case 'end to end: keep: the row of a kept render repeats its line, paths relative to the result directory; a row without keep has no such facts' $false (
    $kFacts['output']['path'] -ceq "renders/$keepStamp/run1/kept.wav" -and $kFacts['stems'][0]['path'] -ceq "renders/$keepStamp/run1/kept-stem-Voice.wav" -and $kFacts['output']['sha256'] -ceq $kOut['sha256'] -and
    @($kFacts['fx']).Count -eq 2 -and -not (& $keepRow 'plain').Contains('facts'))
$twinEntry = & $entryOf 'twin'; $twinTwo = & $entryOf 'twin-stem-pad'
Write-Case "end to end: keep: a kept file is never overwritten (file names ignore case): the scenario whose file would land on another's is INCOMPLETE, its render stays in the work directory ($((& $keepRow 'twin-stem-pad').detail))" $true (
    (& $keepRow 'twin-stem-pad').status -ceq 'INCOMPLETE' -and (& $keepRow 'twin-stem-pad').detail -clike '*; not kept: twin-stem-pad.wav is there already and is never overwritten' -and
    (& $hashOf (& $keptAt 'twin-stem-Pad.wav')) -ceq $twinEntry['stems'][0]['sha256'] -and $twinTwo['status'] -ceq 'INCOMPLETE' -and $null -eq $twinTwo['output']['path'] -and
    (Test-Path -LiteralPath (Join-Path $keepWork 'twin-stem-pad.wav')))
$drivePath = '[A-Za-z]:[\\/]'
Write-Case 'end to end: keep: no local path in the manifest or in the result' $false (
    [Text.UTF8Encoding]::new($false).GetString($manifestBytes) -cnotmatch $drivePath -and (ConvertTo-HarnessJsonText -Value $r -Indent 2) -cnotmatch $drivePath)
# One kept scenario, judged on its own: the smallest run that keeps something
$soloChange = {
    param($c)
    & $noExt $c
    $c.layouts = [ordered]@{ solo = [ordered]@{ tracks = @([ordered]@{ name = 'Tone'; source = $true; fx = @(@{ plugin = 'gain' }) }) } }
    $c.scenarios = @([ordered]@{ id = 'solo'; kind = 'render'; layout = 'solo'; compare = 'none'; keep = $true })
    $c.negative = @()
}
# A reason that holds a local path (renders is a file, so renders/<stamp> cannot be made, and the exception names the
# manifest by its full path) is masked in the row, in the row's copy of the line, in the result and on the console
$maskCfg = & $writeVariant $soloChange
$maskCfg.ReaperExe = $pwshExe; $maskCfg.ResultDir = Join-Path $Work 'e2e-keep-masked'
$null = New-Item -ItemType Directory -Force -Path $maskCfg.ResultDir
[IO.File]::WriteAllText((Join-Path $maskCfg.ResultDir 'renders'), 'not a directory')
$r = Invoke-HarnessSuite @maskCfg -NoNegative -SelfTestHooks $hooks -InformationVariable maskSaid
$maskRow = @($r.runs[0].scenarios | Where-Object { $_.id -ceq 'solo' })[0]
$saidText = @($maskSaid | ForEach-Object { [string]$_.MessageData }) -join "`n"
Write-Case "end to end: keep: a reason that holds a local path is masked in the row, in its copy of the line, in the result and on the console ($($maskRow.detail))" $true (
    $maskRow.status -ceq 'INCOMPLETE' -and $maskRow.detail -clike '*; not kept: renders/* could not be made: *<path>*' -and $maskRow.facts['kept']['detail'] -ceq $maskRow.detail -and
    (ConvertTo-HarnessJsonText -Value $r -Indent 2) -cnotmatch $drivePath -and $saidText -clike '*not kept: renders/* could not be made: *<path>*' -and $saidText -cnotmatch $drivePath -and $null -eq $r.manifest)
# -Repeat 2: one directory for the run, a directory per round in it, a line per round with its number
$repeatCfg = & $writeVariant $soloChange
$repeatCfg.ReaperExe = $pwshExe; $repeatCfg.ResultDir = Join-Path $Work 'e2e-keep-repeat'
$r = Invoke-HarnessSuite @repeatCfg -NoNegative -Repeat 2 -SelfTestHooks $hooks
$repeatDirs = @(Get-ChildItem -LiteralPath (Join-Path $repeatCfg.ResultDir 'renders') -Directory)
$repeatStamp = $repeatDirs[0].Name
$repeatEntries = @([IO.File]::ReadAllLines((Join-Path $repeatDirs[0].FullName 'manifest.jsonl')) | ForEach-Object { ConvertFrom-HarnessJson $_ })
$repeatRows = @($r.runs | ForEach-Object { @($_.scenarios | Where-Object { $_.id -ceq 'solo' })[0] })
Write-Case "end to end: keep with -Repeat 2: one directory for the run, run1/ and run2/ in it, one line per round with its number, the result names the manifest ($(@($repeatRows | ForEach-Object { "$($_.status): $($_.detail)" }) -join ' | '))" $false (
    $r.verdict -ceq 'PASS' -and @($r.runs).Count -eq 2 -and $repeatDirs.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $repeatDirs[0].FullName 'run1/solo.wav')) -and (Test-Path -LiteralPath (Join-Path $repeatDirs[0].FullName 'run2/solo.wav')) -and
    $repeatEntries.Count -eq 2 -and (@($repeatEntries | ForEach-Object { "$($_['round']):$($_['output']['path'])" }) -join ',') -ceq '1:run1/solo.wav,2:run2/solo.wav' -and
    @($repeatEntries | Where-Object { $_['runStamp'] -cne $repeatStamp }).Count -eq 0 -and $r.manifest -ceq "renders/$repeatStamp/manifest.jsonl" -and
    $repeatRows.Count -eq 2 -and $repeatRows[1].facts['kept']['output']['path'] -ceq "renders/$repeatStamp/run2/solo.wav" -and $repeatRows[1].facts['kept']['round'] -eq 2)
$badKeep =& $writeVariant { param($c) & $noExt $c; @($c.scenarios | Where-Object { $_.kind -ceq 'device' })[0].keep = $true }
$badKeep.ReaperExe = $pwshExe; $badKeep.ResultDir = Join-Path $Work 'e2e-keep-bad'
$seenBefore = $seenArgs.Count
Write-Case 'end to end: keep on a scenario that is not a render is a usage error before REAPER starts' $true (
    (Test-Throws { $null = Invoke-HarnessSuite @badKeep -NoNegative -SelfTestHooks $hooks } "USAGE:*keep*") -and $seenArgs.Count -eq $seenBefore -and -not (Test-Path -LiteralPath $badKeep.ResultDir))

# ---- a residual that is only reported, and a render tail ----
# The stand-in's Drift sets one sample of every channel after the bus plugin (frame 100) to the number of the render
# times 2^-10: two renders through it differ there by exactly 2^-10 (-60.21 dBFS) and nowhere else, while the gain
# plugin stays deterministic. The delay JSFX at 64 samples, its latency not reported, moves the end of the test signal
# (24000 frames at 48000 Hz) into a tail of 0.01 s (480 frames). In 'aside' the track with the bus plugin is kept out
# of the master: its stem drifts while the master stays bit-identical.
$driftStep = [Math]::Pow(2, -10)
$plainSet = @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs }
$repChange = {
    param($c)
    & $noExt $c
    $lateDelay = [ordered]@{ plugin = 'delay'; params = [ordered]@{ 'Delay (samples)' = [ordered]@{ normalized = 0.0078125; display = '64.0' }; 'Report delay as PDC' = 0 } }
    $c.layouts = [ordered]@{
        steady = [ordered]@{ tracks = @([ordered]@{ name = 'Voice'; source = $true; fx = @([ordered]@{ plugin = 'gain' }) }) }
        drifty = [ordered]@{ tracks = @([ordered]@{ name = 'Voice'; source = $true; fx = @([ordered]@{ plugin = 'bus' }) }) }
        pair   = [ordered]@{ tracks = @([ordered]@{ name = 'A'; source = $true; fx = @([ordered]@{ plugin = 'gain' }) }, [ordered]@{ name = 'B'; source = $true; signal = @{ seed = 3 }; fx = @([ordered]@{ plugin = 'bus' }) }) }
        louder = [ordered]@{ tracks = @([ordered]@{ name = 'Voice'; source = $true; fx = @([ordered]@{ plugin = 'gain'; params = @{ Trim = 0.75 } }) }) }
        late   = [ordered]@{ tracks = @([ordered]@{ name = 'Voice'; source = $true; fx = @($lateDelay) }) }
        mixed  = [ordered]@{ tracks = @([ordered]@{ name = 'Voice'; source = $true; file = 'sources/voice.wav'; fx = @([ordered]@{ plugin = 'gain' }) }, [ordered]@{ name = 'Pad'; source = $true; signal = @{ seed = 3 } }) }
        aside  = [ordered]@{ tracks = @([ordered]@{ name = 'Voice'; source = $true; fx = @([ordered]@{ plugin = 'gain' }) }, [ordered]@{ name = 'Side'; source = $true; signal = @{ seed = 3 }; masterSend = $false; fx = @([ordered]@{ plugin = 'bus' }) }) }
    }
    $c.scenarios = @(
        [ordered]@{ id = 'rep-same'; kind = 'render'; layout = 'steady'; compare = 'repeat'; maxDiffDb = 'report' },
        [ordered]@{ id = 'rep-drift'; kind = 'render'; layout = 'drifty'; compare = 'repeat'; maxDiffDb = 'report' },
        [ordered]@{ id = 'rep-stems'; kind = 'render'; layout = 'pair'; compare = 'repeat'; maxDiffDb = 'report'; stems = @('A', [ordered]@{ track = 'B'; maxDiffDb = -40 }) },
        [ordered]@{ id = 'rep-alone'; kind = 'render'; layout = 'pair'; compare = 'repeat'; maxDiffDb = 'report'; stems = @([ordered]@{ track = 'A'; compare = 'none' }, 'B') },
        [ordered]@{ id = 'rep-variants'; kind = 'render'; layout = 'steady'; compare = 'repeat'; maxDiffDb = 'report'; variants = @([ordered]@{ id = 'a' }, [ordered]@{ id = 'b'; fx = @{ gain = @{ params = @{ Gain = 0.25 } } } }) },
        [ordered]@{ id = 'rep-dry'; kind = 'render'; layout = 'louder'; maxDiffDb = 'report' },
        [ordered]@{ id = 'rep-keep-same'; kind = 'render'; layout = 'steady'; compare = 'repeat'; maxDiffDb = 'report'; keep = $true },
        [ordered]@{ id = 'rep-keep-drift'; kind = 'render'; layout = 'drifty'; compare = 'repeat'; maxDiffDb = 'report'; keep = $true },
        [ordered]@{ id = 'rep-keep-first'; kind = 'render'; layout = 'steady'; compare = 'repeat'; maxDiffDb = 'report'; keep = $true; keepFirst = $true },
        [ordered]@{ id = 'rep-keep-stem'; kind = 'render'; layout = 'aside'; compare = 'repeat'; maxDiffDb = 'report'; keep = $true; stems = @('Voice', 'Side') },
        [ordered]@{ id = 'rep-keep-dry'; kind = 'render'; layout = 'louder'; maxDiffDb = 'report'; keep = $true },
        [ordered]@{ id = 'rep-keep-variant'; kind = 'render'; layout = 'louder'; compare = [ordered]@{ bypass = $true }; maxDiffDb = 'report'; keep = $true },
        [ordered]@{ id = 'tail-delay'; kind = 'render'; layout = 'late'; compare = 'none'; notSilent = $true; tailSeconds = 0.01 },
        [ordered]@{ id = 'tail-bypass'; kind = 'render'; layout = 'late'; compare = 'none'; notSilent = $true; bypass = $true; tailSeconds = 0.01 },
        [ordered]@{ id = 'tail-dry'; kind = 'render'; layout = 'steady'; tailSeconds = 0.01 },
        [ordered]@{ id = 'tail-dry-twin'; kind = 'render'; layout = 'steady' },
        [ordered]@{ id = 'tail-repeat'; kind = 'render'; layout = 'steady'; compare = 'repeat'; maxDiffDb = 'report'; tailSeconds = 0.01 },
        [ordered]@{ id = 'tail-variant'; kind = 'render'; layout = 'steady'; compare = [ordered]@{ bypass = $true }; maxDiffDb = 'report'; tailSeconds = 0.01 },
        [ordered]@{ id = 'tail-stems'; kind = 'render'; layout = 'pair'; compare = 'none'; stems = @('A', 'B'); tailSeconds = 0.01 },
        [ordered]@{ id = 'tail-kept'; kind = 'render'; layout = 'mixed'; sr = 44100; compare = 'none'; tailSeconds = 0.1; keep = $true },
        [ordered]@{ id = 'tail-keep-late'; kind = 'render'; layout = 'late'; compare = 'none'; notSilent = $true; tailSeconds = 0.01; keep = $true })
    $c.negative = @(
        [ordered]@{ id = 'rep-stems-judged'; kind = 'render'; layout = 'pair'; compare = 'repeat'; maxDiffDb = 'report'; stems = @('A', [ordered]@{ track = 'B'; maxDiffDb = -200 }); expect = 'FAIL'; expectDetail = '\| stem B: identical=no ' },
        [ordered]@{ id = 'rep-judged'; kind = 'render'; layout = 'drifty'; compare = 'repeat'; expect = 'FAIL'; expectDetail = '^identical=no lag=0 ' })
}
$repCfg = & $writeVariant $repChange
$repCfg.ReaperExe = $pwshExe
$repCfgIn = { param([string]$Leaf) $one = $repCfg.Clone(); $one.ResultDir = Join-Path $Work $Leaf; $one }
# A case of this section whose check, or what its label shows, throws (a fact the run did not produce) fails under its
# own name and says what threw; the child goes on, so a rule that breaks turns its own cases red and no others
function Write-SafeCase([string]$Label, [scriptblock]$Shown, [bool]$Bad, [scriptblock]$Check) {
    $text = $Label
    if ($Shown) { $text += ' (' + $(try { [string](& $Shown) } catch { "what it shows threw: $($_.Exception.Message)" }) + ')' }
    $checkOk = try { [bool](& $Check) } catch { $text += " (the check threw: $($_.Exception.Message))"; $false }
    Write-Case $text $Bad $checkOk
}
$safe = { param([scriptblock]$Get) try { & $Get } catch { $null } }
$repMain = & $repCfgIn 'e2e-report'
Set-FakeReaper ($plainSet + @{ Drift = @{ Plugin = 'Fixture Bus.vst3'; Step = $driftStep; Frame = 100 } })
$repRun = $null; $repWhy = ''
try { $repRun = Invoke-HarnessSuite @repMain -Only '^(rep|tail)-' -KeepWork -SelfTestHooks $hooks }
catch { $repWhy = $_.Exception.Message }
finally { Set-FakeReaper $plainSet }
$repRow = { param([string]$RowId) @($repRun.runs[0].scenarios | Where-Object { $_.id -ceq $RowId })[0] }
$repNotPass = @(& $safe { $repRun.runs[0].scenarios | Where-Object { $_.status -cne 'PASS' } | ForEach-Object { "$($_.id)=$($_.status): $($_.detail)" } })
Write-SafeCase "end to end: report and tail: every row passes, the two negative cases turned red for their reasons" { "$repWhy$(& $rowIds $repRun); $($repNotPass -join ' | ')" } $false {
    $repRun.verdict -ceq 'PASS' -and $repNotPass.Count -eq 0 -and (& $rowIds $repRun) -ceq ('learn,rep-same,rep-drift,rep-stems,rep-alone,rep-variants-a,rep-variants-b,rep-dry,rep-keep-same,rep-keep-drift,rep-keep-first,' +
        'rep-keep-stem,rep-keep-dry,rep-keep-variant,tail-delay,tail-bypass,tail-dry,tail-dry-twin,tail-repeat,tail-variant,tail-stems,tail-kept,tail-keep-late,rep-stems-judged,rep-judged') }
$repWork = & $safe { @(Get-ChildItem -LiteralPath (Join-Path $repMain.ResultDir 'work') -Directory)[-1].FullName }
$wavIn = { param([string]$Leaf) Read-HarnessWav (Join-Path $repWork $Leaf) }
$sameRow = & $safe { & $repRow 'rep-same' }
$sameCmp = & $safe { & $factOf $sameRow 'comparison' }
Write-SafeCase "end to end: report: a repeat of a deterministic plugin is PASS and says bit-identical; the row's comparison has the residual of the master, no residual in dB, no stems" { "$($sameRow.detail)" } $false {
    $sameRow.status -ceq 'PASS' -and $sameRow.detail -cmatch '^identical=yes lag=0 ' -and $sameRow.detail.EndsWith('; reported: bit-identical') -and $sameCmp['against'] -ceq 'repeat' -and
    $sameCmp['master']['reported'] -eq $true -and $sameCmp['master']['identical'] -eq $true -and $sameCmp['master']['maxDiff'] -eq 0 -and $sameCmp['master'].Contains('residualDb') -and
    $null -eq $sameCmp['master']['residualDb'] -and $null -eq $sameCmp['master']['firstDiffFrame'] -and @($sameCmp['stems']).Count -eq 0 -and $null -eq (& $factOf $sameRow 'tail') }
# The residual against the reference over the two files, summed here in the order the comparer sums it
$driftRow = & $safe { & $repRow 'rep-drift' }
$driftMaster = & $safe { (& $factOf $driftRow 'comparison')['master'] }
$driftRms = & $safe {
    $driftA = & $wavIn 'rep-drift-first.wav'; $driftB = & $wavIn 'rep-drift.wav'
    $diffSq = 0.0; $refSq = 0.0
    for ($k = 0; $k -lt $driftA.Samples.Length; $k++) { $dk = $driftA.Samples[$k] - $driftB.Samples[$k]; $diffSq += $dk * $dk; $refSq += $driftA.Samples[$k] * $driftA.Samples[$k] }
    [Math]::Round(10 * [Math]::Log10($diffSq / $refSq), 6)
}
Write-SafeCase "end to end: report: two renders that differ are PASS, the run stays green; the residual, its RMS against the reference, the lags, where it is largest and where it starts are reported" { "$($driftRow.detail)" } $false {
    $driftRow.status -ceq 'PASS' -and $driftRow.detail -cmatch '^identical=no lag=0 maxdiff=-60\.21 ' -and $null -ne $driftRms -and
    $driftRow.detail -cmatch ('; reported: not bit-identical, residual -60\.21 dBFS \(rms ' + [regex]::Escape(([double]$driftRms).ToString('0.00', $inv)) + ' dB against the reference\) measured at lag 0 \(expected\), best lag 0, largest at 0\.002083 s, first difference at frame 100$') -and
    $driftMaster['reported'] -eq $true -and $driftMaster['identical'] -eq $false -and $driftMaster['lag'] -eq 0 -and $driftMaster['bestLag'] -eq 0 -and $driftMaster['maxDiff'] -eq $driftStep -and
    $driftMaster['residualDb'] -eq -60.205999 -and [Math]::Abs($driftMaster['residualRmsDb'] - $driftRms) -lt 1e-6 -and $driftMaster['maxDiffFrame'] -eq 100 -and $driftMaster['maxDiffSeconds'] -eq 0.002083 -and
    $driftMaster['firstDiffFrame'] -eq 100 -and $driftMaster['frames'] -eq 24000 -and $driftMaster['referenceFrames'] -eq 24000 }
$stemsRow = & $safe { & $repRow 'rep-stems' }
$stemsCmp = & $safe { & $factOf $stemsRow 'comparison' }
$stemsListed = @(& $safe { $stemsCmp['stems'] })
Write-SafeCase "end to end: report: the master and stem A report, stem B is judged by its own looser limit: PASS, and both stems are listed, reported and judged" { "$($stemsRow.detail)" } $false {
    $stemsRow.status -ceq 'PASS' -and $stemsRow.detail -cmatch '^identical=no lag=0 [^|]*; reported: not bit-identical, residual -60\.21 dBFS [^|]* \| stem A: identical=yes [^|]*; reported: bit-identical \| stem B: identical=no lag=0 maxdiff=-60\.21 [^|;]*$' -and
    $stemsCmp['master']['identical'] -eq $false -and $stemsListed.Count -eq 2 -and $stemsListed[0]['track'] -ceq 'A' -and $stemsListed[0]['reported'] -eq $true -and $stemsListed[0]['identical'] -eq $true -and
    $stemsListed[1]['track'] -ceq 'B' -and $stemsListed[1]['reported'] -eq $false -and $stemsListed[1]['identical'] -eq $false -and $stemsListed[1]['residualDb'] -eq -60.205999 }
$judgedStem = & $safe { & $repRow 'rep-stems-judged' }
$judgedRep = & $safe { & $repRow 'rep-judged' }
Write-SafeCase "end to end: report: the stem judged bit-identical still FAILs next to a master that reports, and a repeat without report FAILs as before" { "$($judgedStem.detail) / $($judgedRep.detail)" } $true {
    $judgedStem.observed -ceq 'FAIL' -and $judgedStem.status -ceq 'PASS' -and $judgedStem.detail -cmatch '\| stem B: identical=no [^|]*; failed: residual -60\.21 dBFS above -200\.00$' -and
    $judgedRep.observed -ceq 'FAIL' -and $judgedRep.status -ceq 'PASS' -and $judgedRep.detail -cmatch '^identical=no lag=0 ' -and $judgedRep.detail.EndsWith('; failed: not bit-identical') }
$aloneRow = & $safe { & $repRow 'rep-alone' }
$aloneCmp = & $safe { & $factOf $aloneRow 'comparison' }
Write-SafeCase "end to end: report: a stem compared with none is judged on its own and left out of the comparison; the stem compared with the reference takes report from the scenario" { "$($aloneRow.detail)" } $false {
    $aloneRow.status -ceq 'PASS' -and $aloneRow.detail -cmatch '\| stem A: frames=24000 channels=2 [^|]* \| stem B: identical=no [^|]*; reported: not bit-identical, residual -60\.21 dBFS ' -and
    @($aloneCmp['stems']).Count -eq 1 -and @($aloneCmp['stems'])[0]['track'] -ceq 'B' -and @($aloneCmp['stems'])[0]['reported'] -eq $true -and $aloneCmp['master']['reported'] -eq $true }
$variantCmp = @(foreach ($variantId in 'rep-variants-a', 'rep-variants-b') { & $safe { & $factOf (& $repRow $variantId) 'comparison' } })
Write-SafeCase 'end to end: report: each variant of a reporting repeat has a comparison of its own, rendered twice (its first render and its own in the work directory)' $null $false {
    $variantCmp.Count -eq 2 -and @($variantCmp | Where-Object { $null -eq $_ -or $_['against'] -cne 'repeat' -or $_['master']['identical'] -ne $true }).Count -eq 0 -and
    @('rep-variants-a', 'rep-variants-b' | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repWork "$_-first.wav")) -or -not (Test-Path -LiteralPath (Join-Path $repWork "$_.wav")) }).Count -eq 0 -and
    (& $factOf (& $repRow 'rep-variants-b') 'variant') -ceq 'b' }
$dryRow = & $safe { & $repRow 'rep-dry' }
$dryMaster = & $safe { (& $factOf $dryRow 'comparison')['master'] }
Write-SafeCase "end to end: report against dry: a gain of 1.5 is PASS, its residual is half the impulse of 1.0 (-6.0206 dBFS at 0.25 s)" { "$($dryRow.detail)" } $false {
    $dryRow.status -ceq 'PASS' -and $dryRow.detail -cmatch '^identical=no lag=0 maxdiff=-6\.02 ' -and (& $factOf $dryRow 'comparison')['against'] -ceq 'dry' -and $dryMaster['maxDiff'] -eq 0.5 -and
    $dryMaster['residualDb'] -eq [Math]::Round(20 * [Math]::Log10(0.5), 6) -and $dryMaster['maxDiffFrame'] -eq 12000 -and $dryMaster['maxDiffSeconds'] -eq 0.25 -and [Math]::Abs($dryMaster['residualRmsDb'] - 20 * [Math]::Log10(0.5)) -lt 0.001 }
# Kept renders of a reporting repeat: the first one too when the two differ, or with keepFirst
$repKeepDir = & $safe { @(Get-ChildItem -LiteralPath (Join-Path $repMain.ResultDir 'renders') -Directory)[0].FullName }
$repStamp = & $safe { Split-Path -Leaf $repKeepDir }
$repEntries = @(& $safe { [IO.File]::ReadAllLines((Join-Path $repKeepDir 'manifest.jsonl')) | Where-Object { $_ } | ForEach-Object { ConvertFrom-HarnessJson $_ } })
$repEntry = { param([string]$EntryId) @($repEntries | Where-Object { $_['scenario'] -ceq $EntryId })[0] }
$repKept = [string[]]@(& $safe { Get-ChildItem -LiteralPath $repKeepDir -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($repKeepDir, $_.FullName) -replace '\\', '/' } })
[Array]::Sort($repKept, [StringComparer]::Ordinal)
# The comparison of a line against the one of its row, both as JSON, without first (only the line has it)
$noFirst = { param($Cmp) $back = ConvertFrom-HarnessJson (ConvertTo-HarnessJsonText -Value $Cmp); $back.Remove('first'); ConvertTo-HarnessJsonText -Value $back }
$keepSame = & $safe { & $repEntry 'rep-keep-same' }; $keepDrift = & $safe { & $repEntry 'rep-keep-drift' }; $keepForced = & $safe { & $repEntry 'rep-keep-first' }
Write-SafeCase "end to end: report and keep: two identical renders keep only the second, comparison.first is null, the first stays a work file; two that differ keep both; keepFirst keeps both anyway; a stem that differs keeps the first with its stems; against dry or a variant only the render is kept" { "$($repKept -join ', ')" } $false {
    ($repKept -join ',') -ceq ('manifest.jsonl,run1/rep-keep-drift-first.wav,run1/rep-keep-drift.wav,run1/rep-keep-dry.wav,run1/rep-keep-first-first.wav,run1/rep-keep-first.wav,run1/rep-keep-same.wav,' +
        'run1/rep-keep-stem-first-stem-Side.wav,run1/rep-keep-stem-first-stem-Voice.wav,run1/rep-keep-stem-first.wav,run1/rep-keep-stem-stem-Side.wav,run1/rep-keep-stem-stem-Voice.wav,run1/rep-keep-stem.wav,' +
        'run1/rep-keep-variant.wav,run1/tail-keep-late.wav,run1/tail-kept.wav') -and
    $keepSame['comparison'] -is [System.Collections.IDictionary] -and $keepSame['comparison'].Contains('first') -and $null -eq $keepSame['comparison']['first'] -and (Test-Path -LiteralPath (Join-Path $repWork 'rep-keep-same-first.wav')) -and
    -not (Test-Path -LiteralPath (Join-Path $repWork 'rep-keep-drift-first.wav')) -and $keepForced['comparison'] -is [System.Collections.IDictionary] -and $keepForced['comparison']['first'] -is [System.Collections.IDictionary] -and $keepForced['comparison']['first']['path'] -ceq 'run1/rep-keep-first-first.wav' -and $keepForced['comparison']['master']['identical'] -eq $true }
$keptFirst = & $safe { $keepDrift['comparison']['first'] }
Write-SafeCase "end to end: report and keep: the line's comparison is the row's, with the first render described like a kept file (path, sha256 of the file on disk, frames, channels, rate, format, peak, NaN and Inf counts)" { ($keptFirst -is [System.Collections.IDictionary]) ? "$($keptFirst['path'])" : 'the line has no comparison.first' } $false {
    $keepDrift['comparison'] -is [System.Collections.IDictionary] -and $keepSame['comparison'] -is [System.Collections.IDictionary] -and $keptFirst -is [System.Collections.IDictionary] -and
    (& $noFirst $keepDrift['comparison']) -ceq (& $noFirst (& $factOf (& $repRow 'rep-keep-drift') 'comparison')) -and (& $noFirst $keepSame['comparison']) -ceq (& $noFirst (& $factOf (& $repRow 'rep-keep-same') 'comparison')) -and
    $keptFirst['path'] -ceq 'run1/rep-keep-drift-first.wav' -and $keptFirst['sha256'] -ceq (& $hashOf (Join-Path $repKeepDir 'run1/rep-keep-drift-first.wav')) -and $keptFirst['frames'] -eq 24000 -and
    $keptFirst['channels'] -eq 2 -and $keptFirst['sampleRate'] -eq 48000 -and $keptFirst['format'] -ceq 'float32' -and $null -ne $keptFirst['peakDb'] -and $keptFirst['nanCount'] -eq 0 -and $keptFirst['infCount'] -eq 0 -and
    $keptFirst.Contains('stems') -and @($keptFirst['stems']).Count -eq 0 -and
    $keepDrift['comparison']['master']['identical'] -eq $false -and $keepDrift['render']['tailSeconds'] -eq 0 -and $keepDrift['render']['tailFrames'] -eq 0 -and
    (& $factOf (& $repRow 'rep-keep-drift') 'kept')['comparison']['first']['path'] -ceq "renders/$repStamp/run1/rep-keep-drift-first.wav" }
# A stem compared with the reference that differs while the master is identical: the first render is kept with the
# stems it rendered, each described like a kept file, and the row's copy names them under renders/
$keepStem = & $safe { & $repEntry 'rep-keep-stem' }
$stemFirst = & $safe { $keepStem['comparison']['first'] }
$stemFirstStems = @(& $safe { $stemFirst['stems'] })
$stemRowFirst = & $safe { (& $factOf (& $repRow 'rep-keep-stem') 'kept')['comparison']['first'] }
Write-SafeCase "end to end: report and keep: a stem that differs next to an identical master keeps the first render and its stems (<id>-first-stem-<track>.wav), each in comparison.first.stems like a kept file, under renders/ in the row's copy" { "$((& $repRow 'rep-keep-stem').detail)" } $false {
    (& $repRow 'rep-keep-stem').status -ceq 'PASS' -and $keepStem['comparison'] -is [System.Collections.IDictionary] -and $keepStem['comparison']['master']['identical'] -eq $true -and
    (@($keepStem['comparison']['stems'] | ForEach-Object { "$($_['track'])=$($_['identical'])" }) -join ',') -ceq 'Voice=True,Side=False' -and
    $stemFirst -is [System.Collections.IDictionary] -and $stemFirst['path'] -ceq 'run1/rep-keep-stem-first.wav' -and $stemFirst['sha256'] -ceq (& $hashOf (Join-Path $repKeepDir 'run1/rep-keep-stem-first.wav')) -and
    (@($stemFirstStems | ForEach-Object { "$($_['track'])=$($_['path'])" }) -join ',') -ceq 'Voice=run1/rep-keep-stem-first-stem-Voice.wav,Side=run1/rep-keep-stem-first-stem-Side.wav' -and
    @($stemFirstStems | Where-Object { $_['sha256'] -cne (& $hashOf (Join-Path $repKeepDir $_['path'])) -or $_['frames'] -ne 24000 -or $_['channels'] -ne 2 -or $_['sampleRate'] -ne 48000 -or $_['format'] -cne 'float32' -or
            $null -eq $_['peakDb'] -or $_['nanCount'] -ne 0 -or $_['infCount'] -ne 0 }).Count -eq 0 -and
    $stemRowFirst['path'] -ceq "renders/$repStamp/run1/rep-keep-stem-first.wav" -and
    (@($stemRowFirst['stems'] | ForEach-Object { $_['path'] }) -join ',') -ceq "renders/$repStamp/run1/rep-keep-stem-first-stem-Voice.wav,renders/$repStamp/run1/rep-keep-stem-first-stem-Side.wav" }
# Against dry or a variant there is no first render: a kept row that reports and differs keeps the render alone
$keepDry = & $safe { & $repEntry 'rep-keep-dry' }; $keepVariant = & $safe { & $repEntry 'rep-keep-variant' }
Write-SafeCase "end to end: report and keep: a kept render that reports against dry or against a variant and differs is PASS, and its line has comparison.first null" { "$((& $repRow 'rep-keep-dry').detail) / $((& $repRow 'rep-keep-variant').detail)" } $false {
    (& $repRow 'rep-keep-dry').status -ceq 'PASS' -and (& $repRow 'rep-keep-variant').status -ceq 'PASS' -and
    @($keepDry, $keepVariant | Where-Object { $_ -isnot [System.Collections.IDictionary] -or $_['status'] -cne 'PASS' -or $_['comparison'] -isnot [System.Collections.IDictionary] -or -not $_['comparison'].Contains('first') -or
            $null -ne $_['comparison']['first'] -or $_['comparison']['master']['identical'] -ne $false }).Count -eq 0 -and
    $keepDry['comparison']['against'] -ceq 'dry' -and $keepVariant['comparison']['against'] -ceq 'variant' }
# The tail: each item is longer by it and plays its source once; the render is checked to have that length
$tailRow = & $safe { & $repRow 'tail-delay' }
$tailFacts = & $safe { & $factOf $tailRow 'tail' }
$tailWav = & $safe { & $wavIn 'tail-delay.wav' }
$sigWav = & $safe { & $wavIn '_signal-48000-2-0.wav' }
$shiftBad = & $safe { @(for ($k = 24000 * 2; $k -lt 24064 * 2; $k++) { if ($tailWav.Samples[$k] -ne $sigWav.Samples[$k - 128]) { $k } }).Count }
$tailLoud = & $safe { @(for ($k = 24064 * 2; $k -lt $tailWav.Samples.Length; $k++) { if ($tailWav.Samples[$k] -ne 0) { $k } }).Count }
$sigEndPeak = & $safe { $endMax = 0.0; for ($k = 19616 * 2; $k -lt 24000 * 2; $k++) { $endMax = [Math]::Max($endMax, [Math]::Abs($sigWav.Samples[$k])) }; $endMax }
$tailRpp = & $safe { [IO.File]::ReadAllText((Join-Path $repWork 'tail-delay.rpp')) }
Write-SafeCase "end to end: tail: a delay of 64 samples whose latency is not reported moves the end of the signal into the tail: 24480 frames, render[24000..24063] = signal[23936..23999], silence after; the end level is recorded" { "$($tailRow.detail); $($tailFacts['endPeakDb'])" } $false {
    $tailRow.status -ceq 'PASS' -and $tailWav.Frames -eq 24480 -and $shiftBad -eq 0 -and $tailLoud -eq 0 -and $tailFacts['seconds'] -eq 0.01 -and $tailFacts['frames'] -eq 480 -and $tailFacts['renderFrames'] -eq 24480 -and
    $sigEndPeak -gt 0 -and $tailFacts['endPeakDb'] -eq [Math]::Round(20 * [Math]::Log10($sigEndPeak), 6) -and @($tailFacts['stems']).Count -eq 0 -and $null -eq (& $factOf $tailRow 'comparison') -and
    $tailRpp -cmatch "\n      LENGTH $([regex]::Escape((Get-HarnessItemLength 24480 48000).ToString('R', $inv)))\n      LOOP 0\n" }
$bypassWav = & $safe { & $wavIn 'tail-bypass.wav' }
$bypassBad = & $safe { @(for ($k = 0; $k -lt $bypassWav.Samples.Length; $k++) { if ($bypassWav.Samples[$k] -ne (($k -lt 48000) ? $sigWav.Samples[$k] : 0.0)) { $k } }).Count }
Write-SafeCase "end to end: tail: bypassed, the render is the signal and then exactly silence, not the signal again (its item plays once)" { "$bypassBad samples off" } $false {
    (& $repRow 'tail-bypass').status -ceq 'PASS' -and $bypassWav.Frames -eq 24480 -and $bypassBad -eq 0 }
$dryRefs = @(& $safe { Get-ChildItem -LiteralPath $repWork -Filter '_dry-steady-*.wav' | ForEach-Object { $_.Name } | Sort-Object })
Write-SafeCase "end to end: tail: a dry reference with a tail is another render than one without, both made in one round" { "$($dryRefs -join ', ')" } $false {
    (& $repRow 'tail-dry').status -ceq 'PASS' -and (& $repRow 'tail-dry-twin').status -ceq 'PASS' -and ($dryRefs -join ',') -ceq '_dry-steady-48000-512-offline-2-tail480.wav,_dry-steady-48000-512-offline-2.wav' -and
    (Read-HarnessWavHeader (Join-Path $repWork '_dry-steady-48000-512-offline-2-tail480.wav')).Frames -eq 24480 -and (Read-HarnessWavHeader (Join-Path $repWork '_dry-steady-48000-512-offline-2.wav')).Frames -eq 24000 }
$tailRepCmp = & $safe { & $factOf (& $repRow 'tail-repeat') 'comparison' }
Write-SafeCase 'end to end: tail: both renders of a reporting repeat have the tail, and they are identical' $null $false {
    (& $repRow 'tail-repeat').status -ceq 'PASS' -and $tailRepCmp['master']['identical'] -eq $true -and $tailRepCmp['master']['frames'] -eq 24480 -and $tailRepCmp['master']['referenceFrames'] -eq 24480 -and
    (& $factOf (& $repRow 'tail-repeat') 'tail')['renderFrames'] -eq 24480 }
$tailStemFacts = & $safe { & $factOf (& $repRow 'tail-stems') 'tail' }
# The peak of the last 100 ms of a render, read here sample by sample
$endPeakOf = {
    param([string]$Leaf)
    $endWav = & $wavIn $Leaf
    $endFrom = $endWav.Frames - [Math]::Min($endWav.Frames, [long][Math]::Round(0.1 * $endWav.Rate, [MidpointRounding]::AwayFromZero))
    $endTop = 0.0
    for ($k = $endFrom * $endWav.Channels; $k -lt $endWav.Samples.Length; $k++) { $endTop = [Math]::Max($endTop, [Math]::Abs($endWav.Samples[$k])) }
    ($endTop -gt 0) ? [Math]::Round(20 * [Math]::Log10($endTop), 6) : $null
}
$stemEnds = @(& $safe { foreach ($endLeaf in 'Master', 'A', 'B') { & $endPeakOf "tail-stems-stem-$endLeaf.wav" } })
Write-SafeCase 'end to end: tail: the master and every stem have the tail; the master and each stem have the end level of their own file (three levels, none null, all different)' { "$($stemEnds -join ' / ')" } $false {
    (& $repRow 'tail-stems').status -ceq 'PASS' -and @('Master', 'A', 'B' | Where-Object { (Read-HarnessWavHeader (Join-Path $repWork "tail-stems-stem-$_.wav")).Frames -ne 24480 }).Count -eq 0 -and
    (@($tailStemFacts['stems'] | ForEach-Object { $_['track'] }) -join ',') -ceq 'A,B' -and $stemEnds.Count -eq 3 -and @($stemEnds | Where-Object { $null -eq $_ }).Count -eq 0 -and
    @($stemEnds | Select-Object -Unique).Count -eq 3 -and $tailStemFacts['endPeakDb'] -eq $stemEnds[0] -and @($tailStemFacts['stems'])[0]['endPeakDb'] -eq $stemEnds[1] -and
    @($tailStemFacts['stems'])[1]['endPeakDb'] -eq $stemEnds[2] }
$tailKept = & $safe { & $repEntry 'tail-kept' }
$keptRpp = & $safe { [IO.File]::ReadAllText((Join-Path $repWork 'tail-kept.rpp')) }
$lengthLine = { param([long]$LengthFrames, [int]$LengthRate) "\n      LENGTH $([regex]::Escape((Get-HarnessItemLength $LengthFrames $LengthRate).ToString('R', $inv)))\n      LOOP 0\n" }
Write-SafeCase "end to end: tail: a kept render with a tail at 44100 Hz: the line has tailSeconds and tailFrames, the file the longer source and the tail, each item its own source and the tail to the frame" { "$($tailKept['output']['frames']) frames" } $false {
    $tailKept['render']['tailSeconds'] -eq 0.1 -and $tailKept['render']['tailFrames'] -eq 4410 -and $tailKept['output']['frames'] -eq $voiceFrames + 4410 -and $tailKept['render'].Contains('endPeakDb') -and
    $null -eq $tailKept['render']['endPeakDb'] -and $null -eq $tailKept['comparison'] -and @($tailKept['sources'])[0]['file']['frames'] -eq $voiceFrames -and
    (& $trackPart $keptRpp 'Voice') -cmatch (& $lengthLine ($voiceFrames + 4410) 44100) -and (& $trackPart $keptRpp 'Pad') -cmatch (& $lengthLine (22050 + 4410) 44100) }
$lateKept = & $safe { & $repEntry 'tail-keep-late' }
$lateTail = & $safe { & $factOf (& $repRow 'tail-keep-late') 'tail' }
Write-SafeCase "end to end: tail and keep: a kept render whose end is audible: the line's render.endPeakDb is the row's tail.endPeakDb, the level of the delayed end of the signal" { "line $(& $safe { $lateKept['render']['endPeakDb'] }), row $(& $safe { $lateTail['endPeakDb'] })" } $false {
    (& $repRow 'tail-keep-late').status -ceq 'PASS' -and $sigEndPeak -gt 0 -and $lateTail['endPeakDb'] -eq [Math]::Round(20 * [Math]::Log10($sigEndPeak), 6) -and
    $lateKept['render']['endPeakDb'] -eq $lateTail['endPeakDb'] -and $lateKept['render']['tailFrames'] -eq 480 -and $lateKept['output']['frames'] -eq 24480 }
$isTailed = { param([string]$RppName) ($RppName -clike 'tail-*' -and $RppName -cnotlike 'tail-dry-twin*') -or $RppName -clike '*-tail480.rpp' }
$rppAll = @(& $safe { Get-ChildItem -LiteralPath $repWork -Filter '*.rpp' })
$loopWrong = @(& $safe { $rppAll | Where-Object { ([IO.File]::ReadAllText($_.FullName) -cmatch '(?m)^      LOOP 0$') -ne (& $isTailed $_.Name) } | ForEach-Object { $_.Name } })
Write-SafeCase "end to end: tail: a project has LOOP lines exactly when it renders a tail, the references and first renders included; without one the text is as before" { "$($loopWrong -join ', ')" } $false {
    $loopWrong.Count -eq 0 -and @($rppAll | Where-Object { & $isTailed $_.Name }).Count -eq 11 -and @($rppAll | Where-Object { [IO.File]::ReadAllText($_.FullName) -cmatch 'LOOP [^0]' }).Count -eq 0 }
# A render that is shorter than asked: the tail was not rendered, which is no evidence (REAPER ignoring the longer item)
$lostCfg = & $repCfgIn 'e2e-report-lost'
Set-FakeReaper ($plainSet + @{ TailLost = $true })
$lostRun = $null; $lostWhy = ''
try { $lostRun = Invoke-HarnessSuite @lostCfg -Only '^tail-(delay|dry|repeat|variant|stems)$' -NoNegative -SelfTestHooks $hooks }
catch { $lostWhy = $_.Exception.Message }
finally { Set-FakeReaper $plainSet }
$lostRows = @(& $safe { $lostRun.runs[0].scenarios | Where-Object { $_.kind -ceq 'render' } | ForEach-Object { "$($_.id)=$($_.status): $($_.detail)" } })
$lostOf = { param([string]$RowId) @($lostRows | Where-Object { $_.StartsWith("$RowId=") }) -join ' | ' }
$lostEnd = ' has 24000 frames, not 24480: the tail was not rendered as asked'
Write-SafeCase "end to end: tail: a render without the tail it was asked for is INCOMPLETE, the master or a stem named with its frames" { "$lostWhy$($lostRows -join ' | ')" } $true {
    $lostRun.verdict -ceq 'INCOMPLETE' -and $lostRows.Count -eq 5 -and (& $lostOf 'tail-delay') -ceq "tail-delay=INCOMPLETE: the render tail-delay.wav$lostEnd" -and
    (& $lostOf 'tail-stems') -ceq "tail-stems=INCOMPLETE: the render tail-stems-stem-Master.wav$lostEnd" }
# The references are checked for the tail like the render: the one that lacks it is named, before the render is made
foreach ($lostWant in @(
        @{ L = 'the dry reference'; W = 'tail-dry=INCOMPLETE: the dry reference render failed: the render _dry-steady-48000-512-offline-2-tail480.wav' }
        @{ L = 'the first render of a repeat'; W = 'tail-repeat=INCOMPLETE: the first render failed: the render tail-repeat-first.wav' }
        @{ L = 'the render of the variant compared with'; W = 'tail-variant=INCOMPLETE: the variant render failed: the render tail-variant-variant.wav' })) {
    $lostId = $lostWant.W.Split('=')[0]
    Write-SafeCase "end to end: tail: $($lostWant.L) without the tail it was asked for makes the scenario INCOMPLETE, naming that render" { & $lostOf $lostId } $true {
        (& $lostOf $lostId) -ceq "$($lostWant.W)$lostEnd" }
}
# Either render of a repeat that wrote no file
$skipRows = @(foreach ($skipAt in 1, 2) {
        $skipCfg = & $repCfgIn "e2e-report-skip$skipAt"
        Set-FakeReaper ($plainSet + @{ RenderSkip = $skipAt })
        try {
            $skipRun = Invoke-HarnessSuite @skipCfg -Only '^rep-same$' -NoNegative -SelfTestHooks $hooks
            "$($skipRun.verdict) $(@($skipRun.runs[0].scenarios | Where-Object { $_.id -ceq 'rep-same' } | ForEach-Object { "$($_.status): $($_.detail)" }))"
        }
        catch { "threw: $($_.Exception.Message)" }
        finally { Set-FakeReaper $plainSet }
    })
Write-SafeCase "end to end: report: a repeat whose first or second render wrote no file is INCOMPLETE, with the render named" { "$($skipRows -join ' | ')" } $true {
    ($skipRows -join ' | ') -ceq 'INCOMPLETE INCOMPLETE: the first render failed: the render produced no file | INCOMPLETE INCOMPLETE: the render produced no file' }
# Without -KeepWork: a green round removes the first render that is not kept; two launches per reporting repeat
$cleanCfg = & $repCfgIn 'e2e-report-clean'
$launchLabels.Clear()
$null = & (Get-Module Scenarios) { param($s) Set-Item function:script:Invoke-HarnessLaunch $s } $labelLaunch
$cleanRun = $null; $cleanWhy = ''
try { $cleanRun = Invoke-HarnessSuite @cleanCfg -Only '^rep-(keep-same|variants-a|variants-b)$' -NoNegative -SelfTestHooks $hooks }
catch { $cleanWhy = $_.Exception.Message }
finally { $null = & (Get-Module Scenarios) { param($s) Set-Item function:script:Invoke-HarnessLaunch $s } $realLaunch }
$cleanWork = Join-Path $cleanCfg.ResultDir 'work'
$cleanLeft = @((Test-Path -LiteralPath $cleanWork) ? @(Get-ChildItem -LiteralPath $cleanWork -Recurse -File) : @())
$cleanKept = @(& $safe { Get-ChildItem -LiteralPath (Join-Path $cleanCfg.ResultDir 'renders') -Recurse -File | ForEach-Object { $_.Name } | Sort-Object })
Write-SafeCase "end to end: report: two launches each for a kept repeat and two variants; after the green round the first renders are gone with the other work files, only the second is kept" { "$cleanWhy$($launchLabels -join ','); $($cleanKept -join ',')" } $false {
    $cleanRun.verdict -ceq 'PASS' -and @($launchLabels | Where-Object { $_ -ceq 'render' }).Count -eq 6 -and $launchLabels.Count -eq $cleanRun.launches -and $cleanLeft.Count -eq 0 -and
    ($cleanKept -join ',') -ceq 'manifest.jsonl,rep-keep-same.wav' }

# A feed file of the configuration: installed as it is, named with its hash; at another rate a usage error
$feedWav = Join-Path $Work 'feeds\voice.wav'
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $feedWav)
New-HarnessSignalFile -Path $feedWav -Rate 48000 -Channels 1 -Seconds 0.5
New-HarnessSignalFile -Path (Join-Path $Work 'feeds\slow.wav') -Rate 44100 -Channels 2 -Seconds 0.1
$withFeed = {
    param([string]$Wav, [string]$Channels)
    $v = & $writeVariant {
        param($c)
        & $noExt $c
        $one = @($c.scenarios | Where-Object { $_.id -ceq 'monitor-states' })[0]
        $one.feed = @{ wav = $Wav; channels = $Channels }
        $one.states[1].expect.channels = $Channels
        $c.scenarios = @($one); $c.negative = @()
    }
    $v.ReaperExe = $pwshExe; $v.ResultDir = $e2e.ResultDir; $v
}
$fed = & $withFeed 'feeds/voice.wav' 'same'
$r = Invoke-HarnessSuite @fed -NoNegative -SelfTestHooks $hooks
$fedRow = @($r.runs[0].scenarios | Where-Object { $_.id -ceq 'monitor-states' })[0]
$feedSha = (Get-FileHash -LiteralPath $feedWav -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Case 'end to end: a feed file of the configuration is installed as it is and named in the facts with its hash; a mono file plays the same on both sides' $false (
    $r.verdict -ceq 'PASS' -and $null -ne $fedRow -and $fedRow.status -ceq 'PASS' -and $fedRow.facts.feed.source -ceq 'feeds/voice.wav' -and $fedRow.facts.feed.sha256 -ceq $feedSha.Substring(0, 12) -and
    (Get-FileHash -LiteralPath (Join-Path $pinned.Dir 'Data\reaper-harness\feed.wav') -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $feedSha -and
    $fedRow.detail -clike '*| stopped-armed-on: blocks=10/10 silent=0 signal=10 left=10 right=10 same=10 *')
$slow = & $withFeed 'feeds/slow.wav' 'different'
$seenBefore = $seenArgs.Count
Write-Case 'end to end: a feed file at another rate is a usage error before REAPER starts' $true (
    (Test-Throws { $null = Invoke-HarnessSuite @slow -NoNegative -SelfTestHooks $hooks } 'USAGE: feeds: 1 problem(s): monitor-states: *nothing is resampled*') -and $seenArgs.Count -eq $seenBefore)
# Something recorded: a file in the record directory of the project is FAIL, whatever the states say
Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; RecordFor = 'monitor-states' }
try { $r = Invoke-HarnessSuite @e2e -Only '^monitor-states$' -NoNegative -SelfTestHooks $hooks }
finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
$recRow = @($r.runs[0].scenarios | Where-Object { $_.id -ceq 'monitor-states' })[0]
# A block probe that is not first in the chain: the numbers would not be what the plugin gets
Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; ProbeIdx = 1 }
try { $gapRun = Invoke-HarnessSuite @e2e -Only '^monitor-states$' -NoNegative -SelfTestHooks $hooks }
finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
$gapRow = @($gapRun.runs[0].scenarios | Where-Object { $_.id -ceq 'monitor-states' })[0]
Write-Case 'end to end: a block probe that is not first in the chain makes the row INCOMPLETE, never PASS or FAIL' $true (
    $gapRun.verdict -ceq 'INCOMPLETE' -and $null -ne $gapRow -and $gapRow.status -ceq 'INCOMPLETE' -and $gapRow.detail -clike "the block probe of the tested track is not the harness's own first in its chain (idx 1*")
# A feed that played nothing in an armed state whose chain must be silent (it would pass for the wrong reason), and a feed
# that never ran although a state arms the track: no evidence
Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; FeedIdle = 'playing-auto' }
try { $idleRun = Invoke-HarnessSuite @e2e -Only '^monitor-states$' -NoNegative -SelfTestHooks $hooks }
finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
$idleRow = @($idleRun.runs[0].scenarios | Where-Object { $_.id -ceq 'monitor-states' })[0]
Write-Case 'end to end: a feed that played nothing in an armed state makes that state and the row INCOMPLETE, where "silent" would pass' $true (
    $idleRun.verdict -ceq 'INCOMPLETE' -and $null -ne $idleRow -and $idleRow.status -ceq 'INCOMPLETE' -and $idleRow.detail -clike '*playing-auto: *; no evidence: the feed played no block in the window although the track is armed*' -and
    @($idleRow.facts.states | Where-Object { $_.name -ceq 'playing-auto' })[0].status -ceq 'INCOMPLETE' -and @($idleRow.facts.states | Where-Object { $_.name -ceq 'stopped-armed-on' })[0].status -ceq 'PASS' -and
    @($idleRow.facts.states | Where-Object { $_.name -ceq 'stopped-armed-on' })[0].fed -gt 0)
Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; FeedIdle = '*' }
try { $deadRun = Invoke-HarnessSuite @e2e -Only '^monitor-states$' -NoNegative -SelfTestHooks $hooks }
finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
$deadRow = @($deadRun.runs[0].scenarios | Where-Object { $_.id -ceq 'monitor-states' })[0]
Write-Case 'end to end: a feed that never ran although a state arms the track makes the row INCOMPLETE' $true (
    $deadRun.verdict -ceq 'INCOMPLETE' -and $null -ne $deadRow -and $deadRow.status -ceq 'INCOMPLETE' -and $deadRow.detail -ceq 'the feed never ran although a state arms the track')
# A record path that does not read back: the step stops before it arms anything, and the row is INCOMPLETE
Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; RecordPathFails = $true }
try { $pathRun = Invoke-HarnessSuite @e2e -Only '^monitor-states$' -NoNegative -SelfTestHooks $hooks }
finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
$pathRow = @($pathRun.runs[0].scenarios | Where-Object { $_.id -ceq 'monitor-states' })[0]
Write-Case 'end to end: a record path that does not read back ends the transport step before anything is armed: the row is INCOMPLETE and has no states' $true (
    $pathRun.verdict -ceq 'INCOMPLETE' -and $null -ne $pathRow -and $pathRow.status -ceq 'INCOMPLETE' -and
    $pathRow.detail -ceq 'the Lua driver reported an error: the record path of the project could not be set to the work directory; nothing was armed')
# A state without a clean reading of its counts: that state is not observed, the others are judged
Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; Unread = 'playing-auto' }
try { $unreadRun = Invoke-HarnessSuite @e2e -Only '^monitor-states$' -NoNegative -SelfTestHooks $hooks }
finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
$unreadRow = @($unreadRun.runs[0].scenarios | Where-Object { $_.id -ceq 'monitor-states' })[0]
Write-Case 'end to end: a state without a clean reading of its counts is not observed: that state and the row are INCOMPLETE, the others are judged' $true (
    $unreadRun.verdict -ceq 'INCOMPLETE' -and $null -ne $unreadRow -and $unreadRow.status -ceq 'INCOMPLETE' -and $unreadRow.detail -clike '*playing-auto: not observed*' -and
    @($unreadRow.facts.states | Where-Object { $_.name -ceq 'playing-auto' })[0].status -ceq 'INCOMPLETE' -and @($unreadRow.facts.states | Where-Object { $_.name -ceq 'stopped-armed-on' })[0].status -ceq 'PASS')
# A plugin that reports its own counts, and a window opened and closed while a state runs: the variable reaches the
# REAPER of the step and nothing else, the readings are judged by how much the fields grew in the state's window
$reportChange = {
    param($c)
    & $noExt $c
    $c.plugins.gain.report = @{ env = 'FIXTURE_REPORT_JSON'; fields = @('blocks', 'opens'); pid = 'pid'; periodMs = 100 }
    $one = @($c.scenarios | Where-Object { $_.id -ceq 'monitor-states' })[0]
    $one.states[1].windows = @{ plugin = 'gain'; count = 3 }
    $one.states[1].expect.report = [ordered]@{ gain = [ordered]@{ opens = @{ delta = 10 }; blocks = @{ delta = @{ min = 1 } } } }
    $one.host = @{ informOfflineState = $false }
    $c.scenarios = @($one); $c.negative = @()
}
$reportCfg = & $writeVariant $reportChange
$reportCfg.ReaperExe = $pwshExe; $reportCfg.ResultDir = $e2e.ResultDir
$envSeen = [Collections.Generic.List[string]]::new()
$reportRun = {
    param([hashtable]$SpecPlus = @{}, [hashtable]$RunCfg = $reportCfg)
    $spec = @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; EnvName = 'FIXTURE_REPORT_JSON'; EnvSeen = $envSeen }
    foreach ($k in $SpecPlus.get_Keys()) { $spec[$k] = $SpecPlus[$k] }
    $envSeen.Clear()
    Set-FakeReaper $spec
    try { $run = Invoke-HarnessSuite @RunCfg -NoNegative -SelfTestHooks $hooks }
    finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
    [pscustomobject]@{ Run = $run; Row = @($run.runs[0].scenarios | Where-Object { $_.id -ceq 'monitor-states' })[0]; Env = @($envSeen) }
}
$stateOf = { param($ResultRow) try { @($ResultRow.facts.states | Where-Object { $_.name -ceq 'stopped-armed-on' })[0] } catch { $null } }
$rp = & $reportRun
$armedState = & $stateOf $rp.Row
$stepEnv = @($rp.Env | Where-Object { $_ })
Write-Case "end to end: a reporting plugin with its window opened 3 times: PASS, the state's facts hold the window counts and every field's start, end and growth ($($rp.Row.detail))" $false (& $holds {
        $rp.Run.verdict -ceq 'PASS' -and $rp.Row.status -ceq 'PASS' -and $armedState.status -ceq 'PASS' -and $armedState.win_open -eq 3 -and $armedState.win_closed -eq 3 -and
        $armedState.report.gain.opens.delta -eq 10 -and $armedState.report.gain.blocks.end -eq 22 -and $rp.Row.detail -clike '*stopped-armed-on: * windows=3/3 of 3 report gain.opens=22 (+10) gain.blocks=22 (+10)*' })
Write-Case "end to end: the report variable is set for the transport step's REAPER only, to a file in the work directory, and never in the harness's own process ($($rp.Env.Count) launches)" $true (
    $stepEnv.Count -eq 1 -and $stepEnv[0] -clike '*\monitor-states.report-gain.json' -and $rp.Env.Count -gt 1 -and [string]::IsNullOrEmpty($env:FIXTURE_REPORT_JSON))
# The driver's copies of a report are the plugin's own text: none may be left in the results, whatever the outcome
$copiesLeft = { @(Get-ChildItem -LiteralPath (Join-Path $e2e.ResultDir 'work') -Recurse -File -Filter '*.report-*.copy-*.json' -ErrorAction SilentlyContinue).Count }
Write-Case "end to end: a green round with a reporting plugin leaves no copy of a report in the results ($(& $copiesLeft) left)" $true ($rp.Run.verdict -ceq 'PASS' -and (& $copiesLeft) -eq 0)
$leftAfter = [Collections.Generic.List[string]]::new()
$reportBad = @(
    @{ L = 'a plugin that writes no report'; X = @{ ReportMode = 'none' }; S = 'INCOMPLETE'; W = '*no evidence: the report of gain is no evidence: the plugin wrote no report (FIXTURE_REPORT_JSON)*' }
    @{ L = 'a report written by another process'; X = @{ ReportMode = 'otherpid' }; S = 'INCOMPLETE'; W = '*no evidence: the report of gain is no evidence: it was written by process *, not by the REAPER of this step (*)*' }
    @{ L = 'a report that is not JSON'; X = @{ ReportMode = 'text' }; S = 'INCOMPLETE'; W = '*the report of gain is no evidence: it is not JSON*' }
    @{ L = 'a report field that is a string'; X = @{ ReportMode = 'string' }; S = 'INCOMPLETE'; W = '*the report of gain is no evidence: its field blocks is not a number*' }
    @{ L = 'a report too large to copy'; X = @{ ReportMode = 'toolarge' }; S = 'INCOMPLETE'; W = '*the report of gain is no evidence: its report is larger than 65536 bytes*' }
    @{ L = 'no fresh report in time'; X = @{ ReportMode = 'stale' }; S = 'INCOMPLETE'; W = '*the report of gain is no evidence: no fresh report could be read in time*' }
    @{ L = 'a field that grew by less than expected'; X = @{ ReportDelta = @{ opens = 9 } }; S = 'FAIL'; W = '*failed: gain.opens grew by 9, expected 10*' }
    @{ L = 'a window that opened one time fewer'; X = @{ WindowsFail = 1 }; S = 'FAIL'; W = '*failed: the window of gain opened 2 of 3 times; the window of gain closed 2 of 3 times*' }
)
foreach ($c in $reportBad) {
    $got = & $reportRun $c.X
    $gotState = & $stateOf $got.Row
    Write-Case "end to end: $($c.L) makes the state and the row $($c.S), never PASS ($($got.Row.detail))" $true (
        & $holds { $got.Run.verdict -ceq $c.S -and $got.Row.status -ceq $c.S -and $gotState.status -ceq $c.S -and $got.Row.detail -clike $c.W })
    $leftAfter.Add("$($c.S) $($c.L)=$(& $copiesLeft)")
}
Write-Case "end to end: INCOMPLETE and FAIL rounds with a reporting plugin leave no copy of a report in the results either ($($leftAfter -join ', '))" $true (
    $leftAfter.Count -eq $reportBad.Count -and @($leftAfter | Where-Object { $_ -cnotlike '*=0' }).Count -eq 0)
$rb = & $reportRun @{ VstFullStateReads = '49989' }
Write-Case "end to end: a preference that does not read back makes the transport row FAIL ($($rb.Row.detail))" $true ($rb.Run.verdict -ceq 'FAIL' -and $rb.Row.status -ceq 'FAIL' -and $rb.Row.detail -clike '*Inform plug-ins of offline rendering state reads on, expected off*')
# A window held open: the driver's shortest hold is judged against holdMs, and only that state's facts have it
$ha = & $reportRun @{ HoldAlways = $true }
$alwaysState = & $stateOf $ha.Row
Write-Case "end to end: a state without holdMs has no win_held in its facts and no held= in its line, even when the driver sent one ($($ha.Row.detail))" $false (& $holds {
        $ha.Run.verdict -ceq 'PASS' -and $alwaysState.status -ceq 'PASS' -and -not $alwaysState.Contains('win_held') -and $ha.Row.detail -cnotlike '*held=*' })
$holdCfg = & $writeVariant { param($c) & $reportChange $c; $c.scenarios[0].states[1].windows.holdMs = 2000 }
$holdCfg.ReaperExe = $pwshExe; $holdCfg.ResultDir = $e2e.ResultDir
$hp = & $reportRun @{} $holdCfg
$heldState = & $stateOf $hp.Row
Write-Case "end to end: a window held open 2000 ms: PASS, the line says how long, and the state's facts hold win_held ($($hp.Row.detail))" $false (& $holds {
        $hp.Run.verdict -ceq 'PASS' -and $hp.Row.status -ceq 'PASS' -and $heldState.status -ceq 'PASS' -and $heldState.win_held -eq 2003 -and
        $hp.Row.detail -clike '*stopped-armed-on: * windows=3/3 of 3 held=2003/2000ms report gain.opens=22 (+10) gain.blocks=22 (+10)*' })
$holdBad = @(
    @{ L = 'a window held 1000 ms short'; X = @{ HoldShort = $true }; S = 'FAIL'; W = '*stopped-armed-on: * windows=3/3 of 3 held=1000/2000ms report gain.opens=22 (+10) gain.blocks=22 (+10); failed: the window of gain was held 1000 of 2000 ms*' }
    @{ L = 'no hold time from the driver'; X = @{ HoldMissing = $true }; S = 'INCOMPLETE'; W = '*stopped-armed-on: * windows=3/3 of 3 held=/2000ms report gain.opens=22 (+10) gain.blocks=22 (+10); no evidence: the driver reported no hold time*' }
)
foreach ($c in $holdBad) {
    $got = & $reportRun $c.X $holdCfg
    $gotState = & $stateOf $got.Row
    Write-Case "end to end: $($c.L) makes the state and the row $($c.S), for that alone ($($got.Row.detail))" $true (& $holds {
            $got.Run.verdict -ceq $c.S -and $got.Row.status -ceq $c.S -and $gotState.status -ceq $c.S -and @($gotState.problems).Count -eq 1 -and $got.Row.detail -clike $c.W })
}
# Shots of the window held open (windows.capture): the stand-in REAPER asks for them as the driver does and the real
# capture service of the host answers; the images move to the results, the state's facts list every shot
$shotCfg = & $writeVariant { param($c) & $reportChange $c; $c.scenarios[0].states[1].windows.holdMs = 2000; $c.scenarios[0].states[1].windows.capture = @(0, 1000, 2000) }
$shotCfg.ReaperExe = $pwshExe; $shotCfg.ResultDir = $e2e.ResultDir
$shotNames = 'stopped-armed-on-0.png', 'stopped-armed-on-1000.png', 'stopped-armed-on-2000.png'
$shotDirsLeft = { @(Get-ChildItem -LiteralPath (Join-Path $e2e.ResultDir 'work') -Recurse -Directory -Filter 'monitor-states.shots' -ErrorAction SilentlyContinue) }
# Every launch of the run through the host, as the scenarios module calls it: only the transport step has a service
$hostSeen = [Collections.Generic.List[string]]::new()
$hostWrap = { $r = Host\Invoke-HarnessHost @args; $hostSeen.Add([string]$r.CaptureStopped); $r }.GetNewClosure()
$hostWas = & (Get-Module Scenarios) { param($s) $w = (Get-Item 'function:Invoke-HarnessHost').ScriptBlock; Set-Item 'function:script:Invoke-HarnessHost' $s; $w } $hostWrap
try { $sp = & $reportRun @{ Shots = @{ Window = $true } } $shotCfg }
finally { & (Get-Module Scenarios) { param($w) Set-Item 'function:script:Invoke-HarnessHost' $w } $hostWas }
$shotState = & $stateOf $sp.Row
$shotList = @(@(try { $shotState.shots } catch { $null }) | Where-Object { $_ })
$keptShots = @($shotList | ForEach-Object { if ($_.path) { Join-Path $e2e.ResultDir $_.path } })
Write-Case "end to end: three shots of a window held 2000 ms: PASS, the line counts them, and each image is in the results with its size, view, hash and the driver's times ($($sp.Row.detail))" $false (& $holds {
        $sp.Run.verdict -ceq 'PASS' -and $sp.Row.status -ceq 'PASS' -and $shotState.status -ceq 'PASS' -and
        $sp.Row.detail -clike '*stopped-armed-on: * windows=3/3 of 3 held=2003/2000ms shots=3/3 report gain.opens=22 (+10) gain.blocks=22 (+10)*' -and $sp.Row.detail -cnotlike '*not taken*' -and
        (@($shotList | ForEach-Object { $_.name }) -join ',') -ceq ($shotNames -join ',') -and (@($shotList | ForEach-Object { $_.at }) -join ',') -ceq '0,1000,2000' -and
        (@($shotList | ForEach-Object { $_.held }) -join ',') -ceq '2,1002,2002' -and (@($shotList | ForEach-Object { $_.wallMs }) -join ',') -ceq '5,1005,2005' -and
        @($shotList | Where-Object { $_.taken -and $null -eq $_.problem -and $_.width -eq 640 -and $_.height -eq 427 -and $_.view.x -eq 0 -and $_.view.y -eq 27 -and $_.view.w -eq 640 -and $_.view.h -eq 400 -and $_.dpi -ge 96 -and
                $_.path -clike 'renders/*/run1/monitor-states.shots/stopped-armed-on-*.png' }).Count -eq 3 -and $keptShots.Count -eq 3 -and
        @(for ($i = 0; $i -lt 3; $i++) { if ((Get-HarnessSha256 $keptShots[$i]) -ceq $shotList[$i].sha256 -and ([IO.FileInfo]::new($keptShots[$i])).Length -eq $shotList[$i].bytes) { $i } }).Count -eq 3 })
Write-Case "end to end: a green round with shots leaves no shot directory and no shot file in the work directory ($(@(& $shotDirsLeft).Count) left)" $true ($sp.Run.verdict -ceq 'PASS' -and @(& $shotDirsLeft).Count -eq 0)
Write-Case "end to end: only the transport step with shots has a capture service, which stopped; the other launches of the run have none ($($hostSeen -join ','))" $true (
    $hostSeen.Count -ge 2 -and @($hostSeen | Where-Object { $_ -ceq 'True' }).Count -eq 1 -and @($hostSeen | Where-Object { $_ -cne 'True' -and $_ -cne '' }).Count -eq 0)
# With -KeepWork the requests, the answers and the emptied directory stay in the work directory, the images still move
$spec = @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; EnvName = 'FIXTURE_REPORT_JSON'; EnvSeen = $envSeen; Shots = @{ Window = $true } }
Set-FakeReaper $spec
try { $keptRun = Invoke-HarnessSuite @shotCfg -NoNegative -KeepWork -SelfTestHooks $hooks }
finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
$keptState = & $stateOf @($keptRun.runs[0].scenarios | Where-Object { $_.id -ceq 'monitor-states' })[0]
$keptShotList = @(@(try { $keptState.shots } catch { $null }) | Where-Object { $_ })
$keptStamp = ($keptShotList.Count -and $keptShotList[0].path -cmatch '^renders/([^/]+)/run1/') ? $Matches[1] : 'none'
$keptDir = Join-Path $e2e.ResultDir "work/$keptStamp-run1/monitor-states.shots"
$keptLeft = @(Get-ChildItem -LiteralPath $keptDir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
Write-Case "end to end: with -KeepWork the requests and answers stay in the shot directory, the images are in the results ($($keptLeft -join ', '))" $false (& $holds {
        $keptRun.verdict -ceq 'PASS' -and ($keptLeft -join ',') -ceq (@(foreach ($n in $shotNames) { foreach ($x in 'done', 'err', 'req') { if ($x -cne 'err') { $n.Replace('.png', ".$x") } } }) -join ',') -and
        @($keptShotList | Where-Object { $_.path -and (Test-Path -LiteralPath (Join-Path $e2e.ResultDir $_.path) -PathType Leaf) }).Count -eq 3 })
$noWindow = 'no plugin window of this REAPER was visible'
$shotBad = @(
    @{ L = 'shots without a plugin window'; X = @{ Shots = @{} }; S = 'INCOMPLETE'; T = 0
        W = "*held=2003/2000ms shots=0/3 report gain.opens=22 (+10) gain.blocks=22 (+10); not taken: stopped-armed-on-0.png ($noWindow), stopped-armed-on-1000.png ($noWindow), stopped-armed-on-2000.png ($noWindow)*" }
    @{ L = 'two plugin windows'; X = @{ Shots = @{ Window = $true; Two = $true } }; S = 'INCOMPLETE'; T = 0
        W = '*shots=0/3 report * not taken: stopped-armed-on-0.png (2 plugin windows of this REAPER were visible: which one is meant cannot be told), *' }
    @{ L = 'a shot answered late, one whose window went, one the driver saw answered without an answer file'; S = 'INCOMPLETE'; T = 0
        X = @{ Shots = @{ Window = $true; Status = @{ 'stopped-armed-on-0.png' = 'late'; 'stopped-armed-on-1000.png' = 'gone'; 'stopped-armed-on-2000.png' = 'noreq' } } }
        W = '*shots=0/3 report * not taken: stopped-armed-on-0.png (no answer within 10 s), stopped-armed-on-1000.png (the window was gone before the shot was taken), stopped-armed-on-2000.png (the driver saw an answer, but there is no answer file)*' }
    @{ L = 'a shot never asked for and one the driver did not report, the third taken'; S = 'INCOMPLETE'; T = 1
        X = @{ Shots = @{ Window = $true; Status = @{ 'stopped-armed-on-0.png' = 'none'; 'stopped-armed-on-1000.png' = 'missing' } } }
        W = '*shots=1/3 report * not taken: stopped-armed-on-0.png (it was never asked for: the window did not open, or the request could not be written), stopped-armed-on-1000.png (the driver reported nothing about it)*' }
    @{ L = 'a window held too short whose shots were not taken'; X = @{ HoldShort = $true; Shots = @{} }; S = 'FAIL'; T = 0
        W = "*held=1000/2000ms shots=0/3 report * failed: the window of gain was held 1000 of 2000 ms; not taken: stopped-armed-on-0.png ($noWindow), *" }
)
foreach ($c in $shotBad) {
    $got = & $reportRun $c.X $shotCfg
    $gotState = & $stateOf $got.Row
    $gotShots = @(@(try { $gotState.shots } catch { $null }) | Where-Object { $_ })
    $taken = @($gotShots | Where-Object { $_.taken })
    Write-Case "end to end: $($c.L) makes the state and the row $($c.S), the shots taken kept all the same ($($got.Row.detail))" $true (& $holds {
            $got.Run.verdict -ceq $c.S -and $got.Row.status -ceq $c.S -and $gotState.status -ceq $c.S -and $got.Row.detail -clike $c.W -and $gotShots.Count -eq 3 -and $taken.Count -eq $c.T -and
            @($taken | Where-Object { $_.path -and (Test-Path -LiteralPath (Join-Path $e2e.ResultDir $_.path) -PathType Leaf) }).Count -eq $c.T -and
            @($gotShots | Where-Object { -not $_.taken -and ($null -ne $_.path -or -not $_.problem) }).Count -eq 0 })
}
# One shot: the facts list an array of one, in the result as in its JSON (the variant file is shared: the cases with
# three shots have run)
$oneShotCfg = & $writeVariant { param($c) & $reportChange $c; $c.scenarios[0].states[1].windows.holdMs = 2000; $c.scenarios[0].states[1].windows.capture = @(1000) }
$oneShotCfg.ReaperExe = $pwshExe; $oneShotCfg.ResultDir = $e2e.ResultDir
$os = & $reportRun @{ Shots = @{ Window = $true } } $oneShotCfg
$osState = & $stateOf $os.Row
Write-Case "end to end: a state with one shot lists an array of one, in the facts and in their JSON ($($os.Row.detail))" $false (& $holds {
        $os.Run.verdict -ceq 'PASS' -and $osState.shots -is [array] -and $osState.shots.Count -eq 1 -and $osState.shots[0].taken -and $os.Row.detail -clike '* shots=1/1 *' -and
        (ConvertTo-HarnessJsonText -Value $osState) -cmatch '"shots":\[\{"at":1000,' })
# A render judged by what the plugin reports: the driver renders between two readings, the audio is compared as ever
$reportRenderChange = {
    param($c)
    & $noExt $c
    $c.plugins.gain.report = @{ env = 'FIXTURE_REPORT_JSON'; fields = @('blocks', 'opens'); pid = 'pid'; periodMs = 100 }
    $c.scenarios = @(@{ id = 'chain-report'; kind = 'render'; layout = 'chain'; compare = 'repeat'; host = @{ runFxWhenStopped = $false; informOfflineState = $false }; report = [ordered]@{ gain = [ordered]@{ blocks = @{ delta = 10 }; opens = @{ value = @{ min = 1 } } } } }); $c.negative = @()
}
$reportRenderCfg = & $writeVariant $reportRenderChange
$reportRenderCfg.ReaperExe = $pwshExe; $reportRenderCfg.ResultDir = $e2e.ResultDir
$reportRenderRun = {
    param([hashtable]$SpecPlus = @{})
    $spec = @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; EnvName = 'FIXTURE_REPORT_JSON'; EnvSeen = $envSeen }
    foreach ($k in $SpecPlus.get_Keys()) { $spec[$k] = $SpecPlus[$k] }
    $envSeen.Clear()
    Set-FakeReaper $spec
    try { $run = Invoke-HarnessSuite @reportRenderCfg -NoNegative -SelfTestHooks $hooks }
    finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
    [pscustomobject]@{ Run = $run; Row = @($run.runs[0].scenarios | Where-Object { $_.id -ceq 'chain-report' })[0]; Env = @($envSeen) }
}
$rr = & $reportRenderRun
$leftAfter.Clear(); $leftAfter.Add("PASS=$(& $copiesLeft)")
$rrEnv = @($rr.Env | Where-Object { $_ })
Write-Case "end to end: a render judged by a report: PASS, the audio compared and the growth over the render recorded ($($rr.Row.detail))" $false (
    & $holds { $rr.Run.verdict -ceq 'PASS' -and $rr.Row.status -ceq 'PASS' -and $rr.Row.detail -clike 'identical=yes *| report gain.blocks=11 (+10) gain.opens=11 (+10)' -and $rr.Row.facts.report.gain.blocks.delta -eq 10 -and $rr.Row.facts.report.gain.opens.end -eq 11 })
Write-Case 'end to end: the variable is set for the REAPER of the judged render only: the first render of the comparison goes without it' $true (
    $rrEnv.Count -eq 1 -and $rrEnv[0] -clike '*\chain-report.report-gain.json' -and $rr.Env.Count -gt 1)
Write-Case 'end to end: the offline-state preference a scenario asks for is in the private ini when REAPER starts' $false ((Get-HarnessIniValue -Section REAPER -Key vstfullstate) -ceq '49733')
$renderBad = @(
    @{ L = 'a field that grew by another amount'; X = @{ ReportDelta = @{ blocks = 9 } }; S = 'FAIL'; W = '*| report *; failed: gain.blocks grew by 9, expected 10' }
    @{ L = 'a plugin still being run before the render'; X = @{ ReportMode = 'busy' }; S = 'INCOMPLETE'; W = '*no evidence: the report of gain is no evidence: its report kept changing where it had to stay the same: the plugin was still being run' }
    @{ L = 'a plugin that writes no report'; X = @{ ReportMode = 'none' }; S = 'INCOMPLETE'; W = '*no evidence: the report of gain is no evidence: the plugin wrote no report (FIXTURE_REPORT_JSON)' }
    @{ L = 'a report written by another process'; X = @{ ReportMode = 'otherpid' }; S = 'INCOMPLETE'; W = '*no evidence: the report of gain is no evidence: it was written by process *, not by the REAPER of this step (*)' }
    @{ L = 'a preference that does not read back'; X = @{ VstFullStateReads = '49989' }; S = 'FAIL'; W = '*; failed: Inform plug-ins of offline rendering state reads on, expected off' }
    @{ L = 'a render that wrote no file'; X = @{ RenderFails = $true }; S = 'INCOMPLETE'; W = 'the render produced no file' }
)
foreach ($c in $renderBad) {
    $got = & $reportRenderRun $c.X
    Write-Case "end to end: $($c.L) makes the judged render $($c.S), never PASS ($($got.Row.detail))" $true ($got.Run.verdict -ceq $c.S -and $got.Row.status -ceq $c.S -and $got.Row.detail -clike $c.W)
    $leftAfter.Add("$($c.S) $($c.L)=$(& $copiesLeft)")
}
Write-Case "end to end: a judged render leaves no copy of a report in the results, whatever its outcome ($($leftAfter -join ', '))" $true (
    $rr.Run.verdict -ceq 'PASS' -and $leftAfter.Count -eq $renderBad.Count + 1 -and @($leftAfter | Where-Object { $_ -cnotlike '*=0' }).Count -eq 0)
# A render judged by a report gets its tail as well, and its length is checked as any render's: without the tail it is
# INCOMPLETE (the driver's render step, not -renderproject)
$reportTailCfg = & $writeVariant { param($c) & $reportRenderChange $c; $c.scenarios[0].compare = 'none'; $c.scenarios[0].tailSeconds = 0.01 }
$reportTailCfg.ReaperExe = $pwshExe; $reportTailCfg.ResultDir = Join-Path $Work 'e2e-report-tail'
$judgedTail = @(foreach ($lose in $false, $true) {
        Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; EnvName = 'FIXTURE_REPORT_JSON'; EnvSeen = $envSeen; TailLost = $lose }
        try { $judgedRun = Invoke-HarnessSuite @reportTailCfg -NoNegative -SelfTestHooks $hooks; [pscustomobject]@{ Verdict = $judgedRun.verdict; Row = @($judgedRun.runs[0].scenarios | Where-Object { $_.id -ceq 'chain-report' })[0] } }
        catch { [pscustomobject]@{ Verdict = "threw: $($_.Exception.Message)"; Row = $null } }
        finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
    })
Write-SafeCase 'end to end: tail: a render judged by a report renders its tail: PASS, the render as long as the source and the tail, the growth over the render recorded' { "$($judgedTail[0].Verdict): $($judgedTail[0].Row.detail)" } $false {
    $judgedTail[0].Verdict -ceq 'PASS' -and $judgedTail[0].Row.status -ceq 'PASS' -and $judgedTail[0].Row.detail -clike 'frames=24480 *| report gain.blocks=* (+10) *' -and
    $judgedTail[0].Row.facts['tail']['renderFrames'] -eq 24480 -and $judgedTail[0].Row.facts['report']['gain']['blocks']['delta'] -eq 10 }
Write-SafeCase 'end to end: tail: a render judged by a report without the tail it was asked for is INCOMPLETE, as any render' { "$($judgedTail[1].Verdict): $($judgedTail[1].Row.detail)" } $true {
    $judgedTail[1].Verdict -ceq 'INCOMPLETE' -and $judgedTail[1].Row.status -ceq 'INCOMPLETE' -and $judgedTail[1].Row.detail -ceq 'the render chain-report.wav has 24000 frames, not 24480: the tail was not rendered as asked' }
# The licence reminder ends a launch after it saved its copy, and the launch started once more cannot save: the copy of
# the first one must not prove the states
$nagSpec = @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs }
$realOnce = & (Get-Module Scenarios) { ${function:Invoke-HarnessLaunchOnce} }
$nagFirst = {
    param([Alias('Ctx')]$RunCtx, $HostArgs, $Label)
    $run = & $realOnce -Ctx $RunCtx -HostArgs $HostArgs -Label $Label
    if ($Label -ceq 'device' -and -not $nagSpec['SaveFails']) { $nagSpec['SaveFails'] = $true; $run.Status = 'Modal'; $run.Modal = 'license-nag' }
    $run
}.GetNewClosure()
$setOnce = { param($b) & (Get-Module Scenarios) { param($s) Set-Item function:script:Invoke-HarnessLaunchOnce $s } $b }
Set-FakeReaper $nagSpec
& $setOnce $nagFirst
try { $nagRun = Invoke-HarnessSuite @e2e -Only '^states-device$' -NoNegative -SelfTestHooks $hooks }
finally { & $setOnce $realOnce; Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
$nagRow = @($nagRun.runs[0].scenarios | Where-Object { $_.id -ceq 'states-device' })[0]
Write-Case 'end to end: a copy saved before the licence reminder ended the launch does not count for the launch started once more' $true (
    $nagRun.verdict -ceq 'INCOMPLETE' -and $null -ne $nagRow -and $nagRow.status -ceq 'INCOMPLETE' -and $nagRow.detail -ceq 'the copy that proves the states was not saved' -and
    @($nagRun.runs[0].retries).Count -eq 1)
# A report of the launch the licence reminder ended is not there for the launch started once more, and an old file at
# the path of a report is gone before the REAPER of the step starts
$reportCfg = & $writeVariant $reportChange
$reportCfg.ReaperExe = $pwshExe; $reportCfg.ResultDir = $e2e.ResultDir
$nagged = @{ Done = $false }
$nagTransport = {
    param([Alias('Ctx')]$RunCtx, $HostArgs, $Label)
    $run = & $realOnce -Ctx $RunCtx -HostArgs $HostArgs -Label $Label
    if ($Label -ceq 'transport' -and -not $nagged.Done) { $nagged.Done = $true; $run.Status = 'Modal'; $run.Modal = 'license-nag' }
    $run
}.GetNewClosure()
$atStart = [Collections.Generic.List[bool]]::new()
$copiesAtStart = [Collections.Generic.List[int]]::new()
& $setOnce $nagTransport
try { $nagReport = & $reportRun @{ FileAtStart = $atStart; CopiesAtStart = $copiesAtStart } } finally { & $setOnce $realOnce }
Write-Case "end to end: the report of a launch the licence reminder ended is deleted before the launch started once more ($($atStart -join ','))" $true (
    ($atStart -join ',') -ceq 'False,False' -and @($nagReport.Run.runs[0].retries).Count -eq 1)
Write-Case "end to end: the copies the driver made in a launch the licence reminder ended are deleted before the launch started once more ($($copiesAtStart -join ','))" $true (
    ($copiesAtStart -join ',') -ceq '0,0' -and @($nagReport.Run.runs[0].retries).Count -eq 1)
$realPlan = & (Get-Module Scenarios) { ${function:Get-HarnessReportPlan} }
$oldFile = {
    param([Alias('Plugins')]$PluginTable, $Layout, $Work, $Name)
    $plan = & $realPlan -Plugins $PluginTable -Layout $Layout -Work $Work -Name $Name
    foreach ($row in $plan) { [IO.File]::WriteAllText($row.Path, '{"blocks":1}'); [IO.File]::WriteAllText("$($row.Copy)1.json", '{"blocks":1}') }
    , $plan
}.GetNewClosure()
$setPlan = { param($b) & (Get-Module Scenarios) { param($s) Set-Item function:script:Get-HarnessReportPlan $s } $b }
& $setPlan $oldFile
$atStart.Clear(); $copiesAtStart.Clear()
try { $null = & $reportRun @{ FileAtStart = $atStart; CopiesAtStart = $copiesAtStart } } finally { & $setPlan $realPlan }
Write-Case "end to end: an old file at the path of a report is gone before the REAPER of the step starts ($($atStart -join ','))" $true (($atStart -join ',') -ceq 'False')
Write-Case "end to end: an old copy of a report is gone before the REAPER of the step starts ($($copiesAtStart -join ','))" $true (($copiesAtStart -join ',') -ceq '0')
# A launch that ends badly after the driver copied the reports: INCOMPLETE, and the copies are gone all the same
$timedOut = {
    param([Alias('Ctx')]$RunCtx, $HostArgs, $Label)
    $run = & $realOnce -Ctx $RunCtx -HostArgs $HostArgs -Label $Label
    if ($Label -ceq 'transport') { $run.Status = 'Timeout' }
    $run
}.GetNewClosure()
& $setOnce $timedOut
try { $late = & $reportRun } finally { & $setOnce $realOnce }
Write-Case "end to end: a transport launch that ends badly after the driver copied the reports is INCOMPLETE and leaves no copy ($($late.Row.detail); $(& $copiesLeft) left)" $true (
    & $holds { $late.Row.status -ceq 'INCOMPLETE' -and $late.Row.detail -clike 'timed out after *' -and (& $copiesLeft) -eq 0 })
# A launch that throws once the driver has copied the reports (a guard, the host): nobody reads the copies, they go all the same
$thrownAt = @{ Copies = -1 }
$throwsLate = {
    param([Alias('Ctx')]$RunCtx, $HostArgs, $Label)
    $run = & $realOnce -Ctx $RunCtx -HostArgs $HostArgs -Label $Label
    if ($Label -ceq 'transport') { $thrownAt.Copies = @(Get-ChildItem -LiteralPath $RunCtx.Work -File -Filter '*.report-*.copy-*.json').Count; throw 'the host failed after the step' }
    $run
}.GetNewClosure()
& $setOnce $throwsLate
try { $threw = & $reportRun } finally { & $setOnce $realOnce }
Write-Case "end to end: a transport launch that throws after the driver copied the reports is INCOMPLETE and leaves no copy ($($threw.Row.detail); $($thrownAt.Copies) copies then, $(& $copiesLeft) left)" $true (
    & $holds { $threw.Row.status -ceq 'INCOMPLETE' -and $threw.Row.detail -clike 'the scenario threw: the host failed after the step*' -and $thrownAt.Copies -gt 0 -and (& $copiesLeft) -eq 0 })
# The same for a judged render: its configuration file was written over by the transport one above, so it is written again
$reportRenderCfg = & $writeVariant $reportRenderChange
$reportRenderCfg.ReaperExe = $pwshExe; $reportRenderCfg.ResultDir = $e2e.ResultDir
& $setPlan $oldFile
$copiesAtStart.Clear()
try { $null = & $reportRenderRun @{ CopiesAtStart = $copiesAtStart } } finally { & $setPlan $realPlan }
Write-Case "end to end: an old copy of a report is gone before the REAPER of a judged render starts ($($copiesAtStart -join ','))" $true (($copiesAtStart -join ',') -ceq '0')
Write-Case 'end to end: a file in the record directory of the project makes the row FAIL: something was recorded' $true (
    $r.verdict -ceq 'FAIL' -and $null -ne $recRow -and $recRow.status -ceq 'FAIL' -and $recRow.detail -ceq '1 file(s) appeared in the record directory of the project: something was recorded')

# ---- probe variables: a plugin told where a copy of its script is and an empty directory to write into ----
# Gain declares two probe variables and a report variable, as a test build would; the source is the WAV file of the
# file-source cases. The result directories of these runs sit right below the scratch directory: a probe directory path
# is at most 140 characters (a name of 100 then fits in a path of 241), and the work directory of this child is too
# deep for that.
$pbRoot = Split-Path -Parent $Work
# Precondition: a probe directory path over the limit makes the scenario INCOMPLETE before its render starts. The longest one
# these runs make (the longest run leaf with the longest scenario id) has to fit, or every probe case below is INCOMPLETE
$pbLimit = & @(Get-Module Probe)[0] { $script:MaxDirPath }
$pbLongest = [IO.Path]::Join($pbRoot, 'pf10', 'work', '20260101-000000-run1', 'tv-sh.out').Length
Write-Case "end to end: probe: precondition: the probe directories of these runs fit the limit of a probe directory path ($pbLongest of $pbLimit characters; with a longer temporary directory every probe case below is INCOMPLETE)" $false ($pbLongest -le $pbLimit)
$pbProbeDir = Join-Path $Work 'probe'
$null = New-Item -ItemType Directory -Force -Path $pbProbeDir
[IO.File]::WriteAllText((Join-Path $pbProbeDir 'take1.json'), '{"example":1}')
[IO.File]::WriteAllText((Join-Path $pbProbeDir 'take1-shifted.json'), '{"example":2}')
$pbShaOf = { param([string]$ShaPath) (Get-FileHash -LiteralPath $ShaPath -Algorithm SHA256).Hash.ToLowerInvariant() }
$pbSha = & $pbShaOf (Join-Path $pbProbeDir 'take1.json')
$pbShiftedSha = & $pbShaOf (Join-Path $pbProbeDir 'take1-shifted.json')
$pbNames = 'EXAMPLE_PROBE_SCRIPT', 'EXAMPLE_PROBE_OUT', 'EXAMPLE_PROBE_JSON'
$pbBase = { param([string]$ScenarioId) [ordered]@{ id = $ScenarioId; kind = 'render'; layout = 'take'; sr = 44100; compare = 'none'; notSilent = $true; probe = $true } }
$pbChange = {
    param($c, [object[]]$ScenarioList)
    & $noExt $c
    $c.plugins.gain.probe = [ordered]@{ EXAMPLE_PROBE_SCRIPT = @{ file = 'probe/take1.json' }; EXAMPLE_PROBE_OUT = @{ dir = $true } }
    $c.plugins.gain.report = @{ env = 'EXAMPLE_PROBE_JSON'; fields = @('blocks', 'opens'); pid = 'pid'; periodMs = 100 }
    $c.layouts.take = [ordered]@{ tracks = @([ordered]@{ name = 'Take'; source = $true; file = 'sources/voice.wav'; fx = @(@{ plugin = 'gain' }) }) }
    $c.scenarios = $ScenarioList; $c.negative = @()
}
$pbLog = [Collections.Generic.List[object]]::new()
$pbSpecOf = {
    param([hashtable]$ProbePlus = @{})
    $told = @{ Script = 'EXAMPLE_PROBE_SCRIPT'; Out = 'EXAMPLE_PROBE_OUT'; Steps = 2 }
    foreach ($k in $ProbePlus.get_Keys()) { $told[$k] = $ProbePlus[$k] }
    @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; EnvNames = @($pbNames) + 'REAPER_HARNESS_JOB'; EnvLog = $pbLog; Probe = $told }
}
$pbRunOf = {
    param([hashtable]$RunCfg, [string]$RunLeaf, [hashtable]$RunSpec, [hashtable]$RunAlso = @{})
    $one = $RunCfg.Clone(); $one.ResultDir = Join-Path $pbRoot $RunLeaf
    $pbLog.Clear()
    $suiteRun = $null; $why = ''
    Set-FakeReaper $RunSpec
    try { $suiteRun = Invoke-HarnessSuite @one @RunAlso -NoNegative -SelfTestHooks $hooks }
    catch { $why = "the run threw: $($_.Exception.Message) " }
    finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }
    [pscustomobject]@{ Run = $suiteRun; Why = $why; Res = $one.ResultDir; Log = @($pbLog) }
}
$pbRowOf = { param($Finished, [string]$RowId) try { @($Finished.Run.runs[0].scenarios | Where-Object { $_.id -ceq $RowId })[0] } catch { $null } }
$pbNamesOf = { param($FileList) @($FileList | ForEach-Object { $_['name'] }) -join ',' }
$pbBlank = { param($LogEntry) @($pbNames | Where-Object { $LogEntry[$_] }).Count -eq 0 }
# One round of five scenarios: t1 (compare none), td (compare dry), tp (the same plugin without probe, compare repeat),
# tv (two variants, one with its own script), tr (judged by the report as well); final.json is written by the stand-in
# process as it exits, so it is only there when collection waits for the end of the launch
$pbDryScen = & $pbBase 'td'; $pbDryScen.compare = 'dry'
$pbPlainScen = [ordered]@{ id = 'tp'; kind = 'render'; layout = 'take'; sr = 44100; compare = 'repeat' }
$pbTv = & $pbBase 'tv'
$pbTv.variants = @([ordered]@{ id = 'sh'; probe = [ordered]@{ EXAMPLE_PROBE_SCRIPT = @{ file = 'probe/take1-shifted.json' } } }, [ordered]@{ id = 'pl' })
$pbJudged = & $pbBase 'tr'
$pbJudged.host = @{ runFxWhenStopped = $false; informOfflineState = $false }
$pbJudged.report = [ordered]@{ gain = [ordered]@{ blocks = @{ delta = 10 } } }
$pbCfgA = & $writeVariant { param($c) & $pbChange $c @((& $pbBase 't1'), $pbDryScen, $pbPlainScen, $pbTv, $pbJudged) }
$pbCfgA.ReaperExe = $pwshExe
# This process has all three variables set while the round runs: a launch that inherited one would write where it points
$pbShell = Join-Path $Work 'probe-shell'
$null = New-Item -ItemType Directory -Force -Path $pbShell
$pbWas = @{}
foreach ($n in $pbNames) { $pbWas[$n] = [Environment]::GetEnvironmentVariable($n) }
try {
    [Environment]::SetEnvironmentVariable('EXAMPLE_PROBE_SCRIPT', (Join-Path $pbShell 'script.json'))
    [Environment]::SetEnvironmentVariable('EXAMPLE_PROBE_OUT', $pbShell)
    [Environment]::SetEnvironmentVariable('EXAMPLE_PROBE_JSON', (Join-Path $pbShell 'report.json'))
    $pbA = & $pbRunOf $pbCfgA 'pa' (& $pbSpecOf @{ LateFinal = $true })
} finally { foreach ($n in $pbNames) { Restore-ChildEnvVariable $n $pbWas[$n] } }
$pbStampA = & $safe { @(Get-ChildItem -LiteralPath (Join-Path $pbA.Res 'renders') -Directory)[0].Name }
$pbRunDirA = & $safe { [IO.Path]::Join($pbA.Res, 'renders', $pbStampA, 'run1') }
$pbT1 = & $pbRowOf $pbA 't1'
$pbFilesA = & $safe { @($pbT1.facts['probe']['files']) }
Write-SafeCase 'end to end: probe: a render with probe variables, compare none, no keep: PASS; final.json (written as the stand-in exited) and the step files are collected under renders/<stamp>/run1/t1.out, each with the sha256 of the file there' { "$($pbA.Why)$($pbT1.detail)" } $false {
    $pbA.Run.verdict -ceq 'PASS' -and $pbT1.status -ceq 'PASS' -and (& $pbNamesOf $pbFilesA) -ceq 'final.json,step-001.json,step-002.json' -and
    @($pbFilesA | Where-Object { $_['temporary'] -or $_['sha256'] -cne (& $pbShaOf ([IO.Path]::Join($pbRunDirA, 't1.out', $_['name']))) }).Count -eq 0 -and
    $pbT1.facts['probe']['dir'] -ceq "renders/$pbStampA/run1/t1.out" -and $pbT1.facts['probe']['collected'] -eq 3 -and $pbT1.facts['probe']['left'] -eq 0 -and $pbT1.facts['probe']['pid'] -gt 0 -and
    $pbT1.detail -clike '*; probe: 3 files collected, * bytes' }
$pbFinalA = & $safe { [IO.File]::ReadAllText([IO.Path]::Join($pbRunDirA, 't1.out', 'final.json')) | ConvertFrom-Json -AsHashtable }
Write-SafeCase 'end to end: probe: the plugin read the copy of the configured script: its final.json names the sha256 of probe/take1.json, as the facts do' { "$($pbFinalA['script'])" } $false {
    $pbFinalA['script'] -ceq $pbSha -and @($pbT1.facts['probe']['variables'] | Where-Object { $_['name'] -ceq 'EXAMPLE_PROBE_SCRIPT' -and $_['path'] -ceq 'probe/take1.json' -and $_['sha256'] -ceq $pbSha }).Count -eq 1 }
$pbLeftA = @(Get-ChildItem -LiteralPath (Join-Path $pbA.Res 'work') -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -clike '*.probe-*' -or $_.Name -clike '*.out' } | ForEach-Object { $_.Name })
Write-SafeCase 'end to end: probe: after the green round no input copy and no probe directory is left in the work directory, and no manifest is named' { $pbLeftA -join ', ' } $false {
    $pbA.Run.verdict -ceq 'PASS' -and $pbLeftA.Count -eq 0 -and $pbA.Run.PSObject.Properties['manifest'] -and $null -eq $pbA.Run.manifest }
$pbLogA = @($pbA.Log)
$pbLearn = @($pbLogA | Where-Object { $_['REAPER_HARNESS_JOB'] -clike '*\_learn-*.job.lua' })
Write-SafeCase 'end to end: probe: the learn launch inherits none of the declared probe and report variables although this process had all three set, nothing was written where they pointed, and they are as they were' { "$($pbLearn.Count) learn launches" } $true {
    $pbLearn.Count -ge 1 -and @($pbLearn | Where-Object { -not (& $pbBlank $_) }).Count -eq 0 -and @(Get-ChildItem -LiteralPath $pbShell -Force).Count -eq 0 -and
    @($pbNames | Where-Object { [Environment]::GetEnvironmentVariable($_) -cne $pbWas[$_] }).Count -eq 0 }
$pbDryRef = @($pbLogA | Where-Object { $_['args'] -clike '*\_dry-take-*.rpp' })
$pbDryTest = @($pbLogA | Where-Object { $_['args'] -clike '*\td.rpp' })
Write-SafeCase 'end to end: probe: compare dry: the dry reference is told no variable, the scenario''s own render both probe paths' { "$((& $pbRowOf $pbA 'td').detail)" } $true {
    (& $pbRowOf $pbA 'td').status -ceq 'PASS' -and $pbDryRef.Count -eq 1 -and (& $pbBlank $pbDryRef[0]) -and $pbDryTest.Count -eq 1 -and
    $pbDryTest[0]['EXAMPLE_PROBE_SCRIPT'] -clike '*\td.probe-EXAMPLE_PROBE_SCRIPT.json' -and $pbDryTest[0]['EXAMPLE_PROBE_OUT'] -clike '*\td.out' -and -not $pbDryTest[0]['EXAMPLE_PROBE_JSON'] }
$pbPlainLog = @($pbLogA | Where-Object { $_['args'] -clike '*\tp-first.rpp' -or $_['args'] -clike '*\tp.rpp' })
Write-SafeCase 'end to end: probe: a scenario of the same plugin without probe (compare repeat) tells neither of its two launches a variable' { "$((& $pbRowOf $pbA 'tp').detail)" } $true {
    (& $pbRowOf $pbA 'tp').status -ceq 'PASS' -and $pbPlainLog.Count -eq 2 -and @($pbPlainLog | Where-Object { -not (& $pbBlank $_) }).Count -eq 0 }
$pbT1Log = @($pbLogA | Where-Object { $_['args'] -clike '*\t1.rpp' })
$pbWorkA = & $safe { [IO.Path]::Join($pbA.Res, 'work', "$pbStampA-run1") }
Write-SafeCase 'end to end: probe: the render of t1 is told exactly its two paths in the work directory, and not the report variable' { "$(& $safe { $pbT1Log[0]['EXAMPLE_PROBE_SCRIPT'] }) | $(& $safe { $pbT1Log[0]['EXAMPLE_PROBE_OUT'] })" } $false {
    $pbT1Log.Count -eq 1 -and $pbT1Log[0]['EXAMPLE_PROBE_SCRIPT'] -ceq [IO.Path]::Join($pbWorkA, 't1.probe-EXAMPLE_PROBE_SCRIPT.json') -and $pbT1Log[0]['EXAMPLE_PROBE_OUT'] -ceq [IO.Path]::Join($pbWorkA, 't1.out') -and
    -not $pbT1Log[0]['EXAMPLE_PROBE_JSON'] }
$pbVar = @(foreach ($v in 'sh', 'pl') {
        $vRow = & $pbRowOf $pbA "tv-$v"
        [pscustomobject]@{ Row = $vRow; Final = (& $safe { [IO.File]::ReadAllText([IO.Path]::Join($pbRunDirA, "tv-$v.out", 'final.json')) | ConvertFrom-Json -AsHashtable }) }
    })
Write-SafeCase 'end to end: probe: variants: each has its own directory, and its final.json names the hash of its own script: the override of the shifted one, the scenario''s for the plain one' { "$($pbVar[0].Row.detail) | $($pbVar[1].Row.detail)" } $false {
    $pbVar[0].Row.status -ceq 'PASS' -and $pbVar[1].Row.status -ceq 'PASS' -and $pbVar[0].Final['script'] -ceq $pbShiftedSha -and $pbVar[1].Final['script'] -ceq $pbSha -and
    $pbVar[0].Row.facts['probe']['dir'] -ceq "renders/$pbStampA/run1/tv-sh.out" -and $pbVar[1].Row.facts['probe']['dir'] -ceq "renders/$pbStampA/run1/tv-pl.out" -and
    @($pbVar[0].Row.facts['probe']['variables'] | Where-Object { $_['path'] -ceq 'probe/take1-shifted.json' -and $_['sha256'] -ceq $pbShiftedSha }).Count -eq 1 }
$pbTr = & $pbRowOf $pbA 'tr'
$pbTrLog = @($pbLogA | Where-Object { $_['REAPER_HARNESS_JOB'] -clike '*\tr.job.lua' })
Write-SafeCase 'end to end: probe: a render judged by a report: its one driver launch is told the report path and both probe paths; the report is judged and the files collected' { "$($pbTr.detail)" } $false {
    $pbTr.status -ceq 'PASS' -and $pbTr.facts['report']['gain']['blocks']['delta'] -eq 10 -and $pbTr.facts['probe']['collected'] -eq 3 -and $pbTrLog.Count -eq 1 -and
    $pbTrLog[0]['EXAMPLE_PROBE_JSON'] -clike '*\tr.report-gain.json' -and $pbTrLog[0]['EXAMPLE_PROBE_SCRIPT'] -clike '*\tr.probe-EXAMPLE_PROBE_SCRIPT.json' -and $pbTrLog[0]['EXAMPLE_PROBE_OUT'] -clike '*\tr.out' }
# keep and -KeepWork: the manifest line, the facts of the kept render, and what stays in the work directory
$pbKept = & $pbBase 't1'; $pbKept.keep = $true
$pbCfgB = & $writeVariant { param($c) & $pbChange $c @($pbKept) }
$pbCfgB.ReaperExe = $pwshExe
$pbB = & $pbRunOf $pbCfgB 'pb' (& $pbSpecOf @{ LateFinal = $true }) @{ KeepWork = $true }
$pbStampB = & $safe { @(Get-ChildItem -LiteralPath (Join-Path $pbB.Res 'renders') -Directory)[0].Name }
$pbT1B = & $pbRowOf $pbB 't1'
$pbLineB = & $safe { @(Get-Content -LiteralPath ([IO.Path]::Join($pbB.Res, 'renders', $pbStampB, 'manifest.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable } | Where-Object { $_['scenario'] -ceq 't1' })[0] }
$pbPairs = { param($FileList) @($FileList | ForEach-Object { "$($_['name'])=$($_['sha256'])" }) -join ',' }
Write-SafeCase 'end to end: probe: keep: the manifest line has probe with dir run1/t1.out, the pid, and the files and hashes of the run without keep; facts.kept.probe.dir starts renders/' { "$($pbB.Why)$($pbT1B.detail)" } $false {
    $pbB.Run.verdict -ceq 'PASS' -and $pbLineB['probe']['dir'] -ceq 'run1/t1.out' -and $pbLineB['probe']['pid'] -gt 0 -and @($pbLineB['probe']['files']).Count -eq 3 -and
    (& $pbPairs $pbLineB['probe']['files']) -ceq (& $pbPairs $pbFilesA) -and $pbT1B.facts['kept']['probe']['dir'] -ceq "renders/$pbStampB/run1/t1.out" -and $pbB.Run.manifest -ceq "renders/$pbStampB/manifest.jsonl" }
$pbWorkB = & $safe { [IO.Path]::Join($pbB.Res, 'work', "$pbStampB-run1") }
Write-SafeCase 'end to end: probe: -KeepWork: the input copy and the emptied directory stay in the work directory, the files are under renders all the same' { $pbWorkB } $false {
    (& $pbShaOf ([IO.Path]::Join($pbWorkB, 't1.probe-EXAMPLE_PROBE_SCRIPT.json'))) -ceq $pbSha -and (Test-Path -LiteralPath ([IO.Path]::Join($pbWorkB, 't1.out')) -PathType Container) -and
    @(Get-ChildItem -LiteralPath ([IO.Path]::Join($pbWorkB, 't1.out')) -Force).Count -eq 0 -and @(Get-ChildItem -LiteralPath ([IO.Path]::Join($pbB.Res, 'renders', $pbStampB, 'run1', 't1.out')) -File).Count -eq 3 }
# What a plugin may write into its directory, one round each: only plain files with plain names, within the limits
$pbOutside = Join-Path $Work 'probe-outside'
$null = New-Item -ItemType Directory -Force -Path $pbOutside
[IO.File]::WriteAllText((Join-Path $pbOutside 'secret.json'), '{"outside":1}')
$pbOutsideIntact = { $there = @(Get-ChildItem -LiteralPath $pbOutside -Force); $there.Count -eq 1 -and $there[0].Name -ceq 'secret.json' -and [IO.File]::ReadAllText($there[0].FullName) -ceq '{"outside":1}' }
$pbKeptNamed = { param([string]$Res, [string]$LeafName) @(Get-ChildItem -LiteralPath (Join-Path $Res 'renders') -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ceq $LeafName }).Count }
$pbCfgF = & $writeVariant { param($c) & $pbChange $c @(& $pbBase 't1') }
$pbCfgF.ReaperExe = $pwshExe
$pbFaults = @(
    @{ F = 'Subdir'; S = 'INCOMPLETE'; N = 3; W = '*; probe: 3 files collected, * bytes; not collected: a subdirectory sub'; X = { param($Probed) Test-Path -LiteralPath ([IO.Path]::Join($Probed.Work, 't1.out', 'sub', 'x.json')) -PathType Leaf } }
    @{ F = 'Junction'; S = 'INCOMPLETE'; N = 3; W = '*; probe: 3 files collected, * bytes; not collected: a link or junction link (not followed)'; X = { param($Probed) (& $pbOutsideIntact) -and (& $pbKeptNamed $Probed.Res 'secret.json') -eq 0 } }
    @{ F = 'DirLink'; S = 'INCOMPLETE'; N = 0; W = '*; probe: nothing collected: the directory was replaced by a link or junction'; X = { param($Probed) (& $pbOutsideIntact) -and (& $pbKeptNamed $Probed.Res 't1.out') -eq 0 } }
    @{ F = 'BadName'; S = 'INCOMPLETE'; N = 3; W = '*; probe: 3 files collected, * bytes; not collected: 2 entries whose name is not allowed *'; X = { param($Probed) $rowText = $Probed.Row | ConvertTo-Json -Depth 30; -not $rowText.Contains('bad name') -and -not $rowText.Contains('.hidden') } }
    @{ F = 'Big'; S = 'INCOMPLETE'; N = 3; W = '*; probe: 3 files collected, * bytes; not collected: big.bin is larger than 4194304 bytes'; X = $null }
    @{ F = 'Many'; S = 'INCOMPLETE'; N = 32; W = '*; probe: 32 files collected, 64 bytes; not collected: more than 32 files: 1 file left in the work directory'; X = $null }
    @{ F = 'Total'; S = 'INCOMPLETE'; N = 4; W = '*; probe: 4 files collected, 16777216 bytes; not collected: more than 16777216 bytes in all: 1 file left in the work directory'; X = $null }
    @{ F = 'None'; S = 'INCOMPLETE'; N = 0; W = '*; probe: 0 files collected, 0 bytes; not collected: 0 files to collect, fewer than the 1 asked for (min)'; X = $null }
    @{ F = 'TmpOnly'; S = 'INCOMPLETE'; N = 1; W = '*; probe: 1 file collected, 2 bytes, 1 temporary; not collected: 0 files to collect, fewer than the 1 asked for (min)'
        X = { param($Probed) $only = @($Probed.Row.facts['probe']['files'])[0]; $only['name'] -ceq 'final.json.4242.tmp' -and $only['temporary'] -eq $true } }
    @{ F = 'Tmp'; S = 'PASS'; N = 4; W = '*; probe: 4 files collected, * bytes, 1 temporary'; X = { param($Probed) $Probed.Row.facts['probe']['temporary'] -eq 1 } }
)
$pbAt = 0
foreach ($pbF in $pbFaults) {
    $pbAt++
    $pbGot = & $pbRunOf $pbCfgF "pf$pbAt" (& $pbSpecOf @{ Fault = $pbF.F; Outside = $pbOutside })
    $pbGotRow = & $pbRowOf $pbGot 't1'
    $pbProbed = [pscustomobject]@{ Row = $pbGotRow; Res = $pbGot.Res; Work = (& $safe { @(Get-ChildItem -LiteralPath (Join-Path $pbGot.Res 'work') -Directory)[0].FullName }) }
    Write-SafeCase "end to end: probe: a plugin that writes $($pbF.F): the round and the row are $($pbF.S), $(Get-HarnessCount $pbF.N 'file') collected" { "$($pbGot.Why)$($pbGotRow.detail)" } ($pbF.S -cne 'PASS') {
        $pbGot.Run.verdict -ceq $pbF.S -and $pbGotRow.status -ceq $pbF.S -and $pbGotRow.detail -clike $pbF.W -and $pbGotRow.facts['probe']['collected'] -eq $pbF.N -and (-not $pbF.X -or (& $pbF.X $pbProbed)) }
}
$pbSkip = & $pbRunOf $pbCfgF 'ps' ((& $pbSpecOf @{}) + @{ RenderSkip = 1 })
$pbSkipRow = & $pbRowOf $pbSkip 't1'
Write-SafeCase 'end to end: probe: a render that wrote no file is INCOMPLETE, and what the plugin wrote is collected all the same' { "$($pbSkip.Why)$($pbSkipRow.detail)" } $true {
    $pbSkip.Run.verdict -ceq 'INCOMPLETE' -and $pbSkipRow.status -ceq 'INCOMPLETE' -and $pbSkipRow.detail -clike 'the render produced no file; probe: 3 files collected, * bytes' -and
    (& $pbNamesOf $pbSkipRow.facts['probe']['files']) -ceq 'final.json,step-001.json,step-002.json' }
# The licence reminder ends the first launch of the render: the directory is the plugin's again only when it is empty
$pbNag = @{ Launches = 0; Seen = [Collections.Generic.List[object]]::new(); Pids = [Collections.Generic.List[object]]::new(); Spec = $null }
$pbNagOnce = {
    param([Alias('Ctx')]$RunCtx, $HostArgs, $Label)
    $told = $HostArgs['Environment']
    $outDir = ($told -is [Collections.IDictionary] -and $told.Contains('EXAMPLE_PROBE_OUT')) ? [string]$told['EXAMPLE_PROBE_OUT'] : ''
    if ($outDir) {
        $pbNag.Launches++
        $copyFile = [string]$told['EXAMPLE_PROBE_SCRIPT']
        $pbNag.Seen.Add([pscustomobject]@{ There = (Test-Path -LiteralPath $outDir -PathType Container); Entries = @(Get-ChildItem -LiteralPath $outDir -Force -ErrorAction SilentlyContinue).Count
                Sha = ((Test-Path -LiteralPath $copyFile -PathType Leaf) ? (Get-FileHash -LiteralPath $copyFile -Algorithm SHA256).Hash.ToLowerInvariant() : '') })
    }
    $launched = & $realOnce -Ctx $RunCtx -HostArgs $HostArgs -Label $Label
    if ($outDir) { $pbNag.Pids.Add($launched.Pid) }
    if ($outDir -and $pbNag.Launches -eq 1) { $null = $pbNag.Spec.Probe.Remove('Fault'); $launched.Status = 'Modal'; $launched.Modal = 'license-nag' }
    $launched
}.GetNewClosure()
$pbNag.Spec = & $pbSpecOf @{ Fault = 'None' }
& $setOnce $pbNagOnce
try { $pbN1 = & $pbRunOf $pbCfgF 'pn' $pbNag.Spec } finally { & $setOnce $realOnce }
$pbN1Row = & $pbRowOf $pbN1 't1'
Write-SafeCase 'end to end: probe: a licence reminder ends the first launch, which wrote nothing: the directory stays and is empty, the input copy is unchanged, the launch is started once more, the row is PASS and its pid is the second launch''s' { "$($pbN1.Why)$($pbN1Row.detail); pids $($pbNag.Pids -join ', '), facts $(& $safe { $pbN1Row.facts['probe']['pid'] })" } $false {
    $pbN1.Run.verdict -ceq 'PASS' -and $pbN1Row.status -ceq 'PASS' -and @($pbN1.Run.runs[0].retries).Count -eq 1 -and $pbNag.Seen.Count -eq 2 -and $pbNag.Seen[1].There -and $pbNag.Seen[1].Entries -eq 0 -and
    $pbNag.Seen[1].Sha -ceq $pbSha -and $pbN1Row.facts['probe']['collected'] -eq 3 -and $pbNag.Pids.Count -eq 2 -and $pbNag.Pids[0] -ne $pbNag.Pids[1] -and $pbN1Row.facts['probe']['pid'] -eq $pbNag.Pids[1] }
$pbNag.Launches = 0; $pbNag.Seen.Clear(); $pbNag.Pids.Clear(); $pbNag.Spec = & $pbSpecOf @{}
& $setOnce $pbNagOnce
try { $pbN2 = & $pbRunOf $pbCfgF 'po' $pbNag.Spec } finally { & $setOnce $realOnce }
$pbN2Row = & $pbRowOf $pbN2 't1'
Write-SafeCase 'end to end: probe: a licence reminder ends a first launch that wrote into the directory: no retry, the row INCOMPLETE with the reminder and why it was not started again, what was written collected' { "$($pbN2.Why)$($pbN2Row.detail)" } $true {
    $pbN2.Run.verdict -ceq 'INCOMPLETE' -and $pbN2Row.status -ceq 'INCOMPLETE' -and $pbN2Row.detail -clike 'stuck on dialog license-nag *, ended; not retried: the first launch wrote into t1.out; probe: 3 files collected, * bytes' -and
    @($pbN2.Run.runs[0].retries).Count -eq 0 -and $pbNag.Launches -eq 1 }
# A probe scenario that does not run because learning failed: nothing to collect, and its row says only why it did not run
$pbGapOnce = {
    param([Alias('Ctx')]$RunCtx, $HostArgs, $Label)
    $launched = & $realOnce -Ctx $RunCtx -HostArgs $HostArgs -Label $Label
    if ($Label -ceq 'learn') { $launched.Status = 'Timeout' }
    $launched
}.GetNewClosure()
& $setOnce $pbGapOnce
try { $pbGap = & $pbRunOf $pbCfgF 'pg' (& $pbSpecOf @{}) } finally { & $setOnce $realOnce }
$pbGapRow = & $pbRowOf $pbGap 't1'
$pbGapFacts = & $safe { $pbGapRow.facts }
Write-SafeCase 'end to end: probe: a probe scenario learning did not cover is not run, nothing is collected for it and its row has no probe facts' { "$($pbGap.Why)$($pbGapRow.detail)" } $true {
    $pbGap.Run.verdict -ceq 'INCOMPLETE' -and $pbGapRow.status -ceq 'INCOMPLETE' -and $pbGapRow.detail -clike 'not run: *' -and $pbGapRow.detail -cnotlike '*probe*' -and
    ($null -eq $pbGapFacts -or -not $pbGapFacts.Contains('probe')) }
# The same reminder on the one driver launch of a render judged by a report: its probe directory is an output of that
# launch too, so files the first launch wrote mean no retry
$pbCfgJ = & $writeVariant { param($c) & $pbChange $c @($pbJudged) }
$pbCfgJ.ReaperExe = $pwshExe
$pbNag.Launches = 0; $pbNag.Seen.Clear(); $pbNag.Pids.Clear(); $pbNag.Spec = & $pbSpecOf @{}
& $setOnce $pbNagOnce
try { $pbN3 = & $pbRunOf $pbCfgJ 'pj' $pbNag.Spec } finally { & $setOnce $realOnce }
$pbN3Row = & $pbRowOf $pbN3 'tr'
Write-SafeCase 'end to end: probe: a licence reminder ends the driver launch of a render judged by a report after it wrote into the directory: no retry, and the row says why' { "$($pbN3.Why)$($pbN3Row.detail)" } $true {
    $pbN3.Run.verdict -ceq 'INCOMPLETE' -and $pbN3Row.status -ceq 'INCOMPLETE' -and $pbN3Row.detail -clike '*stuck on dialog license-nag *, ended; not retried: the first launch wrote into tr.out*' -and
    @($pbN3.Run.runs[0].retries).Count -eq 0 -and $pbNag.Launches -eq 1 -and $pbN3Row.facts['probe']['collected'] -eq 3 }

# ---- listing parameters ----
# Fixture Gain with parameters of its own: a name used twice, one with a path in it, REAPER's three at the end
$gainName = 'VST3: Fixture Gain (Fixture Audio)'
$listSpec = @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs; HostParams = $true
    Params = @{ $gainName = @(@{ Name = 'Gain'; Value = 0.5 }, @{ Name = 'Gain'; Value = 0.25 }, @{ Name = 'Path //server/x'; Value = 0 }, @{ Name = 'Mode'; Value = 1 }) } }
$setList = { param([hashtable]$More = @{}) $spec = $listSpec.Clone(); foreach ($k in @($More.get_Keys())) { $spec[$k] = $More[$k] }; Set-FakeReaper $spec }
$listE2e = $e2e.Clone(); $listE2e.ResultDir = Join-Path $Work 'e2e-list'
$listRun = { param([hashtable]$Bound = @{ List = 'params' }, [hashtable]$Cfg = $listE2e) Invoke-HarnessSuite @Cfg -List (Test-HarnessListRequest -Bound $Bound) -SelfTestHooks $hooks -KeepWork }
$listedOf = { param($Res, [string]$PluginId) @($Res.listing['plugins'] | Where-Object { $_['id'] -ceq $PluginId })[0] }
$paramsRow = { param($Res) & $rowOf $Res 'params' }
& $setList
try {
    $lr = & $listRun
    $lrPath = Write-HarnessResult -Data $lr -ResultDir $listE2e.ResultDir
    $lrJson = [IO.File]::ReadAllText($lrPath)
    $lrBack = ConvertFrom-HarnessJson $lrJson
    $lg = @($lrBack['listing']['plugins'] | Where-Object { $_['id'] -ceq 'gain' })[0]
    $lgParams = @($lg['params'])
    $field = { param([string]$Name) @($lgParams | ForEach-Object { [string]$_[$Name] }) -join '|' }
    Write-Case "listing end to end: -List params is one learn launch: rows learn and params PASS and nothing else, module check PASS, default directory unchanged ($(& $rowIds $lr); $((& $paramsRow $lr).detail))" $false (
        & $holds { $lr.verdict -ceq 'PASS' -and (& $rowIds $lr) -ceq 'learn,params' -and (& $paramsRow $lr).status -ceq 'PASS' -and @($lr.runs).Count -eq 1 -and $lr.launches -eq 1 -and
            $lr.runs[0].moduleCheck.status -ceq 'PASS' -and $lr.runs[0].defaultCfgDir.unchanged -and $lr.runs[0].reaperProcessesLeft -eq 0 -and (Split-Path -Leaf $lrPath) -cmatch '^\d{8}-\d{6}-fixture-[0-9a-f-]+-list-params\.json$' })
    Write-Case "listing end to end: every parameter with its index, name, value and display as REAPER read it; paramCount equals nparams ($(& $field 'name'))" $false (
        & $holds { $lrBack['listing']['kind'] -ceq 'params' -and $null -eq $lrBack['listing']['values'] -and $lrBack['listing']['readAt']['sr'] -eq 48000 -and $lrBack['listing']['readAt']['block'] -eq 512 -and
            (@($lrBack['listing']['plugins'] | ForEach-Object { $_['id'] }) -join ',') -ceq 'gain,bus,delay' -and
            (& $field 'index') -ceq '0|1|2|3|4|5|6' -and (& $field 'name') -ceq 'Gain|Gain|Path <path>|Mode|Bypass|Wet|Delta' -and (& $field 'normalized') -ceq '0.5|0.25|0|1|0|1|0' -and
            (& $field 'display') -ceq '0.50|0.25|0.00|1.00|0.00|1.00|0.00' -and (& $field 'ident') -ceq '0:1000|1:1001|2:1002|3:1003|4:bypass|5:wet|6:delta' -and (& $field 'host') -ceq 'False|False|False|False|True|True|True' -and
            $lg['paramCount'] -eq 7 -and $lg['nparams'] -eq 7 -and (@($lg['hostBy']) -join ',') -ceq 'ident' -and $lg['listed'] -and $lg['status'] -ceq 'PASS' -and $lg['bundle'] -ceq 'Fixture Gain.vst3' -and
            $lg['class']['name'] -ceq 'Fixture Gain' -and $lg['classFrom'] -ceq 'moduleinfo' -and $lg['blockSha256'] -cmatch '^[0-9a-f]{64}$' -and $lg['pdc'] -eq 0 -and
            @(@($lrBack['listing']['plugins']) | Where-Object { $_['paramCount'] -ne $_['nparams'] -or -not $_['listed'] }).Count -eq 0 })
    Write-Case "listing end to end: a name used twice points at the first; a name with a path in it is masked, and no path is in the file; only the first Gain and Mode are settable ($(& $field 'settable'))" $true (
        & $holds { (& $field 'sameNameAs') -ceq '|0|||||' -and (& $field 'masked') -ceq 'False|False|True|False|False|False|False' -and (& $field 'settable') -ceq 'True|False|False|True|False|False|False' -and
            $lrJson -cnotlike '*//server*' -and $lrJson -cnotmatch '[A-Za-z]:\\\\' })
    # The tie: the listing's block hash is the one a kept render's manifest has for the same plugin with no params and no
    # state (the stand-in saves the same state every time). The ordinary run's learn launch lists nothing.
    $tieCfg = & $writeVariant { param($c) & $noExt $c; $c.layouts = @{ tie = @{ tracks = @(@{ name = 'Voice'; source = $true; fx = @(@{ plugin = 'gain' }, @{ plugin = 'bus' }) }) } }; $c.scenarios = @(@{ id = 'tie-kept'; kind = 'render'; layout = 'tie'; compare = 'none'; keep = $true }); $c.negative = @() }
    $tieCfg.ReaperExe = $pwshExe; $tieCfg.ResultDir = Join-Path $Work 'e2e-tie'
    $tieRun = Invoke-HarnessSuite @tieCfg -NoNegative -SelfTestHooks $hooks -KeepWork
    $tieJob = try { ConvertFrom-FakeLua ([IO.File]::ReadAllText((Join-Path @(Get-ChildItem -LiteralPath (Join-Path $tieCfg.ResultDir 'work') -Directory)[0].FullName '_learn-1.job.lua'))) } catch { @{ fx = @() } }
    Write-Case "listing end to end: an ordinary run lists nothing: no entry of its learn job asks for a listing or a sweep, and its listing is null ($(@($tieJob['fx']).Count) entries)" $true (
        & $holds { $tieRun.verdict -ceq 'PASS' -and @($tieJob['fx']).Count -ge 2 -and @($tieJob['fx'] | Where-Object { $_.Contains('list') -or $_.Contains('sweep') }).Count -eq 0 -and $null -eq $tieRun.listing })
    $tieList = & $listRun @{ List = 'params' } $tieCfg
    $tieFx = try {
        $tieKeep = @(Get-ChildItem -LiteralPath (Join-Path $tieCfg.ResultDir 'renders') -Directory)[0].FullName
        @((ConvertFrom-HarnessJson @([IO.File]::ReadAllText((Join-Path $tieKeep 'manifest.jsonl')) -split "`n" | Where-Object { $_ })[0])['fx'])
    } catch { @() }
    $tieOf = { param([string]$PluginId) [string](@($tieFx | Where-Object { $_['plugin'] -ceq $PluginId })[0])['blockSha256'] }
    Write-Case "listing end to end: the block hash of a listed plugin is the blockSha256 a kept render's manifest has for it with no params and no state ($(& $tieOf 'gain'))" $true (
        & $holds { $tieRun.verdict -ceq 'PASS' -and $tieList.verdict -ceq 'PASS' -and (& $tieOf 'gain') -cmatch '^[0-9a-f]{64}$' -and (& $tieOf 'gain') -ceq (& $listedOf $tieList 'gain')['blockSha256'] -and
            (& $tieOf 'bus') -ceq (& $listedOf $tieList 'bus')['blockSha256'] -and (& $tieOf 'gain') -cne (& $tieOf 'bus') })
    # A sweep of one plugin: only that plugin is installed and learned, one entry in the learn job, swept on it
    $sw = Invoke-HarnessSuite @listE2e -List (Test-HarnessListRequest -Bound @{ List = 'params'; ListPlugin = 'gain'; ListParam = 'Gain'; ListValues = '0,0.5,1' }) -SelfTestHooks $hooks -KeepWork -InformationVariable swSaid
    $swJob = try { ConvertFrom-FakeLua ([IO.File]::ReadAllText((Join-Path @(Get-ChildItem -LiteralPath (Join-Path $listE2e.ResultDir 'work') -Directory | Sort-Object Name)[-1].FullName '_learn-1.job.lua'))) } catch { @{ fx = @() } }
    $swGain = & $listedOf $sw 'gain'
    $swValues = { param($Sweep) @($Sweep['values'] | ForEach-Object { "$($_['normalized'])/$($_['readNormalized'])/$($_['display'])/$($_['displayUsable'])" }) -join ',' }
    Write-Case "listing end to end: -ListPlugin gain -ListParam Gain -ListValues 0,0.5,1 sets and reads each value on a fresh instance ($(try { & $swValues @($swGain['sweeps'])[0] } catch { 'no sweep' }))" $false (
        & $holds { $sw.verdict -ceq 'PASS' -and @($swGain['sweeps']).Count -eq 1 -and @($swGain['sweeps'])[0]['name'] -ceq 'Gain' -and @($swGain['sweeps'])[0]['index'] -eq 0 -and
            (& $swValues @($swGain['sweeps'])[0]) -ceq '0/0/0.00/True,0.5/0.5/0.50/True,1/1/1.00/True' -and ($sw.listing['values'] -join ',') -ceq '0,0.5,1' -and (& $paramsRow $sw).detail -ceq '1 plugin listed, 7 parameters, 1 swept at 3 values' })
    Write-Case "listing end to end: -ListPlugin picks what is installed and learned: one plugin in the result, one entry in the learn job, the sweep on it ($(@($sw.plugins | ForEach-Object { $_['name'] }) -join ', '))" $false (
        & $holds { @($sw.plugins).Count -eq 1 -and @($sw.listing['plugins']).Count -eq 1 -and @($swJob['fx']).Count -eq 1 -and $swJob['fx'][0]['list'] -and (@($swJob['fx'][0]['sweep']['names']) -join ',') -ceq 'Gain' -and
            (@($swJob['fx'][0]['sweep']['values']) -join ',') -ceq '0,0.5,1' })
    $swLines = @($swSaid | ForEach-Object { [string]$_.MessageData })
    Write-Case "listing end to end: the console says what is listed and swept before the launch, then the params row and a line per plugin ($(@($swLines | Where-Object { $_ -clike '*swept*' }) -join ' | '))" $false (
        $swLines -ccontains 'listing the parameters of 1 plugin in one learn launch (1 parameter swept at 3 values)' -and $swLines -ccontains '  [PASS] params  1 plugin listed, 7 parameters, 1 swept at 3 values' -and
        $swLines -ccontains '    gain: 7 parameters (3 of them REAPER''s own, 2 settable), 1 name used more than once, 1 swept at 3 values')
    $nf = & $listRun @{ List = 'params'; ListPlugin = 'gain'; ListParamFile = (& { $f = Join-Path $Work 'sweep-names.txt'; [IO.File]::WriteAllText($f, "Mode`nVolume`n"); $f }) }
    Write-Case "listing end to end: a swept name the plugin does not have is notFound and the params row FAILs ($((& $paramsRow $nf).detail))" $true (
        & $holds { $nf.verdict -ceq 'FAIL' -and (& $paramsRow $nf).status -ceq 'FAIL' -and (@((& $listedOf $nf 'gain')['notFound']) -join ',') -ceq 'Volume' -and @((& $listedOf $nf 'gain')['sweeps']).Count -eq 1 -and
            @((& $listedOf $nf 'gain')['sweeps'])[0]['values'].Count -eq 5 -and (& $rowOf $nf 'learn').status -ceq 'PASS' })
    $factsOf = { param($Res) try { $f = (& $paramsRow $Res).facts; "plugins=$($f.plugins) listed=$($f.listed) params=$($f.params) sweeps=$($f.sweeps) notFound=$(@($f.notFound) -join '|')" } catch { 'no facts' } }
    Write-Case "listing end to end: the facts of the params row count the plugins, those listed, their parameters, the sweeps and the names not found ($(& $factsOf $lr); $(& $factsOf $nf))" $false (
        & $holds { (& $factsOf $lr) -ceq "plugins=3 listed=3 params=$((@($lr.listing['plugins'] | ForEach-Object { [int]$_['paramCount'] }) | Measure-Object -Sum).Sum) sweeps=0 notFound=" -and
            (& $factsOf $sw) -ceq 'plugins=1 listed=1 params=7 sweeps=1 notFound=' -and (& $factsOf $nf) -ceq 'plugins=1 listed=1 params=7 sweeps=1 notFound=Volume' })
    $whyOf = @{ ListError = '*the driver stopped listing: driver.lua:1: listing stopped*'; SweepError = '*the driver stopped sweeping: driver.lua:1: sweep stopped*' }
    foreach ($fault in 'ListError', 'ListCountEnd', 'SweepNoAdd', 'SweepOtherName', 'SweepOtherBinary', 'SweepError') {
        & $setList @{ $fault = $true }
        $fr = & $listRun @{ List = 'params'; ListPlugin = 'gain'; ListParam = 'Mode'; ListValues = '0,1' }
        Write-Case "listing end to end: $fault makes the listing of that plugin INCOMPLETE, not listed, with the reason; no parameter of it in the result ($((& $paramsRow $fr).detail))" $true (
            & $holds { $fr.verdict -ceq 'INCOMPLETE' -and (& $paramsRow $fr).status -ceq 'INCOMPLETE' -and -not (& $listedOf $fr 'gain')['listed'] -and (& $listedOf $fr 'gain')['why'] -clike 'not listed: *' -and
                @((& $listedOf $fr 'gain')['params']).Count -eq 0 -and (& $rowOf $fr 'learn').status -ceq 'PASS' -and
                (-not $whyOf.ContainsKey($fault) -or (& $listedOf $fr 'gain')['why'] -clike $whyOf[$fault]) })
    }
    foreach ($fault in 'ListDrop', 'ListInexact') {
        & $setList @{ $fault = $true }
        $fr = & $listRun @{ List = 'params'; ListPlugin = 'gain' }
        Write-Case "listing end to end: $fault makes one parameter unclean: INCOMPLETE, the plugin listed with every parameter, that one not settable ($((& $paramsRow $fr).detail))" $true (
            & $holds { $fr.verdict -ceq 'INCOMPLETE' -and (& $paramsRow $fr).status -ceq 'INCOMPLETE' -and (& $listedOf $fr 'gain')['listed'] -and @((& $listedOf $fr 'gain')['params']).Count -eq 7 -and
                (& $listedOf $fr 'gain')['why'] -ceq '1 parameter could not be read cleanly' -and @((& $listedOf $fr 'gain')['params'])[1]['problem'] -and @((& $listedOf $fr 'gain')['params'] | Where-Object { $_['problem'] }).Count -eq 1 })
    }
    # A plugin learn could not add: the learn row FAILs, that plugin is not listed and points at it, the others are listed
    $noBus = $plugins.Clone(); $noBus.Remove('VST3: Fixture Bus (Fixture Audio)')
    & $setList @{ Plugins = $noBus }
    $lf = & $listRun
    Write-Case "listing end to end: a plugin learn could not add makes the learn row FAIL; it is not listed, pointing at the learn row; the others are listed ($((& $paramsRow $lf).detail))" $true (
        & $holds { $lf.verdict -ceq 'FAIL' -and (& $rowOf $lf 'learn').status -ceq 'FAIL' -and -not (& $listedOf $lf 'bus')['listed'] -and (& $listedOf $lf 'bus')['why'] -ceq 'not listed: its learn entry did not pass (see the learn row)' -and
            (& $listedOf $lf 'gain')['listed'] -and (& $listedOf $lf 'delay')['listed'] -and (& $paramsRow $lf).status -ceq 'INCOMPLETE' })
    # A listing checks the bundles of the plugins it lists only: one of another plugin missing does not skip it
    & $setList
    $gainOnlyDir = Join-Path $Work 'list-plugins-gain-only'
    $null = New-Item -ItemType Directory -Force -Path $gainOnlyDir
    Copy-Item -LiteralPath (Join-Path $listE2e.PluginDir 'Fixture Gain.vst3') -Destination $gainOnlyDir -Recurse
    $gainOnlyCfg = $listE2e.Clone(); $gainOnlyCfg.PluginDir = $gainOnlyDir
    $oneOk = & $listRun @{ List = 'params'; ListPlugin = 'gain' } $gainOnlyCfg
    $allSkip = & $listRun @{ List = 'params' } $gainOnlyCfg
    Write-Case "listing end to end: with the bus bundle missing, -ListPlugin gain lists gain (PASS) and listing every plugin is SKIPPED ($($oneOk.verdict) $(@($oneOk.skipReasons) -join '; '); $($allSkip.verdict) $(@($allSkip.skipReasons) -join '; '))" $true (
        & $holds { $oneOk.verdict -ceq 'PASS' -and @($oneOk.skipReasons).Count -eq 0 -and @($oneOk.listing['plugins']).Count -eq 1 -and (& $listedOf $oneOk 'gain')['listed'] -and
            $allSkip.verdict -ceq 'SKIPPED' -and @($allSkip.skipReasons -match '^plugin bus: bundle Fixture Bus\.vst3 not found').Count -eq 1 })
    # A round that breaks before its listing is read still says what it listed: no plugin, and why
    $realListing = Get-Command Get-HarnessParamListing -CommandType Function
    $listingBreaks = { param($ctx, $request, [string]$notRead = '') if (-not $notRead) { throw 'the listing broke' }; & $realListing -Ctx $ctx -Request $request -NotRead $notRead }.GetNewClosure()
    $broke = Invoke-WithSuiteCommand 'Get-HarnessParamListing' $listingBreaks { & $listRun }
    Write-Case "listing end to end: a round that breaks before its listing is read is INCOMPLETE, and its listing has every plugin not listed, saying why ($(& $rowIds $broke))" $true (
        & $holds { $broke.verdict -ceq 'INCOMPLETE' -and (& $rowIds $broke) -ceq 'learn,round-error' -and (& $rowOf $broke 'round-error').detail -clike '*the listing broke' -and
            @($broke.listing['plugins']).Count -eq 3 -and @($broke.listing['plugins'] | Where-Object { $_['listed'] -or $_['why'] -cne 'not listed: the round stopped before the listing was read' }).Count -eq 0 })
} finally { Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = $plugins; Seen = $seenArgs } }

# ---- what a round counts as left behind ----
$oneScenario = @{ Only = '^chain-offline-48000$'; NoNegative = $true }
# A reaper.exe of somebody else appearing while the round runs: the locks are free between launches, so that can happen
$byNameCalls = @{ N = 0 }
$r = Invoke-WithSuiteCommand 'Get-HarnessReaperProcessIds' { $byNameCalls.N++; if ($byNameCalls.N -gt 1) { 4242 } }.GetNewClosure() { Invoke-HarnessSuite @e2e @oneScenario -SelfTestHooks $hooks }
Write-Case 'left behind: only a reaper.exe of somebody else on the machine does not turn a green round red, and is not counted' $false ($r.verdict -ceq 'PASS' -and $r.runs[0].verdict -ceq 'PASS' -and $r.runs[0].reaperProcessesLeft -eq 0)
# A process this round started, and no launch reported: the launch says it has exited, and it has not
$leftBox = @{ Pid = 0 }
$leftSleep = New-StandIn 'Start-Sleep -Seconds 60' @{}
$saysExited = { param($psi) $real = & $leftSleep $psi; $leftBox.Pid = $real.Id; [pscustomobject]@{ Id = $real.Id; HasExited = $true; ExitCode = 0 } }.GetNewClosure()
$leftHooks = @{ Launcher = $saysExited; ModuleSampler = $hooks.ModuleSampler }
$r = Invoke-HarnessSuite @e2e @oneScenario -SelfTestHooks $leftHooks
try { Write-Case 'left behind: a process this round started that did not exit makes the round FAIL, and is counted' $true ($leftBox.Pid -gt 0 -and -not (& $gone $leftBox.Pid) -and $r.verdict -ceq 'FAIL' -and $r.runs[0].verdict -ceq 'FAIL' -and $r.runs[0].reaperProcessesLeft -eq 1 -and $r.runs[0].stillRunning -eq $false) }
finally { if ($leftBox.Pid) { & $endStandIn $leftBox.Pid } }
# Watching fails in a real round: its process is ended, so nothing is left, and the round has no conclusion
$errorBox = @{ Pid = 0 }
$errorHooks = @{ Launcher = (New-TrackedLauncher (New-StandIn 'Start-Sleep -Seconds 60' @{}) $errorBox); ModuleSampler = { param($proc) throw 'the module list broke' } }
$r = Invoke-HarnessSuite @e2e @oneScenario -SelfTestHooks $errorHooks
Write-Case 'end to end: watching fails: the round is INCOMPLETE, not FAIL, its process is gone and nothing is left' $true ($errorBox.Pid -gt 0 -and (& $gone $errorBox.Pid) -and $r.verdict -ceq 'INCOMPLETE' -and $r.runs[0].reaperProcessesLeft -eq 0 -and $r.runs[0].stillRunning -eq $false -and $r.runs[0].scenarios[0].detail -clike '*watching the process failed and it was ended: the module list broke*')

# ---- an unexpected error in a round, and outside the rows ----
$faultPath = 'C:\Us' + 'ers\John Smith\x y.wav' # assembled: the repository's privacy scan flags a complete user directory path
$faultHooks = $hooks.Clone()
$faultHooks.RoundFault = { throw "boom at $faultPath" }.GetNewClosure()
$r = Invoke-HarnessSuite @e2e @oneScenario -Repeat 2 -SelfTestHooks $faultHooks
$lastRow = @($r.runs[0].scenarios)[-1]
Write-Case 'round breaks: the round and the run are INCOMPLETE, a row says why without a path' $true ($r.verdict -ceq 'INCOMPLETE' -and $r.runs[0].verdict -ceq 'INCOMPLETE' -and $lastRow.id -ceq 'round-error' -and $lastRow.status -ceq 'INCOMPLETE' -and $lastRow.detail -ceq 'the round stopped on an unexpected error: boom at <path>')
Write-Case 'round breaks: no further round runs, and the module check says it did not run' $true (@($r.runs).Count -eq 1 -and $r.runs[0].stoppedBecause -clike '*unexpected error*' -and $r.runs[0].moduleCheck.status -ceq 'INCOMPLETE')
# The facts of the learn row are masked like those of every other row, keys too
$learnFacts = [ordered]@{ variants = 1; modules = 'Proven'; place = "at $faultPath"; $faultPath = 1 }
$r = Invoke-WithSuiteCommand 'Invoke-HarnessLearn' { [pscustomobject]@{ Status = 'INCOMPLETE'; Detail = 'stub learn'; Facts = $learnFacts } }.GetNewClosure() { Invoke-HarnessSuite @e2e @oneScenario -SelfTestHooks $hooks }
$learnRow = @($r.runs[0].scenarios)[0]
Write-Case 'learn row: a path in its facts is masked, in a value and in a key' $true ($learnRow.id -ceq 'learn' -and $learnRow.facts.place -ceq 'at <path>' -and $learnRow.facts.Contains('<path>') -and -not $learnRow.facts.Contains($faultPath))
$refusedHooks = $hooks.Clone()
$refusedHooks.RoundFault = { throw 'REFUSED: stub' }
$r = Invoke-HarnessSuite @e2e @oneScenario -SelfTestHooks $refusedHooks
$lastRow = @($r.runs[0].scenarios)[-1]
Write-Case 'round breaks: a guard that refuses inside a round is a row like any other: INCOMPLETE, the end of the round is still checked' $true ($r.verdict -ceq 'INCOMPLETE' -and $lastRow.id -ceq 'round-error' -and $lastRow.detail -clike '*REFUSED: stub*' -and $r.runs[0].defaultCfgDir.unchanged)
$turned = @{ N = 0 }
$turning = { $turned.N++; [ordered]@{ 'reaper.ini' = "1|$($turned.N)" } }.GetNewClosure()
$r = Invoke-WithSuiteCommand 'Get-HarnessDefaultCfgSnapshot' $turning { Invoke-HarnessSuite @e2e @oneScenario -SelfTestHooks $faultHooks }
Write-Case 'round breaks: the default resource directory is still checked: a change is FAIL, and named' $true ($r.verdict -ceq 'FAIL' -and ($r.runs[0].defaultCfgDir.changed -join ',') -ceq 'changed:reaper.ini')
$leftBox.Pid = 0
$leftFault = @{ Launcher = $saysExited; ModuleSampler = $hooks.ModuleSampler; RoundFault = $faultHooks.RoundFault }
$r = Invoke-HarnessSuite @e2e @oneScenario -SelfTestHooks $leftFault
try { Write-Case 'round breaks: a process it left is still counted: FAIL' $true ($leftBox.Pid -gt 0 -and $r.verdict -ceq 'FAIL' -and $r.runs[0].reaperProcessesLeft -eq 1) }
finally { if ($leftBox.Pid) { & $endStandIn $leftBox.Pid } }
$snapshots = @{ N = 0 }
$thirdThrows = { $snapshots.N++; if ($snapshots.N -ge 3) { throw 'the listing broke' }; [ordered]@{ 'reaper.ini' = '1|1' } }.GetNewClosure()
$r = Invoke-WithSuiteCommand 'Get-HarnessDefaultCfgSnapshot' $thirdThrows { Invoke-HarnessSuite @e2e @oneScenario -Repeat 2 -SelfTestHooks $hooks }
Write-Case 'run stops: a green round before an unexpected error does not make the run green: INCOMPLETE, the error is in the result' $true ($r.verdict -ceq 'INCOMPLETE' -and @($r.runs).Count -eq 1 -and $r.runs[0].verdict -ceq 'PASS' -and $r.error -ceq 'the listing broke')
$stoppedFile = Write-HarnessResult -Data $r -ResultDir $e2e.ResultDir
Write-Case 'run stops: the result file has the verdict and the error' $true ((ConvertFrom-HarnessJson ([IO.File]::ReadAllText($stoppedFile)))['error'] -ceq 'the listing broke')
$r = Invoke-WithSuiteCommand 'Install-HarnessPlugins' { throw "copy failed: $faultPath" }.GetNewClosure() { Invoke-HarnessSuite @e2e @oneScenario -SelfTestHooks $hooks }
Write-Case 'run stops: an error while installing the plugins is INCOMPLETE, no rounds, nothing started, no path in the error' $true ($r.verdict -ceq 'INCOMPLETE' -and @($r.runs).Count -eq 0 -and $r.launches -eq 0 -and $r.error -ceq 'copy failed: <path>')
Write-Case 'run stops: a guard that refuses in there is still refused' $true (Test-Throws { Invoke-WithSuiteCommand 'Install-HarnessPlugins' { throw 'REFUSED: stub' } { $null = Invoke-HarnessSuite @e2e @oneScenario -SelfTestHooks $hooks } } 'REFUSED: stub')
Write-Case 'run stops: a usage error in there is still a usage error' $true (Test-Throws { Invoke-WithSuiteCommand 'Install-HarnessPlugins' { throw 'USAGE: stub' } { $null = Invoke-HarnessSuite @e2e @oneScenario -SelfTestHooks $hooks } } 'USAGE: stub')

# ---- a process the watchdog could not end, in a whole run of two rounds ----
$stuckBox = @{ Pid = 0 }
$stuckHooks = @{ Launcher = (New-TrackedLauncher $hooks.Launcher $stuckBox); ModuleSampler = $hooks.ModuleSampler; Stopper = $noStop }
$launchesBefore = $seenArgs.Count
$r = Invoke-HarnessSuite @e2e -Only '^neg-killed$' -Repeat 2 -SelfTestHooks $stuckHooks
try {
    Write-Case 'end to end: a process that could not be ended makes the round and the run INCOMPLETE, not FAIL, and it is counted' $true ($r.verdict -ceq 'INCOMPLETE' -and $r.runs[0].verdict -ceq 'INCOMPLETE' -and $r.runs[0].stillRunning -eq $true -and $r.runs[0].reaperProcessesLeft -eq 1 -and -not (& $gone $stuckBox.Pid))
    Write-Case 'end to end: after it no further round runs and nothing else was started' $true (@($r.runs).Count -eq 1 -and $r.runs[0].stoppedBecause -like '*could not be ended*' -and $r.launches -eq 1 -and $seenArgs.Count -eq $launchesBefore + 1)
    Write-Case 'end to end: the GUI lock stays held after the run' $true ((& $probeExit) -eq 1)
} finally { if ($stuckBox.Pid) { & $endStandIn $stuckBox.Pid }; & $releaseKept }
# A negative case of a configuration expecting just that: its row is PASS, and the round still is not green
$ownStuck = & $writeVariant { param($c) & $noExt $c; $c.limits = @{ renderTimeoutSec = 1 }; $c.scenarios = @(@{ id = 'one'; kind = 'render'; layout = 'chain' }); $c.negative = @(@{ id = 'own-stuck'; kind = 'render'; layout = 'chain'; expect = 'INCOMPLETE'; expectDetail = 'could not end process' }) }
$ownStuck.ReaperExe = $pwshExe; $ownStuck.ResultDir = $e2e.ResultDir
$ownBox = @{ Pid = 0 }
$sleepRender = New-StandIn 'Start-Sleep -Seconds 60' @{}
$fakeLaunch = $hooks.Launcher
$renderHangs = { param($psi) if ('-renderproject' -cin @($psi.ArgumentList)) { $sleeper = & $sleepRender $psi; $ownBox.Pid = $sleeper.Id; $sleeper } else { & $fakeLaunch $psi } }.GetNewClosure()
$r = Invoke-HarnessSuite @ownStuck -Only '^own-stuck$' -SelfTestHooks @{ Launcher = $renderHangs; ModuleSampler = $hooks.ModuleSampler; Stopper = $noStop }
try { Write-Case 'end to end: every row green and the module check too, but a process could not be ended: the round is INCOMPLETE' $true ($ownBox.Pid -gt 0 -and @($r.runs[0].scenarios | Where-Object { $_.status -cne 'PASS' }).Count -eq 0 -and $r.runs[0].moduleCheck.status -ceq 'PASS' -and $r.runs[0].verdict -ceq 'INCOMPLETE' -and $r.verdict -ceq 'INCOMPLETE') }
finally { if ($ownBox.Pid) { & $endStandIn $ownBox.Pid }; & $releaseKept }

# ---- a default resource directory that could not be listed in full, in a whole run of two rounds ----
$closedListing = { [ordered]@{ 'reaper.ini' = '1|1'; 'Data' = 'unreadable' } }
$r = Invoke-WithSuiteCommand 'Get-HarnessDefaultCfgSnapshot' $closedListing { Invoke-HarnessSuite @e2e @oneScenario -Repeat 2 -SelfTestHooks $hooks }
Write-Case 'end to end: part of the default resource directory could not be listed, every row green: INCOMPLETE, not FAIL' $true ($r.verdict -ceq 'INCOMPLETE' -and $r.runs[0].verdict -ceq 'INCOMPLETE' -and @($r.runs[0].scenarios | Where-Object { $_.status -cne 'PASS' }).Count -eq 0)
Write-Case 'end to end: after that no further round runs, the row says why and names the entry' $true (@($r.runs).Count -eq 1 -and $r.runs[0].stoppedBecause -like '*could not be listed*' -and $r.runs[0].defaultCfgDir.unchanged -eq $false -and @($r.runs[0].defaultCfgDir.changed).Count -eq 0 -and ($r.runs[0].defaultCfgDir.unreadable -join ',') -ceq 'Data')
$closedLater = @{ N = 0 }
$turnsUnreadable = { $closedLater.N++; if ($closedLater.N -eq 1) { [ordered]@{ 'Data' = 'dir'; 'Data\a.ini' = '1|1' } } else { [ordered]@{ 'Data' = 'unreadable' } } }.GetNewClosure()
$r = Invoke-WithSuiteCommand 'Get-HarnessDefaultCfgSnapshot' $turnsUnreadable { Invoke-HarnessSuite @e2e @oneScenario -SelfTestHooks $hooks }
Write-Case 'end to end: a directory that could be listed before and not after is INCOMPLETE too: what is below it was not seen to change' $true ($r.verdict -ceq 'INCOMPLETE' -and $r.runs[0].stoppedBecause -notlike '*changed*')
$changedToo = @{ N = 0 }
$reallyChanged = { $changedToo.N++; [ordered]@{ 'reaper.ini' = "1|$($changedToo.N)"; 'Data' = 'unreadable' } }.GetNewClosure()
$r = Invoke-WithSuiteCommand 'Get-HarnessDefaultCfgSnapshot' $reallyChanged { Invoke-HarnessSuite @e2e @oneScenario -Repeat 2 -SelfTestHooks $hooks }
Write-Case 'end to end: a file that changed next to what could not be listed is FAIL, no further round runs, and the change is named' $true ($r.verdict -ceq 'FAIL' -and @($r.runs).Count -eq 1 -and ($r.runs[0].defaultCfgDir.changed -join ',') -ceq 'changed:reaper.ini' -and $r.runs[0].stoppedBecause -like '*changed*')

# ---- the private copy ----
# The module list shows the release build of the same name: not the private copy, so no conclusion (INCOMPLETE)
$sameName = Join-Path $env:COMMONPROGRAMFILES 'VST3\Fixture Gain.vst3\Contents\x86_64-win\Fixture Gain.vst3' # the release build of the shield case
$foreignSampler = { param($proc) @($sameName) }.GetNewClosure()
$r = Invoke-HarnessSuite @e2e -Only '^chain-offline-48000$' -NoNegative -SelfTestHooks @{ Launcher = $hooks.Launcher; ModuleSampler = $foreignSampler }
Write-Case 'end to end: a same-name binary from outside the private directory makes learn and the round INCOMPLETE, and nothing else runs' $true (
    $r.verdict -eq 'INCOMPLETE' -and $r.runs[0].scenarios[0].status -eq 'INCOMPLETE' -and $r.runs[0].scenarios[0].detail -like 'not the private copy*' -and $r.runs[0].scenarios[1].detail -ceq 'not run: learning saw a tested binary loaded from outside the private copy (see the learn row)' -and
    $r.runs[0].moduleCheck.status -eq 'INCOMPLETE')
$varyCfg = & $writeVariant $varyChange # the file is shared: written again as it was
$varyCfg.ReaperExe = $pwshExe; $varyCfg.ResultDir = Join-Path $Work 'e2e-vary-foreign'
$launchesBefore = $seenArgs.Count
$r = Invoke-HarnessSuite @varyCfg -Only '^vary-g025$' -NoNegative -SelfTestHooks @{ Launcher = $hooks.Launcher; ModuleSampler = $foreignSampler }
Write-Case "end to end: a binary from outside the private copy in the first of two learn launches: the second is not started, and nothing that needs learning runs ($(@($r.runs[0].scenarios | ForEach-Object { "$($_.id)=$($_.status)" }) -join ','))" $true (
    $r.verdict -ceq 'INCOMPLETE' -and (& $rowIds $r) -ceq 'learn.1,learn.2,vary-g025' -and @($r.runs[0].scenarios | Where-Object { $_.status -cne 'INCOMPLETE' }).Count -eq 0 -and
    (& $rowOf $r 'learn.2').detail -ceq 'not run: learning stopped at the learn.1 row' -and
    (& $rowOf $r 'vary-g025').detail -ceq 'not run: learning saw a tested binary loaded from outside the private copy (see the learn.1 row)' -and $seenArgs.Count -eq $launchesBefore + 1)
$r = Invoke-HarnessSuite @e2e -Only '^chain-offline-48000$' -NoNegative -SelfTestHooks @{ Launcher = $hooks.Launcher; ModuleSampler = { param($proc) @() } }
Write-Case 'end to end: a tested binary never seen loaded makes learn INCOMPLETE (the private copy is not proven)' $true ($r.verdict -eq 'INCOMPLETE' -and $r.runs[0].scenarios[0].detail -like '*not proven*')
# A state block of another plugin: a usage error before REAPER is ever started
$badCfg = Join-Path $Work 'cfg-state'
Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests/fixtures') -Destination $badCfg -Recurse
$loud = Join-Path $badCfg 'states\loud.RfxChain'
[IO.File]::WriteAllText($loud, [IO.File]::ReadAllText($loud).Replace('"VST3: Fixture Gain (Fixture Audio)"', '"VST3: Fixture Bus (Fixture Audio)"'))
$badRun = $e2e.Clone(); $badRun.Config = Join-Path $badCfg 'config.json'
$launchesBefore = $seenArgs.Count
Write-Case 'end to end: a state block of another plugin is a usage error naming the state; REAPER is never started' $true (
    (Test-Throws { $null = Invoke-HarnessSuite @badRun -SelfTestHooks $hooks } "USAGE: states: *plugins.gain.states.loud: the block is of 'VST3: Fixture Bus (Fixture Audio)'*") -and $seenArgs.Count -eq $launchesBefore)
Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = @{ ($plugins.get_Keys() | Where-Object { $_ -like '*Gain*' }) = $plugins[($plugins.get_Keys() | Where-Object { $_ -like '*Gain*' })] }; Seen = $seenArgs }
$r = Invoke-HarnessSuite @e2e -Only '^chain-offline-48000$' -NoNegative -SelfTestHooks $hooks
Write-Case 'end to end: a plugin REAPER cannot add makes learn FAIL with the plugin named, and the round FAIL' $true ($r.verdict -eq 'FAIL' -and $r.runs[0].scenarios[0].status -eq 'FAIL' -and $r.runs[0].scenarios[0].detail -like 'bus could not be added*')

# ---- the fixture extension ----
$ext = Import-HarnessExtensions (Read-HarnessConfigExtensions $configFile)
Write-Case 'extension: the fixture module registers its kind and preflight; the Lua file declares its step' $false ($ext.Kinds.ContainsKey('fixture-count') -and $ext.Preflight.Count -eq 1 -and ($ext.LuaSteps -join ',') -ceq 'fixture_ping' -and $ext.Lua.Count -eq 1)
$ectx = & $newCtx @($gui)
$ectx.Kinds = $ext.Kinds
$o = Invoke-HarnessScenario -Ctx $ectx -Scenario ([pscustomobject]@{ id = 'ext'; kind = 'fixture-count'; raw = [ordered]@{ count = 2 } })
Write-Case 'extension: a kind that never starts REAPER runs through Invoke-HarnessScenario and gets the API' $false ($o.Status -eq 'PASS' -and $o.Detail -ceq 'counted 2' -and $ectx.Launches -eq 0)
$env:REAPER_HARNESS_FIXTURE_SKIP = '1'
try { $r = Invoke-HarnessSuite @e2e -SelfTestHooks $hooks } finally { $env:REAPER_HARNESS_FIXTURE_SKIP = '' }
Write-Case 'extension: a preflight reason of an extension skips the whole suite, REAPER never started' $true ($r.verdict -eq 'SKIPPED' -and $r.launches -eq 0 -and ($r.skipReasons -match '^extension fixture: '))

# Keep this the last statement: the parent turns red when it does not see this case (an early exit 0 must not look green)
Write-Case 'child: reached its last statement' $false $true
