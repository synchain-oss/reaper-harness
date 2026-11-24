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
- `expectPdc`: the latency in samples the plugin must report (default 0), checked by `device`, `savereopen` and
  `transport`; or `"report"`, for a plugin whose latency depends on its settings: what it reports is recorded, not
  judged (`facts.pdc` of those rows, see [RESULTS.md](RESULTS.md#a-row-scenarios)), and a reading that is not there
  makes the row INCOMPLETE (no evidence). The `pdc` of a kept render is the one the learn launch read (48000 Hz, block
  512) for that setting of the plugin; a kept render with a `"report"` plugin whose latency was not read there is
  INCOMPLETE, its files kept all the same.
- `params`: parameter values every FX of this plugin gets (an FX's own `params` go on top), see [layouts](#layouts).
- `states`: named plugin states, see [states](#states). VST3 plugins only.
- `report`: counts the plugin writes about itself to a small file, see [reports](#reports).
- `probe`: environment variables of a test build whose values are paths the harness makes for one render: a copy of a
  file for the plugin to read, or a new directory for it to write into, whose files are collected. See
  [probes](#probes). VST3 plugins only.

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
line aside). A state used with `params` on top (its own or the plugin's) is learned once more on a track of its
own without them, since only a state with nothing set on top can be compared so. `device` and `savereopen` save
the project they opened again and compare every state FX's block with the block it was given. A plugin that
ignores or rewrites a state fails there, naming the track and the FX.

A plugin can keep in its state what it sees of other instances, for example a bus plugin that labels its inputs by
the names of their tracks. It then saves its block back changed whenever those tracks are named otherwise, although
it holds the state it was given. So in the learn project the track of a state taken from a template gets the name of
that template track (the `track` field); a state file, a name an earlier variant already has (in any case), a name
with a double quote and a name like `learn-<n>` get `learn-<n>`, as every variant without a state does. For the same
reason, a layout that uses such states should name its tracks as the template does: `device` and `savereopen`
compare with the block as it was given.

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
| `learnTimeoutSec` | 120 | one learn launch (each batch, see `learnBatchSize`) |
| `learnBatchSize` | 32 | plugin settings learned per launch, 1 … 256; the settings of every plugin as configured all go into the first launch, which can then hold more |
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
| `file` | | a WAV file the track plays instead of the test signal, relative to the configuration file; only on a `source` track and not together with `signal` (see [source files](#source-files)) |
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
block for every distinct state and set of parameters is learned once per round, in launches of at most
`limits.learnBatchSize` of them (see [SAFETY.md](SAFETY.md#learning-the-plugin-blocks)); a plugin block is never
written by hand. One setting (plugin, state and values) has one display text: asking two different texts of it,
anywhere in the configuration, is a usage error; a text given once is checked wherever that setting is used.

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

### source files

`"file": "audio/voice.wav"` on a `source` track plays that file instead of the test signal. The path follows the
rules of extension paths: relative to the configuration file and inside its directory, links and junctions resolved.

Before REAPER starts, every file a picked scenario uses (in its layout or in the layout it compares with) is checked
once: its header is read (not its samples) and its SHA-256 taken. A usage error (exit 64) that lists every problem at
once, and REAPER is never started, when

- the file is not there, cannot be read, is not a WAV file, or its path leaves the directory of the configuration file;
- it is not pcm16, pcm24 or float32 (what a 32-bit float render carries exactly; pcm32 and float64 are refused);
- it has other than 1 or 2 channels, holds no samples, or is longer than 600 s;
- a scenario using it runs at another `sr` (nothing is resampled; a matrix is checked per expanded scenario), or
  renders `mono` while the file has two channels (nothing is mixed down).

Scenarios of extension kinds have no `sr` the harness knows of, so before the start they are not checked against the
rate; when one of them renders a file at another rate than the render, or with more channels, `NewRun` refuses
([EXTENDING.md](EXTENDING.md)) and the row is INCOMPLETE: nothing is resampled or mixed down for them either. Files
that only scenarios left out by `-Only` use are not read at all.

Each round copies every file into its work directory once, as `_source-<first 12 hex digits of its SHA-256>.wav`, and
checks the copy's SHA-256 and its header (format, channels, rate, frames) against those taken before the start: header
and hash were two reads of the file, and a file written over in between would pair the facts of one content with the
hash of another. REAPER only ever sees the copy (it writes peak files next to a source, never into the directory of
the configuration file). When either differs, or the copy cannot be read back (a scanner holding it right after it was
written), every scenario that uses the file is INCOMPLETE (`source file <path> changed since it was checked`, `source
file <path> could not be read back: ...`) and the rest of the round goes on. Two names of the same content share one
copy. The name that made it deletes it when its own check fails, and another name of that content then makes a copy of
its own; a later name whose own check fails (its header, or a read) leaves the copy to the names that checked it. When
the bytes of a shared copy are not the ones hashed any more, the copy is deleted and every name that plays it is
INCOMPLETE: `the copy of source file <path> changed after it was checked`; a later name of that content makes a copy of
its own. A copy is never read-only, whatever the file is. The copies are work files: removed after a green round
unless `-KeepWork` is given.

The item of a file track starts at 0 and is as long as the file: frames / rate, written with every digit and never
short of the last frame (when frames / rate times the rate falls short of the frames in floating point, the next
larger number is written). The items of the other source tracks keep the length of the test signal
(`signal.seconds`); a project renders as long as its longest item. A file is played as it is: the shift and the volume
change of the built-in negative cases apply to their own internal layout only. With a [tail](#tails) every item is
longer by the tail and plays its source once.

`render`, `device` and `savereopen` play the file wherever they would play the test signal, the dry reference
included. `transport` places no items (what reaches the tested track comes through its input): a file in its layout is
checked and listed like any other, and not played. `instances` has no layout.

A file of one channel on a track of a two-channel render comes out on both channels, equal to each other and to the
file: measured on REAPER 7.82 (offline render, 48 kHz, a track with no FX at pan centre and volume 1, REAPER's default
project settings), the left and the right channel were sample-identical to each other and to the pcm24 samples of the
file, 0.00 dB from it, with no pan-law attenuation; with `mono: true` the one-channel render was identical to the file
too ([validation record](validation/2026-11-19-file-sources.md)). Other pan positions were not measured.

The result lists each file with its full SHA-256 ([RESULTS.md](RESULTS.md#top-level)).

## JSFX

The tool ships one JSFX for configurations in `jsfx/`, written for it (MIT); the two others there are tools of the
`transport` kind and cannot be configured as plugins:

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
compensated sum): give such a scenario a `maxDiffDb`. These renders used the test signal, which holds no exact zero
sample. With a [source file](#source-files) that holds digital silence, the active JSFX left values of at most 1.5e-16
(about -316 dBFS) where the file is exactly 0, and nothing elsewhere; bypassed, it rendered bit-identical
([validation record](validation/2026-11-19-file-sources.md)).

## scenarios

Every scenario has `id` and `kind`. The built-in kinds are `render`, `device`, `savereopen`, `instances` and
`transport`; extensions can add more. `sr` (default 48000; 8000 … 384000), `block` (default 512; 16 … 8192, so 32 and
2048 are fine) and `mode` (default `offline`) set the dummy audio device and the render speed: `offline` renders at
full speed; `1x` is REAPER's 1x offline render, at real-time speed but still an offline render; `online` is an online
render, in real time. Whether a plugin is told that it runs offline depends on REAPER's preference to inform plugins
of the offline rendering state, which the tool sets per scenario (`informOfflineState`, see [host](#host)).

### host

`"host": { "anticipativeFx": true | false }` turns REAPER's anticipative FX processing on or off for the scenario
(default on, as REAPER ships). Only the private configuration directory's `reaper.ini` is written: bit 0 (value 1)
of `workrender` in `[REAPER]`; the other bits are kept. Without the key REAPER uses 17 (bit 0 set).

Measured on REAPER 7.82 (x64, Dummy Audio 48 kHz / 512 samples, the private configuration directory): with
`workrender=17` a JSFX that reports its playback position ran 202.7 … 224.0 ms ahead of the play cursor (median
213.3 ms); with `workrender=16` it ran 10.7 … 42.7 ms ahead (median 21.3 ms). The ini has no key while the value
is the default. `device` reads `workrender` back from the running REAPER and checks bit 0.

`"host": { "runFxWhenStopped": true | false }` turns REAPER's "Run FX when stopped" on or off (default on, as REAPER
ships): bit 0 of `runallonstop` in `[REAPER]` of the private `reaper.ini`, the other bits kept; without the key
REAPER uses 1. Off, the FX of a track that is not armed and has no media are not run while the transport is stopped,
nor, measured on REAPER 7.82, while it plays (see `transport`). `device` and `transport` read it back and check bit 0.

`"host": { "informOfflineState": true | false }` turns REAPER's "Inform plug-ins of offline rendering state" (in the
VST compatibility part of its VST preferences) on or off (default on, as REAPER ships): bit 8 (value 256) of
`vstfullstate` in `[REAPER]` of the private `reaper.ini`, the other bits kept. `device`, `transport` and a
[render judged by a report](#reports) read it back and check bit 8; a render without a report has no driver to read it.

Measured on REAPER 7.82 (x64, Dummy Audio 48 kHz / 512 samples, the private configuration directory, a plugin that
counts the blocks it gets, and whether the host called them non-realtime, in a report). Which key: the label is in
the REAPER binary among the VST compatibility options, and of the 16 low bits of `vstfullstate`, each flipped on its
own for one render, only clearing bit 8 changed anything the plugin saw: the render's 301 blocks came as realtime
blocks and no extra prepare came with them (with it set they come as non-realtime blocks, with a prepare before and
after). Bits 14 and 15 did not stick: REAPER read them back set. Without the key REAPER reads 49989, which has bit 8
on, so on is the default. What the plugin is told, with a 3 s render:

| preference | `offline` render | `1x` render | `online` render | transport playing or stopped |
|---|---|---|---|---|
| on | non-realtime (301 blocks) | non-realtime (300 blocks) | realtime (302 blocks) | realtime |
| off | realtime (301 blocks) | realtime (300 blocks) | realtime (301 blocks) | realtime |

Every one of these renders was bit-identical to the same render without the plugin, whose audio passes through.

### matrix

`"matrix": { "mode": [...], "sr": [...], "block": [...] }` expands one scenario into the cross product. The
expanded ids are `<id>-<mode>-<sr>-<block>` for the axes present, in that order (for example `chain-offline-48000`).
An axis cannot also be given directly. Negative cases cannot have a matrix. `device` and `transport` scenarios render
nothing, so their matrix has no `mode` axis (a usage error), only `sr` and `block`.

### render

Renders the layout and compares the render with a reference.

| key | meaning |
|---|---|
| `layout` | required |
| `mode`, `sr`, `block`, `host` | see above |
| `mono` | render one channel instead of two |
| `bypass` | `true` (every FX) or a list of plugin ids rendered bypassed |
| `report` | what the plugins report about this render, see [reports](#reports) |
| `probe` | `true` or overrides: the layout's plugin gets its [probe variables](#probes) for this render, and what it writes there is collected |
| `compare` | `"dry"` (default): the same layout without any FX; `"repeat"`: the same render twice; `"none"`: no reference, the render is judged on its own; or a variant `{ "layout", "block", "mode", "bypass" }`, where the fields given replace the scenario's own |
| `maxDiffDb` | allowed residual in dBFS at the expected lag, -400 … 24 (a mix of several tracks can differ by more than full scale); `"report"`: the residual is measured and written down, never judged ([reported residuals](#reported-residuals)); absent means the renders must be bit-identical |
| `lag` | the expected lag in samples, test render later than the reference is positive; default 0 |
| `peakMaxDb` | the test render must not peak above this |
| `notSilent` | the test render must peak above -120 dBFS |
| `rmsDb` | channel → `[min, max]`: the RMS of that channel of the test render, in dBFS |
| `energyRatioDb` | `"A/B"` → `[min, max]`: RMS of channel A minus RMS of channel B of the test render, in dB |
| `rmsChangeDb` | channel → `[min, max]`: RMS of the test render minus RMS of the reference, per channel, in dB |
| `stems` | tracks rendered as files of their own, see [stems](#stems) |
| `keep` | `true`: keep the render and its stems under `renders/` of the result directory, see [keep](#keep) |
| `keepFirst` | `true`: with `keep`, also keep the first render of a repeat whose residual is reported when the two are bit-identical; only allowed there, see [keep](#keep) |
| `tailSeconds` | render this many seconds past the end of the longest source, 0 … 60 (default 0), see [tails](#tails) |
| `variants` | the scenario once per variant, each with some plugins set otherwise, see [variants](#variants) |

The pass criteria are fields of the scenario itself, not a nested object: in negative cases `expect` names the
expected outcome. Both renders must be readable, comparable (same rate and channel count) and free of NaN and Inf
in every case. A render with no frames is INCOMPLETE before any of this, so a negative case expecting FAIL does not
pass on one. The verdict line always starts with the same facts, in this order:
`identical= lag= maxdiff= head= frames= channels= rate= format= nonfinite= peak=` (with `compare: "none"`:
`frames= channels= rate= format= nonfinite= peak=`), followed by `rms=` per channel when a channel criterion is
given (reference / test), `nan= inf=` when there are any, and `; failed: <reasons>` on a FAIL. Negative cases match
that line with a regex.

`maxDiffDb` (a number or `"report"`), `lag` and `rmsChangeDb` need a reference; with `compare: "none"` they are usage
errors.

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
- A stem takes the scenario's `maxDiffDb` (`"report"` too), `lag`, `peakMaxDb` and `notSilent` unless it gives its
  own: a stem may report its residual while the master is judged by a number, or the other way round, and a stem with
  `compare: "none"` that takes `"report"` is judged on its own. The channel
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

### reported residuals

`"maxDiffDb": "report"` (only this word, in lower case) measures the residual of a render against its reference and
writes it down without judging it: the two may differ by any amount and at any best lag, and the row still passes.
Everything else is judged as before: both renders readable, comparable and free of NaN and Inf, a render with frames,
`peakMaxDb`, `notSilent` and the channel criteria. Two rules are added: the two renders must have the same number of
frames (a FAIL otherwise: both come from the same project, so one of them is broken), and a residual that could not be
measured (no overlapping finite samples) is INCOMPLETE. The verdict line goes on after its fixed facts with
`; reported: bit-identical`, or with

`; reported: not bit-identical, residual <x> dBFS (rms <y> dB against the reference) measured at lag <lag> (expected), best lag <b>, largest at <s> s, first difference at frame <n>`

leaving out what could not be measured. The residual is measured at the expected lag (`lag`, 0 unless given). The best
lag is the least-squares best lag within ±`limits.lagSearch`, only a diagnostic; it is also what `lag=` at the start of
the line shows. The row's `facts.comparison` has the numbers, for the master and every stem compared with the
reference ([RESULTS.md](RESULTS.md#a-row-scenarios)); with [keep](#keep) the manifest line has them too.

It works with every reference: `compare: "repeat"` tells whether the plugin renders the same audio twice
([USAGE.md](USAGE.md#is-the-plugin-deterministic)); `"dry"` or a compare variant tells how far the plugin takes the
signal from the dry one or from the other variant, without a made-up limit. A repeat that reports cannot judge the
[reports](#reports) of its plugins as well (a usage error): its first render would be made by `-renderproject` and the
second by the driver's render step, and a difference between the two ways of rendering would read as a plugin that is
not deterministic. A negative case may report its residual; it then cannot expect a FAIL for "not bit-identical",
which is not judged.

### tails

`"tailSeconds": <0 ... 60>` on a `render` scenario renders that many seconds past the end of its longest source, so
that a reverb or a delay is heard out in the file. The seconds become frames at the scenario's `sr` (half a frame
rounds up), per leg of a [matrix](#matrix); a tail above 0 that is less than one frame is a usage error. Every item of
the project is then longer by the tail, to the frame (the frames of its file, or of the test signal, plus the tail),
and plays its source once (`LOOP 0`, whatever REAPER's preference to loop sources says), so the rest of the item is
silence. The project, and so the render, is as long as the longest source plus the tail. The master and every stem
must have exactly that many frames, or the row is INCOMPLETE (`the render <file> has <n> frames, not <m>: the tail was
not rendered as asked`). The references (the dry render, the first render of a repeat, the compare variant) get the
same tail; a dry reference with a tail is a render of its own, next to the one without.

Latency a plugin reports is compensated as without a tail, and the tail holds what the plugin puts out after the source
ends. A latency it does not report moves the end of the source into the tail, and a tail shorter than that latency
loses the rest. The row's `facts.tail` gives the tail, the length the files were checked to have and the peak of the
last 100 ms of the master and of each stem (`endPeakDb`: how far the tail decayed; only recorded, never judged). Only
`render` scenarios and their negative cases have a tail; on other kinds `tailSeconds` is an unknown key.

Measured on REAPER 7.82 (48 kHz, a 180 s stereo file, a tail of 3 s, the JSFX of the tool delaying by 8192 samples
without reporting it): the master and the stem had exactly 8784000 frames, the end of the file (its last impulse, at its
last frame) lay 8192 frames into the tail, and what followed was silence; with the effect bypassed the whole tail was
exactly 0, so the items played their source once. The same held at the blocks 512, 2048 and 333 (none divides the
length), for a mono file on the two-channel render, with the delay reported as latency (the tail then held nothing of the
source), and in the render modes `offline`, `1x` and `online`, whose files held the same samples as the offline one. The
JSFX leaves values of at most 1.5e-16 where its source is exactly 0, so its `endPeakDb` reads -316.478174 and not null
([validation record](validation/2026-11-22-repeat-report-tail.md)).

### variants

`"variants": [ ... ]` renders one `render` scenario once per variant: the same layout, with some plugins set
otherwise or bypassed. For example, to render a file through an effect at several settings and keep each render, to
be listened to or measured outside the tool:

```json
"plugins": { "eq": { "bundle": "Example EQ.vst3", "states": { "air": { "stateFile": "states/air.RfxChain" } } } },
"layouts": { "eq-on-file": { "tracks": [ { "name": "Voice", "source": true, "file": "sources/voice.wav", "fx": [ { "plugin": "eq" } ] } ] } },
"scenarios": [
  { "id": "eq-gain", "kind": "render", "layout": "eq-on-file", "compare": "none", "keep": true,
    "variants": [
      { "id": "dry", "bypass": true },
      { "id": "as-written" },
      { "id": "g025", "fx": { "eq": { "params": { "Gain 1": 0.25 } } } },
      { "id": "g075", "fx": { "eq": { "params": { "Gain 1": { "normalized": 0.75, "display": "6.0" } } } } },
      { "id": "air", "fx": { "eq": { "state": "air", "params": { "Gain 1": 0.5 } } } }
    ] }
]
```

`eq`, `Example EQ.vst3`, `air` and `Gain 1` stand for a plugin of yours, its state and a parameter by the name REAPER
shows. This gives the scenarios `eq-gain-dry`, `eq-gain-as-written`, `eq-gain-g025`, `eq-gain-g075` and `eq-gain-air`,
and five plugin settings to learn: `eq` as configured (the dry and the as-written variant use it), `Gain 1` at 0.25,
at 0.75, the state `air` alone (it proves the state loads, see [states](#states)) and `air` with `Gain 1` at 0.5. With
the default `learnBatchSize` that is the one row `learn`; with `learnBatchSize` 2 it is `learn.1` (`eq` as configured,
`Gain 1` at 0.25), `learn.2` (0.75) and `learn.3` (both of `air`).

| key | |
|---|---|
| `id` | required; `[a-z0-9][a-z0-9-]{0,39}`, unique within the scenario |
| `fx` | plugin id → `{ "state": "<name>", "params": { ... } }` with at least one of the two (`params` as in [layouts](#layouts)); the plugin must be used in the scenario's layout |
| `bypass` | `true` (every FX) or a list of plugin ids of the layout, rendered bypassed |
| `probe` | overrides of the scenario's [probe variables](#probes), on top of the scenario's; the scenario needs `probe` |

- Each variant is a scenario of its own: `<id>-<variant id>`, after a [matrix](#matrix)
  `<id>-<matrix suffix>-<variant id>` (the legs of the matrix outside, the variants inside, in the order written).
  The ids after expansion are at most 80 characters and unique. `-Only` matches them: `^eq-gain-` picks every
  variant of the scenario, `-dry$` the dry ones, and only what the picked ones need is learned. The row of a variant
  names it and the scenario as written (`facts.variant`, `facts.baseScenario`).
- A variant changes every FX of a plugin it names, on every track of the layout. Its parameters go on top of that
  FX's, which go on top of the plugin's (`plugins.<id>.params` < the FX's `params` < the variant's); its `state`
  replaces the FX's. Nothing else of the layout changes: tracks, files, signals, sends, and the `bypass` of an FX. The
  `bypass` of a variant adds to the scenario's (`true` wins); a variant cannot un-bypass an FX or take a state away.
  A variant with neither (`as-written` above) is the layout as written.
- A scenario with variants must give `compare` (a usage error otherwise). `"none"` renders each variant to be judged
  on its own: an active effect is never identical to the dry render. A compare variant without a `layout`
  (`{ "block": 256 }`) renders the same variant again with another block, mode or bypass, and without a `bypass` of
  its own it takes the variant's; with a `layout` it compares with that layout as written.
- Each setting is learned once, however many variants use it. At most 1000 variants per scenario. Only `render`
  scenarios have variants: on another kind and in a negative case `variants` is an unknown key.

The dry variant `{ "id": "dry", "bypass": true }` is rendered and kept like the others, every FX in its project
bypassed (still loaded, so the chain and its latency are those of the other variants); its manifest line says
`variant: "dry"` and `bypass: true` on every FX. REAPER renders to float32: a kept dry variant of a pcm24 source holds
the values of the source (x / 2^23), not its bytes, so compare the decoded samples, not the files. REAPER also writes the
time of the render into the file, so even two renders of identical audio differ in bytes and in the `sha256` the
manifest gives. The tool's own comparer only reports `identical=yes` for two files of one format and compares values
only with `maxDiffDb`; it never compares a source file with a render.

With the FX bypassed the render stayed identical in value to the source file. Measured on REAPER 7.82 (offline render, 48 kHz,
a file source with the FX alone on its track): the kept dry variant had a largest absolute difference of 0 against the
source, with no sample differing, for a float32 stereo file and for a pcm24 mono file on a two-channel render, with
the JSFX of the tool, Airwindows Consolidated and ZL Equalizer 2 (both VST3) in the chain. For the float32 file the
data of the render is the source's data byte for byte. Not bypassed, the same plugins are another matter: the default
state of Airwindows Consolidated changed every sample, and the JSFX at delay 0 left values of at most 1.5e-16 where the
file is exactly 0 ([validation record](validation/2026-11-19-param-variants.md)). Only these three plugins were tried:
a plugin that has latency or a tail when bypassed was not measured.

### keep

`"keep": true` on a `render` scenario (on no other kind, and not in negative cases: usage errors) keeps what it
rendered. After its verdict, whatever the verdict, its render moves out of the work directory to
`<result directory>/renders/<run stamp>/run<round>/<id>.wav` and each stem to `<id>-stem-<track>.wav` next to it; the
references (dry, compare variant, and the first render of a repeat except as below) are not kept. A scenario of a
matrix or with [variants](#variants) keeps each expanded scenario under its own id (`eq-gain-g025.wav`). The run stamp
is the one of the work directories (`yyyyMMdd-HHmmss`), shared by all rounds of a run. Kept renders take room: 180 s
of stereo float32 at 48 kHz are about 69 MB, so 200 kept variants of such a file are about 14 GB a round, and a
[tail](#tails) of 60 s adds about 23 MB to each. Until a round ends, its work directory holds every render of the
round as well: about the scenarios × their renders (two for a repeat or a compare variant, one for `dry` and `none`,
plus one dry reference per layout and setting) × the size of one render. Nothing is deleted earlier than that: a green
round removes them.

Each kept scenario appends one line to `renders/<run stamp>/manifest.jsonl` as soon as it is done (the format is in
[RESULTS.md](RESULTS.md#kept-renders)): what the files are, how they were rendered, what each source track played,
and every FX with what REAPER read back. A render that failed (no file) still gets its line, with nothing moved.

A repeat whose residual is [reported](#reported-residuals) (`compare: "repeat"`, `maxDiffDb: "report"` on the scenario
or on a stem compared with the reference) keeps its first render too when the master or a stem compared with the
reference is not bit-identical: `<id>-first.wav`, and `<id>-first-stem-<track>.wav` for those stems, next to the
second. `keepFirst: true` keeps it also when the two are identical. The key itself, `false` too, needs `keep`,
`compare: "repeat"` and a reported residual: anywhere else it is a usage error, as `lag` is without a reference.
Otherwise the first render is a work file like the other references. The line describes it in `comparison.first` (null
when it is not to be kept; a file of it that could not be moved has `path` null, as `output` does). The whole-file
hashes of two renders differ even when their audio is identical, because REAPER writes the time of the render into the
file; `comparison.master.identical` says whether the samples are. A record of whether a plugin is deterministic needs
`keep` to be in the manifest; without it the row's `facts.comparison` has the same numbers. A repeat whose two renders
differ keeps two files.

With [probe](#probes) the line has `probe`: the variables and the files collected, in `run<round>/<id>.out/`. The
files are collected with or without `keep`; without it there is no line, the row lists them (`facts.probe`) and the WAV
stays a work file.

A kept file is never overwritten: when its place is taken (by another scenario whose id and stem name give the same
file name, or by a run started in the same second, which finds the manifest there and keeps nothing), the file stays
in the work directory and the scenario is INCOMPLETE with the reason (a FAIL stays FAIL). The same holds when the
place would not be under the result directory, links and junctions resolved, or when its real path cannot be read.
`renders/<run stamp>/` itself is checked that way before anything is made in it: when it fails, nothing of the run is
kept and no manifest is written. A kept file that cannot be read afterwards (a scanner holding it) stays kept, its line
is written with what could be read, and the scenario is INCOMPLETE. A render with NaN or Inf samples keeps its FAIL
and is kept all the same, its line counting them.

### device

Opens the layout's project through the Lua driver and checks that the dummy device runs at `block` and `sr`, that
anticipative FX processing reads back as `host.anticipativeFx` and Run FX when stopped as `host.runFxWhenStopped`,
and that every FX is loaded, not offline, reports
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

### transport

Takes one track of the layout through a list of transport, arm and monitoring states and checks, in each, whether
REAPER runs the track's FX chain and what that chain gets. Meant for plugins whose behaviour depends on the state of
the host, a vocal recording plugin that monitors its input while the track is armed for example. Nothing is ever
recorded ([SAFETY.md](SAFETY.md#nothing-is-recorded)).

| key | |
|---|---|
| `layout` | required |
| `track` | the tested track, by name; may be left out when the layout has one track |
| `states` | required, 1 … 64 states, taken in order |
| `feed` | `{ "wav": "<file>", "channels": "left" \| "same" \| "different" }`: what the input of the tested track gets (below); without it the input gets nothing |
| `settleSamples` | device samples to let pass after each change of state before its window opens (0 … 115200000); default REAPER's "run FX after stopping" time (`runafterstop`, 4000 ms unless set) plus half a second; a shorter time lets the chain's run-on after the previous state into the window |
| `sr`, `block`, `host`, `matrix` | as `device`; the matrix has `sr` and `block` only |

A state:

| key | |
|---|---|
| `name` | required, unique in the scenario, `[a-z0-9][a-z0-9-]*` |
| `transport` | required: `stop`, `play` or `pause`. Recording is not a state the tool can be asked for |
| `arm` | required, `true` / `false`: the track's record arm (recording is disabled on the track, see below) |
| `monitor` | required: input monitoring `off`, `on` or `auto` (REAPER's tape style: only while not playing) |
| `samples` | the observation window in device samples, 64 … 115200000 and at least 4 blocks; default 2 seconds |
| `windows` | `{ "plugin": "<id>", "count": 1 … 1000, "holdMs": 0 … 60000, "maxBlockDiff": 0 … 1000000 }`: open and close that plugin's floating window `count` times in the window, each held open for `holdMs` when it is given (below) |
| `expect` | what must hold in the window; a state without it and without `windows` is only recorded. At least one state of a scenario has one of them |

`expect`:

| key | |
|---|---|
| `called` | `true`: the chain is run in at least one block of the window; `false`: in none |
| `input` | `silent`: no block the chain gets carries signal; `signal`: every one does |
| `channels` | `left`: every block with signal has it on the left and none on the right; `same`: left and right are equal in every block with signal; `different`: both sides carry signal and differ in every block with signal |
| `monitoring` | REAPER reports input monitoring in effect on the track (`B_RECMON_IN_EFFECT`) at the end of the window |
| `report` | what the plugins report about the window, see [reports](#reports) |

`input` and `channels` need a chain that runs: without `called`, a chain that never ran fails them ("not called, so
it has no input"). `called: false` together with either is refused, and so is `input: "silent"` with `channels`.

The feed: `wav` is a WAV file (a path relative to the configuration file, under the same rules as extension paths)
at the scenario's sample rate, nothing is resampled, with 1 or 2 channels (2 for `different`); it plays in a loop,
without a gap however short it is. A channel it plays (the first for `left` and `same`, both for `different`) must
not have a peak of 0: with a silent feed every `input: "silent"` would pass without evidence. Only a peak of 0 is
caught: a file with just a few samples other than 0 gets through and proves little.
Without `wav` it is the configured test signal, in stereo. `channels` (default `different`) says what reaches the
input: the first channel on the left only, the first channel on both sides, or the two channels as they are. The
file is checked before REAPER starts (a usage error otherwise), copied to `Data/reaper-harness/feed.wav` of the
private configuration directory, and named in the result with the first 12 hex digits of its sha256.

How it is observed: the driver opens the project (tracks without items), reads it back like `device` (block size,
sample rate, anticipative FX, Run FX when stopped, every FX), sets the project's record path to the work directory
(when it does not read back, the step stops there with nothing armed and the row is INCOMPLETE) and adds

- `jsfx/harness-block-probe.jsfx` first in the FX chain of the tested track: it counts the blocks it is run with and
  what they carry (signal or not, on which side, left equal to right), so it sees what the first plugin gets;
- a track of its own at the end, armed, with recording disabled, no input, monitoring off and no master send, with
  another block probe: an armed track is run in every state, so it counts the device's blocks (the clock);
- `jsfx/harness-feed.jsfx` in the input FX chain of the tested track, whose input is set to none: it plays the feed,
  so what reaches the chain has come through arming and input monitoring like a hardware input would.

For each state it sets arm and monitoring, then the transport, lets `settleSamples` of the clock pass, and counts
for `samples` of the clock. Both are counted in device samples, not in wall-clock time (REAPER's main thread can
stall while the audio runs on). The tool JSFX are copied into `Effects/reaper-harness/` of the private configuration
directory like a configured JSFX, but they are tools: they cannot be configured as plugins and are not listed with
them.

The detail has one part per state, joined by ` | `:

```
stopped-armed-on: blocks=94/94 silent=0 signal=94 left=94 right=94 same=0 transport=stop monitoring=1
```

`blocks=B/C`: the chain ran in B blocks while the device ran C; `silent` and `signal`: blocks without and with
signal; `left`, `right`: blocks with signal on that side; `same`: blocks with signal whose left and right are equal;
`transport` and `monitoring` as read back at the end of the window; with `windows`, ` windows=O/C of N`: how often the
window opened and closed, and with `holdMs` then ` held=H/<holdMs>ms`: the shortest time a window was held open; with
report criteria, ` report <plugin>.<field>=<end> (+<growth>)` per judged field. A state
that fails adds `; failed: ...`. A state
whose numbers describe another state than the one asked for is INCOMPLETE (`; no evidence: ...`): the device ran
less than the window, or the transport, the arm or the monitoring mode did not read back as asked. So is an armed
state of a scenario with a feed in whose window the feed played no block: its chain would be silent for the wrong
reason. So is a state of which the driver got no clean reading (`<name>: not observed`): the tool JSFX write their
counts one at a time on the audio thread, so the driver takes them only when a generation value around them shows no
write under way, and after a bounded number of tries it reports nothing rather than half-written numbers. The row is
INCOMPLETE as well when a probe or the feed is not the tool's own copy, the probe is not first in
the chain, the record path could not be set, the feed could not open its file, the feed never ran although a state
arms the track, or not every state was observed; it is FAIL, whatever
the states say, when any file appeared in the record directory. Facts: `track`, `runFxWhenStopped`,
`runFxAfterStopMs`, `settleSamples`, `feed` (`source`, `sha256`, `channels`) and per state its settings, `status`,
`problems` and the numbers, among them `fed` and `fed_samples`: the blocks and frames the feed played in the window,
`win_open` and `win_closed` with `windows`, `win_held` with `holdMs`, and `report` with a report: per plugin and field
its `start`, `end` and `delta`.

Windows: the plugin must be on the tested track exactly once. While the state's window runs, the driver opens the
plugin's floating window (`TrackFX_Show`, 3), waits until `TrackFX_GetFloatingWindow` returns it, gives the editor ten
turns of the message loop (a web view, for one, builds itself asynchronously), closes it (`TrackFX_Show`, 2) and waits
until it is gone, `count` times; each wait gives up after 10 s of wall-clock time, and whatever happened the window is
closed once more at the end. The observation window lasts as long as this takes, and at least `samples`. FAIL: it
opened or closed fewer than `count` times, or the chain and the device ran more than `maxBlockDiff` blocks apart in the
window (default 4; not judged when the state expects `called: false`). A tolerance, because the chain's count and the
clock's are read one after the other: a difference of 1 to 2 blocks was seen on REAPER 7.82 with no window at all, and
none was added by 20 windows of a plugin with a web view editor. Opening an editor runs the plugin's own GUI code,
see [SAFETY.md](SAFETY.md#plugin-reports-and-windows).

Holding a window open: an editor that needs seconds to start (a web view, for one) has not finished in ten turns of
the message loop. With `holdMs` the driver keeps each window open for ten turns and at least `holdMs` of message-loop
time before it closes it. That is wall-clock time, but a turn counts at most 100 ms, as for reading
[reports](#reports): the editor runs on REAPER's main thread, so a second that thread stalls is no second the editor
had. A window that is gone before its time is up ends its hold there. The state's ` held=` is the shortest hold of the
windows that opened, in ms rounded to the nearest one (a hold that ran to its end never reads less than `holdMs`), and
0 when none opened. FAIL: it is less than `holdMs` (a window that closed itself, or none that opened). INCOMPLETE: the
driver reported no hold time. `count` × `holdMs` may be at most 600000, ten minutes of holding in one state; more is
refused before REAPER starts. The time the step may take grows by three times the holds. The tool judges nothing about
the editor itself: whether it started is for the state's `expect.report`, from a field the plugin reports. The report
is read after the settle time and again after the last window has closed, so a field meant to show what the editor
did must still hold its value once the editor is gone: a counter the processor keeps, not one of the editor. For a
test build with a web view editor that counts in `editorReady` how often its editor finished starting:

```json
{ "name": "editor-starts", "transport": "play", "arm": false, "monitor": "off",
  "windows": { "plugin": "rec", "count": 3, "holdMs": 5000 },
  "expect": { "report": { "rec": { "editorReady": { "delta": 3 } } } } }
```

Without `holdMs`, or with 0, every window closes after ten turns as before: the line has no ` held=` and the facts
have no `win_held`.

```json
{ "id": "monitor-states", "kind": "transport", "layout": "vocal", "feed": { "channels": "different" },
  "states": [
    { "name": "stopped-unarmed", "transport": "stop", "arm": false, "monitor": "off", "expect": { "called": true, "input": "silent" } },
    { "name": "stopped-armed-on", "transport": "stop", "arm": true, "monitor": "on", "expect": { "input": "signal", "channels": "different", "monitoring": true } },
    { "name": "playing-armed-auto", "transport": "play", "arm": true, "monitor": "auto", "expect": { "input": "silent", "monitoring": false } }
  ] }
```

Measured on REAPER 7.82 (x64, Dummy Audio 48 kHz / 512 samples, the private configuration directory, tracks without
items, 2 s windows after settling), with the feed in stereo:

| tested track | Run FX when stopped on (REAPER's default) | off |
|---|---|---|
| unarmed, stopped | run, silent | not run |
| unarmed, playing | run, silent | not run |
| unarmed, paused | not run | not run |
| armed, monitoring off, stopped or playing | run, silent | run, silent |
| armed, monitoring on, stopped, playing or paused | run, both channels intact, monitoring in effect | the same |
| armed, monitoring auto, stopped | run, both channels intact, monitoring in effect | the same |
| armed, monitoring auto, playing | run, silent, monitoring not in effect | the same |

Also measured there:

- after the project is opened, and after playing stops, an unarmed chain goes on being run for about 3.25 … 3.75 s
  even with Run FX when stopped off: REAPER's "run FX after stopping" (`runafterstop`, 4000 ms by default, no key in
  the ini while it is the default). Hence the default settle time;
- with no armed track in the project and Run FX when stopped off, nothing is run while stopped, and "monitoring in
  effect" is not updated (it read 1 on a track that had been disarmed). Hence the clock track;
- the Dummy device has no inputs (`num_audio_in` 0): the feed in the input FX chain is the only input there is;
- the feed is run in every armed state, whatever the transport and the monitoring mode, and not on an unarmed track;
- record mode "disabled" on the tested track made no difference to any of the above against record mode "input";
- `-1000` as the position of `TrackFX_AddByName` puts the probe first in the chain; the record bit of the transport
  was never seen.

Measured on the same setup before: with the default preferences REAPER's automatic bypass of muted tracks did not
stop a JSFX on a muted track; only an FX with `force_auto_bypass` set stopped being run. Not measured: how a real
hardware input behaves. The tool has no way to set `force_auto_bypass`.

### reports

A plugin can count things only it knows (the blocks it got and whether the host called them non-realtime, how often
its editor opened) and write them to a small JSON file. The harness tells it where through an environment variable,
reads the file at moments it chooses and judges the numbers. It knows nothing about what they mean: a test build of the
plugin decides what to count. Audio is never in it.

```json
"plugins": {
  "rec": { "bundle": "Recorder Test Build.vst3",
           "report": { "env": "RECORDER_REPORT_JSON", "fields": ["blocksOffline", "blocksRealtime", "editorOpens"], "pid": "pid", "periodMs": 250 } }
}
```

| key | |
|---|---|
| `env` | required: the variable that gets the file's path, `[A-Z][A-Z0-9_]{2,63}`. A name Windows, a runtime, REAPER or what it loads, a plugin format or WebView2 reads is refused ([SAFETY.md](SAFETY.md#plugin-reports-and-windows); a [probe variable](#probes) has a longer list); so is one that another plugin of the configuration uses |
| `fields` | required, 1 … 32 distinct names: the numeric fields to take from the file. Nothing else in it is read or recorded |
| `pid` | the field that holds the id of the process that wrote the file: it must be the REAPER of this step, or the file is no evidence |
| `periodMs` | how often the plugin writes while something changes, 10 … 10000, default 500 |

What the plugin has to do: read the variable; when it is set, write a flat JSON object to that path at most every
`periodMs` while the counts change, from a thread that runs while the host's message loop runs. It should replace the
file atomically: write a temporary file in the same directory and rename it over the target (`MoveFileEx` with
`MOVEFILE_REPLACE_EXISTING`), so that no reader sees half a file. A turn in which a file that was there is missing is
skipped as a replacement in progress; a file that is not there at all is no evidence. The directory exists.
Counts are its own business; if they are totals of the whole process, the plugin must be alone in the project, and the
harness requires that of every judged plugin: used exactly once in the layout.

The variable is set for the REAPER of one driver step, and the path is a new file of that step in the work directory.
A reading takes the file as it is at a moment, then waits, turn by turn of REAPER's message loop, until its content
changes (a write after that moment) or stays the same for four periods (a change before that moment would have been
written by then). A turn counts at most 100 ms, because a stalled main thread stalls the plugin's timer as well. 30 s of
wall-clock time is only the limit. The file has to be at most 64 KiB.

Criteria: `expect.report` of a transport state is judged between a reading right after the state's settle time and one
right after its window; `report` of a `render` between a reading before and one after the render. Both are plugin id →
field → criterion:

```json
"report": { "rec": { "blocksOffline": { "delta": { "min": 1 } }, "blocksRealtime": { "delta": 0 }, "editorOpens": { "value": 0 } } }
```

`delta`: how much the field grew between the readings; `value`: what it reads at the end. Each is a number (exactly
that) or `{ "min", "max" }` (either may be left out). Because the first reading ends at the first write after its moment and the last
one starts after the window, a count of a running chain grows by somewhat more than the window's blocks: `{ "min": 1 }`
is the way to ask for "some". A field only counts what the plugin counts: one that stays 0 because the
plugin does not implement it yet meets `delta: 0` all the same.

A criterion not met is FAIL. No evidence is INCOMPLETE: the plugin wrote no file; the file is over the size limit, is
not a JSON object, has a declared field missing or not a number, or names another process; no fresh reading could be
taken in time. Facts: every declared field of the two readings, per plugin: `start`, `end`, `delta`.

A render with `report` is not started with `-renderproject`, which leaves no moment to read before the render: the
driver opens the project, waits for "run FX after stopping" to end, takes the first reading once the file has stayed
the same for four periods, runs the action "Render project, using the most recent render settings, auto-close render
dialog", which uses the settings in the project, and takes the second. It needs `host.runFxWhenStopped: false` (refused otherwise): with it on, the plugin runs in real time before and after the
render and its counts cannot be told apart. If the file never stays the same, the row is INCOMPLETE. The audio is
compared as for any render, and the detail adds ` | report <plugin>.<field>=<end> (+<growth>)`. Measured on REAPER 7.82: the
action returns when the file is written, no deferred script runs meanwhile, and the realtime count did not move between
the readings of an `offline` or `1x` render with the preference on.

### probes

A test build of a plugin can read environment variables of its own: a file to read (a script, a setting) and a
directory to write into (what it saw, step by step). `probe` declares such variables. For the render of a scenario
that asks for them, the harness gives each a value it made itself, and afterwards it collects what the plugin wrote.
It never reads those files.

```json
"plugins": {
  "tb": { "bundle": "My Probe Test Build.vst3",
          "probe": { "EXAMPLE_PROBE_SCRIPT": { "file": "probe/take1.json" }, "EXAMPLE_PROBE_OUT": { "dir": true } } }
},
"layouts": { "take1": { "tracks": [ { "name": "Take", "source": true, "file": "sources/take1.wav", "fx": [ { "plugin": "tb" } ] } ] } },
"scenarios": [
  { "id": "take1", "kind": "render", "layout": "take1", "compare": "none", "notSilent": true, "probe": true,
    "variants": [ { "id": "as-written" },
                  { "id": "shifted", "probe": { "EXAMPLE_PROBE_SCRIPT": { "file": "probe/take1-shifted.json" } } } ] }
]
```

`tb`, `My Probe Test Build.vst3`, the three names and the files stand for a test build of yours and its own files;
[examples/plugin-probe](../examples/plugin-probe/reaper-harness.json) is a whole configuration.

| value | the variable gets |
|---|---|
| `{ "file": "<path>" }` | the full path of a copy of a file of the configuration directory, made in the work directory for each launch (`<id>.probe-<NAME><ext>`). The path is resolved like a [source file](#source-files): relative to the configuration file and inside its directory. The file is at most 1 MiB and hashed before REAPER starts; the copy must have that hash |
| `{ "dir": true, "min": <n> }` | the full path of a new, empty directory in the work directory (`<id>.out`); what the plugin writes there is collected. `min`: how many files must be collected, 0 … 32, default 1. `dir` is only ever `true`. At most one per plugin |

- Names: as `env` of a [report](#reports): `[A-Z][A-Z0-9_]{2,63}`, the same deny list and more, and unique among all
  report and probe names of the configuration. A probe variable may also not use the families that make a runtime or
  a library load a file or take options: names starting `SSL_`, `OPENSSL_`, `CURL_`, `NODE_`, `JAVA`, `JDK_`, `PERL`,
  `RUBY`, `GIT_`, `CHROME`, `MSEDGE`, `REQUESTS_`, `HTTP`, `NO_PROXY` or `ALL_PROXY`, `SSLKEYLOGFILE`, and any name
  ending in `_PROXY`. A report's `env` may: [SAFETY.md](SAFETY.md#probe-variables-and-collected-files) says why. VST3
  plugins only: a JSFX reads no environment.
- What the plugin sees: a full path, without quotes, that can hold any character the result directory does (spaces,
  non-ASCII), so read the variable as Unicode (`_wgetenv`, `GetEnvironmentVariableW`). The copy is not read-only, but a
  copy that changed during the launch makes the row INCOMPLETE (`the probe input <NAME> changed during the launch`), and
  so does one that cannot be read back afterwards (`the probe input <NAME> could not be read back: ...`).
  The directory exists, is empty, and only this launch was told its path. Its path is at most 140 characters, so that
  a name of 100 characters still fits in a path of 241 (well under Windows' 260); with a result directory deeper than
  that, the scenario is INCOMPLETE before its render starts (`the probe directory path is too long for a plugin to
  write into it`).
- `probe` on a `render` scenario: `true` (the variables as the plugin declares them) or overrides: name →
  `{ "file": ... }` or `{ "dir": true, "min": <n> }` of a declared variable of that kind (`min` left out keeps the
  plugin's). A [variant](#variants) may give overrides on top of the scenario's; the scenario needs `probe`. Another
  recording is another layout: a variant can change the script, not the recording.
- The layout uses the plugin exactly once, and has at most one `dir` variable. The scenario compares with `"none"` or
  `"dry"`: a repeat or a compare variant would load the plugin again without its variables. `probe` on another kind,
  in a negative case, on a layout without such a plugin, or naming a variable the plugin does not declare, is a usage
  error before REAPER starts; so is a file that is not there, is a directory, leaves the configuration directory or is
  over 1 MiB.
- Only the scenario's own render gets the variables: not the learn launch, a reference, a negative case, another kind
  or a scenario of the same plugin without `probe`, even when they are set in your shell. Every launch takes the
  declared report and probe names out of the environment it inherits, unless it sets them itself. A variable the
  configuration does not declare is inherited as before.
- When REAPER's evaluation licence reminder ends that launch ([SAFETY.md](SAFETY.md#dialogs)), it is started once more
  only if the directory is still empty, with the same copy, which is hashed again afterwards. If the plugin had written
  into the directory, there is no retry: the row is INCOMPLETE with `stuck on dialog license-nag (...), ended; not
  retried: the first launch wrote into <id>.out`, and what it wrote is collected.
- Collection runs after the scenario's launches have ended, whatever the verdict (a render that produced no file
  included). It looks at the top level of the directory only. A file whose name is letters, digits, `.`, `_` and `-`
  (at most 100, starting with a letter or digit, not ending with `.`, not a device name such as `CON`) and
  that is at most 4 MiB is moved to `renders/<run stamp>/run<round>/<id>.out/` of the result directory, with or without
  `keep`, up to 32 files and 16 MiB in all, in name order. A name ending in `.tmp` is moved and marked `temporary`; it
  does not count for `min`.
- A subdirectory, a link or junction (never followed), a name that is not allowed, a file over a limit, fewer than
  `min` files, a directory replaced by a link or junction (checked once, before the listing), or more than 10000
  entries make the row INCOMPLETE with the reason. What was not moved stays in `<id>.out` in the work directory, which
  a round that is not green keeps; a green round removes the emptied directories and the copies.
- The detail adds `; probe: <n> files collected, <bytes> bytes` (`1 file` when it is one; `, <t> temporary` when there are any, and
  `; not collected: <reasons>`); the row's facts have `probe` ([RESULTS.md](RESULTS.md#a-row-scenarios)), and with
  [keep](#keep) so has its manifest line.

For a probe scenario PASS says that the render passed its audio criteria and that at least `min` files were
collected. The harness never reads them: whether the plugin's own script ran correctly is for you to read in them.
`min: 0` accepts a plugin that wrote nothing at all, so use it with care. Measured on REAPER 7.82 with a test build that
writes step files and a final file ([validation record](validation/2026-11-23-plugin-probe.md)): the final file, which the
plugin writes when its instance is destroyed, was in the directory every time collection ran, at `1x` and at `online`; a
render of 180 s took about 185 s as a row; and a script the plugin rejected still gave PASS, with the rejection in the
plugin's own final file.

## negative cases

A negative case is a scenario that must come out a certain way: the same fields as its kind (no `matrix`, `keep`,
`variants` or `probe`), plus

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

These run in every round unless `-NoNegative` is given. They do not depend on your plugins. The last one runs only
when the configuration has a `transport` scenario.

| id | proves | expected |
|---|---|---|
| `neg-offset-1-sample` | the comparer sees a one-sample shift (a layout without FX) | FAIL, `^identical=no lag=1 ` |
| `neg-track-minus-6db` | the comparer sees a -6 dB track | FAIL, `^identical=no lag=0 maxdiff=-6\.0` |
| `neg-timeout` | the watchdog ends a REAPER that hangs at the time limit, the process is gone, the locks are free | INCOMPLETE, `^timed out after .*; the process has ended and the GUI locks are free$` |
| `neg-killed` | the same for the kill point | INCOMPLETE, `^killed at the deadline .*; ...$` |
| `neg-skip-marker` | a skip marker makes the whole entry point SKIPPED without starting REAPER | SKIPPED, `^launches=0; skip marker present` |
| `neg-sentinel-missing` | a configuration directory without the sentinel is refused | REFUSED, `^REFUSED: .*sentinel` |
| `neg-default-dir` | REAPER's default resource directory is refused | REFUSED, `^REFUSED: .*never touched` |
| `neg-transport-probe` | with Run FX when stopped off and the test signal fed, the chain of an unarmed track (no FX) is not run, and armed with monitoring on it gets the feed: the block probe sees both | FAIL, `^stopped-unarmed: blocks=0/… failed: not called (0 blocks while the device ran …) \| stopped-armed: … failed: signal in … blocks$` |

The three guard cases run the real entry point again inside the same process, with one thing changed.
