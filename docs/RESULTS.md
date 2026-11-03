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
Plugin hashes are cut to their first 12 hex digits.

## Top level

| field | type | |
|---|---|---|
| `schema` | integer | `1`; changes when a field changes meaning or goes away |
| `tool` | string | `reaper-harness` |
| `config` | string | `name` of the configuration |
| `buildLabel` | string | `-BuildLabel`, or derived from the plugin hashes: up to five plugins their hash prefixes joined by `-`, more plugins the first 12 hex digits of one hash over all of them |
| `startedUtc` | string | ISO 8601 |
| `reaper` | string | product version of `reaper.exe` (empty when not found) |
| `verdict` | string | `PASS`, `FAIL`, `INCOMPLETE` or `SKIPPED`: the worst round verdict, at least `INCOMPLETE` when `error` is set |
| `launches` | integer | REAPER starts over all rounds |
| `skipReasons` | string[] | why the suite did not run (empty otherwise) |
| `locks` | string[] | the GUI lock set, in the order taken |
| `extensions` | string[] | registered extension names |
| `plugins` | object[] | `id`, `bundle`, `name` (as REAPER shows it), `version`, `classId`, `sha256` (12 hex digits of the binary's hash) |
| `pluginPath` | string | how `vstpath64` was written |
| `scanShield` | object | `directories`, `files` (scanned outside the private directory), `added`, `replaced`, `removed`, `unshielded` |
| `runs` | object[] | one per round |
| `error` | string or null | why the run stopped on an unexpected error (paths masked); null otherwise |

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
| `moduleCheck` | object | `status`, `detail`, `launches`, `foreign` (tested binaries seen from elsewhere, with the launch), `otherPlugins` (count of other `.vst3` / `.clap` modules seen) |
| `scenarios` | object[] | the rows, in run order |
| `stoppedBecause` | string | only when no further round ran: the default resource directory changed, could not be listed in full, a process could not be ended, or the round stopped on an unexpected error |

## A row (`scenarios[]`)

| field | type | |
|---|---|---|
| `id` | string | scenario id; `learn` for the learn launch (first, when any scenario needs it); `round-error` (kind `internal`, last) when the round stopped on an unexpected error |
| `kind` | string | |
| `status` | string | `PASS`, `FAIL` or `INCOMPLETE` |
| `seconds` | number | |
| `detail` | string | one line; for renders the comparer line (`identical= lag= maxdiff= head= frames= channels= rate= format= nonfinite= peak=`) |
| `facts` | object | some kinds only; `learn`: `variants`, `modules` (`Proven`, `Foreign` or `Unseen`), `binaries` (file name → `Private` / `Foreign` / `Unseen`) |

Negative rows also have `negative` (true), `builtin`, `expected` (the expected outcome) and `observed`; their
`status` is PASS only when the observed outcome and the reason both match the case.

## Example (shortened)

```json
{
  "schema": 1, "tool": "reaper-harness", "config": "my-plugin", "buildLabel": "3f2a9c41b0de-77e10c5a9b13",
  "startedUtc": "2026-11-01T09:12:44.1234567Z", "reaper": "7.82", "verdict": "PASS", "launches": 31,
  "skipReasons": [], "locks": ["Local\\ReaperHarness-gui"], "extensions": [],
  "plugins": [ { "id": "gain", "bundle": "My Gain.vst3", "name": "VST3: My Gain (Me)", "version": "1.2.0",
                 "classId": "5A1B2C3D4E5F60718293A4B5C6D7E8F9", "sha256": "3f2a9c41b0de" } ],
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
        "facts": { "variants": 2, "modules": "Proven", "binaries": { "My Gain.vst3": "Private" } } },
      { "id": "chain-offline-48000", "kind": "render", "status": "PASS", "seconds": 4.2,
        "detail": "identical=yes lag=0 maxdiff=-inf head=-inf frames=192000/192000 channels=2/2 rate=48000/48000 format=float32/float32 nonfinite=0/0 peak=0.00/0.00" },
      { "id": "neg-offset-1-sample", "kind": "render", "negative": true, "builtin": true, "expected": "FAIL", "observed": "FAIL",
        "status": "PASS", "seconds": 3.9, "detail": "identical=no lag=1 maxdiff=0.00 ..." }
    ]
  } ]
}
```
