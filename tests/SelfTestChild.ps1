#Requires -Version 7
# SPDX-License-Identifier: MIT
#
# The child-process part of the self-test (called by SelfTest.psm1): Initialize-HarnessCfg pins the configuration
# directory into the process for good, so these cases get a process of their own. Stand-ins replace REAPER: a
# sleeping pwsh and a pwsh that shows a dialog with a given title. They check the watchdog, the dialog handling and
# the locks. Output: one line per case, RESULT<TAB>bad<TAB>passed<TAB>label. The parent replaced APPDATA with a fake
# one; this process inherits it.
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
foreach ($m in 'Guard', 'Host', 'Locks') { Import-Module (Join-Path $src "$m.psm1") -ErrorAction Stop }

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
# Taking and releasing a set directly (what a caller does around Invoke-HarnessHost)
$freeLock = $gui.Replace('-gui', '-free')
$held = Enter-HarnessLocks -Names @($freeLock, $gui) -TimeoutSeconds 5 -Quiet
Write-Case 'locks: while this process holds the set, another process can take neither lock' $true ($null -ne $held -and -not (Test-HarnessLockFree -FullName $gui) -and -not (Test-HarnessLockFree -FullName $freeLock))
Exit-HarnessLocks $held
Write-Case 'locks: after Exit-HarnessLocks both are free again' $false ((Test-HarnessLockFree -FullName $gui) -and (Test-HarnessLockFree -FullName $freeLock))
Write-Case 'locks: Invoke-WithHarnessLocks hands the block the lock object it holds' $false (Invoke-WithHarnessLocks -Names @($gui) -TimeoutSeconds 5 { param($given) Test-HarnessLockHeld -Lock $given -Name $gui })
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

# Keep this the last statement: the parent turns red when it does not see this case (an early exit 0 must not look green)
Write-Case 'child: reached its last statement' $false $true
