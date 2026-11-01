# reaper-harness

Unattended REAPER host tests for VST3 plugins on Windows: render null tests, bypass, save and
reopen, instance churn. Every run uses a private, isolated REAPER configuration and never touches
your own REAPER setup.

> **Status:** in development. Nothing has been released yet, and the command line and the
> configuration format may still change.

[中文说明](README.zh-CN.md)

- **One configuration file per plugin project.** The project lists its plugins, track layouts and
  scenarios; the harness builds the REAPER projects, drives REAPER through a Lua script, renders,
  and compares the renders sample by sample.
- **Safe by default.** REAPER runs on a dummy audio device with a private configuration directory.
  The harness refuses to start when that directory could be REAPER's default resource directory,
  ends only the processes it started itself, and checks before and after every round that the
  default resource directory has not changed.
- **Local only.** It drives an installed copy of REAPER 7 in a real desktop session; you need a
  REAPER licence under REAPER's own terms. It is not meant for hosted CI runners. Its self-test
  needs no REAPER and runs anywhere.

## What is here so far

The safety base and the comparer: the guard for the private configuration directory, the process
host that starts REAPER (watchdog, dialog handling, module list), the GUI locks and the WAV
comparer, each with its self-test. The scenarios and the command that runs them come next.
[docs/SAFETY.md](docs/SAFETY.md) describes what is guaranteed and why.

Requirements: Windows 10 or 11, PowerShell 7.4+.

```powershell
# a private configuration directory (never under %APPDATA%)
pwsh doctor.ps1 -CfgDir D:\reaper-harness\cfg -Init

# the self-test (no REAPER needed)
pwsh run.ps1 -SelfTest
```

REAPER is a trademark of Cockos Incorporated. This project is not affiliated with or endorsed by
Cockos.

## License

MIT, see [LICENSE](LICENSE).
