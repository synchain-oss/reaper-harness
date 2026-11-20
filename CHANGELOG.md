# Changelog

What each version of reaper-harness changed. Before 1.0 the command line may change between versions. The
configuration file and the result file are versioned on their own by their `schema` number: a change to either format
stays backward compatible or raises that number, and the entry of that version says how to migrate.

## Unreleased

- `run.ps1 -List params` lists the parameters of the plugins of a configuration instead of testing: one launch of
  REAPER under every guard of a run, in which learning reads, after the save, each parameter's index, name, normalized
  value, display text and REAPER's identifier, and tells which can go into `params` (`settable`: not a name used
  twice, not one of REAPER's own Bypass, Wet and Delta, nothing masked). `-ListPlugin` picks plugins; `-ListParam` or
  `-ListParamFile` with `-ListValues` sweep parameters of one plugin on an instance of their own and read back the
  value and display text of each value. A row `params` judges the listing; the result file
  (`...-list-params.json`) holds it in `listing`, a new field that is null in every other run, so `schema` stays 1.
  The listing's `blockSha256` is the one a kept render's manifest has for the same plugin.
- A track can play a WAV file of your own instead of the test signal (`layouts.<id>.tracks[].file`): pcm16, pcm24 or
  float32, 1 or 2 channels, at the rate of every scenario that uses it. It is checked before REAPER starts, copied into
  the work directory each round (the copy's hash and header checked again; a copy that cannot be read back or whose
  bytes changed takes out only the scenarios that play it), never resampled or mixed down (by the
  kinds of extensions neither), and listed with its SHA-256 in the result file (`sources`). Configuration and result
  file stay `schema: 1`.
- `keep: true` on a `render` scenario keeps its render and stems under `renders/<run stamp>/run<round>/` of the
  result directory (links and junctions resolved), whatever the verdict and never over another file, and appends a
  line per kept scenario to `renders/<run stamp>/manifest.jsonl`: the files with their full SHA-256, peak and NaN / Inf
  counts, the render settings, what each source track played, and every FX as rendered (bypass, state, the hash of its
  block in the project, the parameters and latency REAPER read back at the learn launch). The row of a kept render
  repeats its line in `facts.kept`; the result file names the manifest (`manifest`).
- The result file names the version of the harness (`toolVersion`) and the commit it ran from (`toolCommit`, read
  from its `.git` without running git; null when it cannot be read). Both are new fields: `schema` stays 1.
- The learn launch reads each plugin's latency after its parameters are set and it had a second to settle, no longer
  right after adding it.
- Parameter variants: `variants` on a `render` scenario renders it once per variant, as `<id>-<variant id>` (after a
  matrix `<id>-<matrix suffix>-<variant id>`), each with some plugins set otherwise (`fx`: a state, parameters on top
  of the layout's) or bypassed (`bypass`); `{ "id": "dry", "bypass": true }` is the dry reference as a variant, kept
  like the others. A scenario with variants must give `compare` (`"none"` to only render). The rows (`facts.variant`,
  `facts.baseScenario`) and the manifest lines (`variant`, and the display text asked for, `params[].display`) name
  the variant. Up to 1000 variants per scenario.
- Learning runs in launches of at most `limits.learnBatchSize` plugin settings (new, default 32, 1 … 256), each a
  row of its own: `learn` with one launch as before, `learn.1` … `learn.<n>` with several (facts `batch`, `batches`,
  `learned`; `variants`, `modules` and `binaries` are those of the launch). Each launch proves the binaries of its own
  plugins; a launch that failed no longer keeps the others from running, and a scenario runs when every setting it
  needs was learned. Of a launch, only the settings that failed nothing are used (not that of an offline plugin).
  `learnTimeoutSec` applies to each launch.
- `expectPdc: "report"`: the latency of such a plugin is recorded (`facts.pdc` of `device`, `savereopen` and
  `transport` rows), not judged; a missing reading is INCOMPLETE, and so is a kept render whose learn launch did not
  read it.
- Behaviour changes: the scenario ids `learn` and `round-error` are refused (they are the ids of rows the tool
  writes); one plugin setting asked to show two different display texts, anywhere in the configuration, is a usage
  error (one learned setting has one display text). Configuration and result file stay `schema: 1`.

## v0.1.0 (2026-11-07)

The first preview release. Configuration `schema: 1`, result file `schema: 1`.

- Safety base: a private REAPER configuration directory that can never be the default resource directory, checked
  before every launch; listings of the default directory around every round; only the processes the tool started are
  ever ended; a GUI lock held before every launch, with `-ExtraGuiLock` to also take the lock of another tool on the
  machine; a sample-by-sample WAV comparer (#2).
- Configuration-driven scenarios (`render`, `device`, `savereopen`, `instances`), learning the plugins' blocks from
  REAPER itself, proof that REAPER loaded the private copy of each plugin, and an extension interface for product-specific
  kinds and driver steps (#4).
- Named per-instance plugin states from a template project, routing and stems, per-channel level and balance criteria,
  a delay JSFX for latency compensation tests, anticipative FX settings (#5).
- An integration guide with a complete example configuration and a validation record (#6, #7).
- The `transport` kind: transport, arm and input-monitoring states, a block-counting probe, an input feed of test
  signals or WAV files; it never records. The "Finished in" window after a render is let through, and a launch ended by
  REAPER's evaluation reminder is done once more (#8).
- Plugin self-reports read as untrusted input and judged per state or per render, opening and closing a plugin's window
  during a state, and the "Inform plug-ins of offline rendering state" preference per scenario (#9).
- The tool's own checks: CI, a review bot, privacy and commit checks, maintainer wrappers and offline self-tests
  (#1, #3).

Known limits: Windows x64 and VST3 only; real runs were tested on REAPER 7.82 only; each document in `docs/` lists its
own limits.
