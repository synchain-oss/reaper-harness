# Validation: reported residuals and render tails on REAPER 7.82

Notes on running a [reported residual](../CONFIG.md#reported-residuals) (`maxDiffDb: "report"`) and a
[render tail](../CONFIG.md#tails) (`tailSeconds`) on a real REAPER on 2026-11-22: what a repeat of a deterministic plugin
and of a plugin that is not reports, what a reported residual against `dry` comes to and whether it is the number an
independent computation gives, whether a render with a tail has exactly the frames asked for and what is in it (at
other blocks and in the modes `1x` and `online` too), whether the first render of a repeat is kept when and only when
it should be, whether the [manifest](../RESULTS.md#kept-renders) describes what was kept, what the comparer costs on
long files, and which configurations are refused before REAPER starts. What the outcomes mean is in
[RESULTS.md](../RESULTS.md). It follows the [record of file sources and kept renders](2026-11-19-file-sources.md), whose
stimuli it uses, and the [record of the parameter listing](2026-11-20-param-listing.md), from which the settings that
switch band 1 of ZL Equalizer 2 on are taken.

## Setup

| | |
|---|---|
| Plugins | `harness-pdc-delay` (the JSFX shipped with the tool, file hash prefix `58d74ae36d7d`); ZL Equalizer 2, VST3, bundle version 1.4.2, hash prefix `dc75178195be`; Airwindows Consolidated, VST3, bundle version 1.2026.320, hash prefix `c76102f6d5c3` |
| Third-party plugins | the two above, unpacked from their public release packages into the plugin directory given to the runs, only for this check; nothing was installed on the machine, and they say nothing about which plugins a machine has |
| Host | REAPER 7.82 x64, Dummy Audio device, a private configuration directory, REAPER's default preferences |
| System | Windows 10 |
| Harness | the feature branch's commit `22f668d393816b47442ae6ca2b5510c44a17567c`, which every result file and manifest line names as `toolCommit`; the commit that adds these notes changes documents only |
| Runs | thirteen calls of `run.ps1`, each given the lock that other GUI tests on the same machine take next to the default GUI lock: eleven rounds, each with the built-in negative cases, and two parameter listings; and nine configurations checked with `doctor.ps1` that are refused (section 8) |

The stimuli are the two of the earlier records, 48 kHz, made for that check and not part of the repository; their hashes
were checked before use and after the last run:

| Stimulus | Format | Channels | Frames | SHA-256 |
|---|---|---|---|---|
| S1 | float32 | 2 | 8640000 (180 s) | `e6a2945d5878874cff79f03e9a154cfc8eb66517d4f5a7cf3e1514f981b3dec1` |
| S2 | pcm24 | 1 | 8640000 (180 s) | `f69dcd57022f48ef1f6e1f99c9dd815f2010809f9d835b7c66e708c512da292a` |

S1 has 19 impulses of 0.5 per channel, the last one on the right channel at its last frame (8639999); S2 is the left
channel of S1 quantised to pcm24 (impulses at the same frames). Every scenario plays one of them as a file source on one
track with the plugin on it, `renderTimeoutSec` 300 (600 for the real-time modes), the default `sr` 48000, `block` 512
and mode `offline` unless a row says otherwise. Every kept file below was also read by a script (`python -I`, decoding
the samples) and what it found is compared with what the result file and the manifest say; a kept 180 s stereo float32
file is 69120692 bytes, and 70272692 with a 3 s tail (144000 frames of 8 bytes more).

## Outcome

| Run | Exit code | Rows | Round |
|---|---|---|---|
| listing of `Gain0` of ZL Equalizer 2 at 0.6 | 0 | `learn`, `params`: PASS; display text `6.00` | PASS, 14.5 s (the learn launch was ended once by REAPER's evaluation reminder and done again) |
| listing of `Delay (samples)` of the JSFX at 64 and 8192 | 0 | `learn`, `params`: PASS; display texts `64.0` and `8192.0` | PASS, 6.9 s |
| repeat, reported: the JSFX and ZL Equalizer 2 | 0 | `learn`, 4 scenarios, 7 built-in negative cases: all PASS | PASS, 184.9 s, 14 starts |
| repeat, reported: Airwindows Consolidated | 0 | `learn`, 1 scenario, 7 negative cases: all PASS | PASS, 92.9 s, 8 starts |
| its judged twin (no `maxDiffDb`) | 0 | all PASS: this pair was identical | PASS, 72.7 s, 8 starts |
| Airwindows Consolidated, four reported repeats alternating with three judged ones | 1 | the 3 judged ones FAIL (`not bit-identical`), all 4 reported ones and the rest PASS | FAIL, 318 s, 20 starts |
| dry report: ZL Equalizer 2 at +6 dB | 0 | `learn`, 1 scenario, 7 negative cases: all PASS | PASS, 74.2 s, 8 starts |
| tail 3 s, block 512 | 0 | `learn`, 5 scenarios, 7 negative cases: all PASS | PASS, 165.6 s, 13 starts |
| tail 3 s, blocks 2048 and 333 | 0 | `learn`, 2 scenarios, 7 negative cases: all PASS | PASS, 115.7 s, 8 starts |
| tail 3 s, mode `1x` | 0 | `learn`, 1 scenario, 7 negative cases: all PASS | PASS, 252.8 s, 7 starts |
| tail 3 s, mode `online` | 0 | `learn`, 1 scenario, 7 negative cases: all PASS | PASS, 224.5 s, 7 starts |
| tail 3 s with a reported repeat and keep: ZL Equalizer 2 and Airwindows Consolidated | 0 | `learn`, 2 scenarios, 7 negative cases: all PASS | PASS, 194.0 s, 11 starts (one learn launch done again) |
| the same with Airwindows Consolidated three times | 0 | `learn`, 3 scenarios, 7 negative cases: all PASS | PASS, 212.5 s, 12 starts |

The one exit code 1 is the expected one: its three failing rows are the judged repeats, which fail when the two renders
differ, as a repeat without `maxDiffDb` always did. No reported repeat failed in any run, whatever it found.

## 1. A repeat that reports: deterministic plugins

`compare: "repeat"`, `maxDiffDb: "report"`, `notSilent: true` on S1; scenarios with `keep: true` except the last.

| Row | Plugin and setting | Line ends | `facts.comparison.master` |
|---|---|---|---|
| `rep-delay` | the JSFX, 64 samples, report as PDC on (`pdc` 64) | `; reported: bit-identical` | `identical` true, `maxDiff` 0, every other residual field null (`residualDb`, `residualRmsDb`, `maxDiffFrame`, `maxDiffSeconds`, `firstDiffFrame`), `frames` and `referenceFrames` 8640000, `lag` 0, `bestLag` 0 |
| `rep-zleq` | ZL Equalizer 2, `Filter Status0` `On`, `Gain0` `15.00` | the same | the same |
| `rep-zleq-first` | the same, with `keepFirst: true` | the same | the same |
| `rep-zleq-nokeep` | the same, no `keep` | the same | the same (in the row only) |

The rows took 36.0 to 41.3 s each (two renders and the comparison; section 7). The manifest has three lines, one per
kept scenario:

- `rep-delay` and `rep-zleq` keep only their second render (`run1/<id>.wav`), and `comparison.first` is null: the
  two renders were identical, so the first stayed a work file.
- `rep-zleq-first` keeps both: `run1/rep-zleq-first.wav` and `run1/rep-zleq-first-first.wav`, and `comparison.first` has
  the path, the SHA-256 (recomputed from the file on disk: equal), 8640000 frames, 2 channels, 48000 Hz, float32, the peak
  (-4.564291) and no NaN or Inf, with an empty `stems`.
- The three ZL Equalizer 2 files hold the same samples (the same data chunk, hash prefix `f06a822ac84a`, which is also the
  data chunk of the 15.00 dB render of the [earlier record](2026-11-20-param-listing.md#the-kept-files)), and still have
  three different whole-file hashes (prefixes `803bc034a17c`, `2ac8825c0045` and `047b19268e39`): REAPER writes the time of
  the render into the file, which is why the manifest says `identical` and not the hash. A second scenario of the same
  layout, rendered in another launch, came out with the same samples too.
- The kept JSFX render differs from S1 by at most 1.5e-16, in S1's digital silence, as in the
  [earlier record](2026-11-19-file-sources.md#1-passthrough); its two renders are identical.

## 2. A repeat that reports: Airwindows Consolidated at its default state

The default state changes the audio, and two renders of it are sometimes identical and sometimes not. Thirteen pairs were
rendered in five runs, nine with a reported residual and four judged; every reported row is PASS and says what it found:

| Pair | Identical | Residual (dBFS) | RMS against the reference (dB) | Largest at (s) | Best lag |
|---|---|---|---|---|---|
| `rep-aw` (kept) | no | -26.642797 | -6.819429 | 7.958208 | 1 |
| `rep-aw-r1` | no | -27.536623 | -8.680274 | 134.93825 | 0 |
| `rep-aw-r2` | no | -34.681994 | -16.676882 | 125.866479 | 0 |
| `rep-aw-r3` | yes | | | | 0 |
| `rep-aw-r4` | no | -29.401965 | -9.935319 | 96.878875 | 0 |
| `tail-rep-aw` (3 s tail) | yes | | | | 0 |
| `tail-rep-aw-1` (tail) | no | -34.980639 | -16.664514 | 125.866583 | 0 |
| `tail-rep-aw-2` (tail) | yes | | | | 0 |
| `tail-rep-aw-3` (tail) | no | -31.068917 | -12.089325 | 124.393062 | 0 |

Every non-identical row also has `firstDiffFrame` 0, `lag` 0 and equal frame counts; its line reads, for `rep-aw`,
`identical=no lag=1 maxdiff=-26.64 ... ; reported: not bit-identical, residual -26.642797 dBFS (rms -6.82 dB against the
reference) measured at lag 0 (expected), best lag 1, largest at 7.958208 s, first difference at frame 0` (the `lag=` of the
fixed part is the best lag, the residual is at the expected lag 0). The four judged repeats of the same scenario, a
repeat with no `maxDiffDb`:

| Judged pair | Outcome | Reason |
|---|---|---|
| `rep-aw-judged` | PASS | `identical=yes` |
| `rep-aw-j1` | FAIL | `not bit-identical` |
| `rep-aw-j2` | FAIL | `lag is 16, expected 0, not bit-identical` |
| `rep-aw-j3` | FAIL | `lag is 17, expected 0, not bit-identical` |

So 9 of the 13 pairs differed and 4 were identical, and the same plugin in the same state came out identical in one pair
and different in the next: one identical pair is not a record that a plugin is deterministic. The 26 renders had only eight
different peak values (-20.48 dBFS in seven of them, -21.06 in five, -20.78 in four, -20.91 in three); in every identical pair both
peaks are the same and in no differing pair are they. Why was not looked into.

Independent check of `rep-aw` (a script read the two kept files): the largest absolute difference of the second against
the first at lag 0 is 0.04654361912980676 at frame 381994 (7.958208 s), -26.642797 dBFS; the RMS of the difference against
the RMS of the first is -6.819429 dB; the first differing frame is 0; every one of the 8640000 frames differs; and the
least-squares best lag within ±64 is 1. All of these are the values of the row and of `comparison.master` in the
manifest. With `keep`, the first render of this pair was kept next to the second, and `comparison.first` has its path and
SHA-256 (prefix `df658ae30767`; the second's is `f981d6f43835`), its peak -21.059469 against the second's -20.48413. In
the two runs with a tail, `tail-rep-aw-1` and `tail-rep-aw-3` (not identical) kept both renders, 8784000 frames each, and
`tail-rep-aw-2` and the identical pair of the other run kept only the second, with `comparison.first` null. A pair with a
reported residual that was identical, and one that was not, were both PASS and the exit code was 0.

## 3. A reported residual against dry: ZL Equalizer 2 at +6 dB

`compare: "dry"`, `maxDiffDb: "report"`, `notSilent`, `keep`; `Filter Status0` 1 (`On`) and `Gain0` 0.6 (read back
0.600000024, `6.00`, as the listing said). Band 1 is the plugin's default peak filter at 1 kHz.

The row passes and says `identical=no lag=0 maxdiff=-24.93 head=-24.93 ... peak=-6.02/-5.49; reported: not bit-identical,
residual -24.93 dBFS (rms -10.09 dB against the reference) measured at lag 0 (expected), best lag 0, largest at 0.000021 s,
first difference at frame 0`. `facts.comparison.master` and the manifest's agree:

| Field | Value |
|---|---|
| `against` | `dry` |
| `identical`, `lag`, `bestLag` | false, 0, 0 |
| `maxDiff`, `residualDb` | 0.05669071525335312, -24.929761 |
| `residualRmsDb` | -10.08758 |
| `maxDiffFrame`, `maxDiffSeconds` | 1, 0.000021 |
| `firstDiffFrame` | 0 |
| `frames`, `referenceFrames` | 8640000, 8640000 |

The independent computation (S1 as the dry signal, which the dry render reproduces bit for bit when the FX is bypassed,
see the [earlier record](2026-11-19-file-sources.md#1-passthrough)) gives every one of these values: 20 log10(0.05669071525335312)
is -24.929761; the largest difference is at frame 1, where S1 holds 0 and the render holds 0.0567 right after the impulse of 0.5
at frame 0 (which the render has as 0.5318); the RMS of the difference against that of S1 is -10.08758 dB; 4780602 frames
differ. The residual is therefore not the gain step of a flat gain; it is what the filter does to this signal.

## 4. Tails

`tailSeconds: 3` (144000 frames), `compare: "none"` unless said, `notSilent`, `keep`, the JSFX delaying by 8192 samples
(`Delay (samples)` 1, `8192.0`) with `Report delay as PDC` off (`pdc` 0) unless said. The expected length is 8640000 +
144000 = 8784000 frames. Positions are the frames at which a sample of 0.5 is found.

| Row | Frames of the master | What the file holds | `endPeakDb` |
|---|---|---|---|
| `tail-off` (with the stem `Src`) | 8784000; the stem too | the first 8192 frames are exactly 0; from there render[n] = S1[n - 8192] to within 1.5e-16; 19 impulses per channel, the first on the left channel at 8192, the last one of the right channel (S1's last frame, 8639999) at **8648191**; from 8648192 to the end only the JSFX's residue of at most 1.5e-16; the stem file is byte for byte the master | -316.478174 |
| `tail-off-bypass`, `compare: "dry"` (with the stem) | 8784000; the stem too | equal to S1 for n < 8640000 (largest difference 0), exactly 0 from 8640000 on; the last impulse of the right channel at 8639999; the comparison with the dry reference, which has the same tail, is `identical=yes` for the master and the stem | null |
| `tail-on` (`Report delay as PDC` on, `pdc` 8192) | 8784000 | render[n] = S1[n] to within 1.5e-16 for n < 8640000; the last impulse of the right channel at 8639999; from 8640000 on only residue of at most 1.5e-16: the tail holds nothing of the source | -316.478174 |
| `tail-off-s2` (S2, mono, on the two-channel render) | 8784000 | both channels equal; 19 impulses on each, the first at 8192 and the last at 8229166 (S2's last, 8220974, plus 8192); the same residue after | -316.478174 |
| `tail-off-s2-bypass`, `compare: "dry"` | 8784000 | equal to S2 on both channels for n < 8640000, exactly 0 after; `identical=yes` with the dry reference | null |
| `tail-off-b2048` (block 2048) | 8784000 | the same samples as `tail-off`, every one | -316.478174 |
| `tail-off-b333` (block 333) | 8784000 | the same impulse positions and the same 1.5e-16 bound; it differs from `tail-off` by at most 1.1e-16 in 4023735 samples, all of them places where the JSFX's residue sits | -316.478174 |
| `tail-off-1x` (mode `1x`) | 8784000 | the same samples as `tail-off`, every one | -316.478174 |
| `tail-off-online` (mode `online`) | 8784000 | the same samples as `tail-off`, every one | -316.478174 |

- 8784000 is not a multiple of 512, 2048 or 333 (the remainders are 128, 128 and 126): every block of the table does not
  divide the length. The length of S1 alone is a multiple of 512.
- `endPeakDb` (the peak of the last 100 ms, 4800 frames, of the master) is what a script finds in the last 4800 frames of
  the kept files, to 6 decimals, in every row, null where those frames are exactly 0; -316.478174 dBFS is the JSFX's residue
  of 1.5e-16. The row's `facts.tail` has `seconds` 3, `frames` 144000, `renderFrames` 8784000 and `stems` (`Src`
  with the same `endPeakDb`), and the manifest line's `render` has `tailSeconds` 3, `tailFrames` 144000 and `endPeakDb`;
  `output.frames` and `stems[].frames` are 8784000. A render without a tail has `tailSeconds` 0, `tailFrames` 0 and
  `endPeakDb` null in its line (all 19 lines were checked for it).
- The tail is silence after the source, not the source again: in the bypassed rows every frame after the end of S1 is
  exactly 0, so the items played their source once.
- In the reported repeats with a tail (section 5), the end of a render was not silent for one plugin:
  `endPeakDb` is -55.7 to -56.2 dBFS for Airwindows Consolidated (-55.695595, -55.87176 twice, -56.183631), null for ZL
  Equalizer 2 (its end is exactly 0).
- Both real-time modes were measured: a render of 183 s of audio took 188.5 s (`1x`) and 189.6 s (`online`) as a row.

## 5. A tail with a reported repeat and keep

`compare: "repeat"`, `maxDiffDb: "report"`, `keep: true`, `tailSeconds: 3`: ZL Equalizer 2 (the setting of section 1) and
Airwindows Consolidated, then Airwindows Consolidated three times (section 2).

- Both renders of every pair have 8784000 frames; the row's `facts.tail` and `facts.comparison` and the manifest's
  `render.tailSeconds` 3, `render.tailFrames` 144000, `comparison` (without and with `first`) are there; the manifest's
  `comparison` equals the row's apart from `first`.
- The ZL Equalizer 2 pair was identical, so only its second render was kept (`first` null) and its `endPeakDb` is null.
- The pairs that differed kept both renders, and the SHA-256 of both is in the manifest and equals that of the file.

## 6. The manifest

For all 19 lines of the manifests (3, 1, 1, 5, 2, 1, 1, 2 and 3 lines in the nine runs that keep) the check found, with
1251 checks and no problem:

- UTF-8 without a BOM, one JSON object per line, a final line feed, every field of [RESULTS.md](../RESULTS.md#kept-renders)
  present (`comparison` and `render.tailSeconds`, `tailFrames`, `endPeakDb` included), `schema` 1 and `toolCommit` the
  commit of the runs;
- every `path` (the master, the stems, `comparison.first` and its stems) relative, inside the manifest's directory, an
  existing file, with the SHA-256, frames, channels, rate, format, peak (to 0.001 dB), NaN and Inf counts recomputed from
  the file equal to the line's;
- the row's `facts.comparison` equals the line's `comparison` without `first`, and is null in the line exactly where the row
  has none; `facts.tail` agrees with `render.tail*` and `output.frames`; `render.endPeakDb`, recomputed from the master,
  equals the one of the line;
- `fx[].version` is `1.4.2` for ZL Equalizer 2, `1.2026.320` for Airwindows Consolidated and null for the JSFX; the other
  fields of the earlier records (`sha256` of 12 hex digits, `blockSha256` of 64, `params` with their read-back values,
  `pdc` 64 for the JSFX with the report on and 8192 for the tail row, 0 where it is off) are as there;
- `config.sha256` is 64 hex digits, and each source's `sha256` equals the file's.

## 7. Timing

- A reported or judged repeat of S1 (two renders of about 5 s and the comparison) took 36.0 to 43.4 s as a row without a
  tail and 37.5 to 45.7 s with a 3 s tail, with the default `lagSearch` of 64.
- The comparison is most of it. Calling the harness's comparer on two kept 180 s stereo float32 files (no REAPER, the
  same machine, each timing done twice): 27.3 and 27.7 s with `limits.lagSearch` 64 (129 passes over the files) and 1.5
  and 1.4 s with 0 (one pass) for the two Airwindows renders; 27.6 and 28.1 s against 1.7 and 1.7 s for two identical ZL
  Equalizer 2 renders. The residual is the same at both (`residualDb` -26.642797 for the Airwindows pair); the best lag
  reads 0 with `lagSearch` 0. A dry comparison of the bypassed twin of section 4 with a stem (two comparisons) took 66.5 s
  as a row, one without a stem 40.7 s.
- A render with a tail of 183 s at block 512 took 6.5 to 8.4 s as a row (with a stem 8.4 s), 11.4 s at block 2048 and
  15.2 s at block 333.
- The first built-in negative case took 7.5 to 53.6 s and the second 4.2 to 22.5 s in the eleven rounds; the difference
  between rounds was not looked into.

## 8. Configurations refused before REAPER starts

Nine configurations checked with `doctor.ps1 -Config` (the same validation as `run.ps1`, which starts nothing after it),
each with one scenario of a repeat on the ZL Equalizer 2 layout; all exit 64:

| Configuration | Message |
|---|---|
| `maxDiffDb: "Report"` | `config.scenarios[0].maxDiffDb: must be one of report` |
| `maxDiffDb: "report"`, `compare: "none"` | `config.scenarios[0]: maxDiffDb needs a reference, but this render is compared with none` |
| `tailSeconds: 61` | `config.scenarios[0].tailSeconds: must be at least 0 and at most 60` |
| `tailSeconds: "1"` | `config.scenarios[0].tailSeconds: must be a number` |
| `tailSeconds: 0.00001` | `config.scenarios[0].tailSeconds: 1E-05 s is less than one frame at 48000 Hz` |
| `keepFirst: true`, `maxDiffDb: "report"`, no `keep` | `config.scenarios[0].keepFirst: needs keep true, compare "repeat" and maxDiffDb "report" (on the scenario or a stem compared with the reference)` |
| `keepFirst: true`, `keep: true`, a repeat without `"report"` | the same message |
| `tailSeconds: 1` on a `device` scenario | `config.scenarios[0]: unknown key 'tailSeconds'` |
| a repeat with `maxDiffDb: "report"` and plugin `report` criteria | `config.scenarios[0].report: a repeat that reports its residual cannot judge plugin reports as well: its two renders would be made in two different ways` |

## Side effects

- REAPER's default resource directory was unchanged after every round, by the harness's own check (`defaultCfgDir`:
  `unchanged` true, 2413 entries, nothing changed or unreadable, in all thirteen rounds).
- The module check passed in every round (for the VST3 runs: no tested binary was loaded from anywhere but the private
  copy, no other plugin module; for the JSFX-only runs: no plugin binary to check), `reaperProcessesLeft` was 0 and
  `stillRunning` false in every round, and no `reaper.exe` was running after the last run.
- The stimuli have the hashes they had before the runs; REAPER saw only the copies in the work directories.
- Every result file lists both GUI locks, the default one and the other test's.

## Known limitations

- One machine, one REAPER version, one Windows version; the Dummy Audio device only, at 48 kHz.
- Tails of 3 s only, on S1 and S2 and with one effect (the JSFX, which has no tail of its own beyond its delay): a tail
  shorter than a latency that is not reported was not measured, nor were a plugin with a reverb tail and a `sr` other than
  48000.
- Stems were measured for one track (`Src`) with a tail; a reported residual was measured on the master only (not on a
  stem, nor against a compare variant); a reported residual with stems of other `maxDiffDb` numbers is covered by the
  self-test with the stand-in and not by these runs.
- Only the default state of Airwindows Consolidated and 13 pairs were rendered; what makes two renders of it differ was not
  looked into, so nothing here says how often it will.
- The mode `1x` and `online` renders were taken at block 512 only.
- The stimuli and the scripts that read the kept files are not part of the repository.
