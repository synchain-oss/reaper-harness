# Changelog

What each version of reaper-harness changed. Before 1.0 the command line may change between versions. The
configuration file and the result file are versioned on their own by their `schema` number: a change to either format
stays backward compatible or raises that number, and the entry of that version says how to migrate.

## Unreleased

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
