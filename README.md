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
- **Tests the build you gave it.** Every round proves, from the module list of the REAPER process
  and from REAPER's own `fx_ident`, that the plugin binaries loaded are the private copies of your
  build and not an installed release with the same name.
- **No silent passes.** Outcomes are PASS, FAIL, INCOMPLETE (no conclusion), SKIPPED or REFUSED;
  INCOMPLETE never counts as PASS. Built-in negative cases prove in every round that the comparer,
  the watchdog and the guards still work.
- **Local only.** It drives an installed copy of REAPER 7 in a real desktop session; you need a
  REAPER licence under REAPER's own terms. It is not meant for hosted CI runners. Its self-test
  needs no REAPER and runs on any Windows machine.

## What it tests

| kind | |
|---|---|
| `render` | renders a layout (tracks, folders, sends, pan and mute, FX chains with parameters set by name or named plugin states, a test signal per track) and compares it with a dry render, a repeat render or a variant (another block size, render mode, bypass or layout), or judges it on its own: bit-identical, or within a residual, at an expected lag, with peak, silence and per-channel level and balance checks; the master and any track as a stem of its own |
| `device` | the dummy device runs at the configured block size, sample rate and anticipative FX setting; every FX is loaded, not offline, reports the expected latency, reads back its parameters and holds the state it was given |
| `savereopen` | saving and reopening, once or many times, keeps every FX, parameter and state, and the reopened project renders bit-identically |
| `instances` | adding and removing instances many times does not grow handles or memory beyond limits |

A small JSFX that ships with the tool delays the signal and reports the delay as latency (or not), so plugin delay
compensation can be tested without depending on the effects that come with REAPER. Extensions add
product-specific kinds and driver steps ([docs/EXTENDING.md](docs/EXTENDING.md)).

## Quick start

Requirements: Windows 10 or 11, PowerShell 7.4+, REAPER 7 (x64).

```powershell
# once: a private configuration directory (never under %APPDATA%)
pwsh doctor.ps1 -CfgDir D:\reaper-harness\cfg -Init

# check a configuration and the machine (never starts REAPER)
pwsh doctor.ps1 -CfgDir D:\reaper-harness\cfg -Config my-plugin.json -PluginDir D:\build\VST3

# run
pwsh run.ps1 -Config my-plugin.json -CfgDir D:\reaper-harness\cfg -PluginDir D:\build\VST3 -ResultDir D:\reaper-harness\results

# the self-test of the harness itself (no REAPER needed)
pwsh run.ps1 -SelfTest
```

Exit codes: 0 PASS, 1 FAIL, 2 INCOMPLETE, 3 SKIPPED, 64 refused or usage error.

## Documentation

- [docs/USAGE.md](docs/USAGE.md): running it, options, exit codes
- [docs/CONFIG.md](docs/CONFIG.md): the configuration file; `schema/config.schema.json` is its JSON Schema
- [docs/SAFETY.md](docs/SAFETY.md): what it guarantees and why
- [docs/RESULTS.md](docs/RESULTS.md): the result file
- [docs/EXTENDING.md](docs/EXTENDING.md): extension modules and Lua steps

REAPER is a trademark of Cockos Incorporated. This project is not affiliated with or endorsed by
Cockos.

## License

MIT, see [LICENSE](LICENSE).
