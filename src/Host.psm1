# SPDX-License-Identifier: MIT
#
# Starts REAPER and watches it: the only place in the repository that builds the -cfgfile argument.
#   Invoke-HarnessHost       starts one REAPER and waits for it to exit on its own; on timeout, at the kill point or
#                            when a dialog blocks it, ends it by the PID it was started with. Refuses to start unless
#                            the caller holds the default GUI lock
#   Get-HarnessModalVerdict  how to treat one window (pure function, used directly by the self-test)
#   Resolve-HarnessExitedUtc the moment the process exited: when the value the process reports cannot be trusted
#                            (real machines occasionally report the year 1601) the moment the exit was noticed is
#                            used instead (pure function, used directly by the self-test)
#   Get-HarnessModuleVerdict whether every watched plugin binary was loaded from the expected private copy (pure)
# Rules: only windows that belong to the started PID are looked at or clicked (if the user's own REAPER is open, its
# dialogs are never touched); the only thing clicked automatically is "REAPER Query" (save prompt, answered "No");
# render, plugin scan and peak building progress windows are let through, unless the title reports trouble; any other
# visible dialog that stays for 0.5 s or more counts as stuck: it is closed, the process is ended and the status is
# Modal, which the caller turns into INCOMPLETE. Processes are only ever ended by the PID this function started.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Guard.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Locks.psm1') -ErrorAction Stop

if (-not ('HarnessWin' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class HarnessWin
{
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32")] static extern bool EnumChildWindows(IntPtr h, EnumProc p, IntPtr l);
    [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);

    // Top-level windows owned by pid, one row each: handle TAB visible(0/1) TAB class TAB title
    public static string[] Windows(uint pid)
    {
        var rows = new List<string>();
        EnumWindows((h, l) =>
        {
            uint owner;
            GetWindowThreadProcessId(h, out owner);
            if (owner != pid) return true;
            var c = new StringBuilder(256);
            var t = new StringBuilder(512);
            GetClassName(h, c, 256);
            GetWindowText(h, t, 512);
            rows.Add(h.ToInt64() + "\t" + (IsWindowVisible(h) ? 1 : 0) + "\t" + c + "\t" + t);
            return true;
        }, IntPtr.Zero);
        return rows.ToArray();
    }

    public static bool Press(long dialog, int ctrlId)
    {
        IntPtr hit = IntPtr.Zero;
        EnumChildWindows(new IntPtr(dialog), (h, l) => { if (GetDlgCtrlID(h) == ctrlId) hit = h; return true; }, IntPtr.Zero);
        if (hit == IntPtr.Zero) return false;
        PostMessage(hit, 0xF5, IntPtr.Zero, IntPtr.Zero); // BM_CLICK
        return true;
    }

    public static void Close(long window) { PostMessage(new IntPtr(window), 0x10, IntPtr.Zero, IntPtr.Zero); } // WM_CLOSE
}
'@
}

$script:IdNo = 7

# Dialogs known to block: title -> name. The name goes into the result json; unknown ones are recorded as
# unknown-dialog with the title (paths masked).
$script:KnownModals = [ordered]@{
    'Project Load Warning'            = 'project-load-warning'
    'REAPER Error'                    = 'reaper-error'
    'Select files to save or delete'  = 'record-save-prompt'
    'REAPER'                          = 'no-audio-device'
}

# How to treat a window: Ignore (not a dialog / not visible), PressNo (save prompt), Benign (render, plugin scan and
# peak building progress windows, which go away on their own), Fatal (stuck; Name says which). A title that starts like
# a progress window but reports trouble ("Render failed") does not go away on its own: left alone it would only end at
# the timeout, and the outcome would not name it.
function Get-HarnessModalVerdict {
    param([string]$Class, [bool]$Visible, [string]$Title)
    if (-not $Visible -or $Class -cne '#32770') { return [pscustomobject]@{ Action = 'Ignore'; Name = '' } }
    if ($Title -ceq 'REAPER Query') { return [pscustomobject]@{ Action = 'PressNo'; Name = 'save-prompt' } }
    if ($Title -inotmatch 'fail|error') {
        if ($Title -imatch '^Render') { return [pscustomobject]@{ Action = 'Benign'; Name = 'render-progress' } }
        if ($Title -imatch '^Scanning') { return [pscustomobject]@{ Action = 'Benign'; Name = 'plugin-scan-progress' } }
        if ($Title -imatch '^Building peaks') { return [pscustomobject]@{ Action = 'Benign'; Name = 'peaks-progress' } }
    }
    # The evaluation licence reminder (title "About REAPER ..."): never dismissed automatically; treated as stuck and
    # named, so the user can buy a licence
    if ($Title -imatch '^About REAPER') { return [pscustomobject]@{ Action = 'Fatal'; Name = 'license-nag' } }
    $name = $script:KnownModals.Contains($Title) ? $script:KnownModals[$Title] : 'unknown-dialog'
    [pscustomobject]@{ Action = 'Fatal'; Name = $name }
}

# A title may contain a project path, and a path may contain spaces (a user name, for one), so nothing short of the
# next double quote or the end of the title can be taken for its end: from a drive letter, \\ or // up to there it
# becomes <path>. Then the title is cut to 40 characters.
function ConvertTo-HarnessSafeTitle([string]$Title) {
    $t = $Title -replace '(?:[A-Za-z]:[\\/]|\\\\|//)[^"]*', '<path>'
    $t.Length -gt 40 ? $t.Substring(0, 40) : $t
}

# Handle count and memory of the process. Only one case of a process that has just exited is recognised, returning
# Exited = $true (the caller reports "the process exited before the sample"): the counters are read through get_
# methods, because when the process has exited .NET throws InvalidOperationException (PowerShell wraps it in a
# MethodInvocationException), caught here. Properties are not used: a throwing property getter is swallowed by
# PowerShell into an empty value (handles $null, memory 0), which would look like "no growth".
# Only when the exception (or its inner one) is an InvalidOperationException and the process really has exited is it
# this case; any other exception is rethrown.
function Get-HarnessProcessSample([System.Diagnostics.Process]$Process) {
    try {
        $Process.Refresh()
        $h = $Process.get_HandleCount(); $pm = $Process.get_PrivateMemorySize64(); $ws = $Process.get_WorkingSet64()
    } catch {
        $ex = $_.Exception
        $exitedNow = ($ex -is [InvalidOperationException] -or $ex.InnerException -is [InvalidOperationException]) -and ($Process.HasExited -eq $true)
        if (-not $exitedNow) { throw }
        return [pscustomobject]@{ Exited = $true; Handles = $null; PrivateMB = $null; WorkingMB = $null }
    }
    [pscustomobject]@{ Exited = $false; Handles = $h; PrivateMB = [math]::Round($pm / 1MB, 1); WorkingMB = [math]::Round($ws / 1MB, 1) }
}

# Full paths of the modules (DLLs) loaded in the process right now, or $null when they cannot be read at this moment
# (the process is starting or exiting, or has exited). Never throws for those cases.
function Get-HarnessProcessModulePaths($Process) {
    try {
        $Process.Refresh()
        if ($Process.HasExited) { return $null }
        $names = @($Process.Modules | ForEach-Object { $_.FileName } | Where-Object { $_ })
    } catch { return $null }
    , $names
}

# Pure function: several marks' process counters complete or not. Complete returns $null; marks missed because the
# process exited before the sample are named as such; any other gap is reported separately.
function Get-HarnessMarkProblem {
    param($Samples, [string[]]$LostAt = @(), [Parameter(Mandatory)][string[]]$Need)
    $missing = @($Need | Where-Object { -not ($Samples -and $Samples.Contains($_)) })
    if (-not $missing.Count) { return $null }
    $lostHere = @($missing | Where-Object { $_ -in $LostAt })
    if ($lostHere.Count) { return "the process exited before the sample (no handle and memory counts at $($lostHere -join ', '))" }
    "no process counters at $($missing -join ', ')"
}

# The moment the process exited. Process.ExitTime occasionally reads FILETIME 0 on real machines (1601-01-01 in
# UTC): earlier than this launch, so it cannot be true. Used as an upper bound such a value would reject everything
# the launch wrote. So the reported value (Reported) is only trusted inside [NotBeforeUtc (just before the start),
# NoticedUtc (when the exit was noticed) + 1 s] (the 1 s covers the different resolution of the two clocks);
# otherwise NoticedUtc is used: it is a few hundred milliseconds after the exit and only widens the bound a little.
# All arguments are UTC.
function Resolve-HarnessExitedUtc {
    param([Nullable[datetime]]$Reported, [Parameter(Mandatory)][datetime]$NotBeforeUtc, [Parameter(Mandatory)][datetime]$NoticedUtc)
    if ($null -ne $Reported -and $Reported -ge $NotBeforeUtc -and $Reported -le $NoticedUtc.AddSeconds(1)) { return [datetime]$Reported }
    $NoticedUtc
}

# Whether two paths name one file: the same full path, or the same volume serial and file ID (a hard link, a subst
# drive or a junction leading to the same file). An identity that cannot be read is never "the same".
function Test-HarnessSameFile([string]$A, [string]$B) {
    if (-not $A -or -not $B) { return $false }
    if ([string]::Equals([IO.Path]::GetFullPath($A), [IO.Path]::GetFullPath($B), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $ia = Get-HarnessFileIdentity $A; $ib = Get-HarnessFileIdentity $B
    [bool]($ia -and $ib -and -not $ia.StartsWith('ERROR:') -and $ia -ceq $ib)
}

# Pure function: did every watched plugin binary load from its expected private file, and nothing of the same file
# name from anywhere else? Expected: binary leaf name -> expected full path. Seen: leaf name -> full paths seen
# loaded in the process (any spelling). SameFile: scriptblock (a, b) -> whether two paths are the same file
# (string comparison first, file identity second; injectable for the self-test).
# Per binary: Private (only the expected file seen), Foreign (some other file of that name seen, whether or not the
# private one was too), Unseen (not seen at all). Verdict: Proven when all are Private; Foreign when any is Foreign;
# otherwise Unseen. Nothing expected is Unseen as well: with no binary checked nothing has been proven.
function Get-HarnessModuleVerdict {
    param([Parameter(Mandatory)][hashtable]$Expected, [hashtable]$Seen = @{}, [scriptblock]$SameFile = $null)
    if ($Expected.get_Count() -eq 0) { return [pscustomobject]@{ Verdict = 'Unseen'; Binaries = [ordered]@{} } }
    $same = $SameFile ?? ${function:Test-HarnessSameFile}
    $rows = [ordered]@{}
    foreach ($leaf in @($Expected.get_Keys() | Sort-Object)) {
        $paths = @($Seen.ContainsKey($leaf) ? $Seen[$leaf] : @())
        $foreign = @($paths | Where-Object { -not (& $same $_ $Expected[$leaf]) })
        $private = @($paths | Where-Object { & $same $_ $Expected[$leaf] })
        $rows[$leaf] = $foreign.Count ? 'Foreign' : ($private.Count ? 'Private' : 'Unseen')
    }
    $states = @($rows.get_Values())
    $verdict = ('Foreign' -in $states) ? 'Foreign' : (('Unseen' -in $states) ? 'Unseen' : 'Proven')
    [pscustomobject]@{ Verdict = $verdict; Binaries = $rows }
}

function Stop-HostRefuse([string]$Why) { throw [System.InvalidOperationException]::new("REFUSED: $Why") }

# Starts REAPER and waits for it to exit. Status: Exited / Timeout (TimeoutSec reached) / Killed (KillAfterSec
# reached, for the negative cases) / Modal (a stuck dialog).
# Refused before anything starts, with no way around it for a Launcher either: Lock is not an object from
# Enter-HarnessLocks holding the default GUI lock; an element of ReaperArgs contains a double quote (the arguments go
# to the process one by one, a quote of its own would arrive escaped); ReaperArgs names the configuration file switch
# again (REAPER would take the later value, so the guarded one has to be the only one).
# Pid, StartedUtc (just before the start) and ExitedUtc (when the process exited; with StillRunning, when the harness
# gave up) describe the launch; SampleLost lists the marks whose counters could not be taken because the process had
# already exited.
# StillRunning is always there: $true when the watchdog ended the process and it is still around after waiting for it.
# The caller then records INCOMPLETE, keeps its locks and starts nothing more: the next start would run next to it.
# WatchFiles: label -> path; when a file appears the process handle and memory counters are sampled once (the Lua
# driver uses this to mark the start and end of a loop).
# WatchModules: binary leaf names; on every poll the full paths of loaded modules with these names are collected
# (Modules: leaf -> paths seen, ModuleScans: how many polls could read the module list). PluginModules: every
# loaded .vst3 / .clap binary seen during those polls, watched or not (shows whether any other plugin was loaded).
# Launcher is for the self-test only: it receives the prepared ProcessStartInfo and returns the started Process.
# Sampler and ModuleSampler are for the self-test only too: they replace Get-HarnessProcessSample and
# Get-HarnessProcessModulePaths. So is Stopper: it replaces the call that ends the process, so a process that cannot
# be ended can be tested.
function Invoke-HarnessHost {
    param(
        [Parameter(Mandatory)][string]$ReaperExe,
        [string[]]$ReaperArgs = @(),
        [hashtable]$Environment = @{},
        [string]$WorkDir = '',
        [double]$TimeoutSec = 90,
        [double]$KillAfterSec = 0,
        [hashtable]$WatchFiles = @{},
        [string[]]$WatchModules = @(),
        $Lock = $null,
        [scriptblock]$Launcher = $null,
        [scriptblock]$Sampler = $null,
        [scriptblock]$ModuleSampler = $null,
        [scriptblock]$Stopper = $null
    )
    if (-not (Test-HarnessLockHeld -Lock $Lock -Name (Get-HarnessDefaultGuiLock))) { Stop-HostRefuse 'REAPER is only started while holding the default GUI lock: pass the object from Enter-HarnessLocks as -Lock' }
    $cfgArgs = @('-nosplash', '-newinst', '-cfgfile', (Get-HarnessCfgArgument))
    foreach ($element in $ReaperArgs) {
        $text = [string]$element
        if ($text.Contains('"')) { Stop-HostRefuse '-ReaperArgs contains a double quote: the arguments are passed one by one and need no quoting of their own' }
        if ($text.Trim() -ieq $cfgArgs[2]) { Stop-HostRefuse '-ReaperArgs names the configuration file switch again: only the guarded value may reach REAPER' }
    }
    $psi = [Diagnostics.ProcessStartInfo]::new($ReaperExe)
    foreach ($element in ($cfgArgs + $ReaperArgs)) { $psi.ArgumentList.Add($element) }
    $psi.UseShellExecute = $false
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    foreach ($k in $Environment.get_Keys()) { $psi.Environment[[string]$k] = [string]$Environment[$k] }
    $startedUtc = [DateTime]::UtcNow # taken before the start: files written by this launch are never older
    $proc = $Launcher ? (& $Launcher $psi) : [Diagnostics.Process]::Start($psi)
    $ownPid = $proc.Id
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $status = $null
    $modal = $null
    $dismissed = [Collections.Generic.List[string]]::new()
    $titles = [Collections.Generic.SortedSet[string]]::new()
    $marks = [ordered]@{}
    $lost = [Collections.Generic.List[string]]::new()
    $firstSeen = @{}
    $modSeen = @{}
    foreach ($leaf in $WatchModules) { $modSeen[$leaf] = [Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
    $plugSeen = [Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $modScans = 0
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 250
        $now = $sw.Elapsed.TotalSeconds
        if ($KillAfterSec -gt 0 -and $now -ge $KillAfterSec) { $status = 'Killed'; break }
        if ($now -ge $TimeoutSec) { $status = 'Timeout'; break }
        if ($WatchModules.Count) {
            $paths = $ModuleSampler ? (& $ModuleSampler $proc) : (Get-HarnessProcessModulePaths $proc)
            if ($null -ne $paths) {
                $modScans++
                foreach ($modPath in $paths) {
                    $leaf = [IO.Path]::GetFileName($modPath)
                    foreach ($w in $WatchModules) { if ([string]::Equals($leaf, $w, [StringComparison]::OrdinalIgnoreCase)) { $null = $modSeen[$w].Add($modPath) } }
                    if ($leaf -match '\.(vst3|clap)$') { $null = $plugSeen.Add($modPath) }
                }
            }
        }
        foreach ($row in [HarnessWin]::Windows([uint32]$ownPid)) {
            $f = $row -split "`t", 4
            $verdict = Get-HarnessModalVerdict -Class $f[2] -Visible ($f[1] -eq '1') -Title $f[3]
            if ($verdict.Action -eq 'Ignore') { continue }
            $null = $titles.Add($verdict.Name + ($verdict.Name -eq 'unknown-dialog' ? ':' + (ConvertTo-HarnessSafeTitle $f[3]) : ''))
            $h = [long]$f[0]
            if ($verdict.Action -eq 'PressNo') {
                if ([HarnessWin]::Press($h, $script:IdNo)) { $dismissed.Add($verdict.Name) }
            } elseif ($verdict.Action -eq 'Fatal') {
                if (-not $firstSeen.ContainsKey($h)) { $firstSeen[$h] = $now }
                elseif ($now - $firstSeen[$h] -ge 0.5) { $modal = $verdict.Name; [HarnessWin]::Close($h); $status = 'Modal'; break }
            }
        }
        if ($status) { break }
        foreach ($label in @($WatchFiles.get_Keys())) {
            if ($marks.Contains($label) -or $label -in $lost -or -not (Test-Path -LiteralPath $WatchFiles[$label])) { continue }
            $sample = $Sampler ? (& $Sampler $proc) : (Get-HarnessProcessSample $proc)
            if ($sample.Exited) { $lost.Add($label) } else { $marks[$label] = $sample }
        }
    }
    if (-not $status) {
        # The process exited faster than the next poll: the mark file is there but there was no time to sample.
        # That is "exited before the sample" too, not "missing".
        foreach ($label in @($WatchFiles.get_Keys())) {
            if (-not $marks.Contains($label) -and $label -notin $lost -and (Test-Path -LiteralPath $WatchFiles[$label])) { $lost.Add($label) }
        }
    }
    $stillRunning = $false
    if ($status) {
        # Only the PID started here is ever ended. A stop that fails is not judged here: what counts is whether the process
        # is still there afterwards, so a failed stop of a live process shows up below and one that had already exited
        # is no failure
        try { if ($Stopper) { & $Stopper $ownPid } else { Stop-Process -Id $ownPid -Force -ErrorAction Stop } } catch { $null = $_ }
        $stillRunning = -not $proc.WaitForExit(5000)
    }
    $exit = ($proc.HasExited -and -not $status) ? $proc.ExitCode : $null
    # When the process exited. If the reported ExitTime cannot be read (the process has not exited, a stand-in has
    # no such property) or cannot be trusted (the year 1601 on some machines), Resolve-HarnessExitedUtc uses the
    # moment the exit was noticed: that only widens the bound
    $seenGoneUtc = [DateTime]::UtcNow
    $reportedUtc = try { $proc.ExitTime.ToUniversalTime() } catch { $null }
    $exitedUtc = Resolve-HarnessExitedUtc -Reported $reportedUtc -NotBeforeUtc $startedUtc -NoticedUtc $seenGoneUtc
    $modules = @{}
    foreach ($leaf in $modSeen.get_Keys()) { $modules[$leaf] = @($modSeen[$leaf]) }
    [pscustomobject]@{
        Status = $status ?? 'Exited'; ExitCode = $exit; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Pid = $ownPid; StartedUtc = $startedUtc; ExitedUtc = $exitedUtc
        Modal = $modal; Dismissed = $dismissed.ToArray(); Windows = @($titles); Marks = $marks; SampleLost = $lost.ToArray(); Modules = $modules; ModuleScans = $modScans
        PluginModules = @($plugSeen); StillRunning = $stillRunning
    }
}

# IDs of the reaper.exe processes on this machine right now (taken before and after: if somebody else's REAPER is
# running the suite does not run; after a run none of ours may be left).
function Get-HarnessReaperProcessIds { Get-Process -Name reaper -ErrorAction SilentlyContinue | ForEach-Object { $_.Id } }

Export-ModuleMember -Function Get-HarnessModalVerdict, ConvertTo-HarnessSafeTitle, Resolve-HarnessExitedUtc, Invoke-HarnessHost, Get-HarnessReaperProcessIds, Get-HarnessProcessSample,
    Get-HarnessMarkProblem, Get-HarnessModuleVerdict, Get-HarnessProcessModulePaths, Test-HarnessSameFile
