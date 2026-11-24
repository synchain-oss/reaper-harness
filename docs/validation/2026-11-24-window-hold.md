# Validation: holding a plugin's window open (`holdMs`) on REAPER 7.82

Notes on running a [transport state](../CONFIG.md#transport) whose `windows` has `holdMs` on a real REAPER on 2026-11-24:
a plugin's private test build with a web view editor, whose editor needs seconds to start, has its floating window opened
and kept open, and what the build reports about it is judged. The notes say whether the hold is as long as asked and how
it reads in the line and the facts, whether the report of the build shows that the editor finished starting when the
window is held and does not when it is not, what a second and a third window cost in a scenario that has a warm-up state,
what a state without `holdMs` looks like, which configurations are refused before REAPER starts, and what a build whose
report lacks the field asked for gives. What the outcomes mean is in [RESULTS.md](../RESULTS.md). It follows the
[record of probe variables and collected files](2026-11-23-plugin-probe.md).

## Setup

| | |
|---|---|
| Plugin | a plugin's private test build with a web view editor (name withheld), VST3, Windows x64, binary hash prefix `cffb213fcefd`. It writes a report file when it is given the name of one in an environment variable, from a timer on REAPER's message thread (every 250 ms, only when something changed, and on prepare, release and destruction), with the id of its process and counters of the whole process: a ready counter (the editor's page finished starting), a fallback counter (it gave up and showed a fallback panel), counters of editor opens and editor closes, a counter of calls between the page and the plugin, and counters of prepares and of blocks. No probe variable was set |
| Older build | once (section 5), an earlier private build of the same plugin, binary hash prefix `90c8bc05f22b`, whose editor is known not to finish starting; it reports through the same variable |
| Third-party plugins | the builds above, used only for this check from private copies of their bundles in the plugin directories given to the runs; nothing was installed on the machine, and it says nothing about which plugins a machine has |
| Host | REAPER 7.82 x64, Dummy Audio device at 48 kHz and block 512, a private configuration directory, REAPER's default preferences with Run FX when stopped on |
| System | Windows 10 |
| Harness | the feature branch's commit `c969799eb9138194d71f8dc638a4eccdc5d919fd`, which every result file names as `toolCommit`; the commit that adds these notes changes documents only |
| Runs | four calls of `run.ps1` that start REAPER, each given the lock that other GUI tests on the same machine take next to the default GUI lock (the first with the eight built-in negative cases, the other three with `-NoNegative`); and two configurations that are refused (section 4), each given to `doctor.ps1 -Config` and to `run.ps1` |

The plugin was declared as in the [example of reports](../CONFIG.md#reports), with invented names for what the build
reports (the names of its fields and of its variable are not given here):

```json
"plugins": { "rec": { "bundle": "Recorder Test Build.vst3",
    "report": { "env": "RECORDER_REPORT_JSON",
                "fields": ["editorReady", "editorFallback", "panelOpens", "panelCloses", "pageCalls", "prepares", "blocks"],
                "pid": "pid", "periodMs": 250 } } }
```

Every scenario was a `transport` scenario of one layout, a track with `"source": true` (the transport step adds no items)
that has the plugin once, and states `stop`, `arm: false`, `monitor: "off"`, the default `samples` (2 s), and a
`windows` of `plugin: "rec"`. The criteria of a state that held its windows were, with `n` the number of windows:

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
| one window held 10 s | 0 | `learn` and 1 scenario, 8 negative cases: all PASS | PASS, 76.6 s, 9 starts (the learn launch was ended once by REAPER's evaluation reminder and done again) |
| a warm-up state, then three windows held 5 s each | 0 | `learn` and 1 scenario (2 states): PASS | PASS, 51 s, 2 starts |
| no `holdMs`, two scenarios | 0 | `learn` and 2 scenarios: PASS | PASS, 31 s, 3 starts |
| the older build, one window held 20 s | 2 | `learn` PASS, 1 scenario INCOMPLETE | INCOMPLETE, 38.4 s, 2 starts |
| two configurations (20 windows x 60000 ms, `holdMs` 60001) | 64 | none: refused, nothing started | 1.5 s each |

## 1. One window held 10 s

`hold-one`: one state, `windows` of `count` 1 and `holdMs` 10000, the criteria above with `n` 1. The row is PASS in
21.8 s:

```
hold-10s: blocks=1060/1060 silent=1060 signal=0 left=0 right=0 same=0 transport=stop monitoring=0 windows=1/1 of 1 held=10037/10000ms report rec.editorReady=1 (+1) rec.editorFallback=0 (+0) rec.panelOpens=1 (+1) rec.panelCloses=1 (+1) rec.pageCalls=1 (+1)
```

- **The hold.** `win_held` of the state's facts is 10037, 37 ms more than asked. The line and the facts say the same
  number. The window opened and closed once.
- **The report.** The ready counter went from 0 to 1 and the fallback counter stayed at 0: the editor finished starting
  while the window was held. The open and close counters read 1 and 1 after the window was gone, so the counters the
  plugin keeps for the process still held their values once the editor had been closed, which is what the
  [documents ask of a field](../CONFIG.md#transport) that is meant to show what the editor did. The counter of calls
  between the page and the plugin read 1 (judged as `{ "min": 1 }`, not as an exact number).
- **The device.** The chain ran 1060 blocks and the device 1060: the 10 s hold did not move the two apart (the tolerance
  `maxBlockDiff` is 4 by default).
- **The cost.** A row of this state took 21.8 s; the rows of the same window without `holdMs` (section 3) took 12.0 and
  12.1 s. The hold added about 10 s, which is what it was asked for.

## 2. A warm-up state, then three windows held 5 s

`hold-warm`: two states in one scenario. The first, `warm-up`, is the state of section 1 (`count` 1, `holdMs` 10000); the
second, `three-opens`, has `count` 3 and `holdMs` 5000 and the criteria with `n` 3. The row is PASS in 43.9 s:

```
warm-up: blocks=1057/1057 silent=1057 signal=0 left=0 right=0 same=0 transport=stop monitoring=0 windows=1/1 of 1 held=10020/10000ms report rec.editorReady=1 (+1) rec.editorFallback=0 (+0) rec.panelOpens=1 (+1) rec.panelCloses=1 (+1) rec.pageCalls=1 (+1) | three-opens: blocks=1654/1654 silent=1654 signal=0 left=0 right=0 same=0 transport=stop monitoring=0 windows=3/3 of 3 held=5018/5000ms report rec.editorReady=4 (+3) rec.editorFallback=0 (+0) rec.panelOpens=4 (+3) rec.panelCloses=4 (+3) rec.pageCalls=4 (+3)
```

| State | Windows opened / closed | `win_held` | Ready counter | Fallback counter | Opens | Closes | Page calls |
|---|---|---|---|---|---|---|---|
| `warm-up` | 1 / 1 | 10020 of 10000 | 0 to 1 (+1) | 0 to 0 | 0 to 1 | 0 to 1 | 0 to 1 |
| `three-opens` | 3 / 3 | 5018 of 5000 | 1 to 4 (+3) | 0 to 0 | 1 to 4 | 1 to 4 | 1 to 4 |

- The shortest of the three holds of the second state is 5018 ms, so every one of the three ran its time (the line
  shows only the shortest), and the ready counter grew by 3 over the three windows, one for each, held 5 s each after
  the first start of the process.
- The whole row is 43.9 s: the two states' settle times and observation windows, 10 s and 3 x 5 s of holding, and the
  readings.
- Both states had the same number of blocks on the chain and on the device (1057 and 1654).

## 3. Without `holdMs`: as before

Two scenarios with `count` 1 and no `holdMs`: `nohold-plain` has no `expect` at all, `nohold-read` has `expect.report`
with `{ "min": 0 }` on the five judged fields, which no counter can miss, only so that the line shows the readings. Both
rows are PASS in 12.0 and 12.1 s:

```
no-hold: blocks=188/188 silent=188 signal=0 left=0 right=0 same=0 transport=stop monitoring=0 windows=1/1 of 1
no-hold-read: blocks=190/189 silent=190 signal=0 left=0 right=0 same=0 transport=stop monitoring=0 windows=1/1 of 1 report rec.editorReady=0 (+0) rec.editorFallback=0 (+0) rec.panelOpens=1 (+1) rec.panelCloses=1 (+1) rec.pageCalls=0 (+0)
```

- **As before.** The line of both states ends with `windows=1/1 of 1` and has no `held=`; the facts of both have no
  `win_held`, and `win_open` and `win_closed` are 1 and 1. The state of `nohold-plain` is judged by its windows alone.
- **What the readings show.** Both states have `report` in their facts, `nohold-plain` as well: a plugin that declares a
  report is read around every state, judged or not. In both, a window closed after ten turns of the message loop left the
  ready counter at 0 and the fallback counter at 0 (0 to 0 each), the counters of opens and closes at +1 and +1, and
  the counter of calls between the page and the plugin at 0. The editor was opened and closed but did not get to
  finish starting, and had not given up either, which is the reason `holdMs` exists. (Recorded, not judged: the criteria
  of `nohold-read` cannot fail, and `nohold-plain` has none.)
- The chain and the device differ by 1 block in `nohold-read` (190 and 189), within the tolerance and as the
  [documents](../CONFIG.md#transport) say a difference of 1 to 2 blocks is seen with no window at all.

## 4. Configurations refused before REAPER starts

Two configurations of one state with `windows` set so that they must be refused, each given to `run.ps1` (with the private
configuration directory, the plugin directory and a new empty result directory) and to `doctor.ps1 -Config`. Both exit 64
with `USAGE` in 1.5 s (`run.ps1`) and 0.9 to 1.0 s (`doctor.ps1`), with the same message from both. No `reaper.exe` was
running before or after each call, the result directory stayed empty (no result file, no work directory), and a listing
with sizes and times of the private configuration directory and of the default resource directory was the same before and
after each:

| Configuration | Message |
|---|---|
| `count` 20, `holdMs` 60000 | `config.scenarios[0].states[0].windows: 20 windows held 60000 ms each is 1200000 ms of holding, more than 600000 in one state` |
| `count` 1, `holdMs` 60001 | `config.scenarios[0].states[0].windows.holdMs: must be between 0 and 60000` |

The limit itself: `count` 10 with `holdMs` 60000, which is exactly 600000, is accepted by `doctor.ps1 -Config` (exit 0,
`1 scenarios`). It was not run.

## 5. An older build of the plugin

The configuration of section 1 with `holdMs` 20000, run with the older build (hash prefix `90c8bc05f22b`) in the plugin
directory instead, as a negative: the editor of that build is known not to finish starting, so the ready counter was
expected not to grow. The row is INCOMPLETE (exit 2), 31.4 s:

```
hold-20s: blocks=1990/1990 silent=1990 signal=0 left=0 right=0 same=0 transport=stop monitoring=0 windows=1/1 of 1 held=20006/20000ms; no evidence: the report of rec is no evidence: it has no field editorReady
```

- The build writes a report to the same variable, but its file has no ready counter, the first field of the criteria it
  lacks: a report with a declared field missing is no evidence, INCOMPLETE and never a PASS, as
  [CONFIG.md](../CONFIG.md#reports) says. So the row cannot show the FAIL on the ready counter that was hoped for:
  catching a broken editor this way needs a build that reports the counter, and this one does not. One run; nothing
  further was tried.
- The hold itself was measured as for any other build: `held=20006/20000ms`, and the window opened and closed once. The
  holding does not depend on the report.

## 6. Timing

| Row | Holds | Row | Whole `run.ps1` call, with the listings of the default resource directory before and after |
|---|---|---|---|
| `hold-one` | 1 x 10 s | 21.8 s | 80 s (8 negative cases in the round) |
| `hold-warm` | 1 x 10 s, 3 x 5 s | 43.9 s | 54.9 s |
| `nohold-plain`, `nohold-read` | none | 12.0 s, 12.1 s | 34.3 s |
| `hold-old` | 1 x 20 s | 31.4 s | 41.6 s |

- The hold read 6 to 37 ms past `holdMs` (10037, 10020, 5018, 20006): a hold ends at the first turn of the message loop
  at which the time is up, and the figure is the shortest of a state's windows, rounded to a whole ms.
- A state without a hold took 12 s as a row (settle time 4.5 s with REAPER's default Run FX after stopping 4000 ms, the
  observation window, the two readings and closing the window); a hold adds its time to that. No step was ended by its
  time limit.
- A learn launch took 6.9 s in the three runs that had no reminder, and 11.3 s in the run where the evaluation reminder
  ended the first launch and it was started once more.

## Side effects

- REAPER's default resource directory was unchanged after every run, by the harness's own check (`defaultCfgDir`:
  `unchanged` true, 2413 entries, nothing changed or unreadable, in all four) and by a listing of it with sizes and times
  taken before and after each call (the same 2413 entries, with the same hash of the listing, before the first call, after
  the last and after every one between).
- The module check passed in every round (no tested binary was loaded from anywhere but the private copy, in 9, 2, 3 and 2
  launches, no other plugin module), `reaperProcessesLeft` was 0 and `stillRunning` false in every round, and no
  `reaper.exe` was running after the last run. No `reaper.exe` of another job was running before any of the starts.
- The web view of the build keeps its own data in the user's local application data, which the harness does not
  redirect ([SAFETY.md](../SAFETY.md#plugin-reports-and-windows) says so, and how a caller keeps a run off it). These runs
  did not redirect it, and what the web view wrote there was not looked at.
- Every result file lists both GUI locks, the default one and the other test's.

## What the documents say now

The documents said what the runs found: the line, the facts, the usage error with its message, and the report advice that
a field meant to show the editor's work must hold its value after the editor is gone (the counters here did). Two things
were added:

- [CONFIG.md](../CONFIG.md#transport) has a paragraph of what was measured here, and says that a plugin that declares a
  report is read around every state, so a state without `expect.report` has `report` in its facts too (it was seen in
  section 3, and [RESULTS.md](../RESULTS.md#a-row-scenarios) says it in its list of facts);
- the new paragraph links to these notes.

No statement of the documents was contradicted.

## Known limitations

- One machine, one REAPER version, one Windows version; the Dummy Audio device only, at 48 kHz and block 512; transport
  `stop`, unarmed, monitoring off only.
- One plugin's test build with one kind of editor, a web view. The web view's data folder was already in the user's
  profile (the build had been run on the machine before) and was not reset, so a start with no data folder at all was not
  tried: whether a first start in a new process finishes within less than 10 s, or a cold one within 10 s, is not
  shown. The three 5 s holds came after a warm-up in the same process, as the plugin's author advised.
- The hold ends at the first turn at which the message-loop time is up; the length of a turn was not measured, and the cap
  of 100 ms that a turn counts was not exercised: no stall of REAPER's main thread was provoked. The largest excess of a
  hold over its time was 37 ms.
- The built-in negative cases ran with the first run only; the others used `-NoNegative`.
- A hold of 600000 ms in one state, or a hold with the transport playing or an armed track, was not run.
- The build's report fields and variable, and the build itself, are not part of the repository.
