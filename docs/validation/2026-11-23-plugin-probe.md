# Validation: probe variables and collected files on REAPER 7.82

Notes on running a [probe](../CONFIG.md#probes) on a real REAPER on 2026-11-23: a plugin's test build is given the path
of a copy of a script and the path of a new empty directory, renders a file source at `1x` and `online`, and writes what
it saw into that directory; the harness collects those files after the launch. The notes say what the harness collected
and whether it is what the plugin wrote (names, sizes, hashes, the process that wrote them), whether a variant gets a
script copy of its own, what a row that passed means when the plugin rejects its script, which configurations are refused
before REAPER starts, and what the renders cost. What the outcomes mean is in [RESULTS.md](../RESULTS.md). It uses the
stimuli of the [record of file sources and kept renders](2026-11-19-file-sources.md) and follows the
[record of reported residuals and render tails](2026-11-22-repeat-report-tail.md).

## Setup

| | |
|---|---|
| Plugin | a plugin's private test build (name withheld), VST3, Windows x64, binary hash prefix `90c8bc05f22b`. It reads one environment variable that names a file (a script of timed actions) and one that names a directory it may write into, and it writes step files and a final file there, each name carrying the writing process's pid |
| Third-party plugins | the one above, used only for this check from a private copy of its bundle in the plugin directory given to the runs; nothing was installed on the machine, and it says nothing about which plugins a machine has |
| Host | REAPER 7.82 x64, Dummy Audio device, a private configuration directory, REAPER's default preferences |
| System | Windows 10 |
| Harness | the feature branch's commit `a67e53c6ef75f34ea1bebfe8965e9fa93225baab`, which every result file names as `toolCommit`; the commit that adds these notes changes documents only |
| Runs | three calls of `run.ps1` that start REAPER, each given the lock that other GUI tests on the same machine take next to the default GUI lock, each with the seven built-in negative cases; and four configurations that are refused (section 5), each given to `doctor.ps1 -Config` and to `run.ps1` |

The configuration of the plugin was, with the placeholder names of the [example](../../examples/plugin-probe/reaper-harness.json):

```json
"plugins": { "tb": { "bundle": "My Probe Test Build.vst3",
    "probe": { "EXAMPLE_PROBE_SCRIPT": { "file": "probe/script.json" }, "EXAMPLE_PROBE_OUT": { "dir": true } } } }
```

and every scenario was a `render` with `compare: "none"`, `notSilent: true`, `host.informOfflineState: false`, `probe` (as
declared, or with the script overridden), the plugin alone on one track that plays a file source, the default `sr`
48000 and `block` 512, and `limits.renderTimeoutSec` 600. The script was a file of five timed actions, the last of them at
45 s of processed audio, so that it is over long before a 180 s render ends. A shifted copy has every time 0.33 s later
(a different hash), and a bad one has an action the plugin does not know.

The stimuli are the two of the earlier records, 48 kHz, made for that check and not part of the repository; their hashes
were checked before use and are the ones of the earlier records:

| Stimulus | Format | Channels | Frames | SHA-256 |
|---|---|---|---|---|
| S1 | float32 | 2 | 8640000 (180 s) | `e6a2945d5878874cff79f03e9a154cfc8eb66517d4f5a7cf3e1514f981b3dec1` |
| S2 | pcm24 | 1 | 8640000 (180 s) | `f69dcd57022f48ef1f6e1f99c9dd815f2010809f9d835b7c66e708c512da292a` |

Every collected file was also read by a script (`python -I`, as data: hash, size, and the few fields that say how the
script ran, never the content of the plugin's snapshot) and what it found is compared with what the result file and the
manifest say.

## Outcome

| Run | Exit code | Rows | Round |
|---|---|---|---|
| S1 at `1x`, a probe, without `keep` and with `keep` | 0 | `learn`, 2 scenarios, 7 negative cases: all PASS | PASS, 407.5 s, 9 starts (the learn launch was ended once by REAPER's evaluation reminder and done again) |
| S1 at `online` and S2 (mono) at `1x` | 0 | `learn`, 2 scenarios, 7 negative cases: all PASS | PASS, 402.1 s, 8 starts |
| two variants (a shifted script, then the plain one) and a script the plugin rejects, S1 at `1x` | 0 | `learn`, 3 scenarios, 7 negative cases: all PASS | PASS, 586.9 s, 9 starts |
| four configurations (denied name twice, a repeat, a JSFX) | 64 | none: refused, nothing started | 1.3 to 1.6 s each |

## 1. S1 at `1x`: what was collected

`mode: "1x"`, S1 as a file source on a stereo track, one scenario without `keep` (`p1-nokeep`) and one with (`p1-keep`).
Both are PASS, `frames=8640000 channels=2 rate=48000 format=float32 nonfinite=0 peak=-6.02`, and the detail ends
`; probe: 3 files collected, 17418 bytes` and `; probe: 3 files collected, 17491 bytes`.

| Row | `facts.probe.pid` | Step file 1 | Step file 2 | Final file | Total |
|---|---|---|---|---|---|
| `p1-nokeep` | 58584 | 5095 bytes | 6166 bytes | 6157 bytes | 17418 |
| `p1-keep` | 50064 | 5134 bytes | 6183 bytes | 6174 bytes | 17491 |

- **Where.** Under `renders/<run stamp>/run1/p1-nokeep.out/` and `run1/p1-keep.out/` of the result directory, with the
  names the plugin gave them: two step files and a final file, listed in name order. The work directory had nothing of
  it left after the round (in all three rounds): no `<id>.out`, no `.probe-` copy.
- **The listing equals the disk.** For both rows `facts.probe.files` has the names of the three files in the directory
  and no other, and the size and the SHA-256 of each equal the file as read from disk (19 files over all the rows of this
  record, all equal). Two of them were hashed once more with `sha256sum`, a tool other than the script that did the
  rest: the final file of `p1-nokeep` (prefix `fb3cd1dfd077`) and the second step file of `p1-keep` (prefix
  `75d79d1b7f82`). `left` is 0 and
  `temporary` 0: the plugin left no `.tmp` file.
- **The pid.** `facts.probe.pid` is the pid of the REAPER of the render, and the name of every collected file carries
  exactly that pid, in both rows. The learn launch loaded the plugin too, but it is given none of the variables and no
  file carries any other pid: nothing that launch might have written is there. (The result file does not record the
  learn launch's pid, so this rests on there being one pid only.)
- **The script copy.** The variable of the script has the hash of the file of the configuration (prefix
  `3c95614dac6e`, 280 bytes), as checked before REAPER started and as the harness hashed the copy again afterwards: the
  row is not INCOMPLETE, so the plugin did not change its copy.
- **The final file** is there: it is written when the plugin instance is destroyed, at the end of the process, which
  shows that collection waits for the process to exit. It says the script was read (state `ok`) and that all 5 actions
  ran (0 left), every reply was `ok`, each at most 0.045 s of processed audio after its time, the plugin counted no error
  of its own, and it had written 2 step files and processed 180.52 s of audio.
- **`keep`.** `manifest` of the result file is `renders/<run stamp>/manifest.jsonl` and has one line, `p1-keep`: its
  `probe` equals the row's `facts.probe` with `dir` relative to the manifest (`run1/p1-keep.out`), and the WAV is kept
  (`run1/p1-keep.wav`, 69120692 bytes, 8640000 frames, peak -6.0206 dBFS). `p1-nokeep` has no line.

## 2. S1 at `online` and S2 at `1x`

`p2-online`: mode `online`, S1 on a stereo track. `p2-mono`: mode `1x`, S2 (mono, pcm24) on the track of a two-channel
render. Both PASS, 3 files each, with the checks of section 1 passing:

| Row | `facts.probe.pid` | Step file 1 | Step file 2 | Final file | Total | Plugin's processed audio |
|---|---|---|---|---|---|---|
| `p2-online` | 39924 | 5090 bytes | 6154 bytes | 6147 bytes | 17391 | 180.81 s |
| `p2-mono` | 42472 | 5082 bytes | 6171 bytes | 6160 bytes | 17413 | 180.52 s |

- Names, sizes and hashes in `facts.probe` equal the files on disk; all names carry the row's pid, and no other.
- The script copy has the same hash as in section 1. The final file of both says state `ok`, 5 of 5 actions, every reply
  `ok`, no error of the plugin's own. In `online` the actions ran at most 0.119 s after their time (0.045 s at `1x`).
- Both rows have the render of a two-channel master (`channels=2`): the mono file is played on both.
- Neither scenario has `keep`, so the result file's `manifest` is null; `renders/<run stamp>/` holds `run1/` (with the
  two `.out` directories) and an empty `manifest.jsonl` (0 bytes), as [RESULTS.md](../RESULTS.md#kept-renders) says.

## 3. Variants: a shifted script, then the plain one

One scenario `p3` with `probe` as declared and two variants in this order: `shifted` (overrides the script variable
with the shifted copy) and `plain` (no override). Both rows PASS, 3 files each.

| Row | `facts.probe.pid` | Script variable (hash prefix, bytes) | Total | First step file ended at (processed audio) |
|---|---|---|---|---|
| `p3-shifted` | 56884 | `cbc07fe72416`, 291 | 17480 | 7.392 s |
| `p3-plain` | 23852 | `3c95614dac6e`, 280 | 17523 | 7.061 s |

- The hash of the shifted row is that of the shifted file and the hash of the plain row is that of the scenario's own
  file: the variant that overrides does not change the one after it.
- Each variant has its own directory, `p3-shifted.out` and `p3-plain.out`, and every name in each carries its own
  launch's pid, and no other (56884 and 23852). They are two launches.
- The plugin saw the copy it was given: the two step files of the shifted launch end at 7.392 s and 33.408 s of processed
  audio, those of the plain launch at 7.061 s and 33.099 s (the launches of sections 1 and 2 with the plain script end
  at 7.02 to 7.07 s and 33.05 to 33.09 s), which is about 0.3 s later, the shift. Both final files say state `ok`, 5 of
  5 actions.

## 4. A script the plugin rejects

`p4-bad`: `probe` overrides the script with the bad file (one action the plugin does not know, among otherwise valid
ones). The row is PASS, `frames=8640000 ... peak=-6.02; probe: 1 file collected, 3445 bytes`:

- The render passed its audio criteria (not silent) and one file, the final one, was collected (`min` is 1). Names, size
  and hash are those on disk, and the pid in the name is the row's (48480).
- The final file says what the harness does not: the script state is `error`, with a reason that names the entry (the
  second one, and the action that is unknown), 0 actions ran, and no step file was written (the plugin had run none).
  The audio was passed through untouched, and the harness never looked.
- So PASS says that the render passed its audio criteria and that at least `min` files were collected. It does not say
  that the plugin's own script ran: that is for the plugin's author to read in the files, which is what the docs say
  ([CONFIG.md](../CONFIG.md#probes), [RESULTS.md](../RESULTS.md#a-row-scenarios)).

## 5. Configurations refused before REAPER starts

Four configurations, each with one scenario of the same layout, checked with `doctor.ps1 -Config` and with `run.ps1`
(with the private configuration directory, the plugin directory and a new empty result directory). Every one exits 64
with `USAGE`, in 1.3 to 1.6 s as a whole run. No `reaper.exe` was running before or after each call, the
result directory stayed empty (no result file, no work directory), and a listing of the private configuration directory
with sizes and times was the same before and after.

| Configuration | Message |
|---|---|
| a probe variable named `NODE_OPTIONS` | `config.plugins.tb.probe.NODE_OPTIONS: 'NODE_OPTIONS' starts with NODE_, which REAPER, what it loads, WebView2, a runtime or the harness reads; a probe variable may not set it` |
| a probe variable named `MY_TEST_PROXY` | `config.plugins.tb.probe.MY_TEST_PROXY: 'MY_TEST_PROXY' ends with _PROXY, which network libraries read; a probe variable may not set it` |
| `probe` on a scenario with `compare: "repeat"` | `config.scenarios[0].probe: a render that sets probe variables compares with "dry" or "none": a repeat or a compare variant would load the plugin again without them` |
| `probe` on a JSFX (the one shipped with the tool) | `config.plugins.dl.probe: probe variables are for VST3 plugins (a JSFX reads no environment)` |

## 6. Timing

- A render of 180 s at `1x` took 184.7 to 185.3 s as a row (seven rows, `1x` and `online` alike: 184.7, 184.8, 184.8, 184.9,
  185.1, 185.2, 185.3), the plugin processing 180.5 to 180.8 s of audio. Launching, collecting and hashing the files is the few
  seconds on top. A recording of 4 minutes would need `limits.renderTimeoutSec` above 240, as the example says.
- A round of two such rows with the built-in negative cases took 407.5 s and 402.1 s, one of three took 586.9 s. The
  learn launch took 6.4 to 10.9 s (10.9 s with a launch REAPER's evaluation reminder had ended and that was done again).
- Wall clock per call of `run.ps1`, including the listing of the default resource directory before and after: 412 s,
  406 s and 591 s.

## Side effects

- REAPER's default resource directory was unchanged after every round, by the harness's own check (`defaultCfgDir`:
  `unchanged` true, 2413 entries, nothing changed or unreadable, in all three rounds) and by a listing of it with sizes
  and times taken before and after each call (the same 2413 entries, equal).
- The module check passed in every round (no tested binary was loaded from anywhere but the private copy, in 9, 8 and 9
  launches, no other plugin module), `reaperProcessesLeft` was 0 and `stillRunning` false in every round, and no
  `reaper.exe` of ours was running after the last run. One start was deferred by about four minutes because a REAPER of
  another job was running on the machine; it was left alone and the run began when it had ended.
- The stimuli have the hashes they had before the runs; REAPER saw only the copies in the work directories. The scripts of
  the configuration were not changed by any run.
- Every result file lists both GUI locks, the default one and the other test's.

## What the documents say now

The documents said what the runs found: where the files go and under which names, the pid of `facts.probe`, the manifest
line only with `keep` and an empty manifest otherwise, and what PASS means. One wording was too loose: the detail says
`1 file collected` when there is one, and [CONFIG.md](../CONFIG.md#probes) and [RESULTS.md](../RESULTS.md#a-row-scenarios)
now say so. What was measured here is added to the end of the probe section of CONFIG and to the usage note on timing.

## Known limitations

- One machine, one REAPER version, one Windows version; the Dummy Audio device only, at 48 kHz and block 512.
- One plugin's test build. What the files say beyond how the script ran (the plugin's own analysis) was not read, and
  the plugin's output is not part of the repository.
- The licence-reminder retry of a probe scenario, a `.tmp` file left by the plugin, a file the plugin held open, and a
  variable left in the shell were not met in these runs: they are covered by the self-test with a stand-in plugin. In
  one run the reminder ended the learn launch, which gets no probe variables.
- The learn launch's pid is not in the result file, so that launch having written nothing is shown by there being one
  pid in the names and by the learn launch not being given the variables, not by a pid.
- Only 180 s recordings at `1x` and `online`; `offline` renders and other block sizes were not tried with a probe.
- The stimuli, the scripts and the helper scripts that read the collected files are not part of the repository.
