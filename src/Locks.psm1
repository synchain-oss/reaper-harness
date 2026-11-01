# SPDX-License-Identifier: MIT
#
# Machine-local GUI locks. Every lock is a Local\ named mutex owned by the kernel: when the holder is killed or
# crashes it is always released and the next waiter takes it over as an abandoned mutex. There are no owner files
# and no "steal the lock after waiting long enough": if a lock cannot be taken in time the caller gets $null and
# decides what that means (the harness records INCOMPLETE). The harness never runs without its locks.
# Local\ only excludes within one logon session. Runs started from SSH, a scheduled task or another user's session
# get a different set of locks and are not excluded, so do not run the harness that way.
#   Local\ReaperHarness-gui   the default lock, always taken before REAPER (or a self-test dialog) starts
#   -ExtraGuiLock <name>      more full mutex names to take as well (for example the GUI lock another tool on this
#                             machine uses), so the harness also waits for that tool. Locks can only be added; the
#                             default lock cannot be removed.
# All locks of a set are taken in one fixed order (ordinal sort of the full names), all or nothing: if a later one
# cannot be taken before the shared deadline, the ones already held are released again. Two harness processes with
# different extra sets therefore cannot deadlock each other.
# Mutexes have thread affinity: take and release on the same thread, which sequential calls in one pwsh process do.
# Taking the same mutex again on the same thread succeeds (re-entrant), so exclusion only holds between processes.
# The default name can only be changed from inside the module (the self-test uses its own names so it never waits
# for, or blocks, a real run); there is no environment variable or parameter for it.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DefaultGui = 'Local\ReaperHarness-gui'

function Get-HarnessDefaultGuiLock { $script:DefaultGui }

# A full mutex name the harness accepts for -ExtraGuiLock: Local\ followed by 1..100 of [A-Za-z0-9._-].
# Global\ is not accepted: an existing Global\ object that denies the current token cannot be opened, and silently
# falling back to some other name would mean thinking a lock is held when it is not.
function Test-HarnessLockName([string]$Name) { $Name -cmatch '^Local\\[A-Za-z0-9._-]{1,100}$' }

# The lock set for one REAPER launch: the default lock plus the extras, de-duplicated (mutex names are case
# sensitive) and sorted ordinally. A bad name is a usage error.
function Get-HarnessGuiLockSet {
    param([string[]]$Extra = @())
    $set = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $null = $set.Add($script:DefaultGui)
    foreach ($Name in $Extra) {
        if (-not (Test-HarnessLockName $Name)) { throw [System.InvalidOperationException]::new("USAGE: -ExtraGuiLock '$Name' is not a full Local\ mutex name (Local\ followed by 1 to 100 of A-Z a-z 0-9 . _ -)") }
        $null = $set.Add($Name)
    }
    , @($set)
}

function Write-Abandoned([string]$Full) {
    Write-Host "  [lock] the previous holder exited without releasing $Full; taken over (its processes and temporary files may still be around)"
}

# Takes every lock of the set in the given order; if the shared deadline passes before all are held, releases the
# ones already taken and returns $null. The returned object goes to Exit-HarnessLocks.
function Enter-HarnessLocks {
    param([Parameter(Mandatory)][string[]]$Names, [double]$TimeoutSeconds = 1800, [switch]$Quiet)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $held = [Collections.Generic.List[object]]::new()
    try {
        foreach ($Full in $Names) {
            $left = [Math]::Max(0.0, $TimeoutSeconds - $sw.Elapsed.TotalSeconds)
            $m = [System.Threading.Mutex]::new($false, $Full)
            try { $got = $m.WaitOne([TimeSpan]::FromSeconds($left)) }
            catch [System.Threading.AbandonedMutexException] { $got = $true; Write-Abandoned $Full }
            if (-not $got) {
                $m.Dispose()
                Exit-HarnessLocks ([pscustomobject]@{ Names = @(); Held = $held.ToArray(); Waited = 0 })
                return $null
            }
            $held.Add([pscustomobject]@{ Name = $Full; Mutex = $m })
        }
    } catch {
        Exit-HarnessLocks ([pscustomobject]@{ Names = @(); Held = $held.ToArray(); Waited = 0 })
        throw
    }
    if (-not $Quiet -and $sw.Elapsed.TotalSeconds -ge 1) { Write-Host ('  [lock] waited {0:N1} s for {1}' -f $sw.Elapsed.TotalSeconds, ($Names -join ', ')) }
    [pscustomobject]@{ Names = $Names; Held = $held.ToArray(); Waited = $sw.Elapsed.TotalSeconds }
}

# Releases in reverse order of taking.
function Exit-HarnessLocks {
    param([Parameter(Position = 0)]$Lock)
    if ($null -eq $Lock) { return }
    $list = @($Lock.Held)
    for ($i = $list.Count - 1; $i -ge 0; $i--) {
        try { $list[$i].Mutex.ReleaseMutex() } catch { Write-Host "  [lock] error releasing $($list[$i].Name): $($_.Exception.Message)" }
        $list[$i].Mutex.Dispose()
    }
}

# Runs the script block while holding the set; always releases (including on errors and Ctrl-C). Throws a
# TimeoutException and does not run the block when the locks cannot be taken.
function Invoke-WithHarnessLocks {
    param([Parameter(Mandatory)][string[]]$Names, [Parameter(Mandatory)][scriptblock]$ScriptBlock, [double]$TimeoutSeconds = 1800)
    $Lock = Enter-HarnessLocks -Names $Names -TimeoutSeconds $TimeoutSeconds
    if (-not $Lock) { throw [System.TimeoutException]::new("waited more than $TimeoutSeconds s for $($Names -join ', ')") }
    try { & $ScriptBlock } finally { Exit-HarnessLocks $Lock }
}

# Starts a pwsh child that tries to take one exact mutex name without waiting; returns whether it could (taken and
# released at once). Mutexes have thread affinity, so "held by someone else" cannot be observed inside this process.
function Test-HarnessLockFree([Parameter(Mandatory)][string]$FullName) {
    $cmd = "`$m = [Threading.Mutex]::new(`$false, '$($FullName -replace "'", "''")'); try { `$got = `$m.WaitOne(0) } catch [Threading.AbandonedMutexException] { `$got = `$true }; if (`$got) { `$m.ReleaseMutex(); exit 0 } else { exit 1 }"
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($a in '-NoProfile', '-NonInteractive', '-Command', $cmd) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $null = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $p.ExitCode -eq 0
}

# Starts a pwsh child that imports this module, switches to the same default lock name as this process, then runs
# Command; returns the Process. For the self-test only.
function Start-HarnessLockChild([string]$Command) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $prelude = "Import-Module '$($PSCommandPath -replace "'", "''")'; & (Get-Module Locks) { `$script:DefaultGui = '$($script:DefaultGui -replace "'", "''")' }; "
    foreach ($a in '-NoProfile', '-NonInteractive', '-Command', ($prelude + $Command)) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    [System.Diagnostics.Process]::Start($psi)
}

Export-ModuleMember -Function Get-HarnessDefaultGuiLock, Test-HarnessLockName, Get-HarnessGuiLockSet, Enter-HarnessLocks, Exit-HarnessLocks, Invoke-WithHarnessLocks,
    Test-HarnessLockFree, Start-HarnessLockChild
