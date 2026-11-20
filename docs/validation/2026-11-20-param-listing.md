# Validation: parameter listing on REAPER 7.82

Notes on running the [parameter listing](../USAGE.md#listing-parameters) (`run.ps1 -List params`) on a real REAPER on
2026-11-20, in two runs. The first run, from commit `9252882`, measured what the listing reports for three third-party
VST3 plugins, what a sweep of two parameters reads back, whether a configuration written from the listing learns and
renders at the first try with the display texts the listing gave, whether the listing's `blockSha256` is the manifest's
for the same plugin, what it costs, and which command lines are refused before REAPER starts. It also found that none of
REAPER's own parameters was marked `host`. The fix is commit `b51be19`; the re-run, from that commit, lists the same three
plugins again and makes a configuration that changes the sound of ZL Equalizer 2 (section 7). What the outcomes mean is
in [RESULTS.md](../RESULTS.md). It follows the [record of parameter variants](2026-11-19-param-variants.md), whose
stimulus S1 it uses.

## Setup

| | |
|---|---|
| Plugins | ZL Equalizer 2, VST3, bundle version 1.4.2, hash prefix `dc75178195be`; Airwindows Consolidated, VST3, bundle version 1.2026.320, hash prefix `c76102f6d5c3`; ZL Compressor, VST3, bundle version 0.6.1, hash prefix `da1d8aede005` |
| Third-party plugins | the three above, unpacked from their public release packages into the plugin directory given to the runs, only for this check; nothing was installed on the machine, and they say nothing about which plugins a machine has. Each bundle has one Audio Module Class |
| Host | REAPER 7.82 x64, Dummy Audio device, a private configuration directory, REAPER's default preferences |
| System | Windows 10 |
| Harness | first run: the feature branch's commit `9252882a940b48c9c7f8a66f56e45f5228e8f10b`, which every result file of that run names as `toolCommit`; re-run: the fix, commit `b51be19fe54d13e9ef4cec94f9269168aef173f9`, named by every result file and manifest line of the re-run. The commits that add these notes change documents only |
| Runs | first run: six calls of `run.ps1` that started REAPER (five listings and one round of scenarios, 18 REAPER starts in all), eight calls that were refused, and two calls of `doctor.ps1`; re-run: five calls of `run.ps1` that started REAPER (four listings and one round of scenarios, 14 REAPER starts in all) and two calls of `doctor.ps1`; each `run.ps1` call was given the lock that other GUI tests on the same machine take next to the default GUI lock |

The stimulus is S1 of the earlier records (float32, 2 channels, 48000 Hz, 180 s, 8640000 frames), made for those checks
and not part of the repository; its SHA-256, checked before use (and again after the re-run), is
`e6a2945d5878874cff79f03e9a154cfc8eb66517d4f5a7cf3e1514f981b3dec1`.

The configuration of the listings is the minimal one of [USAGE.md](../USAGE.md#listing-parameters): one plugin, a layout
with one source track and that plugin, and one `device` scenario that does not run. The re-run listed with the same
three configurations as the first run.

## Outcome

| Run | Commit | Exit code | Rows | Round |
|---|---|---|---|---|
| `-List params`, ZL Equalizer 2 (first call) | `9252882` | 0 | `learn`, `params`: PASS | PASS, 10.3 s, 2 starts, 1 retry |
| the same again | `9252882` | 0 | PASS, PASS | PASS, 6.4 s, 1 start |
| `-List params` with a sweep of two parameters at five values | `9252882` | 0 | PASS, PASS | PASS, 6.3 s, 1 start |
| a round from a configuration written from that listing: 6 variants, `compare: "none"`, `keep` | `9252882` | 0 | `learn`, 6 renders and 7 built-in negative cases: all PASS | PASS, 61.4 s, 12 starts |
| `-List params`, Airwindows Consolidated | `9252882` | 0 | PASS, PASS | PASS, 6.2 s, 1 start |
| `-List params`, ZL Compressor | `9252882` | 0 | PASS, PASS | PASS, 6.2 s, 1 start |
| eight command lines that are refused | `9252882` | 64 | no row | no round |
| re-run: `-List params`, ZL Equalizer 2 (first call) | `b51be19` | 0 | PASS, PASS | PASS, 14.1 s, 2 starts, 1 retry |
| re-run: `-List params`, Airwindows Consolidated | `b51be19` | 0 | PASS, PASS | PASS, 7.5 s, 1 start |
| re-run: `-List params`, ZL Compressor | `b51be19` | 0 | PASS, PASS | PASS, 7.4 s, 1 start |
| re-run: `-List params` with a sweep of three parameters at five values | `b51be19` | 0 | PASS, PASS | PASS, 6.4 s, 1 start |
| re-run: a round from a configuration written from that sweep: 3 variants, `compare: "none"`, `keep` | `b51be19` | 0 | `learn`, 3 renders and 7 built-in negative cases: all PASS | PASS, 46.5 s, 9 starts |

The only retry of the first run is the first launch of its first call, which REAPER's evaluation licence reminder ended
and the harness started again as designed (`license-nag` under the round's `retries`); it is why that learn row says
10.1 s. The other five rounds had none. The same happened to the first call of the re-run (learn row 13.8 s, round 14.1 s, 2
starts); the other four rounds of the re-run had none.

In short: the first run found that REAPER's own `Bypass`, `Wet` and `Delta` were not marked `host` (section 1); the fix
marks them by their identifiers, and the re-run shows them marked, not settable, and the settable counts corrected
(sections 1 and 4); and a configuration that also switches band 1 of ZL Equalizer 2 on renders files that differ from the
source and from each other, where the first run's did not (sections 2 and 7).

## 1. ZL Equalizer 2

`-List params` on a configuration with the plugin as it is. The listing, as the first run (commit `9252882`) and the
re-run (commit `b51be19`) read it:

| | First run (`9252882`) | Re-run (`b51be19`) |
|---|---|---|
| Parameters | 614 (`nparams` read by the learn step 614, `paramCount` 614); read at 48000 Hz and block 512 (`readAt`) | the same |
| Plugin name, class | `VST3: ZL Equalizer 2 (ZL)`, `moduleinfo` as the source of the class (`classFrom`), version 1.4.2 | the same |
| REAPER's own parameters (`host`) | not marked: `host` false for all 614, `hostBy` empty (below) | marked: `host` true for 611, 612 and 613, `hostBy` `ident`: `611:bypass`, `612:wet`, `613:delta` |
| Settable | 612 | 610 |
| Not settable | indices 610 and 611, both named `Bypass`, which `sameNameAs` 2 (the parameter of that name that learning reaches) | 610 (`Bypass`, `sameNameAs` 2), and REAPER's own 611 (`Bypass`, `sameNameAs` 2), 612 (`Wet`) and 613 (`Delta`) |
| Names used more than once | 1: `Bypass`, at 2, 610 and 611 (614 parameters, 612 different names) | the same |
| Masked, not exact, with a `problem` | 0, 0, 0; `displayUsable` for all 614 | the same |
| Values | the plugin's defaults | the same |
| Longest name, longest display text | 20 and 13 characters | the same |
| Result file | 245758 bytes, about 400 bytes a parameter | 245764 bytes |
| Seconds | round 10.3 s, learn row 10.1 s, 2 starts (the first call, with the retry); 6.4 s and 6.1 s with 1 start (the second) | round 14.1 s, learn row 13.8 s, 2 starts (the first call, with the retry) |

The names are the plugin's own: 24 bands (`Freq0` … `Freq23`) of 25 parameters each, with the band number at the end
of the name (`Filter Status0`, `Freq0`, `Gain0`, `Q0`, `Threshold (dB)0` …), ten global ones at the start (`Output Gain`,
`Auto Gain`, `Lookahead` …), then one more `Bypass` (610) and REAPER's three (611 to 613): 10 + 600 + 1 + 3 = 614. Every
`ident` was present, in both runs.

### REAPER's own parameters: found, fixed, re-run

`ident` is REAPER's identifier of the parameter (`TrackFX_GetParamIdent`). On REAPER 7.82 it is always
`<index>:<word or number>`:

| Parameters | `ident` | Examples (ZL Equalizer 2) |
|---|---|---|
| the plugin's own | `<index>:<its VST3 parameter ID, as a decimal number>` | `14:97695928` (`Freq0`), `15:98116753` (`Gain0`), `610:1652125811` (`Bypass`; 1652125811 is 0x62797073, the four characters `byps`, the VST3 standard bypass parameter) |
| REAPER's own, the last three | `<index>:bypass`, `<index>:wet`, `<index>:delta` | `611:bypass` (`Bypass`, normalized 0, display `normal`), `612:wet` (`Wet`, 1, `100`), `613:delta` (`Delta`, 0, `normal`) |

**First run (commit `9252882`): not marked.** That commit marked a parameter `host` when its identifier starts with a
colon (`:bypass`), or, for a parameter without an identifier, when it is one of the last three and they are named
`Bypass`, `Wet` and `Delta`. The identifiers of REAPER 7.82 start with the index, not with a colon, and every parameter
had one, so no parameter was `host` and `hostBy` was empty, in all three plugins (section 4). The last three of each
plugin are named `Bypass`, `Wet`, `Delta` exactly and are the parameters at the indices above. As a result REAPER's `Wet`
and `Delta` read `settable: true`, and its `Bypass` was not settable only because the plugin has a parameter of that name
before it. The idents seen: the `<index>:` prefix equals the parameter's index in every parameter of all three plugins
(717 parameters), the plugins' own parameters have a number after it (611, 14 and 83 of them), and REAPER's three have the
words above.

**The fix (commit `b51be19`).** A parameter is `host` when its ident is exactly `:bypass`, `:wet` or `:delta`
(case-sensitive), with either nothing in front or the parameter's own index written in decimal, string-equal: `612:wet`
at index 612 is `host`; `5:wet` at index 6, `0612:wet`, `15:98116753`, `1:Wet`, `3:wetx` and `wet` are not. `hostBy` is
`ident` then. The rule for a parameter without an ident (one of the last three, when they are named exactly `Bypass`,
`Wet` and `Delta`; `hostBy` `names`) is unchanged.

**Re-run (commit `b51be19`).** In all three plugins the last three parameters are `host`, by `ident`, and no other
parameter is; `hostBy` is `ident` for each plugin, and none of the three is settable:

| | ZL Equalizer 2 | Airwindows Consolidated | ZL Compressor |
|---|---|---|---|
| Parameters | 614 | 17 | 86 |
| `host`, with the `ident` | 611 `611:bypass`, 612 `612:wet`, 613 `613:delta` | 14 `14:bypass`, 15 `15:wet`, 16 `16:delta` | 83 `83:bypass`, 84 `84:wet`, 85 `85:delta` |
| `hostBy` | `ident` | `ident` | `ident` |
| Settable, first run and re-run | 612, 610 | 12, 10 | 84, 83 |

The idents were as before: the `<index>:` prefix equals the parameter's index in all 717 parameters, the plugins' own have
a number after it (611, 14 and 83 of them, none `host`), and the nine of REAPER's own have the words. Every parameter had
an ident, so the rule by names did not apply to any parameter on a real REAPER here; it is covered by the self-test with
the fake host only.

### Sweep of two parameters

First run. `-ListPlugin zleq -ListParamFile` with two names, `Gain0` (index 15) and `Freq0` (index 14), at the default
values `0, 0.25, 0.5, 0.75, 1`: one call, one launch (round 6.3 s, learn row 6.1 s, 1 start, no retry). Each value was
set on an instance of its own, added for that parameter with every other parameter at its default, and read back:

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
what the listing of the defaults holds. The sweep of the re-run is in section 7.

## 2. A configuration written from the listing

First run. The configuration was written by a script from the result file of the sweep: the plugin id, the parameter name
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
and the display texts are right, and a render that is to hear `Gain0` must also set the band on. The re-run does that,
and the sound changes (section 7).

## 3. The listing's block hash against the manifest's

| | `blockSha256` |
|---|---|
| the listing of ZL Equalizer 2, in each of the three calls of the first run and the two listings of the re-run | `b42aaee854f28483bdd8c123c3fb00bad044a6995cf2497f6f15833cccd3a9fa` |
| the manifest line `gain-as-written` of the first run (the FX has no `params` and no `state`) | the same 64 hex digits |

So for an FX with no parameters and no state the listing's `blockSha256` equals the manifest's, and ZL Equalizer 2
saved the same state in all six launches that wrote it (the three listings and the learn launch of the round of section 2
in the first run, and the two listings of the re-run; a launch that REAPER's reminder ended, one in each first call, is
not counted). Of the five variants that set `Gain0`, `g050` asked for 0.5, the default: its block hash equals that of
`as-written` (prefix `b42aaee854f2`), while those of `g000`, `g025`, `g075` and `g100` differ from it and from each other
(`0a759ceca365`, `de6678429f1e`, `cbd94fc563a6`, `38bb3ea81a72`). The three variants of section 7 differ from the default
and from each other too (`dd2a68609afc`, `3056fdfbdcb5`, `5c2cd77ec0c9`). A plugin that stores a time or a random id in
its state would not have the same hash twice; this one does. The other two plugins were listed once in each run and gave
the same `blockSha256` both times (Airwindows Consolidated `80cba11f8fc7…`, ZL Compressor `8ecd44fb2e98…`), and none of
their blocks was compared with a manifest.

## 4. Airwindows Consolidated and ZL Compressor

`-List params` only, each on its own configuration, with the same layout and `device` scenario. First run (commit
`9252882`) and re-run (commit `b51be19`):

| | Airwindows Consolidated | ZL Compressor |
|---|---|---|
| Parameters (`nparams` = `paramCount`) | 17 | 86 |
| Settable | first run 12, re-run 10 | first run 84, re-run 83 |
| Names used more than once | 2: `-` (indices 5 to 9, five times) and `Bypass` (10 and 14) | 2: `Wet` (13 and 84) and `Bypass` (82 and 83) |
| Not settable | first run 6 to 9 and 14; re-run 6 to 9, 14, 15 and 16 | first run 83 and 84; re-run 83, 84 and 85 |
| Masked, not exact, with a `problem` | 0, 0, 0 | 0, 0, 0 |
| REAPER's own (`host`), `hostBy` | first run none, empty; re-run 14, 15 and 16, `ident` | first run none, empty; re-run 83, 84 and 85, `ident` |
| `ident` of REAPER's last three | `14:bypass`, `15:wet`, `16:delta` | `83:bypass`, `84:wet`, `85:delta` |
| The plugin's own idents | `<index>:<number>`, 14 of them | `<index>:<number>`, 83 of them (`82:1652125811` is its `Bypass`) |
| Round, learn row, REAPER starts | first run 6.2 s, 6.1 s, 1; re-run 7.5 s, 7.3 s, 1 | first run 6.2 s, 6.1 s, 1; re-run 7.4 s, 7.2 s, 1 |
| Result file | first run 9967 bytes, re-run 9973 | first run 36802 bytes, re-run 36807 |

In ZL Compressor the plugin has its own `Wet` (index 13), so REAPER's `Wet` (84) was not settable by name in the first run
either; REAPER's `Delta` of each plugin read `settable: true` in the first run (section 1) and is `host` and not settable
in the re-run. In Airwindows Consolidated the parameters 6 to 9 are the ones that share the name `-` with 5. The listing's
`blockSha256` of each plugin was not compared with a manifest.

## 5. Command lines that are refused

First run only: the fix changes no option and no check before REAPER starts, and the re-run did not repeat them. Each is
run with `pwsh -File run.ps1`, a result directory that does not exist and a valid configuration and plugin directory.

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

| | Commit | Parameters | Sweep | Round | Learn row | Whole process |
|---|---|---|---|---|---|---|
| ZL Equalizer 2, first call (with a retry) | `9252882` | 614 | none | 10.3 s | 10.1 s | 14.2 s |
| ZL Equalizer 2 | `9252882` | 614 | none | 6.4 s | 6.1 s | 10.1 s |
| ZL Equalizer 2 | `9252882` | 614 | 2 parameters at 5 values | 6.3 s | 6.1 s | 9.7 s |
| Airwindows Consolidated | `9252882` | 17 | none | 6.2 s | 6.1 s | 9.9 s |
| ZL Compressor | `9252882` | 86 | none | 6.2 s | 6.1 s | 9.4 s |
| ZL Equalizer 2, first call (with a retry) | `b51be19` | 614 | none | 14.1 s | 13.8 s | not timed |
| Airwindows Consolidated | `b51be19` | 17 | none | 7.5 s | 7.3 s | 12.4 s |
| ZL Compressor | `b51be19` | 86 | none | 7.4 s | 7.2 s | 12.0 s |
| ZL Equalizer 2 | `b51be19` | 614 | 3 parameters at 5 values | 6.4 s | 6.2 s | 10.2 s |

The learn launch of ZL Equalizer 2 with 6 settings and no listing (section 2) also took 6.1 s, so reading 614
parameters and ten swept values added nothing that shows at this resolution; most of the time is REAPER starting, as in
the [earlier record](2026-11-19-param-variants.md#7-timing). A launch that REAPER's evaluation reminder ended is done
once more and costs the second start: 10.1 s in the first run, 13.8 s in the re-run. In the re-run the sweep of three
parameters took 6.2 s, again the same as a launch with no listing, and the learn launch with 4 settings of section 7 took
6.4 s. The two plain listings of the re-run that followed the first call (17 and 86 parameters) took 7.3 s and 7.2 s,
about 1.1 s more than the same listings in the first run; neither round had a retry or any other event in its result,
and the difference was not looked into.

## 7. An audible example: ZL Equalizer 2 with band 1 on

The configurations of the first run changed no sample, because band 1 of the plugin is off by default (section 2). The
re-run finds from a listing what turns it on, writes the configuration from that listing, and renders.

### What turns the band on

`-ListPlugin zleq -ListParamFile` with three names, `Filter Status0` (index 10), `Filter Type0` (index 11) and `Gain0`
(index 15), at the default values `0, 0.25, 0.5, 0.75, 1`: one call, one launch (round 6.4 s, learn row 6.2 s, 1 start, no
retry; `params` row `1 plugin listed, 614 parameters, 3 swept at 5 values`, `notFound` empty, `hostBy` `ident`). Each
value was set on an instance of its own with every other parameter at its default, and read back:

| Asked | `Filter Status0`: read back, display | `Filter Type0`: read back, display | `Gain0`: read back, display |
|---|---|---|---|
| 0 | 0, `Off` | 0, `Peak` | 0, `-30.00` |
| 0.25 | 0.25, `Off` | 0.25, `Low Pass` | 0.25, `-15.00` |
| 0.5 | 0.5, `Bypass` | 0.5, `Notch` | 0.5, `0.00` |
| 0.75 | 0.75, `On` | 0.75, `Flat Tilt` | 0.75, `15.00` |
| 1 | 1, `On` | 1, `Flat Gain` | 1, `30.00` |

All fifteen values were read back as asked. The plugin's defaults are `Filter Status0` 0 (`Off`) and `Filter Type0` 0
(`Peak`), with `Freq0` at `1000.0` and `Q0` at `0.707`, so band 1 is a peak filter at 1 kHz once it is switched on, and
the one thing the listing says is missing is the status: it shows `On` at 0.75 and at 1, `Bypass` at 0.5 and `Off` below.
Where between the swept values the text changes was not looked at. The `Gain0` texts are the same as in the sweep of the
first run (section 1).

### The configuration

Written by a script from that result file: the plugin id, the parameter names `Filter Status0` and `Gain0`, and the
`normalized` (the value read back) and `display` of each setting were copied, none typed. The script took for
`Filter Status0` the last swept value whose display is `On` (1), and for `Gain0` three of the five swept values, 0.25,
0.75 and 1 (which three is the script's argument; their texts are the listing's). One `render` scenario `eq` on a layout
with S1 as a file source (its hash checked before use, as above) and the plugin, `compare: "none"`, `keep: true`,
`limits.renderTimeoutSec` 300, with 3 variants, each setting both parameters with their display texts:

| Variant | `Filter Status0` | `Gain0` |
|---|---|---|
| `on-g025` | 1, `On` | 0.25, `-15.00` |
| `on-g075` | 1, `On` | 0.75, `15.00` |
| `on-g100` | 1, `On` | 1, `30.00` |

`doctor.ps1` said ready.

### The round

| Row | Status | Seconds | Detail |
|---|---|---|---|
| `learn` | PASS | 6.4 | 4 plugin variants learned in 1 launch (the plugin as configured and one for each variant), every tested binary loaded from the private copy (module list and `fx_ident`) |
| `eq-on-g025` | PASS | 5.2 | `frames=8640000 channels=2 rate=48000 format=float32 nonfinite=0 peak=-7.48` |
| `eq-on-g075` | PASS | 4.8 | the same, `peak=-4.56` |
| `eq-on-g100` | PASS | 4.8 | the same, `peak=-0.91` |
| the 7 built-in negative cases | PASS | 0 to 8.8 | each came out as expected |

Learning passed at the first try, with no retry and no FAIL row; none of the learned settings was refused for its
display text, so `On` and the three `Gain0` texts are what REAPER shows when the parameters are set in a learn launch of
their own. The round took 46.5 s with 9 REAPER starts: 1 learn, 3 renders and the other 5 for the built-in negative cases.

The manifest (3 lines) agrees with the listing: each line's `params` has two entries, `Filter Status0` and `Gain0`, with
`normalized` as asked, `readNormalized` the same to 9 digits, `display` as asked and `readDisplay` equal to it; the three
`readDisplay` texts of `Filter Status0` are `On`, and those of `Gain0` are `-15.00`, `15.00` and `30.00`, each equal to the
sweep's text of the same value. All three lines have `pdc` 0, `bypass` false, the plugin name, the hash prefix
`dc75178195be` and `pdcReadAt` 48000 and 512; their `blockSha256` prefixes are `dd2a68609afc`, `3056fdfbdcb5` and
`5c2cd77ec0c9`.

### The kept files

Read by a script (`python -I`) from the kept WAV files and the source: each is 69120692 bytes with a data chunk of
69120000 bytes (float32, 2 channels, 48000 Hz, 8640000 frames), like S1's. Levels in dBFS over all samples of both
channels; the peaks equal the `peakDb` of the manifest (-7.476908, -4.564291, -0.913304):

| | Data chunk SHA-256 (prefix) | Peak | RMS | Samples that differ from S1, of 17280000 | Largest difference from S1 |
|---|---|---|---|---|---|
| S1 | `3f49cedcd8b3` | -6.02 | -32.59 | | |
| `on-g025` (-15.00 dB) | `64ba12504c7f` | -7.48 | -33.66 | 9560119 | 0.118 |
| `on-g075` (15.00 dB) | `f06a822ac84a` | -4.56 | -27.83 | 9568616 | 0.203 |
| `on-g100` (30.00 dB) | `c8fa993d4def` | -0.91 | -17.67 | 9662310 | 0.920 |

The three kept files differ from S1 and from each other: no data chunk hash is shared, and between the kept files 9568622
(`on-g025` against `on-g075`), 9662310 (`on-g025` against `on-g100`) and 9662310 (`on-g075` against `on-g100`) samples
differ, by at most 0.283, 0.949 and 0.730. The data chunk of S1 (`3f49cedcd8b3`) is the one that all six kept files of the
first run had; none of these has it. Of S1's 17280000 samples 7775962 (45.0%) are exactly 0 and 9504038 are not; every one
of those 9504038 is different in each of the three files, and 56081, 64578 and 158272 of the zeros of S1 are not 0 in
`on-g025`, `on-g075` and `on-g100`. The differences themselves have an RMS of -40.83, -31.17 and -18.09 dBFS.

What it took: the one parameter the first run left out, `Filter Status0` at a value whose text is `On`. Nothing else was
set (the filter type, frequency and Q stay at the defaults of the listing), and the settings were found from the
listing alone. The files were compared by hash, level and difference; they were not listened to.

## Side effects

- REAPER's default resource directory was unchanged after every round, by the harness's own check (`defaultCfgDir`:
  `unchanged` true, 2413 entries, nothing changed or unreadable, in all six rounds of the first run and all five of the
  re-run); the refused runs had no round.
- The module check of every round was PASS (`no tested binary was loaded from anywhere but the private copy in 1
  launches` for each listing, and in 2 for the first call and 12 for the round of section 2 in the first run; in the
  re-run in 2 launches for the first call, 1 for each of the next three listings and 9 for the round of section 7).
- No REAPER process was left after any run (`reaperProcessesLeft` 0, `stillRunning` false in all eleven rounds, and no
  `reaper.exe` in the process list after each call of the first run and after the last call of the re-run; the checks
  before every call of the re-run found none either).
- The result files and the manifests hold no local path (the one `AppData` in them is the text of a built-in negative
  case). The stimulus and the three bundles have the hashes they had before the runs (checked after the re-run); REAPER saw
  only the copies in the private plugins directory.

## Known limitations

- One machine, one REAPER version, one Windows version; the Dummy Audio device only; three plugins, one class each; no
  JSFX.
- **REAPER's own parameters were not marked in the first run** (commit `9252882`: `host` false and `hostBy` empty for all
  three plugins, `Wet` and `Delta` settable). The fix (commit `b51be19`) reads REAPER 7.82's identifiers
  `<index>:bypass`, `<index>:wet` and `<index>:delta`, and the re-run marked them in all three plugins. That rests on what
  REAPER 7.82 writes: another version of REAPER may write them otherwise, and a parameter without an identifier is
  marked by the rule by names only, which did not occur on a real REAPER here.
- The largest listing is 614 parameters; a plugin with thousands of parameters was not listed, nor was a sweep of more
  than three parameters or five values.
- A masked name or display text, a name that is not exact, and a parameter that could not be read cleanly did not
  occur in these three plugins: those paths are covered by the self-test with the fake host only.
- Parameters were read at their defaults, on instances of their own, at 48000 Hz and block 512. A value read with every
  other parameter at its default can read otherwise in a chain where parameters depend on each other; the learn of the
  configurations of sections 2 and 7 read each setting back and found none that differed.
- The rendered configurations set the gain of one band, with and without the band on: the first run's (band off) rendered
  the source's samples, the re-run's (band on) changed them. The sound was judged by hash, level and difference, not by
  ear; one band of one plugin on one stimulus.
- Whether a plugin saves the same state every time was looked at for ZL Equalizer 2 only (six launches); the other two
  plugins were listed twice each.
