# Usage

Windows only, PowerShell 7.4 or later, an installed REAPER 7 (x64) and a REAPER licence under REAPER's own terms.
The harness drives REAPER in a real desktop session; run it on a machine you are logged in to, not over SSH or as a
scheduled task, and not on hosted CI runners. The self-test (`-SelfTest`) needs no REAPER and runs anywhere.

## 1. Create a private configuration directory

```powershell
pwsh doctor.ps1 -CfgDir D:\reaper-harness\cfg -Init
```

This creates the directory with a minimal `reaper.ini` (dummy audio device, version check off), an empty `plugins`
directory and the sentinel file. It only takes over a directory that does not exist, an empty one or one it
initialised before (whose `reaper.ini` it leaves alone; the run itself writes the keys it needs into it). It never
accepts anything under `%APPDATA%` (see [SAFETY.md](SAFETY.md)). Use one directory per machine and keep it for later
runs: the scan cache in it makes later starts fast.

The first launch in a new directory makes REAPER scan the plugin path. With the scan shield (see SAFETY.md) it does
not load third-party plugins, but it still lists them, which can take a minute on a machine with many plugins.

## 2. Write a configuration

Start from `tests/fixtures/config.json` and [CONFIG.md](CONFIG.md). Check it without REAPER:

```powershell
pwsh doctor.ps1 -Config my-plugin.json
```

## 3. Check the machine

```powershell
pwsh doctor.ps1 -CfgDir D:\reaper-harness\cfg -Config my-plugin.json -PluginDir D:\build\VST3
```

`-PluginDir` holds the `.vst3` bundles named in the configuration. This runs the same preflight as `run.ps1` and
never starts REAPER: REAPER found (`-ReaperExe`, default `%ProgramFiles%\REAPER (x64)\reaper.exe`), every bundle with
a readable `moduleinfo.json` and a Windows binary, no other `reaper.exe` running, no skip marker present.

### Listing parameters

To write `params` and `variants` ([CONFIG.md](CONFIG.md#variants)) you need the exact names of a plugin's parameters
and the normalized values that give the display texts you want. `run.ps1 -List params` reads them from REAPER:

```powershell
pwsh run.ps1 -List params -Config my-plugin.json -CfgDir D:\reaper-harness\cfg -PluginDir D:\build\VST3 -ResultDir D:\reaper-harness\results
pwsh run.ps1 -List params -ListPlugin eq -ListParam "Band 1 Gain" -ListValues 0,0.5,1 -Config my-plugin.json -CfgDir D:\reaper-harness\cfg -PluginDir D:\build\VST3 -ResultDir D:\reaper-harness\results
```

A listing is a run of one round that starts REAPER once, under every guard of a run (the private configuration
directory, the GUI locks, the module check, the default resource directory listed before and after): it installs the
plugins of the configuration (or those `-ListPlugin` names), adds each on a track of its own and saves the project as
learning does, then reads every parameter of each: its index, name, normalized value, display text and REAPER's
identifier. No scenario and no negative case runs. `doctor.ps1` still never starts REAPER. The configuration must be
complete and valid, layouts and scenarios included, though none of them runs; a minimal one:

```json
{
  "schema": 1,
  "name": "my-eq-listing",
  "plugins": { "eq": { "bundle": "My EQ.vst3" } },
  "layouts": { "one": { "tracks": [ { "name": "Voice", "source": true, "fx": [ { "plugin": "eq" } ] } ] } },
  "scenarios": [ { "id": "device", "kind": "device", "layout": "one" } ]
}
```

The console shows the `learn` and `params` rows and a line per plugin
(`eq: 214 parameters (3 of them REAPER's own, 205 settable), 3 names used more than once`); the result file is
`<time>-<config name>-<build label>-list-params.json`, with the listing in its `listing` field
([RESULTS.md](RESULTS.md#parameter-listing)).

A sweep (`-ListParam` for one name, `-ListParamFile` for up to 32) sets each named parameter, on an instance of its
own added for it with every other parameter at its default, to each value of `-ListValues` (default
`0,0.25,0.5,0.75,1`) and reads back the value REAPER took and the display text it shows. To turn that into `params`,
use the name as the key, a value's `readNormalized` as `normalized` and its `display` as `display` (when
`displayUsable`). With every other parameter at its default, a value can read otherwise in a chain where parameters
depend on each other; learning reads every setting back, and says so when it does not take.

Some parameters cannot go into `params`, and `settable` is false for them:

- a name used by more than one parameter: learning sets the first of them, so the others have `sameNameAs` (the index
  of the first) and are not settable;
- REAPER's own parameters: REAPER adds `Bypass`, `Wet` and `Delta` at the end of every plugin; REAPER 7.82 gives them the
  identifiers `<index>:bypass`, `<index>:wet` and `<index>:delta`, and a plugin's own parameters `<index>:<number>`
  ([validation record](validation/2026-11-20-param-listing.md)). A parameter is `host` when its identifier is
  `:bypass`, `:wet` or `:delta` (case-sensitive) with nothing or its own index in front (`612:wet` of parameter 612,
  not `5:wet` of parameter 6); a parameter without an identifier is `host` when it is one of the last three and they
  are named exactly `Bypass`, `Wet` and `Delta` (`hostBy` says which rule applied). REAPER's own are set through
  `bypass` of a variant, not through `params`;
- a name longer than 128 characters or with a control character, a name or display text with a path in it (masked),
  and a parameter that could not be read cleanly (`problem`).

Listing and sweeps run in the learn launch, within `limits.learnTimeoutSec` ([CONFIG.md](CONFIG.md#limits)): raise it
for a plugin with thousands of parameters or a large sweep. Measured on REAPER 7.82: the launch of a listing took 6.1 to 7.3 s
for plugins with 17, 86 and 614 parameters, with a sweep of two or three parameters at five values too, about as long as
a learn launch of the same plugin with no listing; a launch that REAPER's evaluation reminder ended was done once more and
took 10.1 to 13.8 s ([validation record](validation/2026-11-20-param-listing.md)). A plugin with thousands of parameters was not listed.

## 4. Run

```powershell
pwsh run.ps1 -Config my-plugin.json -CfgDir D:\reaper-harness\cfg -PluginDir D:\build\VST3 -ResultDir D:\reaper-harness\results
```

| option | |
|---|---|
| `-Only <regex>` | run only scenarios (and negative cases) whose id matches; picking nothing is a usage error |
| `-NoNegative` | leave out all negative cases, the built-in ones included (faster, but proves less) |
| `-Repeat <n>` | run the whole set n times in a row (rounds); a changed default resource directory stops all further rounds |
| `-BuildLabel <label>` | `[0-9A-Za-z._-]{1,40}`, goes into the result file name; default: from the sha256 of the plugin binaries |
| `-SkipMarker <file>` | repeatable; while any of these files exists the suite is SKIPPED and REAPER is never started |
| `-ExtraGuiLock <Local\name>` | repeatable; GUI locks to take in addition to `Local\ReaperHarness-gui` before every launch |
| `-KeepWork` | keep the projects, renders and driver files of green rounds (rounds that are not green are always kept) |
| `-ReaperExe <path>` | another REAPER |
| `-List params` | list the parameters of the plugins instead of testing ([listing parameters](#listing-parameters)); with it `-Only`, `-NoNegative` and `-Repeat` are usage errors, and without it every other `-List...` option is |
| `-ListPlugin <ids>` | the plugins to list, ids separated by commas; default: every plugin of the configuration |
| `-ListParam <name>` | the exact name of one parameter to sweep; needs exactly one plugin in `-ListPlugin` |
| `-ListParamFile <file>` | the names of 1 to 32 parameters to sweep, one a line (UTF-8); instead of `-ListParam` |
| `-ListValues <values>` | the normalized values of a sweep, separated by commas: 1 to 101, each from 0 to 1 and given once; default `0,0.25,0.5,0.75,1` |

Once, before the first round: the plugin bundles are copied into the private `plugins` directory and the plugin
path and the scan shield are written (with a `transport` scenario, its block probe and feed JSFX are copied into the
private `Effects/reaper-harness/` too). Each round: learning proves the private copies are what REAPER loads and
learns every plugin setting the scenarios use, in launches of at most `limits.learnBatchSize` settings
([CONFIG.md](CONFIG.md#limits), one row each); then every scenario runs, then the negative cases. Before the first
launch one line says how many scenarios and negative cases were picked (after matrix and variant expansion) and how
many plugin settings are learned in how many launches. Measured on REAPER 7.82: a learn launch took 5.5 to 5.6 s with
one setting, 5.6 to 5.7 s with 8 and 6.1 s with 32 (JSFX; [validation
record](validation/2026-11-19-param-variants.md)). A launch that REAPER's evaluation licence reminder ended is done once more, through every guard
again ([SAFETY.md](SAFETY.md#dialogs)). The work files of a round go to `<ResultDir>/work/<time>-run<n>/`;
the result file is `<ResultDir>/<time>-<config name>-<build label>.json` ([RESULTS.md](RESULTS.md)). Renders of
scenarios with `keep` ([CONFIG.md](CONFIG.md#keep)) go to `<ResultDir>/renders/<time>/run<n>/`, with a
`manifest.jsonl` that describes each of them ([RESULTS.md](RESULTS.md#kept-renders)); they are not work files, and
nothing removes them. They take room: 180 s of stereo float32 at 48 kHz are about 69 MB, so 200 kept
[variants](CONFIG.md#variants) of such a file are about 14 GB a round.

While a run is going on, do not use REAPER on the same machine: the run refuses to start next to a running
`reaper.exe`, but cannot stop you from starting one in the middle. Create one of your skip markers first if you
need to.

The work directory of a round holds every render of the round until the round ends: about the scenarios x their
renders (two for a `repeat` or a compare variant, one for `dry` and `none`, plus one dry reference per layout and
setting) x the size of one render. A [tail](CONFIG.md#tails) of 60 s adds about 23 MB to each render of stereo float32
at 48 kHz.

### Is the plugin deterministic?

A small scenario of its own renders the same project twice and says whether the two renders are bit-identical,
without failing when they are not:

```json
{ "id": "verb-repeat", "kind": "render", "layout": "voice", "compare": "repeat", "maxDiffDb": "report", "notSilent": true, "keep": true }
```

`notSilent` matters here: two silent renders (a source that did not play, a plugin that muted, an FX that did not load)
are bit-identical too and would read as a deterministic plugin; with it they FAIL. Otherwise the row passes either
way. Its line ends `; reported: bit-identical`, or `; reported: not bit-identical, residual ...` with the residual
peak, its RMS against the reference, where it is largest and where the first difference is;
`facts.comparison` of the row has the numbers ([RESULTS.md](RESULTS.md#a-row-scenarios)), and with `keep` the
manifest line has them too, with both renders when they differ ([CONFIG.md](CONFIG.md#keep)). Keep it out of a
scenario with many [variants](CONFIG.md#variants): each variant renders twice. The comparer looks for the best lag by
going over the two files 2 x `limits.lagSearch` + 1 times (129 times at the default 64), which takes time on long
files; the residual itself is measured at the expected lag, so `limits.lagSearch` 0 gives the same residual sooner,
its best lag then reading 0. The example
[file-source-variants](../examples/file-source-variants/reaper-harness.json) has such a scenario, next to five
variants of a plugin compared with dry and a render with a tail.

## Exit codes

| code | |
|---|---|
| 0 | PASS: every row of every round passed |
| 1 | FAIL, also when the result file could not be written |
| 2 | INCOMPLETE: some row could not run or could not be checked, the run stopped on an unexpected error, or the result file of anything but a FAIL could not be written; this is never a PASS |
| 3 | SKIPPED: the suite did not run (the reasons are printed and in the result file) |
| 64 | refused by a guard, or a usage error (including any problem in the configuration); nothing was started |

A listing (`-List params`) exits like a run: 0 when every plugin was listed cleanly, 1 when a swept name is not a
parameter of the plugin or learning failed, 2 when a plugin could not be listed or read cleanly.

An option given without its value (`-Config` or `-List` as the last argument, for example) never reaches the tool:
PowerShell refuses it (`Missing an argument for parameter ...`) and exits 1, not 64. Nothing was started and no result
file was written.

`doctor.ps1` exits 0 when ready, 2 when the check itself stopped on an unexpected error, 3 when `run.ps1` would be SKIPPED, 64 when refused.

## Self-test

```powershell
pwsh run.ps1 -SelfTest [-ExtraGuiLock Local\Other-gui]
```

About 350 cases, a few minutes, no REAPER. It runs everything against a fake `%APPDATA%` in a scratch directory
under the system temporary directory and compares a listing of the real default resource directory before and
after. Some cases show real message boxes for a moment; they take the GUI locks like a real run.
`-CollisionSample <file.ps1>` additionally checks that a script you know to have a case collision is caught.
