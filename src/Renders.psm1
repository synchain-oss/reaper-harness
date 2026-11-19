# SPDX-License-Identifier: MIT
#
# Kept renders, their manifest, and the version of the harness itself.
#   Get-HarnessToolVersion      { version (one constant); commit } of this harness
#   Get-HarnessGitCommit <dir>  the commit checked out in a directory, read from its .git without running git: .git as a
#                               directory or as a "gitdir:" file (worktrees, with commondir), HEAD as a commit or as a
#                               ref resolved through its loose file or packed-refs. Anything unexpected gives $null,
#                               never an error and never a path. Changes not committed are not detected.
#   New-HarnessKeep             what one run keeps: <ResultDir>/renders/<run stamp>/, run fields of every manifest line
#   Save-HarnessKeptRender      after the verdict of a render scenario with keep: moves its own render and stems to
#                               run<k>/<id>.wav and run<k>/<id>-stem-<track>.wav, never over a file that is there, then
#                               appends its manifest line (written and flushed at once, every string masked). The
#                               first one checks that renders/<stamp> is under the result directory (real paths) and
#                               claims it by creating the manifest: a run of the same second finds it and keeps nothing.
#                               Returns Status and Detail of the row (INCOMPLETE added when something could not be
#                               kept or a kept file could not be read, FAIL stays FAIL) and the Record.
#   Move-HarnessKeptFile        one file, only to a place under the result directory, never over another (pure on files)
#   Get-HarnessKeptFileFacts    a kept file: path, sha256, frames, channels, sampleRate, format, peakDb, nanCount, infCount
#   Get-HarnessFxFacts          every FX of a layout as rendered: plugin, binary hash, bypass, state, the hash of its
#                               block as written into the project, the parameters asked for and read back, the latency
#   ConvertTo-HarnessKeptFacts  a record with its paths relative to the result directory (the facts of the row)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Guard.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Json.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Wav.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Rpp.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Plugins.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Sources.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Scenarios.psm1') -ErrorAction Stop

$script:ToolVersion = '0.1.0'
$script:Hex40 = '^[0-9a-f]{40}$'

function Get-HarnessGitCommit([string]$Root) {
    try {
        $dotGit = Join-Path $Root '.git'
        if (Test-Path -LiteralPath $dotGit -PathType Container) { $gitDir = $dotGit }
        elseif (Test-Path -LiteralPath $dotGit -PathType Leaf) {
            $m = [regex]::Match([IO.File]::ReadAllText($dotGit), '\Agitdir: ([^\r\n]+)\r?\n?\z')
            if (-not $m.Success) { return $null }
            $gitDir = [IO.Path]::GetFullPath($m.Groups[1].Value, $Root)
        } else { return $null }
        $common = $gitDir
        $cd = Join-Path $gitDir 'commondir'
        if (Test-Path -LiteralPath $cd -PathType Leaf) { $common = [IO.Path]::GetFullPath([IO.File]::ReadAllText($cd).Trim(), $gitDir) }
        $head = [IO.File]::ReadAllText((Join-Path $gitDir 'HEAD')).Trim()
        if ($head -cmatch $script:Hex40) { return $head }
        $r = [regex]::Match($head, '\Aref: (refs/[A-Za-z0-9._/-]+)\z')
        if (-not $r.Success -or $r.Groups[1].Value.Contains('..')) { return $null }
        $ref = $r.Groups[1].Value
        foreach ($d in $gitDir, $common) {
            $f = Join-Path $d $ref
            if (Test-Path -LiteralPath $f -PathType Leaf) { $v = [IO.File]::ReadAllText($f).Trim(); return ($v -cmatch $script:Hex40) ? $v : $null }
        }
        $packed = Join-Path $common 'packed-refs'
        if (Test-Path -LiteralPath $packed -PathType Leaf) {
            foreach ($line in [IO.File]::ReadAllLines($packed)) { if ($line -cmatch '\A([0-9a-f]{40}) (\S+)\z' -and $Matches[2] -ceq $ref) { return $Matches[1] } }
        }
        $null
    } catch { $null }
}

function Get-HarnessToolVersion { [ordered]@{ version = $script:ToolVersion; commit = (Get-HarnessGitCommit ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))) } }

# Run: the fields every manifest line repeats (reaper, toolVersion, toolCommit, buildLabel, config).
function New-HarnessKeep([Parameter(Mandatory)][string]$ResultDir, [Parameter(Mandatory)][string]$Stamp, [System.Collections.IDictionary]$Run = [ordered]@{}) {
    $dir = Join-Path $ResultDir "renders/$Stamp"
    [pscustomobject]@{ ResultDir = $ResultDir; Stamp = $Stamp; Rel = "renders/$Stamp"; Dir = $dir; Manifest = (Join-Path $dir 'manifest.jsonl'); Run = $Run; Checked = $false; Refused = ''; Lines = 0 }
}

# A real path that cannot be read (links that lead round in a circle, nested too deep) proves nothing: refused too.
function Move-HarnessKeptFile([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To, [Parameter(Mandatory)][string]$ResultDir) {
    $leaf = Split-Path -Leaf $To
    try { $inside = (Test-HarnessUnder $To $ResultDir) -and (Test-HarnessUnder (Resolve-HarnessRealPath $To) (Resolve-HarnessRealPath $ResultDir)) }
    catch { return "$leaf cannot be shown to be under the result directory: $($_.Exception.Message -replace '\s+', ' ')" }
    if (-not $inside) { return "$leaf would not be under the result directory" }
    if (Test-Path -LiteralPath $To) { return "$leaf is there already and is never overwritten" }
    try { $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $To); [IO.File]::Move($From, $To, $false) }
    catch { return "$leaf could not be moved there: $($_.Exception.Message -replace '\s+', ' ')" }
    $null
}

# Rel: the path the manifest names the file by ('' when nothing was kept: every field is null then). peakDb is null for
# a file without a finite sample above zero. A kept file that cannot be read (a scanner holding it, not a WAV) keeps
# the fields read so far, and the reason goes to Reasons.
function Get-HarnessKeptFileFacts([string]$Path, [string]$Rel, [Collections.Generic.List[string]]$Reasons = [Collections.Generic.List[string]]::new()) {
    $f = [ordered]@{ path = $null; sha256 = $null; frames = $null; channels = $null; sampleRate = $null; format = $null; peakDb = $null; nanCount = $null; infCount = $null }
    if (-not $Rel) { return $f }
    $f.path = $Rel
    try {
        $f.sha256 = Get-HarnessSha256 $Path
        $scan = Get-HarnessWavScan $Path
        $f.frames = $scan.Info.Frames; $f.channels = $scan.Info.Channels; $f.sampleRate = $scan.Info.Rate; $f.format = $scan.Info.Format
        $f.peakDb = ($scan.Peak -gt 0) ? [Math]::Round(20 * [Math]::Log10($scan.Peak), 6) : $null
        $f.nanCount = $scan.Nan; $f.infCount = $scan.Inf
    } catch { $Reasons.Add("$(Split-Path -Leaf $Rel) could not be read: $($_.Exception.Message -replace '\s+', ' ')") }
    $f
}

function Get-HarnessFxFacts([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Layout, [string[]]$Bypass = @()) {
    , @(foreach ($t in $Layout.Tracks) {
            for ($i = 0; $i -lt $t.Fx.Count; $i++) {
                $fx = $t.Fx[$i]
                $vst = $Ctx.Installed.ContainsKey($fx.Plugin) ? $Ctx.Installed[$fx.Plugin] : $null
                $js = $Ctx.Jsfx.ContainsKey($fx.Plugin) ? $Ctx.Jsfx[$fx.Plugin] : $null
                $read = $Ctx.LearnReads.ContainsKey($fx.Variant) ? $Ctx.LearnReads[$fx.Variant] : $null
                $sk = "$($fx.Plugin)@$($fx.State)"
                $pdc = 0
                [ordered]@{
                    track = $t.Name; index = $i; plugin = $fx.Plugin; bundle = ($vst ? $vst.Bundle : $null); jsfx = ($js ? $js.Jsfx : $null); name = ($read ? $read.Name : $null)
                    sha256 = ($vst ? $vst.Sha256.Substring(0, 12) : ($js ? $js.Sha256.Substring(0, 12) : $null)); bypass = (Test-HarnessFxBypassed $fx $Bypass)
                    state = ($fx.State ? $fx.State : $null); stateSha256 = (($fx.State -and $Ctx.States.Contains($sk)) ? $Ctx.States[$sk].Sha : $null)
                    blockSha256 = ($Ctx.Blocks.ContainsKey($fx.Variant) ? [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes((Get-HarnessBlockText $Ctx.Blocks[$fx.Variant])))).ToLowerInvariant() : $null)
                    params = @(foreach ($pn in $fx.Params.get_Keys()) {
                            $back = ($read -and $read.Params.Contains($pn)) ? $read.Params[$pn] : $null
                            [ordered]@{ name = $pn; normalized = $fx.Params[$pn].Normalized; readNormalized = ($back ? $back.Read : $null); readDisplay = ($back ? $back.Display : $null) }
                        })
                    pdc = (($read -and [int]::TryParse([string]$read.Pdc, [ref]$pdc)) ? $pdc : $null); pdcReadAt = ($read ? [ordered]@{ sr = $read.Sr; block = $read.Block } : $null)
                }
            }
        })
}

function Get-HarnessSourceFacts([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Layout) {
    , @(foreach ($t in $Layout.Tracks) {
            if (-not $t.Source) { continue }
            $file = Get-HarnessTrackFile $t
            if ($file) {
                $key = Get-HarnessSourceKey $Ctx.Config.ConfigDir $file
                $c = $Ctx.SourceCopies.ContainsKey($key) ? $Ctx.SourceCopies[$key] : $null
                [ordered]@{ track = $t.Name; file = ($c ? (ConvertTo-HarnessSourceFact $c.File) : [ordered]@{ path = $key }); signal = $null }
            } else {
                $g = $t.Signal ?? $Ctx.Signal
                [ordered]@{ track = $t.Name; file = $null; signal = [ordered]@{ seconds = $Ctx.Signal.Seconds; seed = $g.Seed; noiseDb = $g.NoiseDb; sine = (($g.SineHz -gt 0) ? [ordered]@{ hz = $g.SineHz; db = $g.SineDb } : $null) } }
            }
        })
}

# Why nothing of this run can be kept ('' when it can): renders/<stamp> must be under the result directory, links and
# junctions resolved, before anything is made there, and it is claimed by creating its manifest, which a run started in
# the same second finds there. Never throws: whatever goes wrong is the reason, for every scenario of the run.
function Get-HarnessKeepRefusal([Parameter(Mandatory)]$Keep) {
    try { $inside = Test-HarnessUnder (Resolve-HarnessRealPath $Keep.Dir) (Resolve-HarnessRealPath $Keep.ResultDir) }
    catch { return "$($Keep.Rel) cannot be shown to be under the result directory: $($_.Exception.Message -replace '\s+', ' ')" }
    if (-not $inside) { return "$($Keep.Rel) would not be under the result directory" }
    try { $null = New-Item -ItemType Directory -Force -Path $Keep.Dir; [IO.FileStream]::new($Keep.Manifest, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read).Dispose(); '' }
    catch { (Test-Path -LiteralPath $Keep.Manifest) ? "$($Keep.Rel)/manifest.jsonl is there already (a run started in the same second)" : "$($Keep.Rel) could not be made: $($_.Exception.Message -replace '\s+', ' ')" }
}

function Get-HarnessWorse([string]$A, [string]$B) { foreach ($x in 'FAIL', 'INCOMPLETE') { if ($x -cin $A, $B) { return $x } }; 'PASS' }

function Save-HarnessKeptRender {
    param([Parameter(Mandatory)]$Keep, [Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Scenario, [int]$Round = 1, [Parameter(Mandatory)][string]$Status, [string]$Detail = '')
    $s = $Scenario
    try {
        # The refusal is set before the claim counts as done: a claim that threw is tried again, never taken as made
        if (-not $Keep.Checked) { $Keep.Refused = Get-HarnessKeepRefusal $Keep; $Keep.Checked = $true }
        $problems = [Collections.Generic.List[string]]::new() # what was not kept
        $unread = [Collections.Generic.List[string]]::new() # what was kept but could not be described
        if ($Keep.Refused) { $problems.Add($Keep.Refused) }
        $stemTracks = @($s.stems | ForEach-Object { $_.Track })
        $files = Get-HarnessRunFiles $Ctx.Work $s.id $stemTracks
        # The master of a render with stems is <id>-stem-Master.wav in the work directory; kept, it is <id>.wav
        $plan = @([pscustomobject]@{ From = $files.Wav; Leaf = "$($s.id).wav"; Track = '' }) + @(foreach ($t in $stemTracks) { [pscustomobject]@{ From = $files.Stems[$t]; Leaf = "$($s.id)-stem-$t.wav"; Track = $t } })
        $out = @(foreach ($p in $plan) {
                $keptRel = "run$Round/$($p.Leaf)"
                $dest = Join-Path $Keep.Dir $keptRel
                $kept = $false
                # No file (the render failed): nothing to move; the line still says how the scenario ended
                if (-not $Keep.Refused -and (Test-Path -LiteralPath $p.From -PathType Leaf)) {
                    $why = Move-HarnessKeptFile -From $p.From -To $dest -ResultDir $Keep.ResultDir
                    if ($why) { $problems.Add($why) } else { $kept = $true; while ($Ctx.Files.Remove($p.From)) { } }
                }
                $facts = Get-HarnessKeptFileFacts $dest ($kept ? $keptRel : '') $unread
                if ($p.Track) { $named = [ordered]@{ track = $p.Track }; foreach ($k in $facts.get_Keys()) { $named[$k] = $facts[$k] }; $facts = $named }
                $facts
            })
        if ($problems.Count) { $Status = Get-HarnessWorse $Status 'INCOMPLETE'; $Detail += "; not kept: $($problems -join '; ')" }
        if ($unread.Count) { $Status = Get-HarnessWorse $Status 'INCOMPLETE'; $Detail += "; kept, but $($unread -join '; ')" }
        $scenarioLayout = Get-HarnessLayout $Ctx $s.layout
        $record = [ordered]@{
            schema = 1; runStamp = $Keep.Stamp; round = $Round; scenario = $s.id; baseScenario = ($s.PSObject.Properties['baseId'] ? $s.baseId : $s.id); variant = $null; layout = $s.layout; kind = $s.kind
            status = $Status; detail = $Detail; output = $out[0]; stems = @($out | Select-Object -Skip 1)
            render = [ordered]@{ sr = $s.sr; block = $s.block; mode = $s.mode; channels = ($s.mono ? 1 : 2)
                host = [ordered]@{ anticipativeFx = [bool]$s.host.AnticipativeFx; runFxWhenStopped = [bool]$s.host.RunFxWhenStopped; informOfflineState = [bool]$s.host.InformOfflineState } }
            sources = (Get-HarnessSourceFacts $Ctx $scenarioLayout); fx = (Get-HarnessFxFacts $Ctx $scenarioLayout @($s.bypass))
        }
        foreach ($k in $Keep.Run.get_Keys()) { $record[$k] = $Keep.Run[$k] }
        $record = Hide-HarnessFacts $record # every string of the line, keys too: details carry exception texts, names come from plugins
        if (-not $Keep.Refused) {
            try {
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-HarnessJsonText -Value $record) + "`n")
                $fs = [IO.FileStream]::new($Keep.Manifest, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
                try {
                    # A line a write that failed left unfinished (a full disk) stays on a line of its own: this one starts after it
                    if ($fs.Length -gt 0) { $null = $fs.Seek(-1, [IO.SeekOrigin]::End); if ($fs.ReadByte() -ne 10) { $fs.WriteByte(10) } }
                    $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true)
                } finally { $fs.Dispose() }
                $Keep.Lines++
            } catch { $Status = Get-HarnessWorse $Status 'INCOMPLETE'; $Detail += "; its manifest line could not be written: $($_.Exception.Message -replace '\s+', ' ')" }
        }
        [pscustomobject]@{ Status = $Status; Detail = $Detail; Record = $record }
    } catch {
        [pscustomobject]@{ Status = (Get-HarnessWorse $Status 'INCOMPLETE'); Detail = "$Detail; not kept: keeping it stopped on an unexpected error: $($_.Exception.Message -replace '\s+', ' ')"; Record = $null }
    }
}

# The row's copy of a manifest line: paths relative to the result directory instead of the manifest's directory.
function ConvertTo-HarnessKeptFacts([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Rel) {
    $copy = ConvertFrom-HarnessJson (ConvertTo-HarnessJsonText -Value $Entry)
    foreach ($f in @($copy['output']) + @($copy['stems'])) { if ($f -and $f['path']) { $f['path'] = "$Rel/$($f['path'])" } }
    $copy
}

Export-ModuleMember -Function Get-HarnessToolVersion, Get-HarnessGitCommit, New-HarnessKeep, Move-HarnessKeptFile, Get-HarnessKeptFileFacts, Get-HarnessFxFacts, Get-HarnessSourceFacts,
    Save-HarnessKeptRender, ConvertTo-HarnessKeptFacts
