# Configuration file

One JSON file describes what to test: the plugins, the track layouts and the scenarios. It is read strictly:
an unknown key, a wrong type, a value out of range or a reference to something that does not exist is a usage
error (exit code 64) and REAPER is never started. Every problem is listed at once.

`schema/config.schema.json` is a JSON Schema (draft 2020-12) of the structure. It is generated from the validator
(`pwsh run.ps1 -WriteSchema`) and the self-test checks that it is current and that `Test-Json` agrees with the
validator. Point an editor at it with `"$schema": "<path>/config.schema.json"` for completion. The schema covers
the structure only; references between parts (layout ids, plugin ids, states, parent tracks, send targets) are
checked by the validator.

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
  "gain":  { "bundle": "My Gain.vst3" },
  "bus":   { "bundle": "My Bus.vst3", "expectPdc": 64 },
  "delay": { "jsfx": "harness-pdc-delay", "expectPdc": 64,
             "params": { "Delay (samples)": { "normalized": 0.0078125, "display": "64.0" } } }
}
```

A plugin has exactly one of `bundle` and `jsfx`.

- `bundle`: the name of the `.vst3` bundle directory, looked up in `-PluginDir`. The bundle must contain
  `Contents/Resources/moduleinfo.json` (the VST3 SDK writes it) with exactly one `Audio Module Class`, and
  `Contents/x86_64-win/<bundle>` (the binary). The name REAPER shows, `VST3: <Name> (<Vendor>)`, is taken from that
  class; two plugins with the same name cannot be told apart and are refused in the preflight.
- `jsfx`: a JSFX shipped with the tool (see [JSFX](#jsfx)), instead of a bundle.
- `expectPdc`: the latency in samples the plugin must report (default 0). Checked by `device` and `savereopen`.
- `params`: parameter values every FX of this plugin gets (an FX's own `params` go on top), see [layouts](#layouts).
- `states`: named plugin states, see [states](#states). VST3 plugins only.

### states

Some settings of a plugin live only in its state, not in any parameter: a channel or group number, a routing
switch, anything the plugin's own window sets. Two instances of one plugin with such settings need two states. A
state is a plugin block exactly as REAPER saved it; you set the instances up in REAPER, save, and name the block:

```json
"input": {
  "bundle": "My Input.vst3",
  "states": {
    "ch1": { "template": "states/template.rpp", "track": "Vox 1", "fx": 1 },
    "ch2": { "template": "states/template.rpp", "track": "Vox 2", "fx": 1 },
    "spare": { "stateFile": "states/spare.RfxChain" }
  }
}
```

- `template`, `track`, `fx`: a project saved by REAPER (the template), the name of one of its tracks, and which FX
  of that track's chain (counted from 1, a container counts as one FX, as in REAPER's FX list). The track name must
  be unique in the template.
- `stateFile`: a file that holds exactly one plugin block at its top level, for example an FX chain REAPER saved
  with one FX in it (`.RfxChain`).
- Names match `^[a-z0-9][a-z0-9-]{0,39}$`. Paths are relative to the configuration file and must stay inside its
  directory (the same rules as extension paths).

An FX uses a state with `"state": "<name>"`. `params` still apply on top of the state and are read back.

What is checked, all before REAPER starts (any problem is a usage error naming the state; nothing is run):

- the template has that track and that many FX, and the block is a VST3 block (not a JS or other effect);
- the block belongs to the plugin: the name REAPER wrote (`VST3: <Name> (<Vendor>)`) and the class ID in the block
  header must equal the ones in the bundle's `moduleinfo.json`.

Only the named block is taken from a template; nothing else in it is read into the harness, logged or written to
the results. A custom FX name in the block header (REAPER's "Rename FX") is dropped, because the runs check the name
REAPER shows. The block goes only into projects in the work directory. Result files carry the state's name and the
first 12 hex digits of the SHA-256 of the block (`states` at the top level and in the `learn` row's facts).

How the state is proven to be loaded: the learn launch opens a project that already holds each state's block, so
REAPER loads it like any saved project, and the block REAPER saves back must equal the one it was given (the header
line aside); `device` and `savereopen` save the project they opened again and compare every state FX's block with
the block it was given. A plugin that ignores or rewrites a state fails there, naming the track and the FX.

## signal

The test signal is one impulse at 0.25 s followed by seeded noise (and optionally a sine), written as 32-bit float
WAV per sample rate and channel count. Each channel gets its own noise stream, so swapped channels are detectable.
The same settings always give the same file.

| key | default | |
|---|---|---|
| `seconds` | 4 | 0.5 … 600 |
| `seed` | 1 | 0 … 4294967295 |
| `noiseDb` | -20 | noise level in dBFS |
| `sine` | none | `{ "hz": 440, "db": -20 }` |

A track can have its own signal (`seed`, `noiseDb`, `sine`; see [layouts](#layouts)); the fields it gives replace
the top-level ones. Tracks with the same settings get the same file, in any layout: a track named the same in two
layouts can be rendered in both with the same signal and subtracted on the same timeline (`compare: { "layout" }`).

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
"mix": {
  "tracks": [
    { "name": "Bus", "source": false, "folder": true, "fx": [ { "plugin": "bus" } ] },
    { "name": "Vox 1", "source": true, "parent": "Bus", "fx": [ { "plugin": "input", "state": "ch1" } ] },
    { "name": "Vox 2", "source": true, "parent": "Bus", "volume": 0.5, "signal": { "seed": 2 },
      "fx": [ { "plugin": "gain", "params": { "Gain": { "normalized": 0.25, "display": "0.25" } } } ] },
    { "name": "Drums", "source": true, "pan": -0.5, "signal": { "seed": 3 },
      "sends": [ { "to": "Verb", "volume": 0.5 }, { "to": "Cue", "mode": "pre" } ] },
    { "name": "Verb", "source": false, "fx": [ { "plugin": "gain" } ] },
    { "name": "Cue", "source": false, "masterSend": false }
  ]
}
```

| key | required | meaning |
|---|---|---|
| `name` | yes | unique within the layout; no double quotes or control characters |
| `source` | yes | the track carries the test signal |
| `signal` | | this track's own signal: `seed`, `noiseDb`, `sine` replace the top-level ones; only on a `source` track |
| `folder` | | a REAPER folder (bus) track |
| `parent` | | name of the folder track above this one; children follow their folder directly |
| `volume` | | linear track volume 0 … 4, default 1 |
| `pan` | | -1 (left) … 1 (right), default 0 |
| `mute` | | default false |
| `masterSend` | | default true; false keeps the track out of the master (or out of its folder) |
| `sends` | | sends to other tracks of the layout: `{ "to", "mode", "volume" }` |
| `fx` | | the FX chain, in order |

An FX is `{ "plugin": "<id>", "state": "<name>", "bypass": true|false, "params": { "<parameter name>": <value> } }`.
A parameter value is a normalized number 0 … 1, or `{ "normalized": 0.25, "display": "0.25" }`: then the text
REAPER shows for the parameter must equal `display` exactly. Parameters are set and read back by name. The plugin
block for every distinct state and set of parameters is learned once per round (see
[SAFETY.md](SAFETY.md#learning-the-plugin-blocks)); a plugin block is never written by hand.

### routing

A send is `{ "to": "<track>", "mode": "post" | "pre" | "prefx", "volume": 0 … 4 }`:

| mode | taps the track | REAPER's name |
|---|---|---|
| `post` (default) | after the FX, the fader and the pan | post-fader (post-pan) |
| `pre` | after the FX, before the fader and the pan | pre-fader (post-FX) |
| `prefx` | before the FX | pre-FX |

An aux track is an ordinary track without `source` that receives sends. A track with `masterSend: false` is not
mixed into the master (or its folder) but still renders as a stem. A send to a track not in the layout, a send to
itself and a loop (sends and folder feeds that lead back to a track) are usage errors.

Measured on REAPER 7.82 (offline render, 48 kHz, REAPER's default preferences): a muted track renders silence as a
stem and sends nothing, through post-fader, pre-fader and pre-FX sends alike. Pan is REAPER's default for stereo
tracks (balance: the far channel is scaled, -0.5 halves the right channel, 6.02 dB below the left).

## JSFX

The tool ships one JSFX in `jsfx/`, written for it (MIT):

| name | parameters | what it does |
|---|---|---|
| `harness-pdc-delay` | `Delay (samples)` 0 … 8192 (normalized: samples / 8192; REAPER shows `64.0` for 64), `Report delay as PDC` Off / On (default On) | delays both channels by a whole number of samples; with the report on it tells REAPER that delay as its latency (PDC), so REAPER compensates it and a render lines up with the dry signal; with the report off the render is late by the delay |

A plugin with `"jsfx": "<name>"` is copied into `Effects/reaper-harness/` of the private configuration directory
before the first launch and added by its path there, so no JSFX that comes with REAPER (whose file names change
between versions) is needed. The result lists it with the plugins (`jsfx`, `name`, `sha256` of the file). States are
not supported for JSFX; use `params`.

Measured on REAPER 7.82 (offline render, 48 kHz): with the report on, a 64-sample delay reads back as `pdc` 64 and
renders bit-identical to the dry render at block sizes 32 and 2048 (in the master and in stems); with the report
off, a 16-sample delay renders 16 samples late. In a mix of several tracks where one reports latency, the stems
were bit-identical to the dry ones but the master differed from the dry master by about -156 dBFS (rounding in the
compensated sum): give such a scenario a `maxDiffDb`.

## scenarios

Every scenario has `id` and `kind`. The built-in kinds are `render`, `device`, `savereopen` and `instances`;
extensions can add more. `sr` (default 48000; 8000 … 384000), `block` (default 512; 16 … 8192, so 32 and 2048 are
fine) and `mode` (default `offline`) set the dummy audio device and the render speed: `offline` renders at full
speed, `1x` at real-time speed with plugins told they run offline, `online` in real time with plugins told they run
live.

### host

`"host": { "anticipativeFx": true | false }` turns REAPER's anticipative FX processing on or off for the scenario
(default on, as REAPER ships). Only the private configuration directory's `reaper.ini` is written: bit 0 (value 1)
of `workrender` in `[REAPER]`; the other bits are kept. Without the key REAPER uses 17 (bit 0 set).

Measured on REAPER 7.82 (x64, Dummy Audio 48 kHz / 512 samples, the private configuration directory): with
`workrender=17` a JSFX that reports its playback position ran 202.7 … 224.0 ms ahead of the play cursor (median
213.3 ms); with `workrender=16` it ran 10.7 … 42.7 ms ahead (median 21.3 ms). The ini has no key while the value
is the default. `device` reads `workrender` back from the running REAPER and checks bit 0.

### matrix

`"matrix": { "mode": [...], "sr": [...], "block": [...] }` expands one scenario into the cross product. The
expanded ids are `<id>-<mode>-<sr>-<block>` for the axes present, in that order (for example `chain-offline-48000`).
An axis cannot also be given directly. Negative cases cannot have a matrix. A `device` scenario renders nothing, so
its matrix has no `mode` axis (a usage error), only `sr` and `block`.

### render

Renders the layout and compares the render with a reference.

| key | meaning |
|---|---|
| `layout` | required |
| `mode`, `sr`, `block`, `host` | see above |
| `mono` | render one channel instead of two |
| `bypass` | `true` (every FX) or a list of plugin ids rendered bypassed |
| `compare` | `"dry"` (default): the same layout without any FX; `"repeat"`: the same render twice; `"none"`: no reference, the render is judged on its own; or a variant `{ "layout", "block", "mode", "bypass" }`, where the fields given replace the scenario's own |
| `maxDiffDb` | allowed residual in dBFS at the expected lag, -400 … 24 (a mix of several tracks can differ by more than full scale); absent means the renders must be bit-identical |
| `lag` | the expected lag in samples, test render later than the reference is positive; default 0 |
| `peakMaxDb` | the test render must not peak above this |
| `notSilent` | the test render must peak above -120 dBFS |
| `rmsDb` | channel → `[min, max]`: the RMS of that channel of the test render, in dBFS |
| `energyRatioDb` | `"A/B"` → `[min, max]`: RMS of channel A minus RMS of channel B of the test render, in dB |
| `rmsChangeDb` | channel → `[min, max]`: RMS of the test render minus RMS of the reference, per channel, in dB |
| `stems` | tracks rendered as files of their own, see [stems](#stems) |

The pass criteria are fields of the scenario itself, not a nested object: in negative cases `expect` names the
expected outcome. Both renders must be readable, comparable (same rate and channel count) and free of NaN and Inf
in every case. A render with no frames is INCOMPLETE before any of this, so a negative case expecting FAIL does not
pass on one. The verdict line always starts with the same facts, in this order:
`identical= lag= maxdiff= head= frames= channels= rate= format= nonfinite= peak=` (with `compare: "none"`:
`frames= channels= rate= format= nonfinite= peak=`), followed by `rms=` per channel when a channel criterion is
given (reference / test), `nan= inf=` when there are any, and `; failed: <reasons>` on a FAIL. Negative cases match
that line with a regex.

`maxDiffDb`, `lag` and `rmsChangeDb` need a reference; with `compare: "none"` they are usage errors.

Channel criteria: a channel is `L`, `R` or its number from 1. A channel the render does not have is a usage error
(for example `R` of a `mono` render). The RMS of a channel is taken over its finite samples; NaN and Inf are
counted apart (and fail the render anyway); a channel without finite samples has no RMS, which fails any criterion
on it. Digital silence counts as -400 dB, the lowest value a range can name, so `[-400, -400]` means "silent" and
`[-400, x]` accepts silence; the ratio of two silent channels is undefined and fails. A range is `[min, max]`
with -400 ≤ min ≤ max ≤ 24.

### stems

`"stems": [ "<track>", { "track": "<track>", "compare": "reference" | "none", <criteria> } ]` renders each listed
track (folder and aux tracks too) as a file of its own next to the master, in the same launch (REAPER's "master mix
and stems of selected tracks"). Each stem is judged on its own criteria and appended to the verdict line as
`| stem <track>: <its line>`; the master's line comes first, so negative cases can still match its start. The
scenario's outcome is the worst of the master and the stems.

- `compare: "reference"` (the default when the scenario has a reference) compares the stem with the same track's
  stem of the reference render (the dry layout, the first render, or the variant's layout, which must have the
  track); `"none"` judges it on its own.
- A stem takes the scenario's `maxDiffDb`, `lag`, `peakMaxDb` and `notSilent` unless it gives its own. The channel
  criteria (`rmsDb`, `energyRatioDb`, `rmsChangeDb`) describe one signal's levels and balance, so a stem has only
  its own.
- The stem file is named after the track, so a stem's track name may only use letters, digits, space and
  `( ) + _ . -`, must not end in a space or a dot, and must not be `Master` (REAPER names the master file so). A
  track listed twice (in any case) is a usage error.

What a stem holds, measured on REAPER 7.82 (offline render, 48 kHz): the track's output as it leaves the track,
after its FX, fader, pan and mute, including what it receives (a folder's stem is the sum of its children through
its own fader; an aux's stem has its sends in it), whether or not it sends to the master; latency the plugins report
is compensated in stems as in the master. A pre-fader send from a track carries the signal before that track's
fader and pan.

There is no switch for bypassing an FX in the middle of a render; render two layouts (or the same layout with and
without `bypass`) and compare them instead.

### device

Opens the layout's project through the Lua driver and checks that the dummy device runs at `block` and `sr`, that
anticipative FX processing reads back as `host.anticipativeFx`, and that every FX is loaded, not offline, reports
`expectPdc`, has the configured bypass state and reads back every configured parameter. A layout with states also
saves a copy while the project is open and checks every state FX's block in it against the block it was given.

### savereopen

Opens the project, reads every FX (as `device`), saves it as a new file, opens that and reads again, `cycles` times
(default 1, up to 100): every value must read the same after each reopen. A layout with states also checks the
state blocks of the last saved copy against the blocks they were given. Then renders the original and the saved
copy; the two renders must be bit-identical. Takes `mode`, `sr`, `block`, `host` and `bypass` like `render`.

### instances

Adds and removes instances of the listed plugins `cycles` times on an empty project (`play`: with the transport
running), after `warmup` cycles. The process handle count and private memory are sampled after the warm-up (with
`warmup` 0, before the first cycle) and at the end; growth above `maxHandleGrowth` or `maxPrivateGrowthMB` is FAIL.

| key | |
|---|---|
| `plugins` | required, plugin ids |
| `cycles`, `warmup`, `play`, `maxHandleGrowth`, `maxPrivateGrowthMB` | default from `limits.instances` |
| `sr`, `block`, `host` | |

## negative cases

A negative case is a scenario that must come out a certain way: the same fields as its kind (no matrix), plus

| key | |
|---|---|
| `expect` | `PASS`, `FAIL`, `SKIPPED`, `INCOMPLETE` or `REFUSED` |
| `expectDetail` | a .NET regex, case sensitive, that the outcome detail must match; one that matches the empty text (`.*`, `^`) would accept any reason and is refused |

A negative row is PASS only when both the outcome and the detail match. Outcomes alone can come about without the
case having run (a lock that was busy, a render that never started); a matching outcome with another detail is
INCOMPLETE ("not verified"), and an observed INCOMPLETE is INCOMPLETE too, never FAIL. Examples: a layout that must
differ from another one; a latency that is not reported must show as a lag; two states that must not be swapped.

```json
{ "id": "neg-bus-is-not-chain", "kind": "render", "layout": "bus", "compare": { "layout": "chain" },
  "expect": "FAIL", "expectDetail": "^identical=no lag=0 " },
{ "id": "neg-pdc-unreported", "kind": "render", "layout": "pdc-off",
  "expect": "FAIL", "expectDetail": "^identical=no lag=16 " },
{ "id": "neg-states-swapped", "kind": "render", "layout": "states", "maxDiffDb": 0,
  "stems": [ { "track": "Quiet", "rmsChangeDb": { "L": [5.9, 6.1] } } ],
  "expect": "FAIL", "expectDetail": "\\| stem Quiet: .*; failed: rms change L -6\\.02 dB outside" }
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
