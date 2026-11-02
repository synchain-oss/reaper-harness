# SPDX-License-Identifier: MIT
#
# Named plugin states. Some settings live only in a plugin's state, not in any parameter (a channel or group number,
# a routing switch): two instances of one plugin with different settings need two different states. A state is a
# plugin block REAPER wrote, taken from a project the user set up and saved (template, track name, FX number) or
# from a file holding one plugin block (for example an FX chain file saved with one FX).
#   Get-HarnessTemplateFxBlock    the n-th FX block of a named track of a project's text (pure)
#   Get-HarnessStateFileBlock     the one plugin block of a file's text (pure)
#   Test-HarnessStateHeader       a block against the plugin's moduleinfo: name and class ID must match (pure)
#   Read-HarnessStates            every state of a configuration: paths and blocks; problems are usage errors
#   Assert-HarnessStateIdentity   after the preflight: every block is the plugin it is configured for, or usage error
# Of a template only the requested block is kept; nothing else in it goes to the console or the results, and the
# problems name only the file, the track and the FX number. A block only goes into projects in the work directory;
# results carry the state's name and the first 12 hex digits of the block's sha256.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Rpp.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Extensions.psm1') -ErrorAction Stop

# Blocks that are one FX of a chain (a container counts as one FX, like in REAPER's FX numbering).
$script:FxTags = 'VST', 'JS', 'AU', 'CLAP', 'DX', 'LV2', 'CONTAINER', 'VIDEO_EFFECT'

function Get-BlockTag([string]$Line) { ($Line.Substring(1) -split ' ', 2)[0] }

# Text: a project. Returns @{ Lines; Problem }: the block of FX number Fx (from 1) of the one track named Track.
function Get-HarnessTemplateFxBlock {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Track, [Parameter(Mandatory)][int]$Fx)
    $stack = [Collections.Generic.List[string]]::new()
    $matched = [Collections.Generic.List[object]]::new() # per track of that name: its FX blocks (tag, lines)
    $current = $null
    $capture = $null
    foreach ($raw in ($Text -split '\r?\n')) {
        $s = $raw.Trim()
        if ($null -ne $capture) {
            $capture.Lines.Add($s)
            if ($s.StartsWith('<')) { $capture.Level++ } elseif ($s -eq '>') { $capture.Level-- }
            if ($capture.Level -gt 0) { continue }
            $capture = $null
            $stack.RemoveAt($stack.Count - 1)
            continue
        }
        if ($s.StartsWith('<')) {
            $tag = Get-BlockTag $s
            $stack.Add($tag)
            $d = $stack.Count
            if ($d -eq 2 -and $tag -ceq 'TRACK') { $current = [pscustomobject]@{ Named = $false; Fx = [Collections.Generic.List[object]]::new() }; continue }
            if ($d -eq 4 -and $stack[1] -ceq 'TRACK' -and $stack[2] -ceq 'FXCHAIN' -and $tag -cin $script:FxTags -and $null -ne $current) {
                $entry = [pscustomobject]@{ Tag = $tag; Lines = $null }
                if ($current.Named) { $entry.Lines = [Collections.Generic.List[string]]::new(); $entry.Lines.Add($s); $capture = [pscustomobject]@{ Lines = $entry.Lines; Level = 1 } }
                else { $capture = [pscustomobject]@{ Lines = [Collections.Generic.List[string]]::new(); Level = 1 } }
                $current.Fx.Add($entry)
            }
            continue
        }
        if ($s -eq '>') {
            if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) }
            if ($stack.Count -lt 2) { $current = $null }
            continue
        }
        if ($stack.Count -eq 2 -and $stack[1] -ceq 'TRACK' -and $null -ne $current -and $s -match '^NAME( |$)') {
            $tok = ConvertFrom-HarnessRppTokens $s
            if ((($tok.Count -gt 1) ? $tok[1] : '') -ceq $Track) { $current.Named = $true; $matched.Add($current) }
        }
    }
    if ($matched.Count -eq 0) { return [pscustomobject]@{ Lines = $null; Problem = "has no track named '$Track'" } }
    if ($matched.Count -gt 1) { return [pscustomobject]@{ Lines = $null; Problem = "has $($matched.Count) tracks named '$Track'; the state is ambiguous" } }
    $list = $matched[0].Fx
    if ($Fx -gt $list.Count) { return [pscustomobject]@{ Lines = $null; Problem = "track '$Track' has $($list.Count) FX, not $Fx" } }
    $e = $list[$Fx - 1]
    if ($e.Tag -cne 'VST') { return [pscustomobject]@{ Lines = $null; Problem = "FX $Fx of track '$Track' is a $($e.Tag) block, not a VST3 plugin" } }
    if ($null -eq $e.Lines -or $e.Lines[$e.Lines.Count - 1] -ne '>') { return [pscustomobject]@{ Lines = $null; Problem = "FX $Fx of track '$Track' is not closed" } }
    [pscustomobject]@{ Lines = $e.Lines.ToArray(); Problem = '' }
}

# Text: a file that holds exactly one plugin block at its top level (FX chain files also hold BYPASS, FLOATPOS, FXID
# and WAK lines around it). Returns @{ Lines; Problem }.
function Get-HarnessStateFileBlock([Parameter(Mandatory)][AllowEmptyString()][string]$Text) {
    $blocks = [Collections.Generic.List[object]]::new()
    $level = 0
    $capture = $null
    foreach ($raw in ($Text -split '\r?\n')) {
        $s = $raw.Trim()
        if ($s.StartsWith('<')) {
            if ($level -eq 0) {
                $capture = [pscustomobject]@{ Tag = (Get-BlockTag $s); Lines = [Collections.Generic.List[string]]::new() }
                $blocks.Add($capture)
            }
            $level++
        }
        if ($null -ne $capture) { $capture.Lines.Add($s) }
        if ($s -eq '>') {
            $level--
            if ($level -lt 0) { return [pscustomobject]@{ Lines = $null; Problem = 'has a ">" without a block' } }
            if ($level -eq 0) { $capture = $null }
        }
    }
    if ($level -ne 0) { return [pscustomobject]@{ Lines = $null; Problem = 'has a block that is not closed' } }
    $found = @($blocks | Where-Object { $_.Tag -cin $script:FxTags })
    if ($found.Count -ne 1) { return [pscustomobject]@{ Lines = $null; Problem = "holds $($found.Count) plugin blocks at its top level, expected 1 (a project needs template, track and fx instead)" } }
    if ($found[0].Tag -cne 'VST') { return [pscustomobject]@{ Lines = $null; Problem = "holds a $($found[0].Tag) block, not a VST3 plugin" } }
    [pscustomobject]@{ Lines = $found[0].Lines.ToArray(); Problem = '' }
}

# A VST3 block header: <VST "VST3: Name (Vendor)" "file" 0 "custom name" uid{CID} ...>. A custom name (REAPER's
# "rename FX") would change the name REAPER shows, which the runs check: it is emptied. Returns @{ Lines; Name; Cid;
# Problem } (Lines with the header rewritten when it had a custom name).
function Read-HarnessStateHeader([Parameter(Mandatory)][string[]]$Lines) {
    $tok = ConvertFrom-HarnessRppTokens $Lines[0].Substring(1)
    $m = ($tok.Count -ge 6) ? [regex]::Match($tok[5], '^-?\d+\{([0-9A-Fa-f]{32})\}$') : $null
    if (-not $m -or -not $m.Success -or -not $tok[1].StartsWith('VST3: ')) { return [pscustomobject]@{ Lines = $null; Name = ''; Cid = ''; Problem = 'the block is not a VST3 plugin block as REAPER writes it' } }
    $out = [string[]]$Lines.Clone()
    if ($tok[4]) {
        $q = { param([string]$v) $c = $v.Contains('"') ? ($v.Contains("'") ? '`' : "'") : '"'; "$c$v$c" }
        $rest = @($tok | Select-Object -Skip 6 | ForEach-Object { & $q $_ })
        $out[0] = (@('<VST', (& $q $tok[1]), (& $q $tok[2]), $tok[3], '""', $tok[5]) + $rest) -join ' '
    }
    [pscustomobject]@{ Lines = $out; Name = $tok[1]; Cid = $m.Groups[1].Value.ToUpperInvariant(); Problem = '' }
}

# Pure function: does the block belong to the plugin described by moduleinfo (Info: Name, Vendor, Cid)?
function Test-HarnessStateHeader([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Info) {
    $want = "VST3: $($Info.Name) ($($Info.Vendor))"
    if ($State.Name -cne $want) { return "the block is of '$($State.Name)', the plugin is '$want'" }
    if ($State.Cid -cne $Info.Cid) { return "the block has class ID $($State.Cid), moduleinfo.json says $($Info.Cid)" }
    ''
}

function Get-HarnessBlockSha([string[]]$Lines) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($Lines -join "`n") + "`n"))).ToLowerInvariant()
}

# Every state of the configuration (Config.ConfigDir is the directory paths are relative to). Returns an ordered table
# "<plugin>@<state>" -> @{ Plugin; State; Lines; Name; Cid; Sha (12 hex digits) }. Throws "USAGE: states: ..." with
# every problem.
function Read-HarnessStates {
    param([Parameter(Mandatory)]$Config)
    $out = [ordered]@{}
    $bad = [Collections.Generic.List[string]]::new()
    $texts = @{}
    foreach ($p in $Config.Plugins.get_Values()) {
        foreach ($st in $p.States.get_Values()) {
            $label = "plugins.$($p.Id).states.$($st.Name)"
            $rel = $st.Template ? $st.Template : $st.StateFile
            try { $file = Resolve-HarnessExtensionPath -ConfigDir $Config.ConfigDir -Relative $rel -What 'state' }
            catch { $bad.Add("${label}: $($_.Exception.Message -replace '^USAGE: ', '')"); continue }
            if (-not $texts.ContainsKey($file)) { $texts[$file] = [IO.File]::ReadAllText($file) }
            $leaf = Split-Path -Leaf $file
            $got = $st.Template ? (Get-HarnessTemplateFxBlock -Text $texts[$file] -Track $st.Track -Fx $st.Fx) : (Get-HarnessStateFileBlock $texts[$file])
            if ($got.Problem) { $bad.Add("${label}: $leaf $($got.Problem)"); continue }
            $h = Read-HarnessStateHeader $got.Lines
            if ($h.Problem) { $bad.Add("${label}: $leaf ($($st.Template ? "track '$($st.Track)', FX $($st.Fx)" : 'state file')): $($h.Problem)"); continue }
            $out["$($p.Id)@$($st.Name)"] = [pscustomobject]@{ Plugin = $p.Id; State = $st.Name; Lines = $h.Lines; Name = $h.Name; Cid = $h.Cid; Sha = (Get-HarnessBlockSha $h.Lines).Substring(0, 12) }
        }
    }
    if ($bad.Count) { Stop-Usage ("states: $($bad.Count) problem(s): " + ($bad -join '; ')) }
    $out
}

# After the preflight read moduleinfo (Infos: plugin id -> Info): every state block must be its plugin's.
function Assert-HarnessStateIdentity {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$States, [Parameter(Mandatory)][System.Collections.IDictionary]$Infos)
    $bad = [Collections.Generic.List[string]]::new()
    foreach ($k in $States.get_Keys()) {
        $s = $States[$k]
        if (-not $Infos.Contains($s.Plugin)) { continue } # the preflight already gave a reason for this plugin
        $why = Test-HarnessStateHeader -State $s -Info $Infos[$s.Plugin]
        if ($why) { $bad.Add("plugins.$($s.Plugin).states.$($s.State): $why") }
    }
    if ($bad.Count) { Stop-Usage ("states: $($bad.Count) problem(s): " + ($bad -join '; ')) }
}

Export-ModuleMember -Function Get-HarnessTemplateFxBlock, Get-HarnessStateFileBlock, Read-HarnessStateHeader, Test-HarnessStateHeader, Get-HarnessBlockSha, Read-HarnessStates, Assert-HarnessStateIdentity
