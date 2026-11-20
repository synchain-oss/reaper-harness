# Validation: parameter variants, batched learning and report-only latency on REAPER 7.82

Notes on running [parameter variants](../CONFIG.md#variants), the [batched learn](../SAFETY.md#learning-the-plugin-blocks)
and a [`"report"` latency](../CONFIG.md#plugins) on a real REAPER on 2026-11-19: what 41 variants of one scenario cost
and whether each kept file and manifest line matches its variant, whether the dry reference as a bypass variant is
identical in value to its source, what a plugin that only reports its latency shows in `device`, `savereopen` and a
kept render, what one wrong display text does to the launch it is in, and which configurations are refused before REAPER
starts. What the outcomes mean is in [RESULTS.md](../RESULTS.md). It follows the
[record of file sources and kept renders](2026-11-19-file-sources.md), whose stimuli it uses.

## Setup

| | |
|---|---|
| Plugins | `harness-pdc-delay` (the JSFX shipped with the tool, file hash prefix `58d74ae36d7d`); Airwindows Consolidated, VST3, bundle version 1.2026.320, hash prefix `c76102f6d5c3`; ZL Equalizer 2, VST3, bundle version 1.4.2, hash prefix `dc75178195be` |
| Third-party plugins | the two above, unpacked from their public release packages into the plugin directory given to the runs, only for this check; nothing was installed on the machine, and they say nothing about which plugins a machine has. They were used in their default state and bypassed only: a parameter listing does not exist yet, so no parameter of either was set. The parameter variants themselves were run with the JSFX, whose parameter names are known |
| Host | REAPER 7.82 x64, Dummy Audio device, a private configuration directory, REAPER's default preferences |
| System | Windows 10 |
| Harness | the feature branch's commit `5b13e187bc95f251e35be07ecc7347186c0995b4`, which every result file and manifest line names as `toolCommit`; the commit that adds these notes changes documents only |
| Runs | ten calls of `run.ps1`, each given the lock that other GUI tests on the same machine take next to the default GUI lock: seven rounds, each with the built-in negative cases, and three configurations that are refused |

The stimuli are the two of the earlier record, 48 kHz, made for that check and not part of the repository (every 10 s
cell has the same shape: digital silence, one impulse of 0.5 per channel, pink-ish noise at -30 dBFS, digital silence).
Their hashes were checked before use.

| Stimulus | Format | Channels | Rate | Length | Frames | SHA-256 |
|---|---|---|---|---|---|---|
| S1 | float32 | 2 | 48000 | 180 s | 8640000 | `e6a2945d5878874cff79f03e9a154cfc8eb66517d4f5a7cf3e1514f981b3dec1` |
| S2 | pcm24 | 1 | 48000 | 180 s | 8640000 | `f69dcd57022f48ef1f6e1f99c9dd815f2010809f9d835b7c66e708c512da292a` |

S1 has 19 impulses per channel (the last one of the right channel is at the last frame). Every `render` scenario below
has `compare: "none"`, the default `sr` 48000 and `block` 512, offline, and `limits.renderTimeoutSec` 300; the file
sources are the files above, played as they are. Samples were compared by decoding the kept file and the source to
floating point (integers divided by 2^23): "max abs difference" is the largest absolute difference of any sample.

## Outcome

| Run | Exit code | Rows | Round |
|---|---|---|---|
| 41 variants, learn in batches of 8 | 0 | `learn.1` … `learn.6`, the 41 rows `scale-*` and the 7 built-in negative cases: all PASS | PASS, 322.7 s, 53 REAPER starts, 1 retry |
| dry variant, JSFX, S1 and S2 | 0 | `learn`, 4 rows, 7 negative cases: all PASS | PASS, 52.7 s, 10 starts |
| Airwindows Consolidated, default and bypassed | 0 | `learn`, 2 rows, 7 negative cases: all PASS | PASS, 37.0 s, 8 starts |
| ZL Equalizer 2, default and bypassed | 0 | `learn`, 2 rows, 7 negative cases: all PASS | PASS, 37.4 s, 8 starts |
| `expectPdc: "report"`, `device`, `savereopen` and kept renders | 0 | `learn`, 6 rows, 7 negative cases: all PASS | PASS, 133.9 s, 16 starts |
| one wrong display text | 1 | `learn.2` FAIL, one scenario INCOMPLETE, the other 8 variants and the 7 negative cases PASS | FAIL, 88.8 s, 16 starts |
| 32 settings in one learn launch | 0 | `learn`, 32 rows, 7 negative cases: all PASS | PASS, 119.7 s, 38 starts |
| three configurations that are refused | 64 | no row | no round |

The first learn launch of the 41-variant run was ended by the evaluation reminder and started again as designed; it is
the one entry under the round's `retries` (`learn.1`, `license-nag`). The other six rounds had none.

## 1. 41 variants and batched learn

One scenario `scale` on a layout with one source track (S1) and `harness-pdc-delay`, with 41 variants: `dry`
(`bypass: true`), `d016`, `d032` … `d576` (36 delays in steps of 16 samples, reporting on, each asked with its display
text, for example `{ "normalized": 0.0078125, "display": "64.0" }`) and `off-d016`, `off-d064`, `off-d256`, `off-d1024`
(the same, with `Report delay as PDC` at 0, display `Off`). `compare: "none"`, `keep: true`, `learnBatchSize` 8. The
line printed before the first launch: `41 scenarios and 7 negative cases picked (after matrix and variant expansion); 41
plugin variants to learn in 6 launches per round`. The 41 settings are the plugin as configured (used by `dry`) and the 40
variants with parameters.

| Learn row | Status | Seconds | Settings in the launch | Taken |
|---|---|---|---|---|
| `learn.1` | PASS | 10.3 (includes the repeated launch) | 8 | 8 |
| `learn.2` | PASS | 5.7 | 8 | 8 |
| `learn.3` | PASS | 5.7 | 8 | 8 |
| `learn.4` | PASS | 5.7 | 8 | 8 |
| `learn.5` | PASS | 5.6 | 8 | 8 |
| `learn.6` | PASS | 5.6 | 1 | 1 |

The rows say `batch` 1 … 6 of `batches` 6, `modules` `NoBinary` (no VST3 binary to prove; each JSFX proven by `fx_ident`),
and the module check of the round said `no plugin binary to check (only JSFX) in 53 launches`. Learning took 38.6 s in
all. The 41 render rows took 5.9 to 6.1 s each, 244.5 s together (mean 5.96 s), all PASS, each with `facts.variant` and
`facts.baseScenario` (`scale`). The round took 322.7 s with 53 REAPER starts: 6 learn launches and 1 repeat, 41 renders
and 5 for the built-in negative cases.

What the 41 kept files and manifest lines hold (checked by decoding every file; positions are frames at which a sample of
0.4 or more is found, against S1's 19 and 19):

| Variants | Impulses found (left / right) | Position against S1 | Max abs difference against S1 (shifted back by the delay when late) |
|---|---|---|---|
| `dry` | 19 / 19 | unchanged | 0 (no sample differs) |
| the 36 `d016` … `d576` (reporting on) | 19 / 19 | unchanged for all 36 delays (16 to 576 samples) | 1.5e-16, in 7775963 samples |
| `off-d016`, `off-d064`, `off-d256`, `off-d1024` (reporting off) | 19 / 18 | exactly 16, 64, 256 and 1024 samples late; the first 16, 64, 256 and 1024 frames are exactly 0; the last impulse of the right channel, which is at the last frame of S1, is beyond the end | 1.5e-16 after shifting back |

So with reporting on REAPER lines every delay up to 576 samples up with the dry signal, and with reporting off the render
is late by the delay, as in the earlier record. The residue (at most 1.5e-16, in the same
7775963 samples for all 36) is the one that record describes for the active JSFX (its count there is 7775962 samples where S1 is exactly 0 and one of its noise); the dry variant has none.

File hashes. All 41 files have different SHA-256 values, **including the 36 whose audio is the same**: the data chunk of
each of the 36 reporting-on files has one and the same hash (prefix `146d152d2642`), the data chunk of `dry` is S1's data
chunk byte for byte (`3f49cedcd8b3`), and each of the four reporting-off files has a data chunk of its own. The files
differ because REAPER writes a broadcast-wave `bext` chunk with the date and time of the render, to the second: two
files of identical audio rendered in different seconds differ in that chunk (one byte, in the last digit of the time,
between `d016` and `d032`) and so in the SHA-256 of the file that the manifest gives. A hash of the file therefore says
which file it is, not whether two renders have the same audio; decode the samples to compare.

The manifest (41 lines in run order; 3626 checks, no problem; see below) agrees with what was asked, line by line:

| Variant | `bypass` | `params` as asked → read back | `pdc` | `blockSha256` (first 12 hex) | Seconds |
|---|---|---|---|---|---|
| `dry` | true | none | 0 | `d0723817d73d` | 6.1 |
| `d016` | false | `Delay (samples)` 0.001953125, `16.0` → `0.001953125`, `16.0` | 16 | `4be8ab67253c` | 6.0 |
| `d064` | false | 0.0078125, `64.0` → `0.007812500`, `64.0` | 64 | `0cfc2763b325` | 6.0 |
| `d576` | false | 0.0703125, `576.0` → `0.070312500`, `576.0` | 576 | `2d3396224178` | 5.9 |
| `off-d016` | false | the delay as `d016`; `Report delay as PDC` 0, `Off` → `0.000000000`, `Off` | 0 | `5cc324a499a3` | 5.9 |
| `off-d064` | false | the delay as `d064`, reporting 0, `Off` | 0 | `d140ff7b269b` | 5.9 |
| `off-d256` | false | 0.03125, `256.0` → `0.031250000`, `256.0`; reporting 0, `Off` | 0 | `303e9f19b9e3` | 5.9 |
| `off-d1024` | false | 0.125, `1024.0` → `0.125000000`, `1024.0`; reporting 0, `Off` | 0 | `bc42e80ae917` | 5.9 |

For all 41 lines: `scenario` is `scale-<variant>`, `baseScenario` `scale`, `variant` the id, `layout` `s1-delay`;
`normalized` and `display` are what the configuration asked, `readNormalized` equals it to 1e-8 and `readDisplay` equals
the asked text; `pdc` is the delay with reporting on and 0 with it off or bypassed (the default setting), and
`pdcReadAt` is `{ "sr": 48000, "block": 512 }`. The 41 `blockSha256` values are 41 different values. The `dry` line's
block is the one of the plugin as configured (no parameters), written with `BYPASS 1`.

`blockSha256` was checked against project text in the round of section 4 (its work files were kept because the round was
not green): for each of its 8 kept variants the SHA-256 of the plugin block in the render project (its 3 lines, each
indented by six spaces and ended by a line feed, UTF-8) is the manifest's value, the project of `dry` has `BYPASS 1`
before the block and the others `BYPASS 0`, and the block's parameter line carries the learned delay.

## 2. The dry reference as a bypass variant

The variants `dry` (`{ "id": "dry", "bypass": true }`) and `as-written` (the plugin as configured, nothing set) of a
scenario on S1 and on S2, with the JSFX; and the same two on S1 with each third-party plugin. The kept renders are
float32, two channels, 8640000 frames; for S2 (one channel, pcm24) the source's samples are compared with both channels.

| Source | Plugin | Variant | Max abs difference against the source | Samples that differ |
|---|---|---|---|---|
| S1 (float32, 2 ch) | `harness-pdc-delay` | `dry` | 0 | 0 of 17280000 |
| S2 (pcm24, 1 ch) | `harness-pdc-delay` | `dry` | 0 | 0 of 17280000 |
| S1 | Airwindows Consolidated | `dry` | 0 | 0 of 17280000 |
| S1 | ZL Equalizer 2 | `dry` | 0 | 0 of 17280000 |
| S1 | `harness-pdc-delay` at delay 0 | `as-written` | 1.5e-16 | 7775963 of 17280000 |
| S2 | `harness-pdc-delay` at delay 0 | `as-written` | 1.5e-16 | 7775984 of 17280000 |
| S1 | Airwindows Consolidated | `as-written` | 0.513 | 17280000 of 17280000 |
| S1 | ZL Equalizer 2 | `as-written` | 0 | 0 of 17280000 |

- Every bypassed variant, the two third-party plugins included, is identical in value to its source: the mono pcm24
  file comes out on both channels with exactly the values of the file (x / 2^23), and for S1 the data chunk of the render
  is S1's data chunk byte for byte (hash prefix `3f49cedcd8b3`). The files themselves are not equal, as the sections
  above say: the render has a `bext` chunk (with the render's time) and a `junk` chunk in front of its data, which the
  source does not, and the manifest's `sha256` of the render is not the one of the source.
- The manifest lines say `variant: "dry"` and `bypass: true` on the FX of each. The plugin was still loaded and read
  (`pdc` 0, `blockSha256` of the plugin as configured).
- ZL Equalizer 2 in its default state is also identical in value, as the earlier record found. The default state of
  Airwindows Consolidated changes every sample (peak -20.67 dBFS against S1's -6.02); that is the plugin's own
  behaviour. It did not render the same twice: the render of the earlier record's run has a peak of -21.38 dBFS and the
  two renders differ by up to 0.035. The cause was not looked into. So a render of a third-party plugin that is not
  bypassed needs a tolerance, or a check by ear or measurement outside the tool, even for the same setting.
- The JSFX at delay 0 and reporting on, not bypassed, leaves the values of at most 1.5e-16 where the source holds exactly
  0 (and one sample of S1's noise), as described in the earlier record; for S2 the first such frame is 1.

## 3. Report-only latency

`harness-pdc-delay` with `expectPdc: "report"`, on S1 with the delay at 64 samples (normalized 0.0078125, `64.0`): one
layout with `Report delay as PDC` on (the default) and one with it at 0. Scenarios of the kinds `device` and
`savereopen` (1 cycle) on both, and a kept `render` of both.

| Row | Kind | Status | Seconds | `facts.pdc` | Notes |
|---|---|---|---|---|---|
| `dev-on` | `device` | PASS | 3.6 | 64 (`Src`, FX 0) | `0 FX report the configured latency, 1 report it only; 1 parameters read back` |
| `dev-off` | `device` | PASS | 3.5 | 0 | `1 report it only; 2 parameters read back` |
| `sr-on` | `savereopen` | PASS | 40.9 | 64 | FX state unchanged after the cycle; the reopened render is identical to the original |
| `sr-off` | `savereopen` | PASS | 40.8 | 0 | the same |
| `kept-on` | `render` | PASS | 5.7 | manifest `pdc` 64, `pdcReadAt` `{ "sr": 48000, "block": 512 }` | 19 / 19 impulses, all at S1's positions |
| `kept-off` | `render` | PASS | 5.6 | manifest `pdc` 0, `pdcReadAt` the same | 19 / 18 impulses, all 64 samples late; the last of the right channel is beyond the end |

With a numeric `expectPdc` the same plugin would be judged against the number; with `"report"` the latency is recorded
and not compared, so the same delay passes with reporting on (64) and off (0). The manifest lines of the two renders
carry the learned values as in section 1.

## 4. One wrong display text

A scenario with 9 variants on S1 (`dry`, then `ok-008`, `ok-024`, `ok-040`, the wrong one, `ok-056`, `ok-072`, `ok-088`,
`ok-104`), `learnBatchSize` 3. The variant `w-bad` asks 100 samples (0.01220703125) and says the display text is
`101.0`; REAPER shows `100.0`. The round has 3 learn launches.

| Row | Status | Seconds | Detail |
|---|---|---|---|
| `learn.1` (the plugin as configured, `ok-008`, `ok-024`) | PASS | 5.5 | 3 settings learned |
| `learn.2` (`ok-040`, `w-bad`, `ok-056`) | FAIL | 5.4 | `delay (variant 2, first used by wrong-w-bad) parameter 'Delay (samples)' shows '100.0', expected '101.0'`; `learned` 2 of 3 |
| `learn.3` (`ok-072`, `ok-088`, `ok-104`) | PASS | 5.6 | 3 settings learned |
| `wrong-w-bad` | INCOMPLETE | 0 | `not run: learning the plugin blocks it needs did not succeed (see the learn.2 row)` |
| the other 8 `wrong-*` rows, `ok-040` and `ok-056` of the failed launch among them | PASS | 5.6 to 6.1 | rendered and kept |

The exit code is 1: the round is FAIL (17 PASS, 1 FAIL, 1 INCOMPLETE), as [RESULTS.md](../RESULTS.md) has it, the FAIL
winning over the INCOMPLETE. The module check said PASS. The manifest has 9 lines: 8 with their files, and one for
`wrong-w-bad` with no file, status INCOMPLETE and the reason, its requested display text `101.0` and nothing read back.
The work files of the round were kept, as for any round that is not green.

## 5. Configurations that are refused

The configurations are otherwise sound (the delay JSFX on S1); each is run with `run.ps1` and a result directory that
does not exist.

| Configuration | Exit code | Output |
|---|---|---|
| variants and no `compare` | 64 | `USAGE: config has 1 problem(s): config.scenarios[0]: a scenario with variants needs compare ("none" to only render)` |
| two variants asking the same value of a parameter with two display texts (`64.0` and `64`) | 64 | `USAGE: config has 1 problem(s): plugin 'delay' parameter 'Delay (samples)' at 0.0078125 is asked to show both '64.0' and '64': one learned setting has one display text` |
| variants on a layout that is not defined | 64 | `USAGE: config has 1 problem(s): config.scenarios[0]: layout 'nope' is not defined in layouts` |

REAPER was not started: no result directory was made, and a listing of the private configuration directory (names, sizes,
write times; 2422 entries) taken before and after the three calls was identical.

## 6. Manifest

For every line of the manifests of the six rounds with `keep` (the check of the earlier record, extended by the variant
and display fields) the check read the file as bytes and as JSON, and found no problem: 3626 checks on the 41 lines of
section 1, 335 on the 4 of section 2 and 169 on each of the two third-party ones, 184 on the 2 of section 3 and 723 on
the 9 of section 4.

- UTF-8 without a BOM, one JSON object per line, a final line feed; every field of [RESULTS.md](../RESULTS.md#kept-renders)
  present, `variant` and `baseScenario` as the row's facts say, `scenario` equal to `<baseScenario>-<variant>`, each
  parameter with `name`, `normalized`, `display`, `readNormalized` and `readDisplay`;
- every `path` is relative and resolves to an existing file whose SHA-256, frames, channels, rate, format, peak, NaN and
  Inf counts recomputed from the file equal the manifest's; `config.sha256` and each source's `sha256` equal those of
  the files; each row's `facts.kept` equals its line with the paths relative to the result directory;
- a scenario that did not run (`wrong-w-bad`) still has its line, with no file and the status of its row.

## 7. Timing

Seconds of a row, as the result file gives them (a row is one REAPER launch that opens the project, renders and ends;
keeping the render comes after the row). The 180 s renders of S1:

| | Seconds |
|---|---|
| a kept variant of the delay JSFX | 5.9 to 6.1 (41 of them: 244.5 s, mean 5.96) |
| a kept variant of a third-party plugin | 4.2 to 4.4 |
| `savereopen` on S1 (two renders and the reopen) | 40.8 to 40.9 |

One learn launch took 5.5 to 5.6 s with 1 setting, 5.6 to 5.7 s with 8 (five launches of the 41-variant run) and
6.1 s with 32 settings (an extra round of 32 variants of the JSFX on the tool's own test signal, one launch, `learnBatchSize`
at its default; its 32 renders took 2.5 to 3.4 s each and the round 119.7 s). The evaluation reminder repeated one launch
in the 41-variant run, which is why `learn.1` took 10.3 s. 41 settings in 6 launches took 38.6 s, so the learn of a
long configuration is small next to its renders: in that run the renders took about six times as long as the learning.

## Side effects

- REAPER's default resource directory was unchanged after every round, by the harness's own check (`defaultCfgDir`:
  `unchanged` true, 2413 entries, nothing changed or unreadable, in all seven rounds); the refused runs had no round.
- The module check of every round was PASS (`no tested binary was loaded from anywhere but the private copy in 8
  launches` for each third-party plugin; `no plugin binary to check (only JSFX)` for the JSFX).
- No REAPER process was left after any round (`reaperProcessesLeft` 0, `stillRunning` false).
- The two stimuli have the hashes they had before the runs; REAPER saw only the copies in the work directory. The kept
  renders of the seven rounds take about 4 GB (a stereo float32 render of 180 s is 69 MB).

## Known limitations

- One machine, one REAPER version, one Windows version; the Dummy Audio device only.
- Parameters of third-party plugins were not set: they were tried in the default state and bypassed only. The 41
  parameter variants are of the tool's own JSFX, whose parameters are two. Variants whose settings change the audio of a
  VST3 plugin, and a state used in a variant, were not run on REAPER (they are covered by the self-test with the fake
  host).
- The bypassed third-party results are for the two plugins above; another plugin may not pass its input through bypassed
  (a plugin with latency or a tail, for one), which this check does not say.
- The latency read at the learn is the one at 48000 Hz and block 512; with `"report"` the latency at the render's own
  rate and block was not read.
- A launch of 32 settings was timed on the JSFX; a launch of 32 VST3 plugin instances of a heavy plugin was not.
- The `bext` timestamp means that `sha256` of a kept file is not stable between renders of the same audio; no way to
  render the same file twice with the same bytes was looked for.
- The stimuli and the harness checks that read the kept files are not part of the repository.
