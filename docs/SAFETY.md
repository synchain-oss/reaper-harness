# Safety

The harness starts a real REAPER on your desktop many times in a row. These are the rules it keeps so that this
never changes your own REAPER setup, never hides a failure, and never tests something else than the build you
pointed it at. Every rule has self-test cases (`pwsh run.ps1 -SelfTest`) that turn red when the rule is removed.

## Your REAPER configuration is never touched

REAPER does not fail on a `-cfgfile` path that does not exist: it silently falls back to its default resource
directory, `%APPDATA%\REAPER`, and writes your own configuration. So before every single launch:

1. `-CfgDir` must be an explicit absolute path starting with a drive letter. `\\?\` prefixes, `\\.\` device paths,
   UNC paths and admin shares such as `\\localhost\C$\` name the same directory in ways string comparison cannot
   see, so they are refused. The drive must be local: a mapped network drive can lead back to this very machine, and
   a drive of unknown type, or one whose type cannot be read, proves nothing, so they are refused too. Both the path
   as spelled and the path after expanding links have to pass, because a link can lead to either. A subst drive stands
   for a local directory and stays allowed; rule 3 still sees where it points.
2. The path, after expanding `..`, junctions and symbolic links, must not be under `%APPDATA%`.
3. The directory itself and every parent up to the drive root is compared with `%APPDATA%` by file identity
   (volume serial number and file ID): this catches 8.3 short names, subst drives and any other spelling. A path
   whose identity cannot be read is refused: what cannot be proven is not allowed.
4. The directory must hold the sentinel file `doctor.ps1 -Init` writes, and `reaper.ini`.
5. Nothing in the directory may lead out of it, since REAPER and the harness read and write through those names. Any
   link or junction is refused. So is any file with more than one name on its volume, which is what a hard link is:
   writing it changes the file under its other name too, and that name can be anywhere and called anything, so its link
   count decides and not a search for it. A count that cannot be read is refused, and so is a directory that cannot be
   listed. The top level is checked before every start, because a link can appear at any time and that is where files
   are opened by a fixed name. The whole tree, at every level and without following a link, is walked once per process
   when the path is pinned: a configuration directory can hold thousands of entries and each start checks several
   times, so that walk is left out of the check before every start on purpose. A hard link made below the top level
   after the pin is therefore not seen by that process.

`doctor.ps1 -Init` only takes over a directory that does not exist, an empty one, or one it initialised before.
A directory with content but no sentinel (for example a portable REAPER) is refused and nothing is written; there
is no switch to override that. The top level is checked by rule 5 there as well, before anything is written.

The checked ini path is pinned into a read-only constant for the rest of the process; the `-cfgfile` argument can
only come from it, and is checked again right before every start. A lint rule keeps the `-cfgfile` literal in
exactly one place in the code (`src/Host.psm1`).

`-ResultDir` is written during a run too, so it is refused (exit 64) when it is the default resource directory or below
it: after expanding links, and by file identity for any other spelling. Nothing else is asked of it: unlike `-CfgDir` it
may be elsewhere under `%APPDATA%` or on a network drive, because REAPER never runs from it.

Arguments reach REAPER one by one, not as one command line, so a space in a path cannot split it and the private ini
is always the element right after `-cfgfile`. Before the start, `-ReaperArgs` holding a double quote (a caller still
quoting for itself, which would hand REAPER literal quotes) or naming the `-cfgfile` switch again is refused.

Before and after every round the harness lists `%APPDATA%\REAPER` (file sizes and write times, read only), and the
self-test does so before and after it runs. If anything was seen to change the round is FAIL and no further round runs. A file or
directory that cannot be listed is recorded as `unreadable` (the directory itself under the name `.`), and a comparison
with anything unreadable on either side is not "unchanged", also when both listings say the same: what cannot be read
cannot be proven to have stayed as it was. The comparison names those entries. A round where that happens is
INCOMPLETE, not FAIL (nothing was seen to change, it just cannot be shown that nothing did), and no further round runs.
An entry listed once and unreadable the other time, and what was below it, counts as that same lack of evidence and not
as a change. A change anywhere else in the directory is still FAIL, whatever could not be listed next to it.

The self-test reaches a mapped network drive and a link count that cannot be read through stand-ins for the functions
that read them, and uses a real letter with nothing mounted on it. A real mapped drive changes the machine, so one is
only made on a hosted runner, where it is deleted again; everywhere else that case, like a symbolic link in a session
without the privilege for one, is counted as not run for real in the summary line. What the self-test undoes on the
machine (a deny entry, a subst drive, a mapped drive) is checked as undone, and a failure there turns a case red.

## Only its own processes, one GUI run at a time

- The watchdog ends only the process ID it started, at the time limit (`Timeout`) or at a kill point (`Killed`).
  A `reaper.exe` that was already running makes the whole suite SKIPPED: the harness does not run alongside it,
  and changes to the default resource directory could not be attributed. After a round only the processes that round
  started count, each recognised by its process ID and start time: one of them still there and reported by no launch
  makes the round FAIL. A `reaper.exe` of somebody else that appeared during the round is not looked for, since the
  locks are free between launches and it says nothing about this round, and neither is a later process that got the
  same number.
- A process the watchdog could not end is reported, not assumed gone: the launch result has `StillRunning`, true when
  the stop failed or the process was still there after the wait, and false when it is gone (a process that had already
  exited is no failure). A caller that sees `StillRunning` true records `INCOMPLETE`, does not release its GUI lock and
  does not start the next launch: that window may still be on the desktop. `Invoke-WithHarnessLocks` always releases
  when its block ends, so a caller that can start REAPER must not use it: it takes and releases the locks itself with
  `Enter-HarnessLocks` and `Exit-HarnessLocks`. The run command does just that: `Invoke-HarnessLaunch` keeps the locks
  and notes the process, every later launch of that context starts nothing and reports `Blocked`, the round is
  INCOMPLETE and no further round runs. The kernel takes the locks back when the run's process ends.
- Watching a process can fail too (its counters cannot be read, for one), and only the host knows the process at that
  point. So nothing there throws past it: the process is ended by its PID as at a timeout, the status is `Error` with
  the reason, the launch is INCOMPLETE, and a process that could not be ended is treated as above. The next launch never
  starts next to it.
- Before every launch the GUI lock has to be held: `Invoke-HarnessHost` enforces it, and without the object
  `Enter-HarnessLocks` returned for a set holding the default lock it refuses before anything starts. The other two
  checks before a launch, that no other `reaper.exe` is running and the listing of the default directory, are the job
  of the run command, once at its start and once per round.
- The default lock is `Local\ReaperHarness-gui`, a kernel mutex. `-ExtraGuiLock
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
| `Render…`, `Scanning…`, `Building peaks…` | progress windows, left alone, unless the title has `fail` or `error` in it in any case: those report trouble and do not go away on their own, so they are stuck, `unknown-dialog` |
| `VST3: …`, `VST3i: …`, `VST: …`, `VSTi: …`, `CLAP: …`, `CLAPi: …`, `JS: …` (the floating window of a plugin), `FX: …` (an FX chain window) | not a dialog, left alone (`plugin-window`): the prefix must start the title, in that case, followed by a blank. Measured on REAPER 7.82: a VST3 and a JSFX floated from one track are titled `VST3: Name (Vendor) - Track 1 [1/2]` and `JS: Name - Track 1 [2/2]`, the chain windows `FX: Track 1` and `FX: Master Track`. A dialog a plugin opens itself has a title of its own and is still `unknown-dialog`, as is `Fake VST3: x` |
| `Finished in …` (what the render window of a render started from a script turns into when it is done: `Finished in 0:06 (1.0x realtime)` on REAPER 7.82) | left alone (`render-finished`): it stays until REAPER quits and does not keep it from quitting. Only at the start of the title, in that case, with the blank, and without `fail` or `error` in it; `finished in …` or `Fake Finished in …` is `unknown-dialog` |
| `About REAPER…` (the evaluation licence reminder) | never clicked away: stuck, `license-nag` |
| `Project Load Warning`, `REAPER Error`, `Select files to save or delete`, `REAPER` (no audio device) | stuck, named |
| anything else | stuck, `unknown-dialog` with the title (paths masked) |

A stuck dialog ends the launch and the scenario is INCOMPLETE. The evaluation reminder shows up on some launches
only (about one in six in our runs). A launch it ended (by its process ID, as always) is done once more, after
deleting the files that launch was to write, so that nothing the first attempt left counts for the second: through
every guard again (the skip marker, the locks, the configuration directory), only once, never after a process that
could not be ended, and not at all when one of those files cannot be deleted. Each retry is listed under the round's
`retries` ([RESULTS.md](RESULTS.md)). A second reminder ends the launch like any stuck dialog; buy a licence or run
again.

REAPER also looks for a new version about once a day and shows `REAPER New Version Notification` when there is one,
which would end that launch the same way. So every launch first writes `verchk=0` under `[REAPER]` in the private
`reaper.ini` (and `doctor.ps1 -Init` writes it into a new one), which turns that check off; nothing is clicked away,
and the default resource directory is not touched. Measured on REAPER 7.82: with the key a `[verchk] lastt` a week
old stays as it was and no notification comes; without it the notification shows within about 2 s.

## Nothing is recorded

The `transport` kind arms a track and turns its input monitoring on. It never records:

- the driver calls no record action: the only actions in `lua/driver.lua` are File: New project, File: Quit and, in
  its render step, the render with the project's own settings, and it has no call that records or looks an action up
  by name (the self-test reads the driver's text for both);
- recording is disabled (record mode "disabled") on both tracks it arms, the tested one and its own clock track, and
  their input is none: what the tested track gets comes from the feed JSFX in its input FX chain;
- the project's record path is set to a directory in the work directory before anything is armed, and read back; a
  path that does not read back stops the step there, before anything is armed or the transport is touched, and the row
  is INCOMPLETE;
- every wait checks the transport for the record bit, the readings of plugin reports and the turns given to an open
  editor included; seen, the transport is stopped and the row is INCOMPLETE;
- any file in that record directory after the launch makes the row FAIL, whatever its states say;
- at the end the transport is stopped and both tracks are disarmed.

On REAPER 7.82 with the Dummy device (which has no inputs) the record bit was never seen in these runs.

## Plugin reports and windows

[Reports](CONFIG.md#reports) let a test build of a plugin hand the harness a file, and `windows` opens the plugin's
editor. What keeps that contained:

- the report variable is set in the environment of the REAPER that one driver step starts, and nowhere else: not in the
  harness's own process, not for any other launch. The self-test checks both;
- a configuration cannot use it to change anything else: names Windows, the .NET and PowerShell runtimes, REAPER and
  what it loads (ReaScript's Python and Lua, Qt in a plugin), a plugin format or WebView2 read (`APPDATA`,
  `USERPROFILE`, `HOME`, `TEMP`, `TMPDIR`, `PATH`, anything starting `REAPER_`, `WEBVIEW2_`, `DOTNET_`, `COR_`, `VST3_`,
  `PYTHON`, `LUA_`, `QT_` and the like) are refused before REAPER starts, like the two-character names and lower case;
- the path is a new file in the work directory for every step, deleted before the start;
- the file is what a plugin wrote, so it is read as untrusted: at most 64 KiB, strict JSON, only the declared numeric
  fields. Nothing else in it reaches a result or a log. The driver's copies of it are deleted before the step starts,
  before a retry and once they are read, whatever the outcome, so none is left in the results directory. The file
  itself is a work file like the projects that hold the plugin's state: deleted when the round is green, kept under
  `work/` when it is not, so that the plugin's author can see what was written. Keep those work files out of
  repositories ([INTEGRATING.md](INTEGRATING.md));
- a file with a `pid` field that is not the REAPER of this step, a missing file and a stale one are no evidence
  (INCOMPLETE), never a PASS.

Opening an editor runs the plugin's own GUI code, in REAPER's process, under your account. The tool does not know what
it writes: a plugin with a web view, for one, keeps a cache in its user data. To keep a run off that data, start the
tool with `USERPROFILE`, `APPDATA` and `LOCALAPPDATA` pointed at a scratch profile, and `WEBVIEW2_USER_DATA_FOLDER` at
a directory of it. That is yours to do: the tool never sets them, and then its before-and-after check of the default
REAPER resource directory looks at the scratch profile, not at the real one, so run the check on the real one yourself. The configuration directory comes from
`-CfgDir` either way.

## Outcomes never lie in your favour

- PASS, FAIL, INCOMPLETE (no conclusion: something did not run or could not be checked), SKIPPED (the suite did not
  run at all), REFUSED (a guard said no). INCOMPLETE is never counted as PASS; an empty set of outcomes is
  INCOMPLETE; SKIPPED mixed with PASS is INCOMPLETE.
- A handler that throws gives INCOMPLETE, never PASS. So does any other unexpected error past the guards: it is
  something that could not be done, not a criterion that was checked, so the exit code is 2 and never 1. A round that
  breaks still gets the checks of the end of a round (a change in the default resource directory, or a process it left,
  is still FAIL), and no further round runs. A guard that refuses inside a round is treated the same way: REAPER may
  have run already, so exit 64 (nothing was started) would be wrong, and leaving early would skip those checks.
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
project the learn launch opens already holds the block, REAPER loads it as it loads any saved project, and the block
REAPER saves back must be the one it was given; a state used with parameters on top is learned on its own as well,
so this holds for every state. The track that holds a template state in the learn project is named like the template
track (the `track` field of the configuration, not read from the template), because a plugin may keep the names of
the tracks it sees in its state; any other track is `learn-<n>`. Before anything starts, the block's name and class
ID must be the plugin's (from `moduleinfo.json`); a block of another plugin is a usage error. Of a template project
only that one block is read:
other tracks, other plugins and file paths in it never reach the console, the logs or the result file, and the block
itself only goes into projects in the work directory. A JSFX shipped with the tool is copied into the private
configuration directory and checked by the name REAPER shows and by its path there.

A path in a recorded title is masked from its drive letter, `\\` or `//` up to the next double quote or the end of the
title: a path can hold spaces, and a user name is often right after one. Everything else that reaches a result file or
the console (reasons, exception messages, the facts of a row, usage errors) is masked the same way, see
[RESULTS.md](RESULTS.md). The console names the result file without its directory.

The self-test exercises this with real message boxes. A session without a desktop (a service, for example some CI
runners) cannot show them: the self-test then states that those cases did not run. The classification in the table
above is a pure function and is tested everywhere.

## No evidence is not a pass

- A render with no frames is `INCOMPLETE`, before every other criterion and with or without a tolerance: nothing was
  compared, and two empty files being bit-identical says nothing.
- A render whose data length is still the placeholder `0xFFFFFFFF` is unreadable, so `INCOMPLETE` in a comparison and on
  its own alike: the writer never came back to fill in the length, so the file is not finished, and what is in it says
  nothing about what is missing. REAPER's finished renders hold the real length.
- A `transport` state is judged on device samples, counted on an armed track of the tool's own, never on wall-clock
  time. A state whose numbers describe another state than the one asked for (the transport, the arm or the monitoring
  mode did not read back as asked, or the device ran less than the window) is `INCOMPLETE`, and so is an armed state
  whose feed played nothing in its window, a state of which the driver got no clean reading, and a row whose block probes or feed are not the tool's own copies (by
  `fx_ident`), whose probe is not first in the chain, or whose feed could not open its file or never ran although a
  state arms the track.
- With no plugin binaries expected, the proof of which binaries were loaded is `Unseen`, not proven. A configuration
  needs at least one plugin (the schema refuses an empty `plugins`), but every one of them can be a JSFX shipped with
  the tool, and then there is no binary to prove: learning does not ask the module list at all, its facts say
  `modules: NoBinary`, and each JSFX is proven by its path in the private configuration directory (`fx_ident` and
  the saved block) instead.

## Scripts

Every script runs under `Set-StrictMode -Version Latest`. PowerShell variable names are case insensitive, so a loop
variable `$cfgDir` silently overwrites a parameter `$CfgDir`; a lint rule refuses variable names in one file that
differ only by case. Scripts and data files must not contain invisible control characters (a stray carriage
return inside a regex changes its meaning without showing in an editor or a diff). Only `src/Guard.psm1` and
`tests/SelfTest.psm1` mention `APPDATA`; this exemption and the one for `src/Host.psm1` go by the path from the
repository root, so another file of the same name has none. `.Keys` and `.Values` are never read as properties: on a dictionary with an entry named
`Keys` (a configuration key, a file name, a variable name) the property returns that entry, and a check that walks the
keys silently walks one value instead. The lint rule found exactly that in its own case scan: a script with a
variable `$keys` was not scanned at all. `.get_Keys()`, `.get_Values()` and `.GetEnumerator()` cannot be shadowed.
