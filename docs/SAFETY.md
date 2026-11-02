# Safety

The harness starts a real REAPER on your desktop many times in a row. These are the rules it keeps so that this
never changes your own REAPER setup, never hides a failure, and never tests something else than the build you
pointed it at. Every rule has self-test cases (`pwsh run.ps1 -SelfTest`) that turn red when the rule is removed.

## Your REAPER configuration is never touched

REAPER does not fail on a `-cfgfile` path that does not exist: it silently falls back to its default resource
directory, `%APPDATA%\REAPER`, and writes your own configuration. So before every single launch:

1. `-CfgDir` must be an explicit absolute path starting with a drive letter. `\\?\` prefixes, `\\.\` device paths,
   UNC paths and admin shares such as `\\localhost\C$\` name the same directory in ways string comparison cannot
   see, so they are refused.
2. The path, after expanding `..`, junctions and symbolic links, must not be under `%APPDATA%`.
3. The directory itself and every parent up to the drive root is compared with `%APPDATA%` by file identity
   (volume serial number and file ID): this catches 8.3 short names, subst drives and any other spelling. A path
   whose identity cannot be read is refused: what cannot be proven is not allowed.
4. The directory must hold the sentinel file `doctor.ps1 -Init` writes, and `reaper.ini`.

`doctor.ps1 -Init` only takes over a directory that does not exist, an empty one, or one it initialised before.
A directory with content but no sentinel (for example a portable REAPER) is refused and nothing is written; there
is no switch to override that.

The checked ini path is pinned into a read-only constant for the rest of the process; the `-cfgfile` argument can
only come from it, and is checked again right before every start. A lint rule keeps the `-cfgfile` literal in
exactly one place in the code (`src/Host.psm1`).

Before and after every round the harness lists `%APPDATA%\REAPER` (file sizes and write times, read only). If
anything changed the round is FAIL and no further round runs.

## Only its own processes, one GUI run at a time

- The watchdog ends only the process ID it started, at the time limit (`Timeout`) or at a kill point (`Killed`).
  A `reaper.exe` that was already running makes the whole suite SKIPPED: the harness does not run alongside it,
  and changes to the default resource directory could not be attributed. A `reaper.exe` left over after a round
  makes the round FAIL.
- Before every launch the harness takes its GUI lock, `Local\ReaperHarness-gui`, a kernel mutex. `-ExtraGuiLock
  <Local\name>` adds more (for example the lock another tool on the same machine uses for its GUI tests); locks can
  only be added, never removed. All locks of a set are taken in a fixed order, all or nothing, so two runs with
  different sets cannot deadlock. If they cannot be taken within `limits.lockWaitSec` the scenario is INCOMPLETE
  and REAPER is not started. Nothing ever starts REAPER without the locks.
- `Local\` names only exclude within one logon session; do not run the harness from SSH, a scheduled task or
  another user's session at the same time.
- `-SkipMarker <file>` (repeatable): while any of these files exists, the suite is SKIPPED with zero launches. The
  marker is checked again while holding the locks, right before each launch. Use it to pause automated runs while
  someone is testing on the machine by hand.

## Dialogs

A modal dialog would stop REAPER forever. On every poll (every 250 ms) the windows of the started process ID, and
only those, are classified:

| title | action |
|---|---|
| `REAPER Query` (save changes?) | answered No |
| `Render…`, `Scanning…`, `Building peaks…` | progress windows, left alone |
| `About REAPER…` (the evaluation licence reminder) | never clicked away: stuck, `license-nag` |
| `Project Load Warning`, `REAPER Error`, `Select files to save or delete`, `REAPER` (no audio device) | stuck, named |
| anything else | stuck, `unknown-dialog` with the title (paths masked) |

A stuck dialog ends the launch and the scenario is INCOMPLETE. The evaluation reminder shows up on some launches
only (about one in six in our runs); buy a licence or run again.

## Outcomes never lie in your favour

- PASS, FAIL, INCOMPLETE (no conclusion: something did not run or could not be checked), SKIPPED (the suite did not
  run at all), REFUSED (a guard said no). INCOMPLETE is never counted as PASS; an empty set of outcomes is
  INCOMPLETE; SKIPPED mixed with PASS is INCOMPLETE.
- A handler that throws gives INCOMPLETE, never PASS.
- Negative cases pass only when the outcome and the reason both match (see [CONFIG.md](CONFIG.md#negative-cases)).
  The built-in ones prove the comparer, the watchdog and the entry guards in every round.

## The build under test is the build that ran

This is the part that is easy to get wrong. REAPER keeps one plugin per file name. When a release build of your
plugin is installed in a system VST3 directory, the private copy of your development build has the same bundle
name and the same class ID, and REAPER may load the release build instead. Nothing in the render tells you.

Measured on 2026-11-01 with REAPER 7.82 x64 (evaluation licence) on Windows 10 22H2, dummy audio device, a private
configuration directory made by `doctor.ps1 -Init`, a development build in the private plugins directory and a
release build of the same plugin (same bundle name, class ID and display name, different bytes) in
`%COMMONPROGRAMFILES%\VST3`; which file was loaded was read from the module list of the REAPER process and from
`fx_ident`:

| `vstpath64` | loaded into the REAPER process |
|---|---|
| private directory first, system directories after it (REAPER appends them itself) | the release build |
| the same, with the private binary's write time set to now | the release build |
| system VST3 directories first, **private directory last** | **the private development build** |

So with the same file name the directory scanned **last** wins, regardless of file times. REAPER appends
`%COMMONPROGRAMFILES%\VST3` and `%LOCALAPPDATA%\Programs\Common\VST3` to the path only when they are missing.
Before every round the harness therefore writes `vstpath64` as your other entries, then both system directories,
then the private plugins directory, and removes the cache entries of the configured bundles so REAPER scans them
afresh.

That ordering is observed behaviour, not a documented promise. So it is not trusted on its own; every round also
proves which file was loaded, in two independent ways:

- **The module list of the REAPER process.** On every poll the full paths of loaded modules with the file name of a
  tested binary are collected. Each tested binary must be seen loaded, and only from its private file (compared by
  file identity). Another file with that name (`Foreign`) makes the learn row and the round INCOMPLETE; a binary
  never seen (`Unseen`) makes the learn row INCOMPLETE ("the private copy is not proven"). Every later launch of the
  round is checked for `Foreign` too.
- **`fx_ident`.** After adding each plugin the Lua driver reads `fx_ident`, which for VST3 is the full path of the
  binary followed by the class ID. It must be the private binary, and the class ID must equal the one in
  `moduleinfo.json`.

Plugin scanning happens in a separate process, so only launches that instantiate the plugin can show it in the
module list; the learn launch always does. If a future REAPER resolves duplicate names differently, the result is
INCOMPLETE with the reason, never a PASS about the wrong build.

## Keeping other plugins out

On startup REAPER loads every plugin file it has no up-to-date cache entry for. On a machine with many plugins
that means third-party code runs inside the test process: a newly installed plugin can show an activation dialog
or hang the scan. Before every round the **scan shield** gives each file REAPER would scan outside the private
plugins directory (`*.vst3` bundles and files, `*.dll`) an empty, current entry in the private
`reaper-vstplugins64.ini` when it has none, so REAPER treats it as "scanned, no plugin here" and never loads it.
Only the private cache is written; the plugins and the system directories are only listed. The key is the file
name with every character other than ASCII letters, digits and `.` replaced by `_`; the stamp is the binary's last
write time as FILETIME in little-endian hex. Names with non-ASCII characters have no known key and are counted as
`unshielded` in the result. CLAP plugins are not shielded; the result lists every `.vst3` and `.clap` module seen
loaded, so a third-party plugin in the process is visible.

## Learning the plugin blocks

A plugin block in a project without the state REAPER saved for that plugin is reported as "effect unavailable".
So no block is ever written by hand. Once per round one launch adds every plugin (and every parameter set a layout
uses) by name, sets the parameters by name and reads them back, and saves the project; the blocks REAPER wrote are
what every other project of the round uses. `TrackFX_AddByName` matches loosely (a single letter adds some plugin),
so the full name `VST3: <Name> (<Vendor>)` is used and checked after adding: the displayed name, `fx_ident` and the
class ID of the saved block must all be the expected ones. A plugin that does not load is FAIL.

A named state is a block REAPER saved for you (see [CONFIG.md](CONFIG.md#states)). It is not added by name: the
project the learn launch opens already holds the block, REAPER loads it as it loads any saved project, and the
block REAPER saves back must be the one it was given. Before anything starts, the block's name and class ID must
be the plugin's (from `moduleinfo.json`); a block of another plugin is a usage error. Of a template project only
that one block is read: other tracks, other plugins and file paths in it never reach the console, the logs or the
result file, and the block itself only goes into projects in the work directory. A JSFX shipped with the tool is
copied into the private configuration directory and checked by the name REAPER shows and by its path there.

## Scripts

Every script runs under `Set-StrictMode -Version Latest`. PowerShell variable names are case insensitive, so a loop
variable `$cfgDir` silently overwrites a parameter `$CfgDir`; a lint rule refuses variable names in one file that
differ only by case. Scripts and data files must not contain invisible control characters (a stray carriage
return inside a regex changes its meaning without showing in an editor or a diff). Only `src/Guard.psm1` and the
self-test mention `APPDATA`. `.Keys` and `.Values` are never read as properties: on a dictionary with an entry named
`Keys` (a configuration key, a file name, a variable name) the property returns that entry, and a check that walks the
keys silently walks one value instead. The lint rule found exactly that in its own case scan: a script with a
variable `$keys` was not scanned at all. `.get_Keys()`, `.get_Values()` and `.GetEnumerator()` cannot be shadowed.
