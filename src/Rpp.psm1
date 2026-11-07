# SPDX-License-Identifier: MIT
#
# REAPER project text and Lua job files.
#   New-HarnessProjectText   a minimal .rpp for one layout: tracks in order (folder tracks as REAPER folders), the test
#                            signal as an item on every source track, volume, pan, mute, master / parent send, sends
#                            (written as receives on the receiving track), FX from the learned plugin blocks, and the
#                            stem tracks selected for a stem render
#   New-HarnessLearnProjectText  the project the learn launch opens: one empty track per variant, or the state block
#   Get-HarnessFxBlocks      the plugin blocks (VST and JS) of a project REAPER saved, per track name
#   ConvertFrom-HarnessRppTokens  one project line split into REAPER's tokens
#   ConvertTo-HarnessLuaTable a hashtable as Lua "return { ... }" (the driver reads it with dofile)
#   Write-HarnessText        UTF-8 without BOM
# Plugin blocks are never written by hand: a block without the state REAPER saved for that plugin is reported as
# "effect unavailable", so every block comes from a project REAPER itself saved in this round (see Learn.psm1).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:RenderSpeed = @{ offline = 0; '1x' = 1; online = 2 } # RENDER_1X: 1 = 1x offline render (real-time speed, still offline); 2 = online render
$script:SendMode = @{ post = 0; prefx = 1; pre = 3 } # AUXRECV modes: post-fader, pre-FX, post-FX (pre-fader)

function Write-HarnessText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function ConvertTo-HarnessLuaValue($Value) {
    if ($null -eq $Value) { return 'nil' }
    if ($Value -is [bool]) { return $Value ? 'true' : 'false' }
    if ($Value -is [string]) { return '"' + ($Value -replace '\\', '\\' -replace '"', '\"' -replace "`r", '\r' -replace "`n", '\n') + '"' }
    if ($Value -is [System.Collections.IDictionary]) {
        return '{' + ((@($Value.get_Keys()) | Sort-Object | ForEach-Object { "[$(ConvertTo-HarnessLuaValue ([string]$_))]=$(ConvertTo-HarnessLuaValue $Value[$_])" }) -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) { return '{' + ((@($Value) | ForEach-Object { ConvertTo-HarnessLuaValue $_ }) -join ',') + '}' }
    if ($Value -is [ValueType]) { return ([double]$Value).ToString('R', $script:Inv) }
    throw "cannot write a $($Value.GetType().Name) as Lua"
}

function ConvertTo-HarnessLuaTable([Parameter(Mandatory)][System.Collections.IDictionary]$Job) { 'return ' + (ConvertTo-HarnessLuaValue $Job) + "`n" }

function Format-Number([double]$Value) { $Value.ToString('R', $script:Inv) }

# Quotes a value for an .rpp line. Names come from the validated configuration (no double quotes, no control
# characters); paths come from this tool.
function ConvertTo-RppString([string]$Text) {
    if ($Text.Contains('"')) { throw "cannot write a double quote into a project: $Text" }
    '"' + $Text + '"'
}

# ISBUS of each track: a folder track opens a folder (1 1); the last track inside one or more folders closes them
# (2 -n); everything else 0 0. Depth: how many folders enclose the track.
function Get-HarnessFolderFlags([object[]]$Tracks) {
    $flags = for ($i = 0; $i -lt $Tracks.Count; $i++) {
        if ($Tracks[$i].Folder) { '1 1'; continue }
        $next = ($i + 1 -lt $Tracks.Count) ? $Tracks[$i + 1].Depth : 0
        $delta = $next - $Tracks[$i].Depth
        ($delta -lt 0) ? "2 $delta" : '0 0'
    }
    , @($flags)
}

# Layout: a normalised layout (Config.psm1). Blocks: variant key -> block lines (from Get-HarnessFxBlocks, first line
# "<VST ..." or "<JS ...", last line ">"). Bypass: plugin ids whose FX are written bypassed ('*' = every FX) on top
# of the layout's own bypass flags. NoFx: leave every FX out (the dry reference). VolumeScale: multiplies the volume
# of the source tracks (a built-in negative case uses 0.5). Sources: track name -> signal file for tracks with a
# signal of their own (the others get SourceWav). Stems: track names rendered as stems: the render then writes
# <RenderName>-stem-<track>.wav per stem and <RenderName>-stem-Master.wav (REAPER's "master mix + stems of selected
# tracks"; Get-HarnessRunFiles in Scenarios.psm1 expects these names). NoItems: no track plays anything (the transport
# kind: what a track gets comes through its input).
function New-HarnessProjectText {
    param(
        [Parameter(Mandatory)]$Layout,
        [hashtable]$Blocks = @{},
        [Parameter(Mandatory)][string]$SourceWav,
        [hashtable]$Sources = @{},
        [Parameter(Mandatory)][string]$RenderDir,
        [Parameter(Mandatory)][string]$RenderName,
        [int]$SampleRate = 48000,
        [int]$Channels = 2,
        [ValidateSet('offline', '1x', 'online')][string]$Mode = 'offline',
        [string[]]$Bypass = @(),
        [double]$Seconds = 4.0,
        [double]$VolumeScale = 1.0,
        [string[]]$Stems = @(),
        [switch]$NoFx,
        [switch]$NoItems
    )
    $flags = Get-HarnessFolderFlags $Layout.Tracks
    $sb = [Text.StringBuilder]::new()
    $add = { param([string]$Line) $null = $sb.Append($Line).Append("`n") }
    & $add '<REAPER_PROJECT 0.1 "7.0/win64" 0 0'
    & $add "  RENDER_FILE $(ConvertTo-RppString $RenderDir)"
    & $add "  RENDER_PATTERN $(ConvertTo-RppString ($Stems.Count ? ($RenderName + '-stem-$track') : $RenderName))"
    & $add "  RENDER_FMT 0 $Channels $SampleRate"
    & $add "  RENDER_1X $($script:RenderSpeed[$Mode])"
    & $add '  RENDER_RANGE 1 0 0 0 1000'
    & $add '  RENDER_RESAMPLE 3 0 1'
    & $add '  RENDER_ADDTOPROJ 0'
    if ($Stems.Count) { & $add '  RENDER_STEMS 1' } # master mix and the stems of the selected tracks
    & $add '  RENDER_DITHER 0'
    & $add "  SAMPLERATE $SampleRate 1 0"
    & $add '  <RENDER_CFG'
    & $add '    ZXZhdyAAAQ==' # 32-bit float WAV
    & $add '  >'
    & $add '  TEMPO 120 4 4 0'
    for ($i = 0; $i -lt $Layout.Tracks.Count; $i++) {
        $t = $Layout.Tracks[$i]
        $vol = $t.Volume * ($t.Source ? $VolumeScale : 1.0)
        & $add '  <TRACK'
        & $add "    NAME $(ConvertTo-RppString $t.Name)"
        & $add "    VOLPAN $(Format-Number $vol) $(Format-Number $t.Pan) -1 -1 1"
        & $add "    MUTESOLO $($t.Mute ? 1 : 0) 0 0"
        & $add "    ISBUS $($flags[$i])"
        & $add "    SEL $($t.Name -cin $Stems ? 1 : 0)"
        & $add '    NCHAN 2'
        # Sends are receives of the receiving track: source track index (0-based), mode, volume, pan 0, ...
        for ($s = 0; $s -lt $Layout.Tracks.Count; $s++) {
            foreach ($send in $Layout.Tracks[$s].Sends) {
                if ($send.To -ceq $t.Name) { & $add "    AUXRECV $s $($script:SendMode[$send.Mode]) $(Format-Number $send.Volume) 0 0 0 0 0 0 -1:U 0 -1 ''" }
            }
        }
        & $add "    MAINSEND $($t.MasterSend ? 1 : 0) 0"
        if (-not $NoFx -and $t.Fx.Count) {
            & $add '    <FXCHAIN'
            foreach ($fx in $t.Fx) {
                if (-not $Blocks.ContainsKey($fx.Variant)) { throw "no learned block for plugin '$($fx.Plugin)' (variant $($fx.Variant))" }
                $off = $fx.Bypass -or ('*' -cin $Bypass) -or ($fx.Plugin -cin $Bypass)
                & $add "      BYPASS $($off ? 1 : 0) 0 0"
                foreach ($blockLine in $Blocks[$fx.Variant]) { & $add ('      ' + $blockLine) }
            }
            & $add '    >'
        }
        if ($t.Source -and -not $NoItems) {
            & $add '    <ITEM'
            & $add '      POSITION 0'
            & $add "      LENGTH $(Format-Number $Seconds)"
            & $add '      <SOURCE WAVE'
            & $add "        FILE $(ConvertTo-RppString ($Sources.ContainsKey($t.Name) ? $Sources[$t.Name] : $SourceWav))"
            & $add '      >'
            & $add '    >'
        }
        & $add '  >'
    }
    & $add '>'
    $sb.ToString()
}

# The project the learn launch opens: one track per variant, empty (the driver adds the plugin by name) or with the
# variant's state block (States: variant key -> block lines), which REAPER then loads like any saved project. Track n
# is named TrackNames[n-1] (from Get-HarnessLearnTrackNames, which only gives names safe in quotes), learn-<n> without.
function New-HarnessLearnProjectText {
    param([Parameter(Mandatory)][object[]]$Variants, [hashtable]$States = @{}, [string[]]$TrackNames = @())
    $sb = [Text.StringBuilder]::new()
    $add = { param([string]$Line) $null = $sb.Append($Line).Append("`n") }
    & $add '<REAPER_PROJECT 0.1 "7.0/win64" 0 0'
    & $add '  SAMPLERATE 48000 1 0'
    & $add '  TEMPO 120 4 4 0'
    for ($n = 1; $n -le $Variants.Count; $n++) {
        $v = $Variants[$n - 1]
        $trackName = ($TrackNames.Count -ge $n -and $TrackNames[$n - 1]) ? $TrackNames[$n - 1] : "learn-$n"
        & $add '  <TRACK'
        & $add "    NAME `"$trackName`""
        & $add '    NCHAN 2'
        if ($v.State) {
            if (-not $States.ContainsKey($v.Key)) { throw "no state block for variant $($v.Key)" }
            & $add '    <FXCHAIN'
            & $add '      BYPASS 0 0 0'
            foreach ($blockLine in $States[$v.Key]) { & $add ('      ' + $blockLine) }
            & $add '    >'
        }
        & $add '  >'
    }
    & $add '>'
    $sb.ToString()
}

# One project line as REAPER's tokens: separated by spaces; a token that starts with ", ' or ` runs to the same
# character (that is how REAPER quotes a string holding the other quote characters).
function ConvertFrom-HarnessRppTokens([AllowEmptyString()][string]$Line) {
    $out = [Collections.Generic.List[string]]::new()
    $i = 0
    $n = $Line.Length
    while ($i -lt $n) {
        while ($i -lt $n -and $Line[$i] -eq ' ') { $i++ }
        if ($i -ge $n) { break }
        $q = $Line[$i]
        if ($q -eq [char]'"' -or $q -eq [char]"'" -or $q -eq [char]'`') {
            $j = $Line.IndexOf($q, $i + 1)
            if ($j -lt 0) { $out.Add($Line.Substring($i + 1)); break }
            $out.Add($Line.Substring($i + 1, $j - $i - 1))
            $i = $j + 1
        } else {
            $j = $Line.IndexOf(' ', $i)
            if ($j -lt 0) { $j = $n }
            $out.Add($Line.Substring($i, $j - $i))
            $i = $j
        }
    }
    , $out.ToArray()
}

# The plugin blocks REAPER saved, per track: track name -> list of @{ Kind (VST | JS); Header; Name; File; Uid; Cid;
# Lines; Bypass }. Lines are the block from "<VST" / "<JS" to its closing ">" with the indentation removed; Bypass is
# the state of the BYPASS line before it. A JS block has File (the effect's path under Effects) and no name or class.
function Get-HarnessFxBlocks([Parameter(Mandatory)][AllowEmptyString()][string]$Text) {
    $Tracks = [ordered]@{}
    $lines = $Text -split '\r?\n'
    $track = $null
    $depth = 0
    $trackDepth = -1
    $Bypass = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $s = $lines[$i].Trim()
        if ($s.StartsWith('<')) {
            if ($s -match '^<TRACK\b') { $track = $null; $trackDepth = $depth }
            if ($s -match '^<(VST|JS) ' -and $null -ne $track) {
                $fxKind = $Matches[1]
                $block = [Collections.Generic.List[string]]::new()
                $level = 0
                for ($j = $i; $j -lt $lines.Count; $j++) {
                    $x = $lines[$j].Trim()
                    $block.Add($x)
                    if ($x.StartsWith('<')) { $level++ } elseif ($x -eq '>') { $level--; if ($level -eq 0) { break } }
                }
                if ($level -ne 0) { throw 'a plugin block in the saved project is not closed' }
                if ($fxKind -eq 'JS') {
                    $tok = ConvertFrom-HarnessRppTokens $s.Substring(1)
                    $entry = [pscustomobject]@{ Kind = 'JS'; Header = $s; Name = ''; File = (($tok.Count -gt 1) ? $tok[1] : ''); Uid = ''; Cid = ''; Lines = $block.ToArray(); Bypass = $Bypass }
                } else {
                    $m = [regex]::Match($s, '^<VST "([^"]*)" "?([^"]*?)"? (\S+) "[^"]*" ([0-9-]+)\{([0-9A-Fa-f]{32})\}')
                    $entry = [pscustomobject]@{
                        Kind = 'VST'; Header = $s; Name = ($m.Success ? $m.Groups[1].Value : ''); File = ($m.Success ? $m.Groups[2].Value : '')
                        Uid = ($m.Success ? $m.Groups[4].Value : ''); Cid = ($m.Success ? $m.Groups[5].Value.ToUpperInvariant() : ''); Lines = $block.ToArray(); Bypass = $Bypass
                    }
                }
                $Tracks[$track].Add($entry)
                $i = $j
                continue
            }
            $depth++
            continue
        }
        if ($s -eq '>') { $depth--; if ($depth -eq $trackDepth) { $track = $null; $trackDepth = -1 }; continue }
        if ($depth -eq $trackDepth + 1 -and $s -match '^NAME (.*)$') {
            $track = $Matches[1].Trim('"')
            if (-not $Tracks.Contains($track)) { $Tracks[$track] = [Collections.Generic.List[object]]::new() }
            continue
        }
        if ($s -match '^BYPASS (\d)') { $Bypass = $Matches[1] -ne '0' }
    }
    $Tracks
}

Export-ModuleMember -Function New-HarnessProjectText, New-HarnessLearnProjectText, Get-HarnessFxBlocks, ConvertFrom-HarnessRppTokens, Get-HarnessFolderFlags, ConvertTo-HarnessLuaTable,
    ConvertTo-HarnessLuaValue, Write-HarnessText
