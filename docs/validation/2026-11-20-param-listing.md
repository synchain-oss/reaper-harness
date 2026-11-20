# Validation: parameter listing on REAPER 7.82

Notes on running the [parameter listing](../USAGE.md#listing-parameters) (`run.ps1 -List params`) on a real REAPER on
2026-11-20: what it reports for three third-party VST3 plugins, what a sweep of two parameters reads back, whether a
configuration written from the listing learns and renders at the first try with the display texts the listing gave,
whether the listing's `blockSha256` is the manifest's for the same plugin, what it costs, and which command lines are
refused before REAPER starts. What the outcomes mean is in [RESULTS.md](../RESULTS.md). It follows the
[record of parameter variants](2026-11-19-param-variants.md), whose stimulus S1 it uses.

## Setup

| | |
|---|---|
| Plugins | ZL Equalizer 2, VST3, bundle version 1.4.2, hash prefix `dc75178195be`; Airwindows Consolidated, VST3, bundle version 1.2026.320, hash prefix `c76102f6d5c3`; ZL Compressor, VST3, bundle version 0.6.1, hash prefix `da1d8aede005` |
| Third-party plugins | the three above, unpacked from their public release packages into the plugin directory given to the runs, only for this check; nothing was installed on the machine, and they say nothing about which plugins a machine has. Each bundle has one Audio Module Class |
| Host | REAPER 7.82 x64, Dummy Audio device, a private configuration directory, REAPER's default preferences |
| System | Windows 10 |
| Harness | the feature branch's commit `9252882a940b48c9c7f8a66f56e45f5228e8f10b`, which every result file names as `toolCommit`; the commit that adds these notes changes documents only |
| Runs | six calls of `run.ps1` that started REAPER (five listings and one round of scenarios, 18 REAPER starts in all), eight calls that were refused, and two calls of `doctor.ps1`; each `run.ps1` call was given the lock that other GUI tests on the same machine take next to the default GUI lock |

The stimulus is S1 of the earlier records (float32, 2 channels, 48000 Hz, 180 s, 8640000 frames), made for those checks
and not part of the repository; its SHA-256, checked before use, is
`e6a2945d5878874cff79f03e9a154cfc8eb66517d4f5a7cf3e1514f981b3dec1`.

The configuration of the listings is the minimal one of [USAGE.md](../USAGE.md#listing-parameters): one plugin, a layout
with one source track and that plugin, and one `device` scenario that does not run.

## Outcome

| Run | Exit code | Rows | Round |
|---|---|---|---|
| `-List params`, ZL Equalizer 2 (first call) | 0 | `learn`, `params`: PASS | PASS, 10.3 s, 2 starts, 1 retry |
| the same again | 0 | PASS, PASS | PASS, 6.4 s, 1 start |
| `-List params` with a sweep of two parameters at five values | 0 | PASS, PASS | PASS, 6.3 s, 1 start |
| a round from a configuration written from that listing: 6 variants, `compare: "none"`, `keep` | 0 | `learn`, 6 renders and 7 built-in negative cases: all PASS | PASS, 61.4 s, 12 starts |
| `-List params`, Airwindows Consolidated | 0 | PASS, PASS | PASS, 6.2 s, 1 start |
| `-List params`, ZL Compressor | 0 | PASS, PASS | PASS, 6.2 s, 1 start |
| eight command lines that are refused | 64 | no row | no round |

The only retry is the first launch of the first call, which REAPER's evaluation licence reminder ended and the harness
started again as designed (`license-nag` under the round's `retries`); it is why that learn row says 10.1 s. The other
five rounds had none.

## 1. ZL Equalizer 2

`-List params` on a configuration with the plugin as it is. The listing:

| | |
|---|---|
| Parameters | 614 (`nparams` read by the learn step 614, `paramCount` 614); read at 48000 Hz and block 512 (`readAt`) |
| Plugin name, class | `VST3: ZL Equalizer 2 (ZL)`, `moduleinfo` as the source of the class (`classFrom`), version 1.4.2 |
| Settable | 612 |
| Not settable | indices 610 and 611, both named `Bypass`, which `sameNameAs` 2 (the parameter of that name that learning reaches) |
| Names used more than once | 1: `Bypass`, at 2, 610 and 611 (614 parameters, 612 different names) |
| Masked, not exact, with a `problem` | 0, 0, 0; `displayUsable` for all 614 |
| REAPER's own parameters | not marked: `host` false for all, `hostBy` empty (below) |
| Values | the plugin's defaults |
| Longest name, longest display text | 20 and 13 characters |
| Result file | 245758 bytes, about 400 bytes a parameter |
| Seconds | round 10.3 s, learn row 10.1 s, 2 starts (the first call, with the retry); 6.4 s and 6.1 s with 1 start (the second) |

The names are the plugin's own: 24 bands (`Freq0` … `Freq23`) of 25 parameters each, with the band number at the end
of the name (`Filter Status0`, `Freq0`, `Gain0`, `Q0`, `Threshold (dB)0` …), ten global ones at the start (`Output Gain`,
`Auto Gain`, `Lookahead` …), then one more `Bypass` (610) and REAPER's three (611 to 613): 10 + 600 + 1 + 3 = 614. Every
`ident` was present.

### REAPER's own parameters, and which rule marked them

`ident` is REAPER's identifier of the parameter (`TrackFX_GetParamIdent`). On REAPER 7.82 it is always
`<index>:<word or number>`:

| Parameters | `ident` | Examples (ZL Equalizer 2) |
|---|---|---|
| the plugin's own | `<index>:<its VST3 parameter ID, as a decimal number>` | `14:97695928` (`Freq0`), `15:98116753` (`Gain0`), `610:1652125811` (`Bypass`; 1652125811 is 0x62797073, the four characters `byps`, the VST3 standard bypass parameter) |
| REAPER's own, the last three | `<index>:bypass`, `<index>:wet`, `<index>:delta` | `611:bypass` (`Bypass`, normalized 0, display `normal`), `612:wet` (`Wet`, 1, `100`), `613:delta` (`Delta`, 0, `normal`) |

Which rule marked REAPER's own parameters: **neither**. This commit marks a parameter `host` when its identifier starts
with a colon (`:bypass`), or, for a parameter without an identifier, when it is one of the last three and they are named
`Bypass`, `Wet` and `Delta`. The identifiers of REAPER 7.82 start with the index, not with a colon, and every parameter
had one, so no parameter was `host` and `hostBy` was empty, in all three plugins (below). The last three of each plugin
are named `Bypass`, `Wet`, `Delta` exactly and are the parameters at the indices above. As a result REAPER's `Wet` and
`Delta` read `settable: true`, and its `Bypass` is not settable only because the plugin has a parameter of that name
before it. The idents seen: the `<index>:` prefix equals the parameter's index in every parameter of all three plugins
(717 parameters), the plugins' own parameters have a number after it (611, 14 and 83 of them), and REAPER's three have the
words above.

### Sweep of two parameters

`-ListPlugin zleq -ListParamFile` with two names, `Gain0` (index 15) and `Freq0` (index 14), at the default values
`0, 0.25, 0.5, 0.75, 1`: one call, one launch (round 6.3 s, learn row 6.1 s, 1 start, no retry). Each value was set on an
instance of its own, added for that parameter with every other parameter at its default, and read back:

| `Gain0` asked | read back | display | `Freq0` asked | read back | display |
|---|---|---|---|---|---|
| 0 | 0 | `-30.00` | 0 | 0 | `10.0` |
| 0.25 | 0.25 | `-15.00` | 0.25 | 0.25 | `100.0` |
| 0.5 | 0.5 | `0.00` | 0.5 | 0.5 | `1000.0` |
| 0.75 | 0.75 | `15.00` | 0.75 | 0.75 | `12649.1` |
| 1 | 1 | `30.00` | 1 | 1 | `160000.0` |

All ten values were read back as asked; the display texts are the plugin's own (the last `Freq0` text is what it shows
at the top of its range). The `params` row said `1 plugin listed, 614 parameters, 2 swept at 5 values`, with `notFound`
empty. The listing's 614 parameters and its `blockSha256` are the same as in the plain listings: a sweep does not change
what the listing of the defaults holds.

## 2. A configuration written from the listing

The configuration was written by a script from the result file of the sweep: the plugin id, the parameter name
`Gain0` and, for each of the five values, `normalized` (the value read back) and `display` (the sweep's text) were
copied, none typed. One `render` scenario `gain` on a layout with S1 as a file source and the plugin, `compare: "none"`,
`keep: true`, `limits.renderTimeoutSec` 300, with 6 variants: `as-written` (nothing set) and `g000`, `g025`, `g050`, `g075`
and `g100`, each setting `Gain0` to one of the five values with its display text. `doctor.ps1` said ready.

| Row | Status | Seconds | Detail |
|---|---|---|---|
| `learn` | PASS | 6.1 | 6 plugin variants learned in 1 launch, every tested binary loaded from the private copy (module list and `fx_ident`) |
| `gain-as-written`, `gain-g000`, `gain-g025`, `gain-g050`, `gain-g075` | PASS | 4.8 each | `frames=8640000 channels=2 rate=48000 format=float32 nonfinite=0 peak=-6.02` |
| `gain-g100` | PASS | 4.7 | the same |
| the 7 built-in negative cases | PASS | 0 to 8.7 | each came out as expected |

Learning passed at the first try, with no retry and no FAIL row; none of the six learned settings was refused for its
display text, so the 5 texts the listing gave are what REAPER shows when the parameter is set in a learn launch of its
own. The round took 61.4 s with 12 REAPER starts: 1 learn, 6 renders and the other 5 for the built-in negative cases.

The manifest (6 lines) agrees with the listing: for each of the five variants `params` has one entry `Gain0` with
`normalized` as asked, `readNormalized` the same to 9 digits (`0.000000000`, `0.250000000`, `0.500000000`,
`0.750000000`, `1.000000000`), `display` as asked and `readDisplay` equal to it; the five `readDisplay` texts equal the
sweep's texts of the same values (`-30.00`, `-15.00`, `0.00`, `15.00`, `30.00`). The line of `as-written` has no
parameters. All six lines have `pdc` 0, `bypass` false, the plugin name, the hash prefix `dc75178195be` and
`pdcReadAt` 48000 and 512.

What these renders are: the six kept files have the same samples. Each is 69120692 bytes with a data chunk of
69120000 bytes whose hash prefix is `3f49cedcd8b3`, the data chunk of S1 itself, and a peak of -6.02 dBFS: band 1 of the
plugin is off in its default state (`Filter Status0` reads `Off`), so changing its gain changes no sample. The listing
and the display texts are right, and a render that is to hear `Gain0` must also set the band on.

## 3. The listing's block hash against the manifest's

| | `blockSha256` |
|---|---|
| the listing of ZL Equalizer 2, in each of the three calls | `b42aaee854f28483bdd8c123c3fb00bad044a6995cf2497f6f15833cccd3a9fa` |
| the manifest line `gain-as-written` (the FX has no `params` and no `state`) | the same 64 hex digits |

So for an FX with no parameters and no state the listing's `blockSha256` equals the manifest's, and ZL Equalizer 2
saved the same state in all four launches that wrote it (three listings and the learn launch of the round of section 2).
Of the five variants that set `Gain0`, `g050` asked for 0.5, the default: its block hash equals that of `as-written`
(prefix `b42aaee854f2`), while those of `g000`, `g025`, `g075` and `g100` differ from it and from each other
(`0a759ceca365`, `de6678429f1e`, `cbd94fc563a6`, `38bb3ea81a72`). A plugin that stores a time or a random id in its state would not have the same hash twice; this one
does, and that was only looked at for this plugin (the other two were listed once).

## 4. Airwindows Consolidated and ZL Compressor

`-List params` only, each on its own configuration, with the same layout and `device` scenario.

| | Airwindows Consolidated | ZL Compressor |
|---|---|---|
| Parameters (`nparams` = `paramCount`) | 17 | 86 |
| Settable | 12 | 84 |
| Names used more than once | 2: `-` (indices 5 to 9, five times) and `Bypass` (10 and 14) | 2: `Wet` (13 and 84) and `Bypass` (82 and 83) |
| Not settable | 6 to 9 and 14 | 83 and 84 |
| Masked, not exact, with a `problem` | 0, 0, 0 | 0, 0, 0 |
| REAPER's own (`host`), `hostBy` | none, empty | none, empty |
| `ident` of REAPER's last three | `14:bypass`, `15:wet`, `16:delta` | `83:bypass`, `84:wet`, `85:delta` |
| The plugin's own idents | `<index>:<number>`, 14 of them | `<index>:<number>`, 83 of them (`82:1652125811` is its `Bypass`) |
| Round, learn row, REAPER starts | 6.2 s, 6.1 s, 1 | 6.2 s, 6.1 s, 1 |
| Result file | 9967 bytes | 36802 bytes |

In ZL Compressor the plugin has its own `Wet` (index 13), so REAPER's `Wet` (84) is not settable by name; REAPER's
`Delta` of each plugin reads `settable: true`, as in section 1. The listing's `blockSha256` of each plugin was not
compared with a manifest.

## 5. Command lines that are refused

Each is run with `pwsh -File run.ps1`, a result directory that does not exist and a valid configuration and plugin
directory.

| Options after the common ones | Exit code | Output |
|---|---|---|
| `-List foo` | 64 | `USAGE: -List: only "params" can be listed` |
| `-List params -ListValues x` | 64 | `USAGE: -ListValues needs -ListParam or -ListParamFile: values are for a sweep` |
| `-List params -ListPlugin zleq -ListParam Gain0 -ListValues 0,1.5` | 64 | `USAGE: -ListValues: '1.5' is not a number from 0 to 1 (values are separated by commas, with a dot as the decimal point)` |
| `-List params -Repeat 1` | 64 | `USAGE: -Repeat does not go with -List: a listing runs no scenario, and runs once` |
| `-ListPlugin zleq` (no `-List`) | 64 | `USAGE: -ListPlugin needs -List params` |
| `-List params -ListPlugin nope` | 64 | `USAGE: -ListPlugin: the configuration has no plugin 'nope'` |
| `-List params -ListPlugin zleq,aw -ListParam Gain0` | 64 | `USAGE: a sweep (-ListParam or -ListParamFile) needs exactly one plugin in -ListPlugin` |
| `-List params -ListParam Gain0 -ListParamFile <file> -ListPlugin zleq` | 64 | `USAGE: -ListParam and -ListParamFile do not go together: one name, or a file of names` |

REAPER was not started: none of the eight result directories was made, and a listing of the private configuration
directory (names, sizes, write times; 2433 entries) taken before and after the eight calls was identical.

## 6. Timing

Seconds as the result file gives them (a launch that opens the plugin on a track, saves, reads and ends), against the
time of the whole process, which also holds starting PowerShell, the checks before the launch and the copy of the
plugin:

| | Parameters | Sweep | Round | Learn row | Whole process |
|---|---|---|---|---|---|
| ZL Equalizer 2, first call (with a retry) | 614 | none | 10.3 s | 10.1 s | 14.2 s |
| ZL Equalizer 2 | 614 | none | 6.4 s | 6.1 s | 10.1 s |
| ZL Equalizer 2 | 614 | 2 parameters at 5 values | 6.3 s | 6.1 s | 9.7 s |
| Airwindows Consolidated | 17 | none | 6.2 s | 6.1 s | 9.9 s |
| ZL Compressor | 86 | none | 6.2 s | 6.1 s | 9.4 s |

The learn launch of ZL Equalizer 2 with 6 settings and no listing (section 2) also took 6.1 s, so reading 614
parameters and ten swept values added nothing that shows at this resolution; most of the time is REAPER starting, as in
the [earlier record](2026-11-19-param-variants.md#7-timing). A launch that REAPER's evaluation reminder ended is done
once more and costs the second start: 10.1 s.

## Side effects

- REAPER's default resource directory was unchanged after every round, by the harness's own check (`defaultCfgDir`:
  `unchanged` true, 2413 entries, nothing changed or unreadable, in all six rounds); the refused runs had no round.
- The module check of every round was PASS (`no tested binary was loaded from anywhere but the private copy in 1
  launches` for each listing, and in 2 for the first call and 12 for the round of section 2).
- No REAPER process was left after any run (`reaperProcessesLeft` 0, `stillRunning` false in all six rounds, and no
  `reaper.exe` in the process list after each call).
- The result files and the manifest hold no local path. The stimulus and the three bundles have the hashes they had
  before the runs; REAPER saw only the copies in the private plugins directory.

## Known limitations

- One machine, one REAPER version, one Windows version; the Dummy Audio device only; three plugins, one class each; no
  JSFX.
- **REAPER's own parameters were not marked.** The rule of the commit this was run from expects an identifier that
  starts with a colon; REAPER 7.82 gives `<index>:bypass`, `<index>:wet` and `<index>:delta`. The documentation says
  these parameters are `host` and not settable by name; the listing of this commit does not tell them apart from the
  plugin's own for any of the three plugins (`host` false, `hostBy` empty, `Wet` and `Delta` settable).
- The largest listing is 614 parameters; a plugin with thousands of parameters was not listed, nor was a sweep of
  more than two parameters or five values.
- A masked name or display text, a name that is not exact, and a parameter that could not be read cleanly did not
  occur in these three plugins: those paths are covered by the self-test with the fake host only.
- Parameters were read at their defaults, on instances of their own, at 48000 Hz and block 512. A value read with every
  other parameter at its default can read otherwise in a chain where parameters depend on each other; the learn of the
  configuration of section 2 read each setting back and found none that differed.
- Only the gain of one band was set in a rendered configuration, and its renders were identical in value: no
  parameter that changes the audio was set in a render here.
- Whether a plugin saves the same state every time was looked at for ZL Equalizer 2 only (four launches).
