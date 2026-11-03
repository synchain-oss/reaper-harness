# Extensions

The built-in kinds cover what every plugin needs. Checks that only make sense for one product (reading a plugin's
own diagnostics, driving two instances that talk to each other, a custom stress pattern) go into extensions:
PowerShell modules that add scenario kinds and preflight checks, and Lua files that add steps to the driver.
Extensions are listed in the configuration, relative to the directory of the configuration file:

```json
"extensions": { "modules": ["ext/MyChecks.psm1"], "lua": ["ext/my-steps.lua"] }
```

Everything about extensions is checked before REAPER starts, and every problem is a usage error (exit code 64):

- a path that is absolute, drive-relative, leaves the configuration directory (also after junctions and symbolic
  links are resolved) or does not exist;
- a module that does not export `Register-HarnessExtension`, whose registration throws or returns something else
  than the contract below, or whose file name is the name of one of the harness's own modules;
- a kind name that is built in (`render`, `device`, `savereopen`, `instances`, and the internal `hang`, `guard`) or
  registered by another extension; an extension name used twice;
- a Lua step name that the driver already has or another file declares.

Extensions run with your rights, inside the harness process (modules) and inside REAPER (Lua files). Only list
code you trust.

`tests/fixtures/ext/` holds a complete small example that the self-test runs.

## Modules

A module exports one function, `Register-HarnessExtension`, without parameters:

```powershell
Set-StrictMode -Version Latest

function Register-HarnessExtension {
    @{
        Name      = 'my-checks'               # ^[a-z][a-z0-9-]{0,39}$, recorded in the result file
        Kinds     = @{
            'my-kind' = @{
                Validate = { param($Item) ... }        # returns problem strings; nothing when valid
                Run      = { param($Ctx, $Scenario) ... } # returns an outcome
            }
        }
        Preflight = { param($Config) ... }     # optional; returns reasons to skip the whole suite
    }
}
Export-ModuleMember -Function Register-HarnessExtension
```

`Kinds` or `Preflight` (or both) must be present; no other keys are accepted.

### Validate

Called once per scenario or negative case of the kind while the configuration is read. `$Item` is an ordered
dictionary of the scenario's fields other than `id`, `kind`, `expect` and `expectDetail`, as parsed from JSON
(integers are `[long]`, numbers `[double]`, objects ordered dictionaries, arrays `object[]`). Return one string per
problem; they are listed with the scenario's path. The harness checks `id` (and, for negative cases, `expect` and
`expectDetail`) itself, and a string field `layout` against the layouts.

### Run

Called with the round context and the scenario. The scenario has `id`, `kind`, `raw` (the dictionary from the
configuration, all fields), `layout` when it has one, and `negative`, `expect`, `expectDetail` for negative cases.
Return an outcome made with `& $Ctx.Api.Outcome <PASS|FAIL|INCOMPLETE> '<one line>' [<facts>]`. Anything else, or
an exception, is recorded as INCOMPLETE. The detail and every string in the facts go into the result file with local
paths masked. Numbers, booleans, characters, dates and enums in the facts stay what they are; any other value type is
written as its text, masked the same way. JSON has no NaN or infinity, so those are written as the strings `"NaN"`,
`"Infinity"` and `"-Infinity"`, and dates as ISO 8601 strings.

Scenarios of extension kinds always get the learned plugin blocks: by the time `Run` is called, `$Ctx.Blocks` and
`$Ctx.Names` (plugin id → the name REAPER shows) are filled, and the private copies are proven.

`$Ctx.Api` holds the building blocks the built-in kinds use; call them with `&`:

| member | |
|---|---|
| `Outcome` | `& $Ctx.Api.Outcome PASS 'detail' $facts` |
| `Layout` | `& $Ctx.Api.Layout $Ctx '<layout id>'`: the normalised layout |
| `NewRun` | `& $Ctx.Api.NewRun -Ctx $Ctx -Name <file name> -Layout <layout> [-Sr] [-Block] [-Mode] [-Channels] [-Bypass] [-NoFx] [-Stems <track names>] [-AnticipativeFx <bool>]`: writes the project (from the learned blocks) and sets the audio device (anticipative FX on unless `-AnticipativeFx $false`); returns `Project`, `Wav` (the master) and `Stems` (track name → file). The master is `<Name>.wav`; with stems REAPER writes `<Name>-stem-<track>.wav` per stem and the master as `<Name>-stem-Master.wav`. Start your names with the scenario id: names starting with `_` are the harness's own |
| `Render` | `& $Ctx.Api.Render $Ctx <project> <wav> [-Also <files>]`: one render launch; returns `Run` and `Why` (empty when it worked; a file of `-Also`, such as the stems of `NewRun`, that the render did not produce is a reason too) |
| `LuaStep` | `& $Ctx.Api.LuaStep -Ctx $Ctx -Name <file name> -Step <step> [-Job @{...}] [-Watch @{ label = <mark file> }] [-TimeoutSec]`: one driver launch; returns `Run`, `Result` (the key=value lines as a hashtable) and `Why` |
| `Compare` | `& $Ctx.Api.Compare -A <wav> -B <wav> [-MaxDiffDb] [-Lag] [-PeakMaxDb] [-NotSilent]`: the comparer; returns an outcome |
| `Reference` | `& $Ctx.Api.Reference $Ctx <layout id> <sr> <block> <mode> <channels> [-Stems <track names>] [-AnticipativeFx <bool>]`: the dry reference render, cached per round; returns `Wav`, `Stems` and `Why` (empty when it worked) |
| `Judge` | `& $Ctx.Api.Judge $Ctx <criteria> <reference wav, or '' for none> <test wav>`: one file against criteria as `render` judges it (an object with all of `maxDiffDb`, `lag`, `peakMaxDb`, `notSilent`, `rmsDb`, `energyRatioDb`, `rmsChangeDb`, `$null` for those not used; without a reference the file is judged on its own); returns an outcome |
| `StateProof`, `FxBlocks` | `& $Ctx.Api.StateProof -Layout <layout> -Blocks $Ctx.Blocks -States $Ctx.States -Saved (& $Ctx.Api.FxBlocks <text of a project REAPER saved>)`: whether every FX with a named state holds it, as `device` and `savereopen` check; returns `Problems` and `Proven` |
| `FxReport`, `ParamReads` | check a driver report of tracks and FX against a layout, as `device` does |
| `HostFailure` | the one-line reason for a launch that did not end normally |
| `HidePaths` | masks local paths in a text |
| `Signal` | the path of the test signal file for a rate and channel count |

Every launch through these goes through the same guards, locks, watchdog, dialog handling and module check as the
built-in kinds. Do not start REAPER any other way.

### Preflight

Called once before anything is installed or started, with the normalised configuration. Return strings: each one
is a reason, and any reason makes the whole suite SKIPPED (exit code 3) with zero launches. A preflight that
throws is a reason too. Use it for things your kinds need that may be missing on a machine.

Two checks that belong in a preflight of your own, not in the harness, because only your project knows what to
look for:

- **Another host with your plugin open.** Plugins that talk to each other through shared memory or a named pipe
  can see instances in a DAW the user has open. Probe for the names your plugin creates, read-only, and close
  them again at once; return a reason when one exists, so the suite is SKIPPED instead of mixing with a live
  session.
- **Your plugin's own diagnostic logs.** Note the size of each log file in the preflight and read what was added
  in a scenario of a kind of your own, listed after the others (there is no hook after the run). Only read the
  user's data directories, never write to them.

```powershell
Preflight = {
    param($Config)
    foreach ($name in 'Local\MyPlugin-group-1', 'Local\MyPlugin-group-2') {
        try { $m = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($name, [IO.MemoryMappedFiles.MemoryMappedFileRights]::Read); $m.Dispose(); "another host has $name open" }
        catch [IO.FileNotFoundException] { }
    }
}
```

## Lua files

```lua
-- SPDX-License-Identifier: MIT
-- harness-steps: my_step, my_other_step
return {
    my_step = function(h)
        local track = reaper.GetTrack(0, 0)
        h.put("tracks", reaper.CountTracks(0))
    end,
}
```

The `-- harness-steps:` line (within the first 20 lines) declares the step names, `^[a-z][a-z0-9_]{0,39}$`; the
harness checks them for conflicts before REAPER starts, and the driver checks the returned table again at run time.
The file returns a table of step name → function. The function gets `h`:

| member | |
|---|---|
| `h.job` | the job table (`step`, `result`, and the fields of `-Job`) |
| `h.put(key, value)` | adds a `key=value` line to the result (control characters become spaces) |
| `h.wait(seconds)` | waits while letting REAPER run (the driver is a coroutine; never busy-wait) |
| `h.touch(path)` | writes a mark file; with `-Watch` the harness samples handle and memory counts when it appears |
| `h.openAndWait(path)` | opens a project and waits for its plugins |
| `h.device(attr)` | `GetAudioDeviceInfo` with retries |
| `h.putTracks(prefix, reads)`, `h.findParam`, `h.paramText` | what the `device` step uses to report tracks, FX and parameters |

The driver writes `done=1` and quits REAPER when the function returns; an error is written as `error=...` and makes
the launch's `Why` say so.

## Putting a probe back

A typical product-specific check needs a plugin to report something about itself (a self-test result, a latency it
measured, a state it reached). A pattern that fits the harness: the plugin exposes it as a read-only parameter or a
named config value; a Lua step reads it with `TrackFX_GetNamedConfigParm` or `TrackFX_GetFormattedParamValue` and
`h.put`s it; a kind's `Run` builds a project with `NewRun`, runs the step with `LuaStep` and judges `Result`. Give
such a kind a negative case in the configuration (for example a layout where the probe must report failure) so a
probe that never reads anything cannot pass.
