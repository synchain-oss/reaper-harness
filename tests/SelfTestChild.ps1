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
foreach ($m in 'Guard', 'Host', 'Locks', 'Json', 'Wav', 'Config', 'Rpp', 'Plugins', 'Scenarios', 'Learn', 'Extensions', 'Suite') { Import-Module (Join-Path $src "$m.psm1") -ErrorAction Stop }
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

$pwshExe = (Get-Process -Id $PID).Path
$flag = '-cfg' + 'file'
$gone = { param($ProcessId) $null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) }
$extra = @($ExtraLocks -split ';' | Where-Object { $_ })
# Fake system VST3 directories (REAPER's own additions to the plugin path): the shield scans these, not the machine's
$env:COMMONPROGRAMFILES = Join-Path $Work 'fake-common'
$env:LOCALAPPDATA = Join-Path $Work 'fake-local'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $env:COMMONPROGRAMFILES 'VST3'), (Join-Path $env:LOCALAPPDATA 'Programs\Common\VST3')

# Stand-in: replaces the start info Host prepared with another command and remembers the original command line
# (GetNewClosure keeps only the variables of the current scope: everything the block needs is copied into it first.)
function New-StandIn([string]$Command, [hashtable]$Seen) {
    $standInExe = $pwshExe
    { param($psi) $Seen.Args = $psi.Arguments; $Seen.Called = $true; $psi.FileName = $standInExe; $psi.Arguments = "-NoProfile -Command `"$Command`""; [Diagnostics.Process]::Start($psi) }.GetNewClosure()
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
    "Add-Type -AssemblyName System.Windows.Forms; `$r = [System.Windows.Forms.MessageBox]::Show('x', '$Title', '$Buttons'); Set-Content -LiteralPath '$OutFile' -Value `$r"
}

# ---- pinning ----
$pinned = Initialize-HarnessCfg $CfgA
Write-Case 'pin: Initialize pins the configuration directory; the configuration file argument only comes from the constant' $false ((Get-HarnessCfgArgument) -ceq ('"{0}"' -f $pinned.Ini))
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
$seenA = @{ Called = $false }
$bystander = [Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]::new($pwshExe, '-NoProfile -Command Start-Sleep -Seconds 120'))
try {
    $run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 2 -Launcher (New-StandIn 'Start-Sleep -Seconds 60' $seenA)
    Write-Case 'watchdog: ended at the timeout, status Timeout' $true ($run.Status -eq 'Timeout' -and (& $gone $run.Pid))
    Write-Case 'watchdog: only the PID it started is ended; a bystander process is still alive' $false (-not $bystander.HasExited)
    Write-Case 'command line: -nosplash -newinst and the configuration file argument of the private ini' $false ($seenA.Args -ceq ('-nosplash -newinst {0} "{1}"' -f $flag, $pinned.Ini))
} finally { if (-not $bystander.HasExited) { Stop-Process -Id $bystander.Id -Force } }
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 30 -KillAfterSec 1.5 -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
Write-Case 'watchdog: ended at the kill point, status Killed, without waiting for the timeout' $true ($run.Status -eq 'Killed' -and $run.Seconds -lt 8 -and (& $gone $run.Pid))
# The mark file appears after the process has exited (the stand-in waits for its process, then writes the mark):
# recorded as SampleLost with that reason
$quickMark = Join-Path $Work 'mark-after-exit.txt'
$quickLauncher = { param($psi) $psi.FileName = $pwshExe; $psi.Arguments = '-NoProfile -Command exit 0'; $p = [Diagnostics.Process]::Start($psi); $p.WaitForExit(); Set-Content -LiteralPath $quickMark -Value x; $p }.GetNewClosure()
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 30 -WatchFiles @{ loop = $quickMark } -Launcher $quickLauncher
Write-Case 'sampling: a mark that appears after the process exited is SampleLost, reported as "exited before the sample", not "missing"' $true ($run.Status -eq 'Exited' -and @($run.SampleLost) -contains 'loop' -and -not $run.Marks.Contains('loop') -and
    (Get-HarnessMarkProblem -Samples $run.Marks -LostAt @($run.SampleLost) -Need 'loop') -like '*exited before*')
$preMark = Join-Path $Work 'mark-present.txt'
Set-Content -LiteralPath $preMark -Value x
$exitedSampler = { param($p) [pscustomobject]@{ Exited = $true; Handles = $null; PrivateMB = $null; WorkingMB = $null } }
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 30 -KillAfterSec 1.5 -WatchFiles @{ warm = $preMark } -Sampler $exitedSampler -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
Write-Case 'sampling: a sample taken when the process has exited is SampleLost, empty counters are not taken as a sample' $true ($run.Status -eq 'Killed' -and @($run.SampleLost) -contains 'warm' -and -not $run.Marks.Contains('warm') -and (& $gone $run.Pid))
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 30 -Launcher (New-StandIn 'exit 3' @{})
Write-Case 'a process that exits by itself: status Exited, exit code recorded' $false ($run.Status -eq 'Exited' -and $run.ExitCode -eq 3)
Write-Case 'launch record: ExitedUtc is the exit the process reported, after the moment before the start, not later than now' $false (
    $run.ExitedUtc -ge $run.StartedUtc -and $run.ExitedUtc -le [DateTime]::UtcNow.AddSeconds(1) -and ($run.ExitedUtc - $run.StartedUtc).TotalSeconds -lt 20 -and $run.ExitedUtc.Kind -eq [DateTimeKind]::Utc)
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 30 -KillAfterSec 1.5 -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
Write-Case 'launch record: an ended process has ExitedUtc too (after the end, not later than now)' $false ($run.Status -eq 'Killed' -and $run.ExitedUtc -gt $run.StartedUtc.AddSeconds(1) -and $run.ExitedUtc -le [DateTime]::UtcNow.AddSeconds(1))
$xs = [DateTime]::new(2026, 10, 26, 6, 0, 0, [DateTimeKind]::Utc); $xd = $xs.AddSeconds(20)
$xr = { param($rep) Resolve-HarnessExitedUtc -Reported $rep -NotBeforeUtc $xs -NoticedUtc $xd }
Write-Case 'exit time: a reported time within [before the start, noticed + 1 s] is used (both ends included)' $false (
    (& $xr $xs.AddSeconds(19.9)) -eq $xs.AddSeconds(19.9) -and (& $xr $xs) -eq $xs -and (& $xr $xd.AddSeconds(1)) -eq $xd.AddSeconds(1) -and (& $xr $xs.AddSeconds(19.9)).Kind -eq [DateTimeKind]::Utc)
Write-Case 'exit time: a reported FILETIME 0 (1601-01-01 UTC, seen on real machines) is not used; the moment the exit was noticed is' $true ((& $xr ([DateTime]::FromFileTime(0).ToUniversalTime())) -eq $xd)
Write-Case 'exit time: reported 1 ms before the start: not used' $true ((& $xr $xs.AddMilliseconds(-1)) -eq $xd)
Write-Case 'exit time: reported 1 ms after noticed + 1 s: not used' $true ((& $xr $xd.AddSeconds(1).AddMilliseconds(1)) -eq $xd)
Write-Case 'exit time: nothing reported: the moment the exit was noticed' $true ((& $xr $null) -eq $xd -and (& $xr $null).Kind -eq [DateTimeKind]::Utc)
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 30 -Launcher (New-BadExitTimeStandIn 'exit 0')
Write-Case 'launch record: a process reporting the year 1601 (exited by itself): ExitedUtc is when the exit was noticed' $true ($run.Status -eq 'Exited' -and $run.ExitedUtc -ge $run.StartedUtc -and $run.ExitedUtc -le [DateTime]::UtcNow.AddSeconds(1) -and ($run.ExitedUtc - $run.StartedUtc).TotalSeconds -lt 20)
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 30 -KillAfterSec 1.5 -Launcher (New-BadExitTimeStandIn 'Start-Sleep -Seconds 60')
Write-Case 'launch record: a process reporting the year 1601 (ended): ExitedUtc is when the exit was noticed' $true ($run.Status -eq 'Killed' -and $run.ExitedUtc -gt $run.StartedUtc.AddSeconds(1) -and $run.ExitedUtc -le [DateTime]::UtcNow.AddSeconds(1))
$seenB = @{ Called = $false }
$sentinelFile = Join-Path $pinned.Dir (Get-HarnessSentinel).Name
$sentinelText = Get-Content -LiteralPath $sentinelFile -Raw
Remove-Item -LiteralPath $sentinelFile
try { Write-Case 'checked again before every start: with the sentinel deleted the start is refused and the stand-in is never called' $true ((Test-Throws { $null = Invoke-HarnessHost -ReaperExe 'stand-in' -Launcher (New-StandIn 'exit 0' $seenB) } 'REFUSED:*') -and -not $seenB.Called) }
finally { [IO.File]::WriteAllText($sentinelFile, $sentinelText) }
$sampled = @{ N = 0 }
$elsewhere = Join-Path $Work 'elsewhere\Some Plugin.vst3'
$kernel = Join-Path ([Environment]::SystemDirectory) 'kernel32.dll'
$fakeModules = { param($proc) $sampled.N++; @($elsewhere, (Join-Path $pinned.Dir 'plugins\X.vst3\Contents\x86_64-win\X.vst3'), $kernel) }.GetNewClosure()
$run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 30 -KillAfterSec 1.5 -WatchModules 'X.vst3' -ModuleSampler $fakeModules -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
Write-Case 'modules: the watched binary is collected by file name with its full path; every loaded .vst3 / .clap is listed, other DLLs are not' $false (
    $sampled.N -gt 0 -and $run.ModuleScans -eq $sampled.N -and @($run.Modules['X.vst3']).Count -eq 1 -and @($run.PluginModules).Count -eq 2 -and -not (@($run.PluginModules) -match 'kernel32'))

# ---- dialogs (real message boxes, under the GUI locks like a real run) ----
Invoke-WithHarnessLocks -Names (Get-HarnessGuiLockSet -Extra $extra) -TimeoutSeconds 1800 {
    $outNo = Join-Path $Work 'box-no.txt'
    $run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 30 -Launcher (New-StandIn (New-BoxCommand 'REAPER Query' 'YesNo' $outNo) @{})
    Write-Case 'dialog: REAPER Query is answered No, the process exits normally' $false ($run.Status -eq 'Exited' -and 'save-prompt' -in $run.Dismissed -and (Test-Path -LiteralPath $outNo) -and (Get-Content -LiteralPath $outNo -Raw).Trim() -eq 'No')
    $run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 30 -Launcher (New-StandIn (New-BoxCommand 'Project Load Warning' 'OK' (Join-Path $Work 'box-warn.txt')) @{})
    Write-Case 'dialog: Project Load Warning counts as stuck, the process is ended, status Modal' $true ($run.Status -eq 'Modal' -and $run.Modal -eq 'project-load-warning' -and (& $gone $run.Pid))
    $run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 30 -Launcher (New-StandIn (New-BoxCommand 'About REAPER v7.82 - evaluation' 'OK' (Join-Path $Work 'box-nag.txt')) @{})
    Write-Case 'dialog: the licence reminder is never clicked away; stuck as license-nag' $true ($run.Status -eq 'Modal' -and $run.Modal -eq 'license-nag' -and -not (Test-Path -LiteralPath (Join-Path $Work 'box-nag.txt')))
    $run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 30 -Launcher (New-StandIn (New-BoxCommand 'Something New' 'OK' (Join-Path $Work 'box-new.txt')) @{})
    Write-Case 'dialog: a dialog never seen before counts as stuck too (unknown-dialog)' $true ($run.Status -eq 'Modal' -and $run.Modal -eq 'unknown-dialog')
    $outBy = Join-Path $Work 'box-bystander.txt'
    $boxCmd = New-BoxCommand 'REAPER Query' 'YesNo' $outBy
    $bystander = [Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]::new($pwshExe, "-NoProfile -Command `"$boxCmd`""))
    try {
        Start-Sleep -Seconds 3 # let the bystander's dialog come up
        $run = Invoke-HarnessHost -ReaperExe 'stand-in' -TimeoutSec 30 -KillAfterSec 3 -Launcher (New-StandIn 'Start-Sleep -Seconds 60' @{})
        Write-Case "dialog: another process's REAPER Query is not clicked (only windows of the started PID are handled)" $false ($run.Status -eq 'Killed' -and -not $bystander.HasExited -and -not (Test-Path -LiteralPath $outBy))
    } finally { if (-not $bystander.HasExited) { Stop-Process -Id $bystander.Id -Force } }
}

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
# Taking and releasing a set directly (what every launch does through Invoke-HarnessLaunch)
$freeLock = $gui.Replace('-gui', '-free')
$held = Enter-HarnessLocks -Names @($freeLock, $gui) -TimeoutSeconds 5 -Quiet
Write-Case 'locks: while this process holds the set, another process can take neither lock' $true ($null -ne $held -and -not (Test-HarnessLockFree -FullName $gui) -and -not (Test-HarnessLockFree -FullName $freeLock))
Exit-HarnessLocks $held
Write-Case 'locks: after Exit-HarnessLocks both are free again' $false ((Test-HarnessLockFree -FullName $gui) -and (Test-HarnessLockFree -FullName $freeLock))
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
    # A context with other lock names uses them both for the start and for the check afterwards
    $injCtx = & $newCtx @($gui.Replace('-gui', '-other'))
    $injCtx.LockWaitSec = 5; $injCtx.Launcher = New-StandIn 'Start-Sleep -Seconds 60' @{}
    $quick = [pscustomobject]@{}; foreach ($p in $negs['neg-timeout'].PSObject.Properties) { $quick | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    $quick.timeoutSec = 2.0
    $rowInj = Invoke-HarnessNegativeRow -Context $injCtx -Scenario $quick -GuardParams @{} -TempRoot $Work
    Write-Case 'watchdog negative: the lock names of the context are used for the start and the check, so a busy default lock does not matter' $false ($rowInj.status -eq 'PASS' -and $rowInj.detail -like 'timed out after *' -and $injCtx.Launches -eq 1)
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

# ---- entry guards ----
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
Write-Case 'entry: an -ExtraGuiLock that is not a full Local\ name is a usage error' $true (Test-Throws { $null = Invoke-HarnessSuite @suite -ExtraGuiLock 'Rinne-gui' } 'USAGE:*-ExtraGuiLock*')
# Variants of the fixture configuration, written next to the scratch files (so its extension paths do not resolve)
$writeVariant = {
    param([scriptblock]$Change)
    $raw = [IO.File]::ReadAllText($configFile) | ConvertFrom-Json -AsHashtable
    $raw.Remove('$schema')
    & $Change $raw
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
if (@(Get-HarnessReaperProcessIds).Count) {
    Write-Case '(a reaper.exe is running on this machine: the end-to-end cases could not run)' $false $true
} else {
    $r = Invoke-HarnessSuite @e2e -SelfTestHooks $hooks
    $rowsOut = @($r.runs[0].scenarios)
    $notPass = @($rowsOut | Where-Object { $_.status -ne 'PASS' } | ForEach-Object { "$($_.id)=$($_.status): $($_.detail)" })
    Write-Case "end to end: every row of the fixture configuration passes against the stand-in ($($notPass -join ' | '))" $false ($r.verdict -eq 'PASS' -and $notPass.Count -eq 0 -and $rowsOut.Count -eq 22)
    Write-Case 'end to end: learn ran once, first, and proved the private copy; the module check over all launches passed' $false (
        $rowsOut[0].id -eq 'learn' -and $rowsOut[0].status -eq 'PASS' -and $rowsOut[0].facts.modules -eq 'Proven' -and $r.runs[0].moduleCheck.status -eq 'PASS' -and @($seenArgs | Where-Object { $_ -notmatch 'renderproject' }).Count -ge 5)
    Write-Case 'end to end: every launch is counted and the default resource directory is unchanged' $false ($r.launches -eq $seenArgs.Count -and $r.runs[0].launches -eq $seenArgs.Count -and $r.runs[0].defaultCfgDir.unchanged -and $r.runs[0].reaperProcessesLeft -eq 0)
    $path = Write-HarnessResult -Data $r -ResultDir $e2e.ResultDir
    $json = [IO.File]::ReadAllText($path)
    $back = ConvertFrom-HarnessJson $json
    Write-Case 'result file: valid JSON with schema 1, the plugin hashes (12 hex digits) and no local path' $false (
        $back['schema'] -eq 1 -and $back['plugins'][0]['sha256'] -cmatch '^[0-9a-f]{12}$' -and $json -notmatch '[A-Za-z]:\\\\' -and (Split-Path -Leaf $path) -cmatch "-fixture-$($back['buildLabel'])\.json$")
    Write-Case 'end to end: the work files of an all-green round are removed' $false (-not (Test-Path -LiteralPath (Join-Path $e2e.ResultDir 'work')) -or @(Get-ChildItem -LiteralPath (Join-Path $e2e.ResultDir 'work') -Recurse -File).Count -eq 0)
    # The module list shows the release build of the same name: not the private copy, so no conclusion (INCOMPLETE)
    $sameName = Join-Path $env:COMMONPROGRAMFILES 'VST3\Fixture Gain.vst3\Contents\x86_64-win\Fixture Gain.vst3' # the release build of the shield case
    $foreignSampler = { param($proc) @($sameName) }.GetNewClosure()
    $r = Invoke-HarnessSuite @e2e -Only '^chain-offline-48000$' -NoNegative -SelfTestHooks @{ Launcher = $hooks.Launcher; ModuleSampler = $foreignSampler }
    Write-Case 'end to end: a same-name binary from outside the private directory makes learn and the round INCOMPLETE, and nothing else runs' $true (
        $r.verdict -eq 'INCOMPLETE' -and $r.runs[0].scenarios[0].status -eq 'INCOMPLETE' -and $r.runs[0].scenarios[0].detail -like 'not the private copy*' -and $r.runs[0].scenarios[1].detail -like 'not run: learning*' -and $r.runs[0].moduleCheck.status -eq 'INCOMPLETE')
    $r = Invoke-HarnessSuite @e2e -Only '^chain-offline-48000$' -NoNegative -SelfTestHooks @{ Launcher = $hooks.Launcher; ModuleSampler = { param($proc) @() } }
    Write-Case 'end to end: a tested binary never seen loaded makes learn INCOMPLETE (the private copy is not proven)' $true ($r.verdict -eq 'INCOMPLETE' -and $r.runs[0].scenarios[0].detail -like '*not proven*')
    Set-FakeReaper @{ Pwsh = $pwshExe; CfgDir = $pinned.Dir; Plugins = @{ ($plugins.get_Keys() | Where-Object { $_ -like '*Gain*' }) = $plugins[($plugins.get_Keys() | Where-Object { $_ -like '*Gain*' })] }; Seen = $seenArgs }
    $r = Invoke-HarnessSuite @e2e -Only '^chain-offline-48000$' -NoNegative -SelfTestHooks $hooks
    Write-Case 'end to end: a plugin REAPER cannot add makes learn FAIL with the plugin named, and the round FAIL' $true ($r.verdict -eq 'FAIL' -and $r.runs[0].scenarios[0].status -eq 'FAIL' -and $r.runs[0].scenarios[0].detail -like 'bus could not be added*')
}

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
