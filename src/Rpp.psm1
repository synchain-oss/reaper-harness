# SPDX-License-Identifier: MIT
#
# REAPER project text and Lua job files.
#   New-HarnessProjectText   a minimal .rpp for one layout: tracks in order (folder tracks as REAPER folders), the test
#                            signal as an item on every source track, FX from the learned plugin blocks
#   Get-HarnessFxBlocks      the plugin blocks of a project REAPER saved, per track name (used after the learn launch)
#   ConvertTo-HarnessLuaTable a hashtable as Lua "return { ... }" (the driver reads it with dofile)
#   Write-HarnessText        UTF-8 without BOM
# Plugin blocks are never written by hand: a block without the state REAPER saved for that plugin is reported as
# "effect unavailable", so every block comes from a project REAPER itself saved in this round (see Learn.psm1).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:RenderSpeed = @{ offline = 0; '1x' = 1; online = 2 } # RENDER_1X: 1 = real-time speed but plugins are told offline; 2 = online render

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
# "<VST ...", last line ">"). Bypass: plugin ids whose FX are written bypassed ('*' = every FX) on top of the
# layout's own bypass flags. NoFx: leave every FX out (the dry reference). VolumeScale: multiplies the volume of the
# source tracks (a built-in negative case uses 0.5).
function New-HarnessProjectText {
    param(
        [Parameter(Mandatory)]$Layout,
        [hashtable]$Blocks = @{},
        [Parameter(Mandatory)][string]$SourceWav,
        [Parameter(Mandatory)][string]$RenderDir,
        [Parameter(Mandatory)][string]$RenderName,
        [int]$SampleRate = 48000,
        [int]$Channels = 2,
        [ValidateSet('offline', '1x', 'online')][string]$Mode = 'offline',
        [string[]]$Bypass = @(),
        [double]$Seconds = 4.0,
        [double]$VolumeScale = 1.0,
        [switch]$NoFx
    )
    $flags = Get-HarnessFolderFlags $Layout.Tracks
    $sb = [Text.StringBuilder]::new()
    $add = { param([string]$Line) $null = $sb.Append($Line).Append("`n") }
    & $add '<REAPER_PROJECT 0.1 "7.0/win64" 0 0'
    & $add "  RENDER_FILE $(ConvertTo-RppString $RenderDir)"
    & $add "  RENDER_PATTERN $(ConvertTo-RppString $RenderName)"
    & $add "  RENDER_FMT 0 $Channels $SampleRate"
    & $add "  RENDER_1X $($script:RenderSpeed[$Mode])"
    & $add '  RENDER_RANGE 1 0 0 0 1000'
    & $add '  RENDER_RESAMPLE 3 0 1'
    & $add '  RENDER_ADDTOPROJ 0'
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
        & $add "    VOLPAN $(Format-Number $vol) 0 -1 -1 1"
        & $add "    ISBUS $($flags[$i])"
        & $add '    NCHAN 2'
        & $add '    MAINSEND 1 0'
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
        if ($t.Source) {
            & $add '    <ITEM'
            & $add '      POSITION 0'
            & $add "      LENGTH $(Format-Number $Seconds)"
            & $add '      <SOURCE WAVE'
            & $add "        FILE $(ConvertTo-RppString $SourceWav)"
            & $add '      >'
            & $add '    >'
        }
        & $add '  >'
    }
    & $add '>'
    $sb.ToString()
}

# The plugin blocks REAPER saved, per track: track name -> list of @{ Header; Name; File; Uid; Cid; Lines; Bypass }.
# Lines are the block from "<VST" to its closing ">" with the indentation removed; Bypass is the state of the
# BYPASS line before it. Only VST blocks are taken (the tool tests VST3 plugins).
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
            if ($s -match '^<VST ' -and $null -ne $track) {
                $block = [Collections.Generic.List[string]]::new()
                $level = 0
                for ($j = $i; $j -lt $lines.Count; $j++) {
                    $x = $lines[$j].Trim()
                    $block.Add($x)
                    if ($x.StartsWith('<')) { $level++ } elseif ($x -eq '>') { $level--; if ($level -eq 0) { break } }
                }
                if ($level -ne 0) { throw 'a plugin block in the saved project is not closed' }
                $m = [regex]::Match($s, '^<VST "([^"]*)" "?([^"]*?)"? (\S+) "[^"]*" ([0-9-]+)\{([0-9A-Fa-f]{32})\}')
                $Tracks[$track].Add([pscustomobject]@{
                        Header = $s; Name = ($m.Success ? $m.Groups[1].Value : ''); File = ($m.Success ? $m.Groups[2].Value : '')
                        Uid = ($m.Success ? $m.Groups[4].Value : ''); Cid = ($m.Success ? $m.Groups[5].Value.ToUpperInvariant() : ''); Lines = $block.ToArray(); Bypass = $Bypass
                    })
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

Export-ModuleMember -Function New-HarnessProjectText, Get-HarnessFxBlocks, Get-HarnessFolderFlags, ConvertTo-HarnessLuaTable, ConvertTo-HarnessLuaValue, Write-HarnessText
