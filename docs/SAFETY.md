# Safety

The harness starts a real REAPER on your desktop many times in a row. These are the rules it keeps so that this
never changes your own REAPER setup and never hides a failure. Every rule has self-test cases
(`pwsh run.ps1 -SelfTest`) that turn red when the rule is removed.

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

`src/Guard.psm1` lists `%APPDATA%\REAPER` (file sizes and write times, read only) and compares two listings; the
self-test does so before and after it runs, and fails when anything changed.

## Only its own processes, one GUI run at a time

- The watchdog ends only the process ID it started, at the time limit (`Timeout`) or at a kill point (`Killed`).
- Before every launch the harness takes its GUI lock, `Local\ReaperHarness-gui`, a kernel mutex. `-ExtraGuiLock
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
| `Render…`, `Scanning…`, `Building peaks…` | progress windows, left alone |
| `About REAPER…` (the evaluation licence reminder) | never clicked away: stuck, `license-nag` |
| `Project Load Warning`, `REAPER Error`, `Select files to save or delete`, `REAPER` (no audio device) | stuck, named |
| anything else | stuck, `unknown-dialog` with the title (paths masked) |

A stuck dialog ends the launch, which is recorded as `Modal` with the dialog's name. The evaluation reminder shows
up on some launches only (about one in six in our runs); buy a licence or run again.

## Scripts

Every script runs under `Set-StrictMode -Version Latest`. PowerShell variable names are case insensitive, so a loop
variable `$cfgDir` silently overwrites a parameter `$CfgDir`; a lint rule refuses variable names in one file that
differ only by case. Scripts and data files must not contain invisible control characters (a stray carriage
return inside a regex changes its meaning without showing in an editor or a diff). Only `src/Guard.psm1` and the
self-test mention `APPDATA`. `.Keys` and `.Values` are never read as properties: on a dictionary with an entry named
`Keys` (a configuration key, a file name, a variable name) the property returns that entry, and a check that walks the
keys silently walks one value instead. The lint rule found exactly that in its own case scan: a script with a
variable `$keys` was not scanned at all. `.get_Keys()`, `.get_Values()` and `.GetEnumerator()` cannot be shadowed.
