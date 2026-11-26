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

`-ResultDir` is written during a run too (the result file, `work/`, and `renders/` for
[kept renders](#source-files-and-kept-renders)), so it is refused (exit 64) when it is the default resource directory
or below it: after expanding links, and by file identity for any other spelling. Nothing else is asked of it: unlike
`-CfgDir` it may be elsewhere under `%APPDATA%` or on a network drive, because REAPER never runs from it.

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
  checks are the job of the run command: that no other `reaper.exe` is running is checked once, before the first
  round; the default directory is listed before and after every round. A `reaper.exe` someone starts between two
  rounds of `-Repeat` is not looked for again; what it changes in the default directory while a round runs still
  shows when that round's two listings are compared, but a change made between two rounds or after the last one is
  never compared: the next round's first listing simply starts from it.
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
every guard again (the skip marker, the locks, the configuration directory), only once, and never after a process
that could not be ended. A [probe directory](#probe-variables-and-collected-files) is not deleted: it stays, the
plugin is told its path again, and it must still be empty. The probe input copy is reused as it is and hashed again
after the launch. There is no retry when one of those files cannot be deleted or the first launch wrote into its
probe directory, and the reason of the row says so (`; not retried: the first launch wrote into <id>.out`). Each
retry is listed under the round's `retries` ([RESULTS.md](RESULTS.md)). A second reminder ends the launch like any
stuck dialog; buy a licence or run again.

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
  harness's own process, not for any other launch. The self-test checks both. Every other launch takes the name out of
  the environment it inherits, so a variable of that name left in your shell reaches no REAPER;
- a configuration cannot use it to change anything else: names Windows, the .NET and PowerShell runtimes, REAPER and
  what it loads (ReaScript's Python and Lua, Qt in a plugin), a plugin format or WebView2 read (`APPDATA`,
  `USERPROFILE`, `HOME`, `TEMP`, `TMPDIR`, `PATH`, anything starting `REAPER_`, `WEBVIEW2_`, `DOTNET_`, `COR_`, `VST3_`,
  `PYTHON`, `LUA_`, `QT_` and the like) are refused before REAPER starts, like the two-character names and lower case.
  This is the list of the released version; [probe variables](#probe-variables-and-collected-files) have a longer one;
- the path is a new file in the work directory for every step, deleted before the start;
- the file is what a plugin wrote, so it is read as untrusted: at most 64 KiB, strict JSON, only the declared numeric
  fields. Nothing else in it reaches a result or a log. The driver's copies of it are deleted before the step starts,
  before a retry and once they are read, or right away when the launch ends in an error before they could be read:
  whatever the outcome, none is left in the results directory. The file
  itself is a work file like the projects that hold the plugin's state: deleted when the round is green, kept under
  `work/` when it is not, so that the plugin's author can see what was written. Keep those work files out of
  repositories ([INTEGRATING.md](INTEGRATING.md));
- a file with a `pid` field that is not the REAPER of this step, a missing file and a stale one are no evidence
  (INCOMPLETE), never a PASS.

Opening an editor runs the plugin's own GUI code, in REAPER's process, under your account. Holding the window open
(`holdMs`) lets that code run for longer; nothing else changes. Shots of a held window are described
[below](#shots-of-a-held-window). The tool does not know what it writes: a plugin with a
web view, for one, keeps a cache in its user data. To keep a run off that data, start the tool with `USERPROFILE`,
`APPDATA` and `LOCALAPPDATA` pointed at a scratch profile, and `WEBVIEW2_USER_DATA_FOLDER` at a directory of it. That
is yours to do: the tool never sets them, and then its before-and-after check of the default REAPER resource directory
looks at the scratch profile, not at the real one, so run the check on the real one yourself. The configuration
directory comes from `-CfgDir` either way.

## Probe variables and collected files

[Probe variables](CONFIG.md#probes) give a test build of a plugin a file to read and a directory to write into. What
keeps that contained:

- **The values.** A configuration gives a probe variable no value of its own: the value is always a path the harness
  made for that launch. It is either a copy of a file of the configuration directory or a new empty directory in the
  work directory. The file is resolved like an extension path, is at most 1 MiB and is hashed before REAPER starts; it
  is copied for each launch, and the copy's hash must be the checked one. No text, number or other path of the
  configuration reaches an environment. What the file holds does come from the configuration directory, and a test
  build runs code of its own inside REAPER anyway: the deny list is defence in depth, not a boundary.
- **The names** follow the rules of report variables ([above](#plugin-reports-and-windows)), and no two plugin
  variables of a configuration share a name. Their deny list is longer: the families that make a runtime or a library
  load a file or take options are refused too, anything starting `SSL_`, `OPENSSL_`, `CURL_`, `NODE_`, `JAVA`, `JDK_`,
  `PERL`, `RUBY`, `GIT_`, `CHROME`, `MSEDGE`, `REQUESTS_`, `HTTP` (`HTTPS_` too), `NO_PROXY` or `ALL_PROXY`, the name
  `SSLKEYLOGFILE`, and any name ending in `_PROXY`. They matter where the content the value leads to comes from the
  configuration: a probe file variable gets a copy of a file of the configuration directory, which could be a CA
  bundle or a module path. A report variable's value is the path of a file the plugin itself writes, so keeping the
  released list for it gives up nothing, and keeps released configurations valid.
- **Which launch.** They are set for the REAPER of the launch that renders a scenario that asks for them (`probe`), and
  nowhere else: not in the harness's own process, not for the learn launch, a reference, a negative case or another
  kind. They ride on the existing guarded launch: there is no new way to start REAPER, and the launch path, the locks,
  the watchdog and the module check are unchanged.
- **Inherited variables.** Every launch takes each declared report and probe name of the configuration out of the
  environment it inherits, unless it sets that name itself, so a variable left in your shell reaches no launch. Only
  declared names are taken out, and only names that passed the deny list can be declared; any other variable is
  inherited as before.
- **The runtime check.** Extension code is PowerShell in the harness's own process, so a configuration is not the only
  caller. Every launch, whoever asks for it, checks each environment value it is to set before it takes anything: a
  full path strictly inside the work directory, under a name that passes the deny list (the job variable aside): the
  list of report variables for a declared report name of the configuration (exactly that name), the longer list of
  probe variables for every other name, a probe variable or a name an extension asks for.
  Otherwise REAPER is not started and the row is INCOMPLETE. The self-test checks which launch gets the variables,
  that inherited ones are taken out, and the runtime check.
- **The licence reminder.** A launch it ended is started once more only when its probe directory is still empty
  ([above](#dialogs)): the files of the first attempt never mix with the second's. The input copy is not made again;
  it is hashed after the launch like any copy.
- **Collection.**
  - It runs after the scenario's launches have ended, and never while a REAPER of the round may still run (one the
    watchdog could not end).
  - It looks at the top level only, never recurses and never follows a link or junction it finds there. The directory
    itself must not be one either (only an ancestor of the work directory may be); that is checked once, before the
    listing. A process that outlives REAPER and swaps the directory in that moment is not guarded against: a test
    build runs code of its own under your account anyway, and such a plugin could move the files itself.
  - A name is used anywhere only after it passes the name check.
  - At most 32 files, 16 MiB in all and 4 MiB each; nothing beyond is moved.
  - A file another process holds (a sharing violation) is tried again at most three times, 200 ms apart; any other
    error is not tried again. A file that could not be moved stays in the work directory, and one that could not be
    read back after the move has no hash; either makes the row INCOMPLETE.
  - The files go under the rules of kept renders ([below](#source-files-and-kept-renders)): under the result
    directory, links resolved, never overwritten, the run directory claimed once.
- **The files** are the plugin's and untrusted: what is in them is read only to hash it and is never printed; the
  result has their names (only names that passed the check), sizes and hashes. The plugin runs under your account, so
  they may hold anything it could read, paths of this machine among them: the harness does not mask what is in them.
  Keep them out of repositories, like the work files ([INTEGRATING.md](INTEGRATING.md)).
- **Outcomes.** A collection problem is INCOMPLETE. It never turns a FAIL into anything else.

## Shots of a held window

With `windows.capture` ([CONFIG.md](CONFIG.md#transport)) the harness saves images of a plugin's held window. What
keeps that contained:

- **Who and when.** The harness process takes the shots, on a thread of its own that runs only during the launch of a
  transport scenario that asks for shots. The host starts it right after REAPER started and stops it after that REAPER
  has exited or was ended, before the launch returns, whatever ended it; it also leaves by itself once that process is
  gone, and at the launch's time limit plus 30 s. It is compiled on first use, so a configuration without shots never
  loads it.
- **Which window.** Only top-level windows of the process the harness started, by the PID it may end and the start
  time it saw: visible, of the dialog class, with a title that starts with a plugin format's prefix (`VST3: `,
  `VST3i: `, `VST: `, `VSTi: `, `CLAP: `, `CLAPi: `, `JS: `, case-sensitive; not `FX: `, a chain window). Exactly one,
  or no shot. It never finds a process by name or by a window's title, and never looks at another process's windows,
  the screen or the desktop. Inside the window it reads only the class names and rectangles of the child windows that
  process owns, to find where the plugin's view is; apart from the request to draw below, it sends no window anything.
- **How.** `PrintWindow` with `PW_CLIENTONLY | PW_RENDERFULLCONTENT` asks the window to draw its client area into the
  harness's memory. A window in front of it is not in the image, the title bar is not either, and nothing is moved,
  resized, focused, raised, shown, clicked or typed into. This runs REAPER's and the plugin's own drawing code once
  per shot, in REAPER's process, under your account, like opening the editor; for a web view that drawing can reach
  the web view's own processes.
- **The handshake.** The driver asks for a shot with a file in the work directory that names nothing; the harness
  answers only the file names it planned, each once, and writes only those files, each through a `.part` file and a
  rename, never over a file that is there, all inside the work directory: a launch whose shot files would lie
  elsewhere is not started. The shot directory is looked at before each answer: one that was replaced by a link or
  junction during the launch gets no image and no answer with sizes, and its error answer, of fixed text
  (`reason=link`), is then the one file written where the link leads. The window stays open while a request is
  pending, at most 10 s.
- **The images.** They show what REAPER and the plugin draw in that window, which may be anything the plugin shows: a
  file path, a user name, an account. The harness never reads or masks what is in them; the result has their names,
  sizes, hashes, pixel sizes, the view rectangle and the DPI. They are your results: moved to
  `renders/<run stamp>/run<round>/<id>.shots/` with or without `keep`, under the rules of kept renders
  ([below](#source-files-and-kept-renders)), never overwritten, never following a link, at most 64 MiB each. Nothing
  uploads them. Keep them out of repositories, like the work files ([INTEGRATING.md](INTEGRATING.md)).
- **Outcomes.** A shot asked for and not taken makes its state INCOMPLETE with the reason; a FAIL stays FAIL. What is
  in an image is never judged: a black or an unfinished image is a taken shot.

The launch path, the locks, the watchdog and its window rule, and the module check are unchanged: the shots ride on
the guarded launch, which is no new way to start REAPER.

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
- Keeping a render never improves its outcome: a file that could not be kept or read makes the row INCOMPLETE, a FAIL
  stays FAIL, and a render with NaN or Inf is a FAIL that is kept all the same
  ([below](#source-files-and-kept-renders)).
- `maxDiffDb: "report"` is the only way a difference between two renders is never judged: every other difference
  that stays PASS is one the configuration allows in numbers (`maxDiffDb`, `lag`, the level criteria). The word is
  written in the configuration, which takes only that exact word (any other text is a usage error; in
  criteria an extension builds by hand, any other text is bound as a number, and one that is no number makes the
  scenario INCOMPLETE), and the line and the row say `reported`. Everything else is judged as before: readable,
  comparable, finite, the same frame count, peak, silence and levels. A residual that could not be measured is
  INCOMPLETE.

## Source files and kept renders

A [source file](CONFIG.md#source-files) is a file of yours, and REAPER writes peak files next to whatever it plays. So
REAPER never sees the file itself:

- its path is resolved like an extension path: relative to the configuration file and inside its directory, links and
  junctions resolved; an absolute or drive-relative path is a usage error;
- before REAPER starts, its header is read (not its samples) and its SHA-256 taken; a format, a channel count, a length
  or a rate it cannot be played at as it is, is a usage error (exit 64) and REAPER is never started;
- each round copies it into the work directory, and the copy's hash and header must be the ones checked before the
  start; otherwise, and when the copy cannot be read back, every scenario that uses the file is INCOMPLETE and the rest
  of the round goes on. A copy whose bytes are not the hashed ones is deleted, whichever names of the same content share
  it, and every one of them is INCOMPLETE; a name whose own check fails deletes only a copy it made itself. Projects name
  only the copy;
- `NewRun` refuses a file at another rate than the render or with more channels than it, for the kinds of extensions
  too: nothing is resampled or mixed down without being said.

[Kept renders](CONFIG.md#keep), the files collected from a [probe directory](CONFIG.md#probes) and the shots of a
[held window](#shots-of-a-held-window) are the only files a run leaves in `-ResultDir` besides its result file and
`work/`:

- they go to `<ResultDir>/renders/<run stamp>/`, which must be under `-ResultDir` after expanding links and junctions
  before anything is made in it, and so must each file's place; a real path that cannot be read (links in a circle) is
  refused the same way. When the directory is refused nothing of the run is kept; when a place is, that file stays in
  the work directory;
- the first scenario that keeps or collects claims that directory by creating its manifest, which must not be there
  yet: a run started in the same second finds it and keeps nothing;
- nothing is ever overwritten: a place that is taken leaves the file in the work directory;
- the manifest is masked like a result file, and names a plugin binary like it, by bundle name and 12 hex digits of
  its hash; the hashes it gives in full are of data of the run (the kept files, the source files, the configuration,
  the plugin block as the run wrote it into the project), never of an installed binary;
- the first render of a repeat is kept only when its residual is reported and the two renders differ, or when
  `keepFirst` asks for it, next to the second and under the same rules; otherwise it stays a work file;
- nothing removes these files: delete them when you are done with them.

The version of the harness in the result and the manifest is read from its own `.git` as files: `HEAD`, for a worktree
the `gitdir:` file and `commondir` (which lead to the main repository, possibly outside the harness's directory), loose
refs and `packed-refs`. git is never run and nothing is written there; anything unexpected gives null, never an error
or a path.

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
Before the first round the harness therefore writes `vstpath64` as your other entries, then both system
directories, then the private plugins directory, and removes the cache entries of the configured bundles so REAPER
scans them afresh.

That ordering is observed behaviour, not a documented promise. So it is not trusted on its own; every round also
proves which file was loaded, in two independent ways:

- **The module list of the REAPER process.** On every poll the full paths of loaded modules with the file name of a
  tested binary are collected. Each tested binary must be seen loaded, and only from its private file (compared by
  file identity). Each learn launch is judged on its own: another file with the name of any tested binary
  (`Foreign`) makes its learn row and the round INCOMPLETE and stops learning; a binary of a plugin of that launch
  never seen (`Unseen`) makes its learn row INCOMPLETE ("the private copy is not proven"). The first learn launch
  holds every plugin, so it proves every binary. Every later launch of the round is checked for `Foreign` too.
- **`fx_ident`.** After adding each plugin the Lua driver reads `fx_ident`, which for VST3 is the full path of the
  binary followed by the class ID. It must be the private binary, and the class ID must equal the one in
  `moduleinfo.json`.

Plugin scanning happens in a separate process, so only launches that instantiate the plugin can show it in the
module list; the first learn launch always does (it holds every plugin), a later one only for the plugins of its
settings. If a future REAPER resolves duplicate names differently, the result is INCOMPLETE with the reason, never a
PASS about the wrong build.

## Keeping other plugins out

On startup REAPER loads every plugin file it has no up-to-date cache entry for. On a machine with many plugins
that means third-party code runs inside the test process: a newly installed plugin can show an activation dialog
or hang the scan. Before the first round the **scan shield** gives each file REAPER would scan outside the private
plugins directory (`*.vst3` bundles and files, `*.dll`) an empty, current entry in the private
`reaper-vstplugins64.ini` when it has none, so REAPER treats it as "scanned, no plugin here" and never loads it.
Only the private cache is written; the plugins and the system directories are only listed. The key is the file
name with every character other than ASCII letters, digits and `.` replaced by `_`; the stamp is the binary's last
write time as FILETIME in little-endian hex. Names with non-ASCII characters have no known key and are counted as
`unshielded` in the result. CLAP plugins are not shielded; the result lists every `.vst3` and `.clap` module seen
loaded, so a third-party plugin in the process is visible.

## Learning the plugin blocks

A plugin block in a project without the state REAPER saved for that plugin is reported as "effect unavailable".
So no block is ever written by hand. Once per round, learning adds every plugin (and every state and parameter set
a layout or a [variant](CONFIG.md#variants) uses) by name, sets the parameters by name and reads them back, and saves
the project; the blocks REAPER wrote are what every other project of the round uses. `TrackFX_AddByName` matches
loosely (a single letter adds some plugin), so the full name `VST3: <Name> (<Vendor>)` is used and checked after
adding: the displayed name, `fx_ident` and the class ID of the saved block must all be the expected ones. A plugin
that does not load is FAIL.

Learning runs in launches of at most `limits.learnBatchSize` settings (default 32), one row each (`learn`, or
`learn.1` … `learn.<n>`): the first holds every plugin as configured, however many, and then the settings in the
order the scenarios first use them, those of one scenario together where they fit. Each launch goes through every
guard, lock and the watchdog like any other and is proven on its own (see above). A setting is taken only when it
failed nothing (an offline plugin is not) and its plugin was proven in that launch; the clean settings of a launch
with failed ones are taken too, and the row is FAIL. A launch that failed (a timeout, a dialog, no result) leaves its
settings unlearned and the next launch still runs. Learning stops at a tested binary from outside the private copy
(that launch takes nothing, not even its clean settings) and at an unexpected error, and then nothing that needs
learning runs; it stops at a launch that was blocked (a skip marker, a busy lock) or could not be ended as well. The
launches it did not start are INCOMPLETE rows. A scenario runs only when every setting it needs was taken; otherwise
it is INCOMPLETE and names the learn row. A kind of an extension runs only when every learn row passed.

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

A [parameter listing](#listing-parameters) is read in the learn launch, after the project is saved; the blocks
learned are the same with or without it.

A path in a recorded title is masked from its drive letter, `\\` or `//` up to the next double quote or the end of the
title: a path can hold spaces, and a user name is often right after one. Everything else that reaches a result file or
the console (reasons, exception messages, the facts of a row, usage errors) is masked the same way, see
[RESULTS.md](RESULTS.md). The console names the result file without its directory.

The self-test exercises this with real message boxes. A session without a desktop (a service, for example some CI
runners) cannot show them: the self-test then states that those cases did not run. The classification in the table
above is a pure function and is tested everywhere.

## Listing parameters

`run.ps1 -List params` has no launch path of its own. It is a round of the same run with only the learn launch in it:
every guard, lock, the watchdog and the module check apply, the default resource directory is listed before and
after, and `-Only`, `-NoNegative` and `-Repeat` are refused with it. The driver reads the parameters after the learn
project is saved, so the blocks REAPER saved are those of a plain learn, and the listing itself only reads. A sweep
sets values only on an instance of its own, added on a track of its own at the end of the project and deleted again;
that instance must show the name of the plugin learned and an `fx_ident` naming the private copy and the class ID from
`moduleinfo.json` (a JSFX: its path in the private `Effects` directory), or the plugin is not listed. The project is
not saved again; REAPER's save prompt on quitting is answered No as always ([dialogs](#dialogs)).

A plugin that was not listed, or whose parameters were not all read cleanly, is INCOMPLETE, never PASS; a swept name
the plugin does not have is FAIL. An error in the listing of one plugin is that plugin's, not the learn row's.
Parameter names and display texts come from the plugin and are masked like any other text; a parameter with a path in
its name or display text is marked `masked` and is never `settable`. The listing reads nothing of REAPER's plugin
scan cache: names, class IDs and versions come from the plugin as REAPER loaded it and from `moduleinfo.json`, as in
any run.

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
- A parameter listing proves each plugin it lists, or that plugin is `INCOMPLETE`, never `PASS`: its learn entry did
  not pass, the driver stopped listing it with an error, the count of its parameters is missing, not a whole number
  or changed while it was read, a parameter has no name, an instance to sweep could not be added, is not the plugin
  learned (its name, its binary and class ID, or its JSFX path) or reports no parameter index, a swept value was not
  read back as a number from 0 to 1 with its display text, or a parameter's value is not from 0 to 1, its display
  text is missing or its name is not exact. With no plugin to list the `params` row is `INCOMPLETE` too.
- A render asked to have a tail whose master or any stem does not have exactly the frames asked for is `INCOMPLETE`:
  nothing shows that the tail was rendered.
- A residual that is only reported but could not be measured (no overlapping finite samples) is `INCOMPLETE`.
- A render that asks for a probe directory and gets fewer files than `min` (default 1) is `INCOMPLETE`, and so is one
  whose directory could not be looked at: replaced by a link or junction, more than 10000 entries, or a process of the
  round still running.
- A `transport` state that asks for shots and does not get each one is `INCOMPLETE`, with the reason per shot.

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
