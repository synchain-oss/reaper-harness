# Validation: file sources and kept renders on REAPER 7.82

Notes on running the [source files](../CONFIG.md#source-files) and [kept renders](../CONFIG.md#keep) on a real REAPER
on 2026-11-19: what comes out for a file played as it is, for a mono file on a two-channel render, for a file at the
wrong rate, for a plugin that reports latency and for third-party plugins, and whether the
[manifest](../RESULTS.md#kept-renders) describes what was kept. What the outcomes mean is in
[RESULTS.md](../RESULTS.md).

## Setup

| | |
|---|---|
| Plugins | `harness-pdc-delay` (the JSFX shipped with the tool, file hash prefix `58d74ae36d7d`); Airwindows Consolidated, VST3, bundle version 1.2026.320, hash prefix `c76102f6d5c3`; ZL Equalizer 2, VST3, bundle version 1.4.2, hash prefix `dc75178195be` |
| Host | REAPER 7.82 x64, Dummy Audio device, a private configuration directory, REAPER's default preferences |
| System | Windows 10 |
| Harness | the feature branch's commit `a758edf395a1a81004edfc2dc74e96e006272c92`, which every result file and manifest line names as `toolCommit`; the commit that adds these notes changes documents only |
| Runs | five calls of `run.ps1`, each given the lock that other GUI tests on the same machine take next to the default GUI lock; four of them are one round with the built-in negative cases (a core run with the passthrough, mono and latency rows, one run per third-party plugin, and one more run of the first plugin with `-KeepWork`), the fifth has a configuration that is refused |

The stimuli are made for this check and are not part of the repository. Each is 48 kHz unless noted, and every 10 s
cell has the same shape: 3 s of digital silence with one impulse of 0.5 on the left channel at 1 s and one on the right
channel at 2 s (positions differ per cell and per channel), then 5.5 s of pink-ish noise at -30 dBFS (an independent
stream per channel), then 1.5 s of digital silence. There is also an impulse on the left channel at frame 0 and one on
the right channel at the last frame. 0.5 is a multiple of 2^-23, so it is the same value in float32 and in pcm24.

| Stimulus | Format | Channels | Rate | Length | Frames | SHA-256 |
|---|---|---|---|---|---|---|
| S1 | float32 | 2 | 48000 | 180 s | 8640000 | `e6a2945d5878874cff79f03e9a154cfc8eb66517d4f5a7cf3e1514f981b3dec1` |
| S2 | pcm24 | 1 | 48000 | 180 s | 8640000 | `f69dcd57022f48ef1f6e1f99c9dd815f2010809f9d835b7c66e708c512da292a` |
| S3 | pcm24 | 2 | 44100 | 30 s | 1323000 | `cbd405d4c522372e9f1d14daff9059c2354ab0e22281ee6bdc9f2c35944c4827` |

S2 is the left channel of S1 quantised to pcm24 (so its decoded values are those of S1's left channel rounded to
multiples of 2^-23). S1 has 19 impulses per channel. Every `render` scenario below has `compare: "none"` and
`keep: true`, the default `sr` 48000 and `block` 512, offline, and `limits.renderTimeoutSec` 300. Samples were compared
by decoding the kept file and the source to floating point (integers divided by 2^23): "max abs difference" is the
largest absolute difference of any sample.

## Outcome

| Run | Exit code | Rows | Round |
|---|---|---|---|
| core | 0 | learn, `p1-plain`, `p1-bypassed`, `m2-mono-2ch`, `m2-mono-1ch`, `l4-pdc-on`, `l4-pdc-off` and the 7 built-in negative cases: all PASS | PASS, 93.1 s, 13 REAPER starts |
| Airwindows Consolidated | 0 | learn, `t5-airwindows` and the 7 built-in negative cases: all PASS | PASS, 33.8 s, 7 starts |
| ZL Equalizer 2 | 0 | learn, `t5-zleq` and the 7 built-in negative cases: all PASS | PASS, 33.7 s, 7 starts |
| Airwindows Consolidated again, `-KeepWork` | 0 | the same rows, all PASS | PASS, 33.8 s, 7 starts |
| rate mismatch | 64 | refused before the preflight, no row | no round |

In the core run the evaluation reminder ended the learn launch once; it was started again as designed and is listed
under the round's `retries`. The three plugins are in separate configurations on purpose: the learn launch of one
configuration adds every plugin of it, so one that did not load would have taken the rows of the others with it.

## 1. Passthrough

The source track plays S1 and holds no FX (`p1-plain`), or holds `harness-pdc-delay` bypassed (`p1-bypassed`).

| Row | Frames (kept / S1) | Channels, rate, format | Max abs difference | Samples that differ |
|---|---|---|---|---|
| `p1-plain` | 8640000 / 8640000 | 2, 48000, float32 | 0 | 0 of 17280000 |
| `p1-bypassed` | 8640000 / 8640000 | 2, 48000, float32 | 0 | 0 of 17280000 |

Both kept files are sample-identical in value to S1 (the peak is -6.02 dBFS, the 0.5 impulses). The items of the
projects are 180 s long, which is every frame of the file; the project holds only the copy of S1 made in the work
directory, never the file in the configuration directory, and no peak file appeared next to the stimuli. With the delay
effect in the chain, not bypassed, the render is not bit-identical (see the next section for its latency): the files
differ from S1 by at most 1.5e-16 (about -316.5 dBFS), and only where S1 holds exactly 0 (7775962 samples) and at one
sample of S1's noise whose value is 1.19e-9; in the noise itself nothing differs. The values in the silent parts are
5e-17 and 1.5e-16, which is what an anti-denormal offset would give; its cause was not looked into, and the effect is
absent with the effect bypassed and with ZL Equalizer 2 in its default state (below). The tool's own test signal has no
exact zero sample (checked on a generated file), so it does not meet this, and the earlier measurements of this JSFX
with it found the renders bit-identical.

## 2. Mono file on a two-channel render

S2 (one channel, pcm24) on a track with no FX, the track at pan centre and volume 1, REAPER's default project settings.

| Row | Render | Result |
|---|---|---|
| `m2-mono-2ch` | 2 channels, float32, 8640000 frames | left and right are sample-identical (max abs difference 0); both are sample-identical to S2 (max abs difference 0 against the decoded pcm24 samples); level relative to the source 0.00 dB (RMS -32.59 dBFS in the source and in each channel, peak -6.02 dBFS); no pan-law attenuation |
| `m2-mono-1ch` (`mono: true`) | 1 channel, float32, 8640000 frames | sample-identical to S2 (max abs difference 0), 0.00 dB |

So REAPER puts a mono file on both channels of a two-channel render at the file's own level: no -3 dB or -6 dB at
centre, no difference between the channels. This is the sentence [CONFIG.md](../CONFIG.md#source-files) carries. Only
pan centre was measured; other pan positions of a mono file were not.

## 3. Rate mismatch

S3 (44.1 kHz) on a track of a layout used by a scenario at the default 48 kHz:

```
USAGE: sources: 1 problem(s): r3-mismatch: source audio/s3.wav is at 44100 Hz and the scenario runs at 48000 Hz: nothing is resampled
```

The exit code is 64. REAPER was not started: no result directory, work directory or kept file was made, and a listing
of the private configuration directory (names, sizes, write times) taken before and after the call was identical, with
nothing in it that a launch writes (the scan shield's cache entries, `verchk` in the ini). The check comes before the
preflight, so nothing else was looked at either.

## 4. Latency

`harness-pdc-delay` on the source track with S1 and its `Delay (samples)` at 64 (normalized 0.0078125, REAPER shows
`64.0`). Positions are the frames at which a sample of 0.5 or more is found.

| Row | `Report delay as PDC` | `pdc` read back at the learn | Impulses found (left / right, S1 has 19 / 19) | Position against S1 |
|---|---|---|---|---|
| `l4-pdc-on` | On | 64 | 19 / 19 | unchanged for all 38 |
| `l4-pdc-off` | Off | 0 | 19 / 18 | 64 samples late for all 37; the last impulse of the right channel, at the last frame of S1, is beyond the end of the render (8640000 frames, the same as S1) and is gone |

- With reporting on, the render lines up with S1 and differs from it only as described under passthrough (at most
  1.5e-16, in digital silence).
- With reporting off, the first 64 frames of the render are exactly 0 and the render, shifted back by 64 frames,
  equals S1 up to the same residue.

## 5. Third-party plugins

The plugin in its default state with no `params`, on the source track with S1, `keep: true`.

| | Airwindows Consolidated | ZL Equalizer 2 |
|---|---|---|
| `learn` | PASS: 1 variant learned, `modules` Proven, binary `Private` | PASS: the same |
| Module check of the round | PASS: no tested binary loaded from anywhere but the private copy in 7 launches, no other plugin module | the same |
| Row | PASS, 4.7 s (4.9 s in the `-KeepWork` run) | PASS, 4.4 s |
| Name as REAPER showed it | `VST3: Airwindows Consolidated (Airwindows)` | `VST3: ZL Equalizer 2 (ZL)` |
| Hash prefix of the binary in the manifest | `c76102f6d5c3` | `dc75178195be` |
| `pdc` | 0 | 0 |
| `blockSha256` | `80cba11f8fc7f0f3fb8154b6a75b90c8b2fc77db532d4edaa712ae162b0d8281` | `b42aaee854f28483bdd8c123c3fb00bad044a6995cf2497f6f15833cccd3a9fa` |
| Render against S1 | every sample differs (max abs difference 0.51; peak -21.38 dBFS) | sample-identical (0) |

- The hash prefixes were recomputed from the binaries inside the bundles in the plugin directory and are the same as in
  the manifests and in the `plugins` of the result files; the same holds for the JSFX file (`58d74ae36d7d`).
- `blockSha256` was checked against the project text: the run with `-KeepWork` kept the render project, and the SHA-256
  of the plugin block in it (its 8 lines, each indented by six spaces and ended by a line feed, UTF-8) is the manifest's
  value.
- The default state of Airwindows Consolidated changes the audio; that is the plugin's own behaviour and is not judged.
  Nothing was set on either plugin, so `params` is empty in their records.

## 6. Manifest

For every line of the five manifests the check read the file as bytes and as JSON, and found (451 checks on the core
manifest, 85 on each of the others, no problem):

- UTF-8 without a BOM, one JSON object per line, a final line feed; 6 lines in the core manifest (one per kept scenario,
  in run order), 1 in each of the others;
- every field of [RESULTS.md](../RESULTS.md#kept-renders) present: `schema`, `runStamp`, `round`, `scenario`,
  `baseScenario`, `variant` (null), `layout`, `kind`, `status`, `detail`, `output` and `stems` with `path`, `sha256`,
  `frames`, `channels`, `sampleRate`, `format`, `peakDb`, `nanCount` and `infCount`, `render` with `sr`, `block`,
  `mode`, `channels` and `host`, `sources` (per source track, the file record with its path, full SHA-256, frames,
  channels, rate and format), `fx` (per FX: `track`, `index`, `plugin`, `bundle` or `jsfx`, `name`, 12-hex `sha256`,
  `bypass`, `state`, `stateSha256`, 64-hex `blockSha256`, `params` with `name`, `normalized`, `readNormalized` and
  `readDisplay`, `pdc` and `pdcReadAt`), `reaper`, `toolVersion`, `toolCommit` (40 hex), `buildLabel` and `config`;
- every `path` is relative, resolves inside the manifest's directory to an existing file, and the SHA-256 recomputed
  from that file equals the manifest's; frames, channels, rate, format, peak (to 0.001 dB), NaN and Inf counts
  recomputed from the file equal the manifest's;
- `config.sha256` equals the SHA-256 of the configuration file, and each source's `sha256` that of the file in the
  configuration directory; the result's `sources` list S1 and S2 for the core run;
- each row's `facts.kept` equals the manifest line with its paths relative to the result directory, and those paths
  resolve; the result's `manifest` names the file.

The learned values of the delay rows are in the lines: `l4-pdc-on` has `Delay (samples)` asked 0.0078125, read back
`0.007812500` and `64.0`, `Report delay as PDC` asked 1, read back `1.000000000` and `On`, `pdc` 64; `l4-pdc-off` the
same with 0, `0.000000000`, `Off` and `pdc` 0.

## 7. Timing

Seconds of a row, as the result file gives them, for the 180 s renders (a row is one REAPER launch that opens the
project, renders and ends, with the project written before it and the render read after it; keeping the render
comes after the row and is not in its seconds):

| Row | Seconds |
|---|---|
| `p1-plain` | 5.9 |
| `p1-bypassed` | 5.7 |
| `m2-mono-2ch` | 5.8 |
| `m2-mono-1ch` | 5.2 |
| `l4-pdc-on` | 6.0 |
| `l4-pdc-off` | 5.7 |
| `t5-airwindows` | 4.7 (4.9 with `-KeepWork`) |
| `t5-zleq` | 4.4 |

That is 4.4 to 6.0 s per kept render, 5.7 s on average for the six of the core run. A kept stereo render of 180 s as
float32 is 69 MB (a mono one 35 MB). Keeping is cheap: a round took 2.5 s longer than the sum of its rows in the core
run (6 kept renders) and 0.4 to 0.5 s longer in each run with one (this gap also holds the module check and the other
work of a round, so it is an upper bound for keeping, about 0.4 s per render). The learn row took 5.4 to 5.8 s, 33.7 s in
the core run because of the repeated launch. The built-in negative cases took 3.2 to 8.7 s each (`neg-timeout` the
longest, by design). Rounds took 93.1 s (14 rows) and 33.7 to 33.8 s (9 rows), 194.4 s together; the refused run
started nothing.

## Side effects

- REAPER's default resource directory was unchanged after every round, by the harness's own check (`defaultCfgDir`:
  `unchanged` true, 2413 entries, nothing changed or unreadable, in all four rounds); the refused run had no round.
- No REAPER process was left after any round (`reaperProcessesLeft` 0, `stillRunning` false).
- The files in the configuration directory (the three stimuli) have the hashes they had before the runs; REAPER saw
  only the copies in the work directory.

## Known limitations

- One machine, one REAPER version, one Windows version; the Dummy Audio device only.
- The mono measurement is at pan centre and at the default project settings; other pan positions, a changed pan law
  and tracks with FX in front of the mono file were not measured.
- The residue of the delay JSFX in digital silence (at most 1.5e-16) means that a render through that JSFX is not
  bit-identical to a source that holds digital silence; a comparison of such renders needs a `maxDiffDb`, or a source
  without exact zeros. This was not tried in a run.
- Only the latency of the learn launch (48000 Hz, 512) is in the manifest; the latency at the render's own rate and
  block was not read.
- A third-party plugin was tried in its default state only; plugin parameters on kept renders were not exercised here.
- The stimuli and the harness checks that read the kept files are not part of the repository.
