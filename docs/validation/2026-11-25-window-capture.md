# Validation: images of a plugin's held window (`windows.capture`) on REAPER 7.82

Notes on running a [transport state](../CONFIG.md#transport) whose `windows` has `holdMs` and `capture` on a real REAPER on
2026-11-25: a plugin's private test build with a web view editor, whose editor needs seconds to start, has its floating
window opened and kept open, and the harness saves a PNG of the window at offsets of the hold. The notes say whether the
images are taken, how big they are and where the plugin's view is in them, how late after its offset each one was asked
for, whether the files, their sizes and their hashes agree with the result, what the images show (in generic words only),
what is left in the work directory with and without `-KeepWork`, which configurations are refused before REAPER starts,
and what the shots cost in time. What the outcomes mean is in [RESULTS.md](../RESULTS.md). It follows the
[record of holding a window open](2026-11-24-window-hold.md), whose configuration it takes up.

## Setup

| | |
|---|---|
| Plugin | a plugin's private test build with a web view editor (name withheld), VST3, Windows x64, binary hash prefix `cffb213fcefd`, the build of the record before this one. It writes a report file when it is given the name of one in an environment variable, from a timer on REAPER's message thread (every 250 ms, only when something changed, and on prepare, release and destruction), with the id of its process and counters of the whole process: a ready counter (the editor's page finished starting), a fallback counter (it gave up and showed a fallback panel), counters of editor opens and editor closes, a counter of calls between the page and the plugin, and counters of prepares and of blocks. No probe variable was set |
| Third-party plugins | the build above, used only for this check from a private copy of its bundle in the plugin directory given to the runs; nothing was installed on the machine, and it says nothing about which plugins a machine has |
| Host | REAPER 7.82 x64, Dummy Audio device at 48 kHz and block 512, a private configuration directory, REAPER's default preferences with Run FX when stopped on; the display at 96 DPI |
| System | Windows 10 |
| Harness | the feature branch's commit `9bced0c62e1899c4cb5fdcb23ba65f5681537d53`, which every result file names as `toolCommit`; the commit that adds these notes changes documents only |
| Runs | five calls of `run.ps1` that start REAPER, each given the lock that other GUI tests on the same machine take next to the default GUI lock (the first with the eight built-in negative cases, the others with `-NoNegative`); and three configurations that are refused (section 4), each given to `doctor.ps1 -Config` and to `run.ps1` |

The plugin was declared as in the [example of reports](../CONFIG.md#reports), with invented names for what the build
reports (the names of its fields and of its variable are not given here), as in the record before this one:

```json
"plugins": { "rec": { "bundle": "Recorder Test Build.vst3",
    "report": { "env": "RECORDER_REPORT_JSON",
                "fields": ["editorReady", "editorFallback", "panelOpens", "panelCloses", "pageCalls", "prepares", "blocks"],
                "pid": "pid", "periodMs": 250 } } }
```

Every scenario was a `transport` scenario of one layout, a track with `"source": true` that has the plugin once, and
states `stop`, `arm: false`, `monitor: "off"`, the default `samples` (2 s), and a `windows` of `plugin: "rec"`. The criteria
of a state that held its windows were, with `n` the number of windows:

```json
"expect": { "report": { "rec": { "editorReady": { "delta": n }, "editorFallback": { "delta": 0 },
    "panelOpens": { "delta": n }, "panelCloses": { "delta": n }, "pageCalls": { "delta": { "min": n } } } } }
```

The counters are totals of a REAPER process, and a transport scenario is a REAPER of its own: they start at 0 in the first
state of a scenario, and in a later state at what the state before left. The names in the lines below are the invented
ones.

## Outcome

| Run | Exit code | Rows | Round |
|---|---|---|---|
| one window held 10 s, three shots | 0 | `learn`, 1 scenario and 8 negative cases: all PASS | PASS, 76 s, 9 starts (the learn launch was ended once by REAPER's evaluation reminder and done again) |
| a warm-up state, then three windows held 5 s each, one shot | 0 | `learn` and 1 scenario (2 states): PASS | PASS, 51 s, 2 starts |
| the first, with `-KeepWork` | 0 | `learn` and 1 scenario: PASS | PASS, 28.4 s, 2 starts |
| the first without `capture`, twice | 0 | `learn` and 1 scenario: PASS | PASS, 28.1 s and 28.0 s, 2 starts each |
| three configurations (`capture` without `holdMs`, an offset after the hold, nine offsets) | 64 | none: refused, nothing started | 1.5 to 1.7 s each |

## 1. One window held 10 s, three shots

`editor-shots`: one state, `windows` of `count` 1, `holdMs` 10000 and `capture` `[300, 2000, 8000]`, the criteria above
with `n` 1, run with the built-in negative cases. The row is PASS in 21.4 s:

```
editor-start: blocks=1061/1061 silent=1061 signal=0 left=0 right=0 same=0 transport=stop monitoring=0 windows=1/1 of 1 held=10009/10000ms shots=3/3 report rec.editorReady=1 (+1) rec.editorFallback=0 (+0) rec.panelOpens=1 (+1) rec.panelCloses=1 (+1) rec.pageCalls=1 (+1)
```

- **The report.** As in the record before this one: the ready counter went from 0 to 1, the fallback counter stayed at 0,
  the open and close counters read 1 and 1 after the window was gone, and the counter of calls between the page and the
  plugin read 1. Taking three shots did not change what the build did.
- **The hold.** 10009 ms of 10000, 9 ms more than asked; the window opened and closed once. The device and the chain ran
  the same number of blocks (1061 and 1061).
- **The shots.** `shots=3/3`, and three PNGs under `renders/<run stamp>/run1/editor-shots.shots/`, `editor-start-300.png`,
  `-2000.png` and `-8000.png`. Each is 1120 x 727 pixels at 96 DPI, with `view` at `x` 0, `y` 27, `w` 1120, `h` 700: REAPER's
  row of controls is 27 pixels high and the plugin's view fills the rest of the image down to its bottom edge. Each file
  was hashed and sized after the run: the `bytes` and the `sha256` of the facts are those of the moved file, for all
  three, and each has a PNG signature, an 8-bit RGB header and the size above.

  | `at` | `held` | `wallMs` | `bytes` | `sha256` starts with |
  |---|---|---|---|---|
  | 300 | 324 | 397 | 468600 | `a9682b019d80` |
  | 2000 | 2002 | 2075 | 455962 | `1e0fe3a642cd` |
  | 8000 | 8009 | 8082 | 455970 | `4d3e9cab996b` |

- **`held` against `at`.** The hold's clock read 24, 2 and 9 ms past the offset when the driver asked. `wallMs`, the wall
  clock from when the window was first seen shown, read 73 ms more than `held` in all three, the same for every shot of
  a run. Both are what the driver's rule gives: a shot is asked for in the first turn of the message loop whose hold
  time has reached its offset, and a turn counts at most 100 ms of the hold. While the editor starts, the turns are
  long: the hold then moves in steps of up to 100 ms (so the shot at 300 ms came up to one step late) and falls behind
  the wall clock by what those turns took beyond 100 ms, which `wallMs` keeps ahead for the rest of the hold.
- **The work directory.** After the green round without `-KeepWork` the work directory was empty: no `editor-shots.shots`
  and no request or answer file was left behind.

### What the three images show

Looked at once, privately; the images are not part of the repository and are described here in generic words only.

- **300 ms.** REAPER's row of controls on top (a preset box and a few small buttons) and, below it, a pale gradient
  panel with rounded top corners and nothing drawn in it: the view was not drawn yet.
- **2000 ms and 8000 ms.** The editor complete: panels with text, level meters and buttons, filling the view below
  REAPER's row. The two look the same to the eye.

So the editor had not drawn its view at 300 ms and had at 2000 ms; the ready counter, read once the window was gone,
grew by 1 over the state.

## 2. A warm-up state, then three windows held 5 s, one shot

`editor-warm`: two states in one scenario. The first, `warm-up`, is the state of section 1 without `capture` (`count` 1,
`holdMs` 10000); the second, `three-opens`, has `count` 3, `holdMs` 5000 and `capture` `[4000]`, and the criteria with `n` 3.
The row is PASS in 44 s:

```
warm-up: blocks=1050/1050 silent=1050 signal=0 left=0 right=0 same=0 transport=stop monitoring=0 windows=1/1 of 1 held=10021/10000ms report rec.editorReady=1 (+1) rec.editorFallback=0 (+0) rec.panelOpens=1 (+1) rec.panelCloses=1 (+1) rec.pageCalls=1 (+1) | three-opens: blocks=1651/1651 silent=1651 signal=0 left=0 right=0 same=0 transport=stop monitoring=0 windows=3/3 of 3 held=5000/5000ms shots=1/1 report rec.editorReady=4 (+3) rec.editorFallback=0 (+0) rec.panelOpens=4 (+3) rec.panelCloses=4 (+3) rec.pageCalls=4 (+3)
```

| State | Windows opened / closed | `win_held` | Ready counter | Shots | Report |
|---|---|---|---|---|---|
| `warm-up` | 1 / 1 | 10021 of 10000 | 0 to 1 (+1) | none: no `shots` in its facts, no `shots=` in its line | fallback 0 to 0, opens 0 to 1, closes 0 to 1, calls 0 to 1 |
| `three-opens` | 3 / 3 | 5000 of 5000 | 1 to 4 (+3) | `shots=1/1` | fallback 0 to 0, opens 1 to 4, closes 1 to 4, calls 1 to 4 |

- **One image.** The shot was asked for at 4000 ms (`held` 4013, `wallMs` 4097) in the first of the three windows, the
  one that opened first, and the state has exactly one image, `three-opens-4000.png` (455932 bytes, 1120 x 727, the same
  `view` and DPI as in section 1; hash and size equal the facts). The second and third windows of the state were held and
  closed without a shot, and the state has no other file. The image shows the editor complete.
- **The windows.** `windows=3/3 of 3`, the shortest of the three holds 5000 ms, and the ready counter grew by 3: the shot
  taken in the first window did not disturb the other two.
- **The state without `capture`** is as in the record before this one: no `shots` in its facts and no `shots=` in its line.

## 3. Keeping the work directory

The configuration of section 1, run with `-KeepWork` and `-NoNegative`: PASS, the row 21.7 s, `held=10013/10000ms
shots=3/3`, the shots at 300, 2000 and 8000 ms asked for at `held` 395, 2005 and 8013 (`wallMs` 477, 2087 and 8095).

- **In the work directory** (a `<stamp>-run1` directory of the round) stayed, besides the files of the learn and of the
  scenario, the shot directory `editor-shots.shots` with, for each of the three shots, a request file (`.req`, 1 byte) and
  an answer file (`.done`, 48 bytes); no error file (`.err`) and no PNG. The directory was not removed after its images
  were moved out.
- **The images** are in `renders/<run stamp>/run1/editor-shots.shots/`, with `bytes` and `sha256` equal to the files. The
  300 ms image was byte for byte the one of section 1 (same size, same hash); the 2000 and 8000 ms images have other
  hashes than those of section 1, with sizes within 30 bytes of theirs and of each other.
- **Without `-KeepWork`** (sections 1, 2 and 5) the work directory of a green round had no `.shots` directory and nothing
  else left of it.

## 4. Configurations refused before REAPER starts

Three configurations of one state with `windows` set so that they must be refused, each given to `run.ps1` (with the
private configuration directory, the plugin directory and a new empty result directory) and to `doctor.ps1 -Config`. All
three exit 64 with `USAGE` in 1.5 to 1.7 s (`run.ps1`) and 0.9 to 1.0 s (`doctor.ps1`), with the same message from both. No
`reaper.exe` was running before or after each call, the result directory stayed empty (no result file, no work directory),
and a listing with sizes and times of the private configuration directory and of the default resource directory was the
same before and after each:

| Configuration | Message |
|---|---|
| `capture` `[300]`, no `holdMs` | `config.scenarios[0].states[0].windows.capture: shots are taken while the window is held open: it needs holdMs above 0` |
| `capture` `[12000]`, `holdMs` 10000 | `config.scenarios[0].states[0].windows.capture: 12000 ms is after the hold of 10000 ms` |
| `capture` of nine offsets, `holdMs` 10000 | `config.scenarios[0].states[0].windows.capture: has more than 8 items` |

Each message follows `USAGE: config has 1 problem(s): `. The other limits (32 shots in a scenario, none in a negative
case) were not run.

## 5. Timing

The state of section 1 without `capture` (`windows` otherwise the same, `-NoNegative`), run twice in the same session,
against the same state with it:

| Run | Row | `win_held` | Blocks, chain / device | Window of the device | Whole `run.ps1` call, with the listings of the default resource directory |
|---|---|---|---|---|---|
| with three shots, negative cases | 21.4 s | 10009 | 1061 / 1061 | 11.32 s | 79.6 s |
| with three shots, `-KeepWork` | 21.7 s | 10013 | 1056 / 1056 | 11.26 s | 32.0 s |
| without `capture` | 21.2 s | 10030 | 1049 / 1049 | 11.19 s | 31.4 s |
| without `capture` | 21.3 s | 10002 | 1047 / 1047 | 11.17 s | 31.2 s |
| warm-up, then three windows and one shot | 44 s | 10021, 5000 | 1050 / 1050, 1651 / 1651 | | 54.7 s |

- **The cost.** Three shots made the row 0.1 to 0.5 s longer (21.4 and 21.7 s against 21.2 and 21.3 s) and the window the
  device was counted over about 0.1 s longer; the two rows without `capture` differ by 0.1 s from each other, so the cost
  of three shots is a few tenths of a second at most, against a hold of 10 s. The hold itself was not longer (10009 and
  10013 against 10030 and 10002).
- **The chain and the device** ran the same number of blocks in every state of every run, with and without shots.
- **The learn launch** took 6.6 to 6.9 s in the four runs without the reminder, and 11.3 s in the run where the evaluation
  reminder ended the first launch and it was started once more.
- No step was ended by its time limit.

## Side effects

- REAPER's default resource directory was unchanged after every run, by the harness's own check (`defaultCfgDir`:
  `unchanged` true, 2413 entries, nothing changed or unreadable, in all five) and by a listing of it with sizes and times
  taken before and after each call, the three refusals included (the same 2413 entries, with the same hash of the
  listing, before the first call, after the last and after every one between).
- The module check passed in every round (no tested binary was loaded from anywhere but the private copy, in 9, 2, 2, 2
  and 2 launches, no other plugin module), `reaperProcessesLeft` was 0 and `stillRunning` false in every round, and no
  `reaper.exe` was running after the last run. No `reaper.exe` of another job was running before any of the starts: the
  runner looked before every call and did not start one when it found any.
- The images show what the plugin drew in its window and were looked at once; they stayed in the result directory and are
  not part of the repository.
- The web view of the build keeps its own data in the user's local application data, which the harness does not redirect
  ([SAFETY.md](../SAFETY.md#plugin-reports-and-windows) says so). These runs did not redirect it, and what the web view
  wrote there was not looked at.
- Every result file lists both GUI locks, the default one and the other test's.

## What the documents say now

The documents said what the runs found: the line with ` shots=T/N`, the facts' `shots` and their fields, the images' place
and names, the usage errors, the work directory with and without `-KeepWork`, and that an image is never judged (the
300 ms one was a taken shot with an unfinished view). One thing was added:

- [CONFIG.md](../CONFIG.md#transport) has a paragraph of what was measured here (the image size and the view, the time
  between an offset and the shot, what the shots cost), linking to these notes.

No statement of the documents was contradicted.

## Known limitations

- One machine, one REAPER version, one Windows version, one display scale (96 DPI); the Dummy Audio device only, at 48 kHz
  and block 512; transport `stop`, unarmed, monitoring off only. The service's handling of other scales is not shown.
- One plugin's test build with one kind of editor, a web view, in a floating window opened by the harness. A JSFX window
  (no view, `view` null), a window of another kind of plugin or a docked window was not tried.
- A shot not taken (a late answer, an error answer, no window or more than one) was not provoked on a real REAPER; only
  shots that were taken are shown here. The limits of 8 offsets a state (refused, section 4), 32 a scenario, 4096 x 4096
  pixels, 10 s an answer and 64 MiB a file were not run to the end.
- The claim that a window in front of the held one is not in the image was not tried here: nothing was put in front of it.
- The lengths of the message loop's turns were not measured: that the 300 ms shot came latest (24 and 95 ms after its
  offset) and that `wallMs` ran 73 to 84 ms ahead of `held` is explained in section 1 by the driver's rule, not shown
  turn by turn.
- Two rows with shots and two without: the cost in time is a few tenths of a second at most and not more exactly known.
- The built-in negative cases ran with the first run only; the others used `-NoNegative`.
- The images, the build's report fields and variable, and the build itself are not part of the repository.
