# Safety

The harness starts a real REAPER on your desktop many times in a row. These are the rules it keeps so that this
never changes your own REAPER setup and never hides a failure. Every rule has self-test cases
(`pwsh run.ps1 -SelfTest`) that turn red when the rule is removed.

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

Arguments reach REAPER one by one, not as one command line, so a space in a path cannot split it and the private ini
is always the element right after `-cfgfile`. Before the start, `-ReaperArgs` holding a double quote (a caller still
quoting for itself, which would hand REAPER literal quotes) or naming the `-cfgfile` switch again is refused.

`src/Guard.psm1` lists `%APPDATA%\REAPER` (file sizes and write times, read only) and compares two listings; the
self-test does so before and after it runs, and fails when anything changed. A file or directory that cannot be
listed is recorded as `unreadable` (the directory itself under the name `.`), and a comparison with anything
unreadable on either side is not "unchanged", also when both listings say the same: what cannot be read cannot be
proven to have stayed as it was. The comparison names those entries.

The self-test reaches a mapped network drive and a link count that cannot be read through stand-ins for the functions
that read them, and uses a real letter with nothing mounted on it. A real mapped drive changes the machine, so one is
only made on a hosted runner, where it is deleted again; everywhere else that case, like a symbolic link in a session
without the privilege for one, is counted as not run for real in the summary line. What the self-test undoes on the
machine (a deny entry, a subst drive, a mapped drive) is checked as undone, and a failure there turns a case red.

## Only its own processes, one GUI run at a time

- The watchdog ends only the process ID it started, at the time limit (`Timeout`) or at a kill point (`Killed`).
- A process the watchdog could not end is reported, not assumed gone: the launch result has `StillRunning`, true when
  the stop failed or the process was still there after the wait, and false when it is gone (a process that had already
  exited is no failure). A caller that sees `StillRunning` true records `INCOMPLETE`, does not release its GUI lock and
  does not start the next launch: that window may still be on the desktop. `Invoke-WithHarnessLocks` always releases
  when its block ends, so a caller that can start REAPER must not use it: it takes and releases the locks itself with
  `Enter-HarnessLocks` and `Exit-HarnessLocks`.
- Before every launch the GUI lock has to be held: `Invoke-HarnessHost` enforces it, and without the object
  `Enter-HarnessLocks` returned for a set holding the default lock it refuses before anything starts. The other two
  checks before a launch, that no other `reaper.exe` is running and the listing of the default directory, are the job
  of the run command, which arrives with the scenarios.
- The default lock is `Local\ReaperHarness-gui`, a kernel mutex. `-ExtraGuiLock
  <Local\name>` adds more (for example the lock another tool on the same machine uses for its GUI tests); locks can
  only be added, never removed. All locks of a set are taken in a fixed order, all or nothing, so two runs with
  different sets cannot deadlock. If the set cannot be taken within the wait limit, nothing is started. A holder
  that crashes or is killed releases its locks (the kernel does), so they never stay taken.
- `Local\` names only exclude within one logon session; do not run the harness from SSH, a scheduled task or
  another user's session at the same time.

## Dialogs

A modal dialog would stop REAPER forever. On every poll (every 250 ms) the windows of the started process ID, and
only those, are classified:

| title | action |
|---|---|
| `REAPER Query` (save changes?) | answered No |
| `Render…`, `Scanning…`, `Building peaks…` | progress windows, left alone, unless the title has `fail` or `error` in it in any case: those report trouble and do not go away on their own, so they are stuck, `unknown-dialog` |
| `About REAPER…` (the evaluation licence reminder) | never clicked away: stuck, `license-nag` |
| `Project Load Warning`, `REAPER Error`, `Select files to save or delete`, `REAPER` (no audio device) | stuck, named |
| anything else | stuck, `unknown-dialog` with the title (paths masked) |

A stuck dialog ends the launch, which is recorded as `Modal` with the dialog's name. The evaluation reminder shows
up on some launches only (about one in six in our runs); buy a licence or run again.

A path in a recorded title is masked from its drive letter, `\\` or `//` up to the next double quote or the end of the
title: a path can hold spaces, and a user name is often right after one.

The self-test exercises this with real message boxes. A session without a desktop (a service, for example some CI
runners) cannot show them: the self-test then states that those cases did not run. The classification in the table
above is a pure function and is tested everywhere.

## No evidence is not a pass

- A render with no frames is `INCOMPLETE`, before every other criterion and with or without a tolerance: nothing was
  compared, and two empty files being bit-identical says nothing.
- A render whose data length is still the placeholder `0xFFFFFFFF` is unreadable, so `INCOMPLETE` in a comparison and on
  its own alike: the writer never came back to fill in the length, so the file is not finished, and what is in it says
  nothing about what is missing. REAPER's finished renders hold the real length.
- With no plugin binaries expected, the proof of which binaries were loaded is `Unseen`, not proven.

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
