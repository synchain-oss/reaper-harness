# Using reaper-harness in your plugin project

This page is for a plugin project that wants its VST3 builds tested in REAPER without anyone at the keyboard. Your
project keeps one configuration file (and maybe a template project and an extension module); the harness itself
stays a separate clone. [`examples/scvb/`](../examples/scvb/) is a complete worked example for a set of three
plugins that talk to each other, and the sections below go through it part by part.

Read [SAFETY.md](SAFETY.md) once before the first run: the harness runs on your own desktop, next to your everyday
REAPER and plugins, and the rules at the end of this page are what keeps it that way.

## 1. Get the tool

Clone the repository next to your project, not into it, and pin it to one commit:

```powershell
git clone https://github.com/synchain-oss/reaper-harness.git D:\tools\reaper-harness
git -C D:\tools\reaper-harness checkout --detach <40-hex commit>
```

- Pin a full 40-character commit of `feature/v1` or `dev`. Record it in your repository (a one-line file next to
  your configuration is enough) and have your test script compare it with `git -C <clone> rev-parse HEAD` before
  each run, so every result is tied to the harness version that produced it. Once releases are tagged, pinning the
  commit of a tag works the same way.
- Do not copy the harness's files into your repository and do not keep a patched copy. Its guards and the self-test
  that proves them come as a whole; a copy drifts away from both. If something is missing, open an issue (section 8).
- Run the self-test of a new pin once: `pwsh run.ps1 -SelfTest` (a few minutes, no REAPER).

## 2. Create the private configuration directory

```powershell
pwsh doctor.ps1 -CfgDir D:\reaper-harness\cfg -Init
```

- The directory must be new, empty or one the harness initialised before. It can never be REAPER's default resource
  directory (`%APPDATA%\REAPER`), anything under `%APPDATA%`, or a link or junction to such a place: the harness
  refuses, and there is no option to override that.
- Keep one directory per machine and reuse it. It is not part of your project and never goes into a repository.
- The first start in a new directory lists every plugin file on the machine for the scan shield (see SAFETY.md),
  which can take a minute. If that is too slow you may copy a scan cache (`reaper-vstplugins64.ini`) into the
  private directory: copy it, never move or link it, and only read the source. The cache names every plugin
  installed on the machine, so it never goes into a repository, a result or a log; the harness never puts it there.

## 3. Write the configuration

Start from [CONFIG.md](CONFIG.md) and check every change without REAPER:

```powershell
pwsh D:\tools\reaper-harness\doctor.ps1 -Config tests\reaper-harness.json
```

What follows walks through [`examples/scvb/reaper-harness.json`](../examples/scvb/reaper-harness.json). The plugins
there are an input plugin (last on each vocal track), an output plugin (first on the vocal bus) and a read-only
monitor. Instances find each other at run time by a group number.

### Plugins and states

```json
"plugins": {
  "input": {
    "bundle": "SCVB Input.vst3",
    "states": {
      "ch1": { "template": "routing-template.rpp", "track": "Vox 1", "fx": 1 },
      "ch2": { "template": "routing-template.rpp", "track": "Vox 2", "fx": 1 },
      "ch3": { "template": "routing-template.rpp", "track": "Vox 3", "fx": 1 }
    }
  },
  "output": { "bundle": "SCVB Output.vst3", "states": { "group-8": { "template": "routing-template.rpp", "track": "Bus", "fx": 1 } } },
  "monitor": { "bundle": "SCVB Monitor.vst3", "states": { "group-8": { "template": "routing-template.rpp", "track": "Bus", "fx": 2 } } }
}
```

- `bundle` is the folder name in `-PluginDir`; the plugin's name, vendor and class ID come from its
  `moduleinfo.json`, so a build without one cannot be tested.
- A plugin without `states` is tested in its default state. A state is a plugin block REAPER saved, taken from a
  template project by track name and FX number. Settings that live in the state rather than in parameters (here:
  the group and the channel) can only be tested this way.

**Making the template.** Any project REAPER saved will do: set the plugins up as you need them and save. Keep it
minimal, because it goes into your repository: only your own plugins, no media, no file paths; run your privacy
checks on it. Only the named blocks are ever read from it.

To set a state up without anyone at the keyboard, drive the plugin's own editor. For an editor that is a WebView2
page, two environment variables given to that one REAPER process are enough:
`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=<port>` opens the Chrome DevTools Protocol, bound to
127.0.0.1 only, and `WEBVIEW2_USER_DATA_FOLDER=<scratch directory>` keeps WebView2's data out of the user's profile.
A small CDP client can then call the functions the page itself calls, and a Lua script saves the project. Do this
only while making the template: start that REAPER with the private configuration directory, on a desktop nobody
looks at, pick a free port and check that nothing listens on it first, end only the process you started, and never
leave the variables set for a normal run. If the plugin writes settings or logs of its own when its editor opens,
point that process's profile folders (`USERPROFILE`, `APPDATA`, `LOCALAPPDATA`) at a scratch directory as well. That
works for plugins that look these folders up from the process environment; not every plugin does, so also compare a
listing of the plugin's real data directories before and after.

**Choosing a group number.** Plugins that find each other through shared memory or named pipes see every instance
on the machine that uses the same name, including the ones in a DAW the user has open. When the shared names differ
only by a group number, that number is all that keeps a test apart from a live session. So:

- put a group number into your test states that users are unlikely to use, not the default one (the example uses 8);
- add a preflight (see [EXTENDING.md](EXTENDING.md#preflight)) that probes, read-only, for the names your plugin
  creates and makes the suite SKIPPED while any of them exists.
  [`examples/scvb/scvb-preflight.psm1`](../examples/scvb/scvb-preflight.psm1) is such a probe: it opens each
  name read-only, closes it again at once and never creates one.

The preflight runs once, before the run. There is no hook after the run, so an instance that someone opens in the
middle of a run is not caught; say so in your validation notes.

**Track names.** A plugin can keep in its state what it sees of other instances, for example the names of the
tracks its inputs sit on. Name the tracks of a layout that uses such states as the template does (the example uses
`Bus` and `Vox 1` … `Vox 3` in both); the harness names the learn tracks the same way (see
[CONFIG.md](CONFIG.md#states)).

### Signal and layouts

```json
"signal": { "seconds": 4, "seed": 1, "noiseDb": -20 },
"layouts": {
  "monitor": { "tracks": [ { "name": "Voice", "source": true, "fx": [ { "plugin": "monitor" } ] } ] },
  "system": {
    "tracks": [
      { "name": "Bus", "source": false, "folder": true, "fx": [ { "plugin": "output" }, { "plugin": "monitor" } ] },
      { "name": "Vox 1", "source": true, "parent": "Bus", "signal": { "seed": 11 }, "fx": [ { "plugin": "input" } ] },
      { "name": "Vox 2", "source": true, "parent": "Bus", "signal": { "seed": 12 }, "fx": [ { "plugin": "input" } ] },
      { "name": "Vox 3", "source": true, "parent": "Bus", "signal": { "seed": 13 }, "fx": [ { "plugin": "input" } ] }
    ]
  },
  "routing": {
    "tracks": [
      { "name": "Bus", "source": false, "folder": true, "fx": [ { "plugin": "output", "state": "group-8" }, { "plugin": "monitor", "state": "group-8" } ] },
      { "name": "Vox 1", "source": true, "parent": "Bus", "signal": { "seed": 11 }, "fx": [ { "plugin": "input", "state": "ch1" } ] },
      { "name": "Vox 2", "source": true, "parent": "Bus", "signal": { "seed": 12 }, "fx": [ { "plugin": "input", "state": "ch2" } ] },
      { "name": "Vox 3", "source": true, "parent": "Bus", "signal": { "seed": 13 }, "fx": [ { "plugin": "input", "state": "ch3" } ] }
    ]
  }
}
```

- One small layout per plugin (here `monitor`, `input`, `output`) tests each one on its own; a layout like `system`
  puts them where they belong in a session. Give each source track its own `seed`, so a swapped or dropped track
  shows in the render.
- `system` uses every plugin in its default state, `routing` the states from the template. Keep both: they test
  different things (see below).
- Folders nest: a folder track can have another folder as its `parent`; children follow their folder directly, and
  the first track after the last child of an inner folder can belong to the outer one again:

```json
"nested": {
  "tracks": [
    { "name": "Bus", "source": false, "folder": true, "fx": [ { "plugin": "output", "state": "group-8" } ] },
    { "name": "Pair", "source": false, "folder": true, "parent": "Bus" },
    { "name": "Vox 1", "source": true, "parent": "Pair", "signal": { "seed": 11 }, "fx": [ { "plugin": "input", "state": "ch1" } ] },
    { "name": "Vox 2", "source": true, "parent": "Pair", "signal": { "seed": 12 }, "fx": [ { "plugin": "input", "state": "ch2" } ] },
    { "name": "Vox 3", "source": true, "parent": "Bus", "signal": { "seed": 13 }, "fx": [ { "plugin": "input", "state": "ch3" } ] }
  ]
}
```

### Scenarios and criteria

```json
{ "id": "monitor", "kind": "render", "layout": "monitor", "matrix": { "mode": ["offline", "1x"], "sr": [44100, 48000], "block": [64, 1024] } },
{ "id": "monitor-bypass", "kind": "render", "layout": "monitor", "bypass": true },
{ "id": "system", "kind": "render", "layout": "system", "matrix": { "mode": ["offline", "1x", "online"] } },
{ "id": "system-repeat", "kind": "render", "layout": "system", "compare": "repeat" },
{ "id": "system-device", "kind": "device", "layout": "system-params", "matrix": { "sr": [44100, 48000], "block": [64, 1024] } },
{ "id": "system-reopen", "kind": "savereopen", "layout": "system-params", "cycles": 3 },
{ "id": "instances", "kind": "instances", "plugins": ["monitor", "input", "output"] }
```

Only write criteria that your plugin's documentation or a measurement supports, and say in your notes which one it
was. A `render` without `compare` is compared with the dry render (the same layout without any FX) and must be
bit-identical; that is right only for a plugin documented to pass audio through untouched.

- The example's default-state layouts are judged bit-identical to dry: with no input assigned to a channel, these
  plugins leave the audio as it is. A green result there shows passthrough, nothing more. It says nothing about the
  routing the plugins do once they are set up, so do not report it as "routing tested".
- For a layout whose plugins change the audio on purpose, measure first: run it once with wide limits (`maxDiffDb`
  24, `rmsChangeDb` `[-400, 24]`), look at the numbers and at the renders (`-KeepWork` keeps them), then write the
  limits down together with where they came from. The example's routing layout came out like this:

```json
{ "id": "routing", "kind": "render", "layout": "routing", "matrix": { "mode": ["offline", "1x"] },
  "maxDiffDb": 12, "rmsChangeDb": { "L": [-0.5, 0.5], "R": [-0.5, 0.5] },
  "stems": [
    { "track": "Vox 1", "rmsChangeDb": { "L": [-400, -6], "R": [-400, -6] } },
    { "track": "Vox 2", "rmsChangeDb": { "L": [-400, -6], "R": [-400, -6] } },
    { "track": "Vox 3", "rmsChangeDb": { "L": [-400, -6], "R": [-400, -6] } }
  ] }
```

  - At the start of every render the inputs pass their tracks through for a moment (0.1 to 0.4 s, depending on the
    block size), then the output plugin takes the mix over. After that the master equals the dry mix up to rounding,
    but within the handover it does not, so the master is judged by its level (RMS within 0.5 dB of dry) and not
    sample by sample. `maxDiffDb` 12 only bounds the handover: at worst a whole copy of the mix is missing or added
    there, which is the mix's own peak (+9.54 dBFS with three tracks).
  - Each vocal track's stem must be at least 6 dB below dry: once connected, the input silences its own track and
    the output plugin plays it on the bus instead. The stem keeps the scenario's `maxDiffDb`; its difference from dry
    is the whole track, since the track is silent by design.
  - Two renders of this layout are not always bit-identical in their master (see the validation notes), so the
    repeat render `routing-repeat` is judged by the same master levels as the comparison with dry. Its vocal stems
    give `"maxDiffDb": -400`, the lowest value the tool takes (any difference above 10^-20 fails): a stem takes the
    scenario's `maxDiffDb` otherwise, and the vocal tracks are expected to come out the same in both renders.
  - The render with every FX bypassed must be bit-identical to dry, master and stems. `routing-reopen` saves and
    reopens the project with every FX bypassed (`"bypass": true`): every state must still be saved back unchanged,
    and the reopened render, which then does not depend on the handover, must be bit-identical. `device` checks that
    every state is saved back unchanged as well.
  - The online render of this layout is not judged: measured, the master stays silent for 1.2 to 1.3 s after the
    handover there.
  - The negative case `neg-passthrough-is-not-routing` applies the vocal-track criterion to the all-default layout
    and must come out FAIL, which shows that the criterion tells routing from passthrough.
- `device` checks the reported latency (`expectPdc`, from the documentation), the block size, the sample rate and
  the parameters read back; give a parameter `{ "normalized", "display" }` once you have seen the text REAPER shows
  for it (the example: `Width` 0.5 shows `75 %`). `savereopen` and `instances` need no criteria of their own beyond
  their limits.
- Add negative cases of your own: a variant that must come out FAIL proves the comparison can see the difference you
  care about (the example: one track 6 dB quieter must not be identical to the system layout).

## 4. Run and read the results

```powershell
pwsh D:\tools\reaper-harness\run.ps1 -Config tests\reaper-harness.json -CfgDir D:\reaper-harness\cfg `
    -PluginDir build\VST3 -ResultDir D:\reaper-harness\results -SkipMarker <your marker> -ExtraGuiLock <your lock>
```

- `-PluginDir` is your build output; the harness copies the bundles into the private directory and proves in every
  round that REAPER loaded those copies, not an installed release of the same plugin.
- The console prints one line per row and the result file name. [RESULTS.md](RESULTS.md) describes the file; it
  holds no local paths, only bundle names and hash prefixes.
- PASS is the only green. INCOMPLETE means no conclusion (something could not run or could not be proven); it is
  never a PASS and never something to loosen criteria for. Run again first: REAPER's evaluation reminder can make a
  single launch INCOMPLETE now and then. SKIPPED means the suite did not start at all (a skip marker, another
  `reaper.exe`, a preflight reason); the reasons are printed.
- The work files of a round that is not green are kept under `<ResultDir>/work/`; they hold your plugin states, so
  keep them out of repositories too.

## 5. Skip markers and GUI locks

Two conventions let the harness share a machine with you and with your other tests:

- **Skip markers.** `-SkipMarker <file>` (repeatable): while that file exists the suite is SKIPPED and REAPER is
  never started. It is checked again before every launch, so a marker created during a run stops the launches after
  it. Agree on one file per machine that means "someone is using this machine", create it while you test by hand,
  and pass it to every unattended run.
- **GUI locks.** Before every launch the harness takes the named mutex `Local\ReaperHarness-gui`, plus every
  `-ExtraGuiLock <Local\name>`, in a fixed order; it never runs without them, and a lock it cannot get makes the row
  INCOMPLETE. If your project has GUI tests of its own (an editor smoke test, a test host with windows), let them
  take a lock of your own and pass that lock as `-ExtraGuiLock`, so the two never show windows at the same time.

## 6. What never to do

- Point `-CfgDir` (or a link or junction) at REAPER's default resource directory, or copy anything from the private
  directory back into it.
- Run with your own REAPER open, or start one during a run. The harness refuses to start next to a running
  `reaper.exe`, but cannot stop one started in the middle; create your skip marker first.
- End REAPER by process name or window title (`taskkill /IM`, `Stop-Process -Name`) in your own scripts. The harness
  ends only the process IDs it started; anything else may be your user's session.
- Run without the GUI locks, or drop `Local\ReaperHarness-gui`.
- Commit the private configuration directory, the scan cache or the work directories.
- Write into your plugin's own user data directories from a test, or let a test do it for you; list them before and
  after instead.
- Count INCOMPLETE as PASS, or change criteria until a red row turns green. Find out first whether the tool or the
  plugin is at fault.

## 7. Validation notes

Keep a short note per tested release in your project: REAPER version, Windows version, number of rounds, the outcome
of each scenario, the module check, and what the run cannot show (passthrough vs. routing, anything the preflight
cannot catch mid-run). [`docs/validation/`](validation/) holds the notes for the worked example.

## 8. Problems

Open an issue in this repository: https://github.com/synchain-oss/reaper-harness/issues. Attach the result file
(it holds no local paths) and say which commit of the harness you pinned. Security problems go to the address in
[SECURITY.md](../SECURITY.md) instead of an issue.
