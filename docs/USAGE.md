# Usage

Windows only, PowerShell 7.4 or later, an installed REAPER 7 (x64) and a REAPER licence under REAPER's own terms.
The harness drives REAPER in a real desktop session; run it on a machine you are logged in to, not over SSH or as a
scheduled task, and not on hosted CI runners. The self-test (`-SelfTest`) needs no REAPER and runs anywhere.

## 1. Create a private configuration directory

```powershell
pwsh doctor.ps1 -CfgDir D:\reaper-harness\cfg -Init
```

This creates the directory with a minimal `reaper.ini` (dummy audio device), an empty `plugins` directory and the
sentinel file. It only takes over a directory that does not exist, an empty one or one it initialised before; it
never accepts anything under `%APPDATA%` (see [SAFETY.md](SAFETY.md)). Use one directory per machine and keep it
for later runs: the scan cache in it makes later starts fast.

The first launch in a new directory makes REAPER scan the plugin path. With the scan shield (see SAFETY.md) it does
not load third-party plugins, but it still lists them, which can take a minute on a machine with many plugins.

## 2. Write a configuration

Start from `tests/fixtures/config.json` and [CONFIG.md](CONFIG.md). Check it without REAPER:

```powershell
pwsh doctor.ps1 -Config my-plugin.json
```

## 3. Check the machine

```powershell
pwsh doctor.ps1 -CfgDir D:\reaper-harness\cfg -Config my-plugin.json -PluginDir D:\build\VST3
```

`-PluginDir` holds the `.vst3` bundles named in the configuration. This runs the same preflight as `run.ps1` and
never starts REAPER: REAPER found (`-ReaperExe`, default `%ProgramFiles%\REAPER (x64)\reaper.exe`), every bundle with
a readable `moduleinfo.json` and a Windows binary, no other `reaper.exe` running, no skip marker present.

## 4. Run

```powershell
pwsh run.ps1 -Config my-plugin.json -CfgDir D:\reaper-harness\cfg -PluginDir D:\build\VST3 -ResultDir D:\reaper-harness\results
```

| option | |
|---|---|
| `-Only <regex>` | run only scenarios (and negative cases) whose id matches; picking nothing is a usage error |
| `-NoNegative` | leave out all negative cases, the built-in ones included (faster, but proves less) |
| `-Repeat <n>` | run the whole set n times in a row (rounds); a changed default resource directory stops all further rounds |
| `-BuildLabel <label>` | `[0-9A-Za-z._-]{1,40}`, goes into the result file name; default: from the sha256 of the plugin binaries |
| `-SkipMarker <file>` | repeatable; while any of these files exists the suite is SKIPPED and REAPER is never started |
| `-ExtraGuiLock <Local\name>` | repeatable; GUI locks to take in addition to `Local\ReaperHarness-gui` before every launch |
| `-KeepWork` | keep the projects, renders and driver files of green rounds (rounds that are not green are always kept) |
| `-ReaperExe <path>` | another REAPER |

Each round: the plugin bundles are copied into the private `plugins` directory, the plugin path and the scan
shield are written, one learn launch proves the private copies are what REAPER loads, then every scenario runs,
then the negative cases. The work files of a round go to `<ResultDir>/work/<time>-run<n>/`; the result file is
`<ResultDir>/<time>-<config name>-<build label>.json` ([RESULTS.md](RESULTS.md)).

While a run is going on, do not use REAPER on the same machine: the run refuses to start next to a running
`reaper.exe`, but cannot stop you from starting one in the middle. Create one of your skip markers first if you
need to.

## Exit codes

| code | |
|---|---|
| 0 | PASS: every row of every round passed |
| 1 | FAIL, also when the result file could not be written |
| 2 | INCOMPLETE: some row could not run or could not be checked, the run stopped on an unexpected error, or the result file of anything but a FAIL could not be written; this is never a PASS |
| 3 | SKIPPED: the suite did not run (the reasons are printed and in the result file) |
| 64 | refused by a guard, or a usage error (including any problem in the configuration); nothing was started |

`doctor.ps1` exits 0 when ready, 2 when the check itself stopped on an unexpected error, 3 when `run.ps1` would be SKIPPED, 64 when refused.

## Self-test

```powershell
pwsh run.ps1 -SelfTest [-ExtraGuiLock Local\Other-gui]
```

About 350 cases, a few minutes, no REAPER. It runs everything against a fake `%APPDATA%` in a scratch directory
under the system temporary directory and compares a listing of the real default resource directory before and
after. Some cases show real message boxes for a moment; they take the GUI locks like a real run.
`-CollisionSample <file.ps1>` additionally checks that a script you know to have a case collision is caught.
