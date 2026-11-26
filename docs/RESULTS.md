# Result files

Every run that got past the guards writes one JSON file (UTF-8, no BOM):
`<ResultDir>/<yyyyMMdd-HHmmss>-<config name>-<build label>.json`. A SKIPPED run writes one too, with the reasons.
Runs refused by a guard or stopped by a usage error (exit 64) write nothing. A run that stops on an unexpected error
past the preflight writes its file, with `error` set and a verdict of at least INCOMPLETE; an error before that only
reaches the console (exit 2). When the file itself cannot be written, the console says so and the verdict stands: a FAIL
stays a FAIL (exit 1), anything else has no record and so no conclusion (exit 2).

Local paths never appear in a result file: drive paths and UNC paths in any text, the `facts` of a row included, are
replaced by `<path>`. A path can hold spaces, apostrophes, semicolons and commas, so what ends it is a closing quote,
a character no file name can have, or the end of the line; whatever follows an unquoted path on its line goes with it.
A single quote is only taken as the closing one when no `\` or `/` comes after it on that line (otherwise it was an
apostrophe inside a name, and the path goes on).
Plugin hashes are cut to their first 12 hex digits. Two kinds of hash are written in full, because they identify data
of the user's own and not an installed product: those of the files a run was given (source files, the configuration
file) and those of the files and project text a run made (kept renders, the plugin block of a kept render or of a
parameter listing). A hash says nothing about the content it was taken of.

## Top level

| field | type | |
|---|---|---|
| `schema` | integer | `1`; changes when a field changes meaning or goes away |
| `tool` | string | `reaper-harness` |
| `toolVersion` | string | the version of the harness (`0.1.0`) |
| `toolCommit` | string or null | the commit the harness ran from (40 hex digits), read from its own `.git` without running git: a `.git` directory or a `gitdir:` file (a worktree), `HEAD` as a commit or as a branch found as a loose ref or in `packed-refs`; null for anything else (no `.git`, an unusual layout). Changes not committed are not detected: the commit does not prove the code was exactly that |
| `config` | string | `name` of the configuration |
| `buildLabel` | string | `-BuildLabel`, or derived from the plugin hashes: up to five plugins their hash prefixes joined by `-`, more plugins the first 12 hex digits of one hash over all of them |
| `startedUtc` | string | ISO 8601 |
| `reaper` | string | product version of `reaper.exe` (empty when not found) |
| `verdict` | string | `PASS`, `FAIL`, `INCOMPLETE` or `SKIPPED`: the worst round verdict, at least `INCOMPLETE` when `error` is set |
| `launches` | integer | REAPER starts over all rounds |
| `skipReasons` | string[] | why the suite did not run (empty otherwise) |
| `locks` | string[] | the GUI lock set, in the order taken |
| `extensions` | string[] | registered extension names |
| `plugins` | object[] | VST3: `id`, `bundle`, `name` (as REAPER shows it), `version`, `classId`, `sha256` (12 hex digits of the binary's hash); JSFX: `id`, `jsfx`, `name`, `sha256` (of the file) |
| `states` | object[] | the named states of the configuration: `plugin`, `state`, `sha256` (12 hex digits of the hash of the block); never the block itself |
| `sources` | object[] | the WAV files the layouts of the picked scenarios name, each once, as checked before the start ([CONFIG.md](CONFIG.md#source-files); a `transport` scenario checks and lists its file without playing it): `path` (relative to the configuration file, parts joined by `/`), `sha256` (all 64 hex digits: the files are the user's own, not plugins), `frames`, `channels`, `sampleRate`, `format`; empty when there are none |
| `manifest` | string or null | `renders/<run stamp>/manifest.jsonl` when a scenario with `keep` wrote a line ([kept renders](#kept-renders)); null otherwise, also when only collected [probe](CONFIG.md#probes) files are there |
| `pluginPath` | string | how `vstpath64` was written |
| `scanShield` | object | `directories`, `files` (scanned outside the private directory), `added`, `replaced`, `removed`, `unshielded` |
| `runs` | object[] | one per round |
| `error` | string or null | why the run stopped on an unexpected error (paths masked); null otherwise |
| `listing` | object or null | the parameter listing of `run.ps1 -List params` ([parameter listing](#parameter-listing)); null for any other run |

## A round (`runs[]`)

| field | type | |
|---|---|---|
| `index` | integer | 1-based |
| `seconds` | number | |
| `verdict` | string | worst of the rows and the module check; FAIL when the default resource directory was seen to change or a process this round started was left that no launch reported; else INCOMPLETE when part of that directory could not be listed or a process could not be ended |
| `launches` | integer | REAPER starts in this round |
| `counts` | object | rows per outcome: `PASS`, `FAIL`, `INCOMPLETE`, `SKIPPED` |
| `defaultCfgDir` | object | `unchanged` (bool), `entries` (listed before), `changed` (up to 8 entries seen to change, `added:` / `removed:` / `changed:` + relative path), `unreadable` (up to 8 entries that could not be listed, `.` for the directory itself; `unchanged` is false when there are any) |
| `reaperProcessesLeft` | integer | processes this round started that are still there after it, recognised by process ID and start time (must be 0); a `reaper.exe` of somebody else is not counted |
| `stillRunning` | boolean | a process of this round could not be ended by the watchdog: its GUI locks stay held and nothing was started after it (must be false) |
| `retries` | object[] | launches done once more because the evaluation licence reminder ended them ([SAFETY.md](SAFETY.md#dialogs)): `label` (the scenario and step), `reason` (`license-nag`); empty when there were none |
| `moduleCheck` | object | `status`, `detail`, `launches`, `foreign` (tested binaries seen from elsewhere, with the launch), `otherPlugins` (count of other `.vst3` / `.clap` modules seen) |
| `scenarios` | object[] | the rows, in run order |
| `stoppedBecause` | string | only when no further round ran: the default resource directory changed, could not be listed in full, a process could not be ended, or the round stopped on an unexpected error |

## A row (`scenarios[]`)

| field | type | |
|---|---|---|
| `id` | string | scenario id, after matrix and variant expansion; `learn` for the learn launch (first, when any scenario needs it), `learn.1` … `learn.<n>` when learning took several launches ([`learnBatchSize`](CONFIG.md#limits)), one row each; `params` (last) in a [parameter listing](#parameter-listing); `round-error` (kind `internal`, last) when the round stopped on an unexpected error. A scenario that did not run for want of learned blocks says why and names the learn row: `not run: learning the plugin blocks it needs did not succeed (see the learn.2 row)` |
| `kind` | string | |
| `status` | string | `PASS`, `FAIL` or `INCOMPLETE` |
| `seconds` | number | |
| `detail` | string | one line; for renders the comparer line (`identical= lag= maxdiff= head= frames= channels= rate= format= nonfinite= peak=`, then `rms=` and `nan= inf=` when they apply), then ` \| stem <track>: <its line>` per stem, then ` \| report <plugin>.<field>=<end> (+<growth>)` when the render is judged by a report, then `; probe: <n> files collected, <bytes> bytes` (`1 file` when it is one) and what was not collected with [probe](CONFIG.md#probes); `device` and `savereopen` end with `states saved back unchanged: <plugin> <state> <sha256>, ...` when the layout has states; `transport`: one part per state, joined by ` \| ` ([CONFIG.md](CONFIG.md#transport)), then `; shots: ...` when an image could not be kept or nothing was collected (`nothing collected: the capture service did not stop in time`, or `... the shot directory was replaced by a link or junction`) |
| `facts` | object | some kinds only; `learn`: `variants` (plugin settings in this launch), `batch` and `batches` (this launch of how many), `modules` (`Proven`, `Foreign` or `Unseen`, over the binaries of the plugins of this launch; `NoBinary` when they are all JSFX, so there is no binary to prove; a separate pass over every installed binary looks for one loaded from outside the private copy, so a row can say `Proven` and still be INCOMPLETE for the binary of another plugin, as its detail says), `binaries` (file name → `Private` / `Foreign` / `Unseen`, the same binaries), `states` (the states learned: `plugin`, `state`, `sha256`), `learned` (the settings taken from it: those that failed nothing, of plugins proven in it); a launch not started, or one that threw, has only `variants`, `batch`, `batches` and `learned` (0); a row of a variant: `variant` and `baseScenario` (the id as written), also when it did not run; `device`, `savereopen` (before the first reopen) and `transport` with a plugin whose `expectPdc` is `"report"`: `pdc`, per such FX `track`, `index`, `plugin` and `pdc` (the samples it reported, null when there was no reading), on a row that passed or is INCOMPLETE for want of a reading (a FAIL row, or one whose launch or render failed, has none); `transport`: `track`, `runFxWhenStopped`, `runFxAfterStopMs` (REAPER's `runafterstop` as read), `settleSamples` (as used), `feed` (`source`: the file or `test signal`, `sha256`, `channels`; null without a feed), `states` (per state `name`, `transport`, `arm`, `monitor`, `windowSamples`, `status` (`PASS`, `FAIL`, `INCOMPLETE` or `recorded`), `problems`, and the numbers (none when the state was not observed): `clock`, `clock_samples`, `blocks`, `samples`, `silent`, `signal`, `left`, `right`, `equal`, `fed`, `fed_samples`, `playstate`, `arm`, `monitor`, `monitoring`; `win_open` and `win_closed` with `windows`; `win_held` with `windows.holdMs` (the shortest time a window that opened was held open, in ms; 0 when none opened); `shots` with `windows.capture` ([CONFIG.md](CONFIG.md#transport)), one per offset in order: `at` (the offset), `held` (the hold's time in ms when the driver asked for it, by the message-loop clock of the hold) and `wallMs` (wall-clock ms from when the window was first seen shown to that moment; both null when the driver did not ask), `name` (`<state>-<ms>.png`), `taken`, `problem` (why it was not taken, or could not be kept; null otherwise), `path` (relative to the result directory: `renders/<run stamp>/run<round>/<id>.shots/<name>`; null for a shot not taken or not kept), `bytes` and `sha256` of the moved file, `width` and `height` (of the image: the window's client area, in pixels), `view` (`x`, `y`, `w`, `h`: where the plugin's view is, in image coordinates, so `y` is the height of REAPER's row of controls above it; null when REAPER showed none, as for a JSFX) and `dpi` (of the window); a row that ended before its states were judged lists them in `facts.shots` instead, with `state`, and `held` and `wallMs` null: only the images whose answer checks out, moved all the same (none when nothing was collected); `report` with a report: plugin → field → `start`, `end`, `delta`, also in a state without `expect.report` when a plugin of the layout declares a report); `render` judged by a report: `report`, the same; `render` with `keep`: `kept`, its line of the manifest with the paths relative to the result directory ([kept renders](#kept-renders)); `render` whose residual is reported (`maxDiffDb: "report"` on the scenario or on a stem compared with the reference, [CONFIG.md](CONFIG.md#reported-residuals)): `comparison`: `against` (`dry`, `repeat` or `variant`), `master` (the residual of the master; null when its comparison could not be made: a file missing or unreadable) and `stems` (per stem compared with the reference, `track` and then its residual; a stem judged by a number is listed too, with `reported` false, and a stem whose comparison could not be made has `track` only); a residual is `reported`, `identical` (format, rate, channels, frames and every sample bit for bit), `lag` (where the residual was measured: the expected lag), `bestLag` (the least-squares best lag within ±`limits.lagSearch`, a diagnostic, never judged, and what `lag=` of the line shows; null when the two cannot be compared), `maxDiff` (the largest absolute difference at `lag` over the finite pairs, linear; null when nothing was measured), `residualDb` (it in dBFS, 6 decimals; null when 0 or null), `residualRmsDb` (the RMS of the difference against the RMS of the reference over the same pairs, in dB, 6 decimals; null when either is 0), `maxDiffFrame` and `maxDiffSeconds` (where the largest difference is: a frame of the reference, and seconds to 6 decimals; null when nothing differs), `firstDiffFrame` (the first frame of the reference that differs; null when none does), `frames` and `referenceFrames`; a value that cannot be given is null, never NaN; a render that is judged has no `comparison`, and neither has one whose render or reference failed (it is INCOMPLETE, with the reason in its detail); `render` with a [tail](CONFIG.md#tails): `tail`: `seconds`, `frames` (at the scenario's rate), `renderFrames` (the length the master and every stem were checked to have), `endPeakDb` (the peak of the last 100 ms of the master in dBFS, 6 decimals, only recorded; null when that end is silent or the file could not be read) and `stems` (per stem `track` and `endPeakDb`); `render` with [probe](CONFIG.md#probes): `probe`: `variables` (per variable `name`, `plugin`, `kind` (`file` or `dir`), `path` (the file as configured), `sha256` and `bytes` of the file as checked before the start (these three null for a directory), `min` (null for a file)), `pid` (the REAPER process of the render, to match file names that carry a pid; after a [licence reminder retry](SAFETY.md#dialogs) the retry's; null when none was started), `dir` (where the files went, relative to the result directory: `renders/<run stamp>/run<round>/<id>.out`; null when none was moved), `files` (per file moved, in name order: `name`, `bytes`, `sha256` of the moved file (both null when it could not be read back: the detail says `collected, but <name> could not be read`), `temporary` (a name ending in `.tmp`)), `collected`, `bytes` and `temporary` (their counts and total size), `left` (entries that stayed in the work directory; null when the directory could not be looked at); `probe` is null when collection stopped on an unexpected error (the detail says so) |

A render with [probe](CONFIG.md#probes) is PASS when it passed its audio criteria and at least `min` files were
collected. The harness never reads the files: whether the plugin's own script ran correctly is for the plugin's author
to read in them.

Negative rows also have `negative` (true), `builtin`, `expected` (the expected outcome) and `observed`; their
`status` is PASS only when the observed outcome and the reason both match the case.

## Kept renders

A run whose scenarios have `keep` ([CONFIG.md](CONFIG.md#keep)) writes `<ResultDir>/renders/<run stamp>/`:
`run<round>/<id>.wav` and `run<round>/<id>-stem-<track>.wav` (and `<id>-first.wav` with its `-first-stem-<track>.wav`
for a repeat that [reports](CONFIG.md#keep) its residual), and `manifest.jsonl`, UTF-8 without BOM, one JSON
object per line, appended and flushed when each kept scenario is done. Paths in a line are relative to the manifest's
directory. Files a plugin wrote into its [probe directory](CONFIG.md#probes) go to `run<round>/<id>.out/` there,
with or without `keep`, and the shots of a [held window](CONFIG.md#transport) to
`run<round>/<id>.shots/<state>-<ms>.png`, with or without `keep` as well; the first scenario that keeps or collects
makes the manifest. When only collection used it, it stays empty, `renders/<run stamp>/` holds only those directories
and that empty `manifest.jsonl`, and the result file's `facts.probe` and the states' `shots` are the record: a
transport row has no manifest line. Each line:

| field | |
|---|---|
| `schema` | `1`; changes when a field changes meaning or goes away |
| `runStamp`, `round` | the run stamp (`yyyyMMdd-HHmmss`, the one of the work directories) and the round, from 1 |
| `scenario`, `baseScenario` | the scenario id, and the id it was written with (before a matrix or its variants expanded it) |
| `variant` | the id of the [variant](CONFIG.md#variants), null without one |
| `layout`, `kind` | the layout and `render` |
| `status`, `detail` | the outcome of the row, after keeping: `; not kept: <reason>` when a file could not be moved there, `; kept, but <file> could not be read: <reason>` when a kept file could not be described (its fields stay null from there on); either makes the row INCOMPLETE, a FAIL stays FAIL |
| `output` | the master: `path` (null when nothing was kept), `sha256` (all 64 hex digits, of the whole file: REAPER writes the time of the render into the file, so two renders of identical audio differ here; compare decoded samples to tell whether the audio is the same), `frames`, `channels`, `sampleRate`, `format`, `peakDb` (over the finite samples; null when none is above zero), `nanCount`, `infCount` |
| `stems` | the same per stem, with `track` first |
| `render` | `sr`, `block`, `mode`, `channels`, `tailSeconds` and `tailFrames` (0 without a [tail](CONFIG.md#tails)), `endPeakDb` (as in the row's `tail`; null without a tail), `host` (`anticipativeFx`, `runFxWhenStopped`, `informOfflineState`) |
| `comparison` | null unless the residual is [reported](CONFIG.md#reported-residuals), and null too when the render or its reference failed (the row is INCOMPLETE, and a first render that was made stays a work file); otherwise the row's `comparison` ([above](#a-row-scenarios)) and `first`: null when the first render of the repeat is not to be kept, else that render, kept next to the second and described like `output`, with its `stems` (as for `output`, `path` is null for a file that could not be moved, and the row is INCOMPLETE then); its `sha256` differs from the second's even when the audio is identical (the time of the render is in the file) |
| `probe` | null without [probe](CONFIG.md#probes); otherwise the row's `facts.probe` ([above](#a-row-scenarios)), with `dir` relative to the manifest's directory (`run<round>/<id>.out`) |
| `sources` | per source track of the layout: `track`, `file` (as in `sources` of the result) or null, `signal` (`seconds`, `seed`, `noiseDb`, `sine` with `hz` and `db` or null) or null |
| `fx` | per FX of the layout, track by track in order: `track`, `index` (on the track, from 0), `plugin`, `bundle` (VST3) or `jsfx`, `name` (as REAPER showed it when it was learned), `version` (of a VST3, from its `moduleinfo.json`, as in a [parameter listing](#parameter-listing); null for a JSFX), `sha256` (12 hex digits of the binary or the JSFX file), `bypass` (as rendered), `state` and `stateSha256` (12 hex digits, as in `states` of the result) or null, `blockSha256` (all 64 hex digits of the plugin block exactly as written into the project, each line indented by six spaces and ended by a line feed, UTF-8: project text the run wrote, which ties the values read back to what was rendered; it is not a hash of a plugin binary; a [parameter listing](#parameter-listing) of the same plugin has the same one when this FX has no `params` and no `state`, since the listing hashes the block at the plugin's defaults, and when the plugin saves the same state every time: some store a time or a random id; the two were equal for the one plugin this was measured on, see the [validation record](validation/2026-11-20-param-listing.md#3-the-listings-block-hash-against-the-manifests)), `params` (per parameter asked for, the variant's on top of the layout's: `name`, `normalized` and `display` as asked (`display` null when not given), `readNormalized` and `readDisplay` as REAPER read them back, text), `pdc` (the latency REAPER reported in samples, null when it reported none) and `pdcReadAt` (`sr` 48000, `block` 512: the learn launch, where it was read, not necessarily the render's settings) |
| `reaper`, `toolVersion`, `toolCommit`, `buildLabel` | as in the result |
| `config` | `name` (the file name of the configuration) and `sha256` (all 64 hex digits of the bytes the run read and parsed, not of the file as it is later) |

Everything the harness read back comes from the learn launch of the round: the latency of a plugin can differ at
the rate and block of a render.

A line maps back to its condition by `baseScenario` and `variant`, with `render` (`sr`, `block`, `mode`) for the legs
of a matrix; the values the variant asked for are in `fx[].params`, the settings of the dry variant in `fx[].bypass`.

Every string of a line is masked like the rest of a result file (a reason can hold an exception text with a path in
it, a name comes from the plugin). A line a write that failed left unfinished (a full disk) stays as it is, and the
next line starts on a line of its own after it; the row of that scenario says its line could not be written. Read the
manifest line by line and treat a line that does not parse as missing.

## Parameter listing

A listing (`run.ps1 -List params`, [USAGE.md](USAGE.md#listing-parameters)) writes its result file as
`<yyyyMMdd-HHmmss>-<config name>-<build label>-list-params.json`. Its one round has the `learn` row and a `params` row
(kind `params`, `facts`: `plugins`, `listed`, `params`, `sweeps`, `notFound`), and `listing` holds:

| field | |
|---|---|
| `kind` | `params` |
| `values` | the values of the sweep, null without one |
| `readAt` | `sr` 48000, `block` 512: the learn launch, where everything was read |
| `plugins` | per plugin of the configuration (or of `-ListPlugin`), in its order: `id`, `bundle` (VST3) or `jsfx`, `sha256` (12 hex digits), `name` (as REAPER shows it), `class` (`name`, `vendor`, `cid` from `moduleinfo.json`; null for a JSFX), `classFrom` (`moduleinfo`, null for a JSFX), `version`, `status`, `listed`, `why` (null when there is nothing to say), `blockSha256` (the hash of its block as learned at its defaults, taken like `blockSha256` of a kept render ([above](#kept-renders)): the two are equal for an FX of that plugin with no `params` and no `state`, when the plugin saves the same state every time), `pdc` (the latency REAPER reported at the learn launch), `nparams` (the count the learn step read), `paramCount` (the parameters listed), `hostBy` (`ident` and / or `names`: the rules of `host` below that told REAPER's own parameters), `params`, `sweeps`, `notFound` (swept names the plugin does not have) |
| `plugins[].params[]` | `index` (from 0), `name`, `normalized`, `display`, `ident` (REAPER's identifier, null when it gives none; REAPER 7.82 gives `<index>:<number>` to a plugin's own parameters and `<index>:bypass`, `<index>:wet`, `<index>:delta` to its own), `sameNameAs` (the index of the first parameter of that name, null for the first), `host` (one of REAPER's own `Bypass`, `Wet` and `Delta`: by `ident`, one that is `:bypass`, `:wet` or `:delta`, case-sensitive, with nothing or the parameter's own index in front, such as `612:wet` of parameter 612; without `ident`, one of the last three when they are named exactly `Bypass`, `Wet` and `Delta`), `exact` (the name has no control character and is valid UTF-8), `masked` (a path in the name or display text was masked), `settable`, `displayUsable` (the display text is exact, at most 128 characters and has no path), `problem` (why it could not be read cleanly, null otherwise) |
| `plugins[].sweeps[]` | `name`, `index` (the parameter learning sets for that name), `values[]`: `normalized` (as asked), `readNormalized` and `display` (as REAPER read them back), `displayUsable` |

A plugin is PASS when it was listed cleanly and every swept name was found, FAIL when a swept name is not one of its
parameters, and INCOMPLETE when it was not listed (`why`: its learn entry did not pass, the count of its parameters
changed while it was read, an instance to sweep could not be added or was not the plugin learned, the driver stopped
with an error) or some of its parameters could not be read cleanly (they are listed all the same, each with its
`problem`). The `params` row is the worst of them; with no plugin to list it is INCOMPLETE. Names and display texts
come from the plugin and are masked like any text of a result file.

## Example (shortened)

```json
{
  "schema": 1, "tool": "reaper-harness", "toolVersion": "0.1.0", "toolCommit": "0123456789abcdef0123456789abcdef01234567",
  "config": "my-plugin", "buildLabel": "3f2a9c41b0de-77e10c5a9b13",
  "startedUtc": "2026-11-01T09:12:44.1234567Z", "reaper": "7.82", "verdict": "PASS", "launches": 31,
  "skipReasons": [], "locks": ["Local\\ReaperHarness-gui"], "extensions": [],
  "plugins": [ { "id": "gain", "bundle": "My Gain.vst3", "name": "VST3: My Gain (Me)", "version": "1.2.0",
                 "classId": "5A1B2C3D4E5F60718293A4B5C6D7E8F9", "sha256": "3f2a9c41b0de" },
               { "id": "delay", "jsfx": "harness-pdc-delay", "name": "JS: reaper-harness PDC delay", "sha256": "9c0e5d27a1f4" } ],
  "states": [ { "plugin": "gain", "state": "quiet", "sha256": "60b1e4d2c7a9" } ],
  "sources": [ { "path": "audio/voice.wav", "sha256": "38377a01478d702ef0b6b01cfe2b71e3d3a9b2cec162b91e2df5e887de29da2d",
                 "frames": 2646000, "channels": 2, "sampleRate": 44100, "format": "pcm24" } ],
  "manifest": "renders/20261101-091244/manifest.jsonl",
  "pluginPath": "system VST3 directories first, the private plugins directory last",
  "scanShield": { "directories": 2, "files": 214, "added": 0, "replaced": 0, "removed": 1, "unshielded": 0 },
  "runs": [ {
    "index": 1, "seconds": 212.4, "verdict": "PASS", "launches": 31,
    "counts": { "PASS": 19, "FAIL": 0, "INCOMPLETE": 0, "SKIPPED": 0 },
    "defaultCfgDir": { "unchanged": true, "entries": 118, "changed": [], "unreadable": [] }, "reaperProcessesLeft": 0, "stillRunning": false,
    "moduleCheck": { "status": "PASS", "detail": "no tested binary was loaded from anywhere but the private copy in 31 launches",
                     "launches": 31, "foreign": [], "otherPlugins": 0 },
    "scenarios": [
      { "id": "learn", "kind": "learn", "status": "PASS", "seconds": 6.1,
        "detail": "2 plugin variants learned; every tested binary loaded from the private copy (module list and fx_ident)",
        "facts": { "variants": 2, "batch": 1, "batches": 1, "modules": "Proven", "binaries": { "My Gain.vst3": "Private" }, "learned": 2 } },
      { "id": "chain-offline-48000", "kind": "render", "status": "PASS", "seconds": 4.2,
        "detail": "identical=yes lag=0 maxdiff=-inf head=-inf frames=192000/192000 channels=2/2 rate=48000/48000 format=float32/float32 nonfinite=0/0 peak=0.00/0.00" },
      { "id": "neg-offset-1-sample", "kind": "render", "negative": true, "builtin": true, "expected": "FAIL", "observed": "FAIL",
        "status": "PASS", "seconds": 3.9, "detail": "identical=no lag=1 maxdiff=0.00 ..." }
    ]
  } ]
}
```
