# Configuration file

One JSON file describes what to test: the plugins, the track layouts and the scenarios. It is read strictly:
an unknown key, a wrong type, a value out of range or a reference to something that does not exist is a usage
error (exit code 64) and REAPER is never started. Every problem is listed at once.

`schema/config.schema.json` is a JSON Schema (draft 2020-12) of the structure. It is generated from the validator
(`pwsh run.ps1 -WriteSchema`) and the self-test checks that it is current and that `Test-Json` agrees with the
validator. Point an editor at it with `"$schema": "<path>/config.schema.json"` for completion. The schema covers
the structure only; references between parts (layout ids, plugin ids, parent tracks) are checked by the validator.

`tests/fixtures/config.json` is a complete example.

## Top level

| key | required | meaning |
|---|---|---|
| `schema` | yes | always `1` |
| `name` | yes | `[a-z0-9-]{1,40}`; goes into result file names |
| `notes` | | free text |
| `plugins` | yes | id → plugin (at least one) |
| `signal` | | the test signal |
| `limits` | | time limits and search windows |
| `layouts` | yes | id → layout (at least one) |
| `scenarios` | yes | list of scenarios (at least one) |
| `negative` | | your own negative cases |
| `extensions` | | extension modules and Lua files, see [EXTENDING.md](EXTENDING.md) |
| `$schema` | | ignored; for editors |

Ids of plugins and layouts match `^[a-z][a-z0-9-]{0,39}$`. Scenario ids match `^[a-z0-9][a-z0-9-]{0,59}$` and must
be unique across scenarios, negative cases and the built-in negative cases.

## plugins

```json
"plugins": {
  "gain": { "bundle": "My Gain.vst3" },
  "bus":  { "bundle": "My Bus.vst3", "expectPdc": 64 }
}
```

- `bundle`: the name of the `.vst3` bundle directory, looked up in `-PluginDir`. The bundle must contain
  `Contents/Resources/moduleinfo.json` (the VST3 SDK writes it) with exactly one `Audio Module Class`, and
  `Contents/x86_64-win/<bundle>` (the binary). The name REAPER shows, `VST3: <Name> (<Vendor>)`, is taken from that
  class; two plugins with the same name cannot be told apart and are refused in the preflight.
- `expectPdc`: the latency in samples the plugin must report (default 0). Checked by `device` and `savereopen`.

## signal

The test signal is one impulse followed by seeded noise (and optionally a sine), written as 32-bit float WAV per
sample rate and channel count. The same seed always gives the same file.

| key | default | |
|---|---|---|
| `seconds` | 4 | 0.5 … 600 |
| `seed` | 1 | 0 … 4294967295 |
| `noiseDb` | -20 | noise level in dBFS |
| `sine` | none | `{ "hz": 440, "db": -20 }` |

## limits

| key | default | |
|---|---|---|
| `renderTimeoutSec` | 90 | one render launch |
| `luaTimeoutSec` | 120 | one Lua driver launch |
| `learnTimeoutSec` | 120 | the learn launch |
| `lockWaitSec` | 1800 | how long to wait for the GUI locks before a launch; not taken in time is INCOMPLETE |
| `lagSearch` | 64 | the comparer searches lags within ± this many samples |
| `headSeconds` | 2 | the residual of the first seconds is reported separately (`head=`) |
| `instances` | | defaults for the `instances` kind: `cycles` 25, `warmup` 5, `play` false, `maxHandleGrowth` 150, `maxPrivateGrowthMB` 150 |

## layouts

A layout is a list of tracks in project order.

```json
"bus": {
  "tracks": [
    { "name": "Bus", "source": false, "folder": true, "fx": [ { "plugin": "bus" } ] },
    { "name": "Vox 1", "source": true, "parent": "Bus", "fx": [ { "plugin": "gain" } ] },
    { "name": "Vox 2", "source": true, "parent": "Bus", "volume": 0.5,
      "fx": [ { "plugin": "gain", "params": { "Gain": { "normalized": 0.25, "display": "0.25" } } } ] }
  ]
}
```

| key | required | meaning |
|---|---|---|
| `name` | yes | unique within the layout; no double quotes or control characters |
| `source` | yes | the track carries the test signal |
| `folder` | | a REAPER folder (bus) track |
| `parent` | | name of the folder track above this one; children follow their folder directly |
| `volume` | | linear track volume 0 … 4, default 1 |
| `fx` | | the FX chain, in order |

An FX is `{ "plugin": "<id>", "bypass": true|false, "params": { "<parameter name>": <value> } }`. A parameter
value is a normalized number 0 … 1, or `{ "normalized": 0.25, "display": "0.25" }`: then the text REAPER shows for
the parameter must equal `display` exactly. Parameters are set and read back by name. The plugin state for every
distinct set of parameters is learned once per round (see [SAFETY.md](SAFETY.md#learning-the-plugin-blocks)); a
plugin block is never written by hand.

## scenarios

Every scenario has `id` and `kind`. The built-in kinds are `render`, `device`, `savereopen` and `instances`;
extensions can add more. `sr` (default 48000), `block` (default 512) and `mode` (default `offline`) set the dummy
audio device and the render speed: `offline` renders at full speed, `1x` at real-time speed with plugins told
they run offline, `online` in real time with plugins told they run live.

### matrix

`"matrix": { "mode": [...], "sr": [...], "block": [...] }` expands one scenario into the cross product. The
expanded ids are `<id>-<mode>-<sr>-<block>` for the axes present, in that order (for example `chain-offline-48000`).
An axis cannot also be given directly. Negative cases cannot have a matrix.

### render

Renders the layout and compares the render with a reference.

| key | meaning |
|---|---|
| `layout` | required |
| `mode`, `sr`, `block` | see above |
| `mono` | render one channel instead of two |
| `bypass` | `true` (every FX) or a list of plugin ids rendered bypassed |
| `compare` | `"dry"` (default): the same layout without any FX; `"repeat"`: the same render twice; or a variant `{ "layout", "block", "mode", "bypass" }`, where the fields given replace the scenario's own |
| `maxDiffDb` | allowed residual in dBFS at the expected lag; absent means the renders must be bit-identical |
| `lag` | the expected lag in samples, test render later than the reference is positive; default 0 |
| `peakMaxDb` | the test render must not peak above this |
| `notSilent` | the test render must peak above -120 dBFS |

The pass criteria are fields of the scenario itself, not a nested object: in negative cases `expect` names the
expected outcome. Both renders must be readable, comparable (same rate and channel count) and free of NaN and Inf
in every case. A render with no frames is INCOMPLETE before any of this, so a negative case expecting FAIL does not
pass on one. The verdict line always starts with the same facts, in this order:
`identical= lag= maxdiff= head= frames= channels= rate= format= nonfinite= peak=`, followed by `; failed: <reasons>`
on a FAIL. Negative cases match that line with a regex.

### device

Opens the layout's project through the Lua driver and checks that the dummy device runs at `block` and `sr`, that
every FX is loaded, not offline, reports `expectPdc`, has the configured bypass state and reads back every
configured parameter.

### savereopen

Opens the project, reads every FX (as `device`), saves it as a new file, opens that and reads again: everything
must be equal. Then renders the original and the saved copy; the two renders must be bit-identical. Takes `mode`,
`sr`, `block` and `bypass` like `render`.

### instances

Adds and removes instances of the listed plugins `cycles` times on an empty project (`play`: with the transport
running), after `warmup` cycles. The process handle count and private memory are sampled after the warm-up and at
the end; growth above `maxHandleGrowth` or `maxPrivateGrowthMB` is FAIL.

| key | |
|---|---|
| `plugins` | required, plugin ids |
| `cycles`, `warmup`, `play`, `maxHandleGrowth`, `maxPrivateGrowthMB` | default from `limits.instances` |
| `sr`, `block` | |

## negative cases

A negative case is a scenario that must come out a certain way: the same fields as its kind (no matrix), plus

| key | |
|---|---|
| `expect` | `PASS`, `FAIL`, `SKIPPED`, `INCOMPLETE` or `REFUSED` |
| `expectDetail` | a .NET regex, case sensitive, that the outcome detail must match |

A negative row is PASS only when both the outcome and the detail match. Outcomes alone can come about without the
case having run (a lock that was busy, a render that never started); a matching outcome with another detail is
INCOMPLETE ("not verified"), and an observed INCOMPLETE is INCOMPLETE too, never FAIL. Example: a layout that must
differ from another one.

```json
{ "id": "neg-bus-is-not-chain", "kind": "render", "layout": "bus", "compare": { "layout": "chain" },
  "expect": "FAIL", "expectDetail": "^identical=no lag=0 " }
```

### built-in negative cases

These run in every round unless `-NoNegative` is given. They do not depend on your plugins.

| id | proves | expected |
|---|---|---|
| `neg-offset-1-sample` | the comparer sees a one-sample shift (a layout without FX) | FAIL, `^identical=no lag=1 ` |
| `neg-track-minus-6db` | the comparer sees a -6 dB track | FAIL, `^identical=no lag=0 maxdiff=-6\.0` |
| `neg-timeout` | the watchdog ends a REAPER that hangs at the time limit, the process is gone, the locks are free | INCOMPLETE, `^timed out after .*; the process has ended and the GUI locks are free$` |
| `neg-killed` | the same for the kill point | INCOMPLETE, `^killed at the deadline .*; ...$` |
| `neg-skip-marker` | a skip marker makes the whole entry point SKIPPED without starting REAPER | SKIPPED, `^launches=0; skip marker present` |
| `neg-sentinel-missing` | a configuration directory without the sentinel is refused | REFUSED, `^REFUSED: .*sentinel` |
| `neg-default-dir` | REAPER's default resource directory is refused | REFUSED, `^REFUSED: .*never touched` |

The three guard cases run the real entry point again inside the same process, with one thing changed.
