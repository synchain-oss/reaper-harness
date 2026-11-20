# SPDX-License-Identifier: MIT
#
# Learning the plugin blocks, and proving which plugin binary REAPER loaded.
# Once per round, REAPER launches in batches (limits.learnBatchSize) add every plugin variant the round needs (each
# configured plugin with its default state, plus every distinct parameter set and named state a layout or a variant of a
# scenario asks for) by name, set the parameters by name, read them back, and save the project. A variant with a named state is not added by name: the project
# the launch opens already has its block (from the template or state file), so REAPER loads that state. The plugin
# blocks REAPER wrote into the saved project are what every other project of the round uses, so no plugin state is
# ever written by hand.
# Checks: each FX was added (TrackFX_AddByName matches loosely, so the name REAPER shows must equal the expected
# "VST3: <Name> (<Vendor>)" exactly), is not offline, fx_ident names the private binary and the class ID from
# moduleinfo.json, the saved block has that class ID too, and every parameter exists and reads back as configured.
# A named state without parameters on top must come back from REAPER as it was given; a state used with parameters
# on top is learned alone too, so every state is checked so. A JSFX shipped with the tool is checked by its name
# ("JS: <desc>"), its path under Effects in fx_ident and in the saved block.
# Proof of the private copy: the module list of the REAPER process, sampled while it ran, must show each tested
# binary from the private plugins directory and no file of the same name from anywhere else.
#   Get-HarnessScenarioLearnKeys the variants one scenario needs (pure; the same walk gives what is learned)
#   Get-HarnessLearnVariants  the variants a set of scenarios needs, each with For: the first scenario that needs it (pure)
#   Get-HarnessLearnBatches   those variants in launches of at most a size (pure)
#   Get-HarnessLearnRowId     the id of the row of a batch: learn, or learn.<k> when there are several
#   Get-HarnessLearnVerdict   the outcome of one batch and what of it is committed (pure)
#   Get-HarnessLearnTrackNames the learn project's track names: a template state on its template track's name (pure)
#   Get-HarnessReaperName     "VST3: <Name> (<Vendor>)" from moduleinfo
#   Test-HarnessLearnReport   the driver's report and the saved project against what was asked (pure)
#   Invoke-HarnessLearn       the launch of one batch; fills Ctx.Blocks, Ctx.Names and Ctx.LearnReads (what REAPER read
#                             back per variant, at the learn settings: 48000 Hz, block 512) with what it committed
#   Get-HarnessModuleCheck    the module proof over every launch of the round (pure over Ctx.LaunchLog)
# A parameter listing (run.ps1 -List params) rides on the learn launch of the plugins it lists: after the save, the
# driver reads every parameter of each learned instance, and sweeps the parameters asked for on a fresh instance each.
#   Read-HarnessParamListing  what the driver reported of one entry's listing and sweeps (pure)
#   Get-HarnessParamListing   the params row and the listing of the result, from what the launch committed

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Guard.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Host.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Rpp.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Scenarios.psm1') -ErrorAction Stop

# The settings of the learn launch; what it reads back (latency included) is read at these
$script:LearnRate = 48000
$script:LearnBlock = 512

function Get-HarnessReaperName($Info) { "VST3: $($Info.Name) ($($Info.Vendor))" }

# The variants one scenario needs, in order (pure): every FX of the layout it renders (its variant's when it has one) and
# of the layout it compares with, a state with parameters on top preceded by that state alone (only a state with nothing
# set on top can be compared with the block it was given, and that is what proves the plugin loads it); for instances
# the default variant of each of its plugins; nothing for built-in negative cases. A kind of an extension gets those of
# its layout, and needs every learn batch to pass on top (Get-HarnessLearnGap). Key, Plugin, State, Params each.
function Get-HarnessScenarioLearnKeys {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Scenario)
    $p = $Scenario.PSObject.Properties
    $out = [ordered]@{}
    if ($p['builtin'] -and $Scenario.builtin) { return , @() }
    if ($p['kind'] -and $Scenario.kind -ceq 'instances') {
        foreach ($id in @($Scenario.plugins)) { $out["$id|"] = [pscustomobject]@{ Key = "$id|"; Plugin = $id; State = ''; Params = [ordered]@{} } }
        return , @($out.get_Values())
    }
    $own = ($p['layout'] -and $Scenario.layout -is [string] -and $Scenario.layout -notlike '@*') ? (Get-HarnessScenarioLayout $Config $Scenario) : $null
    $walk = @($own)
    $c = $p['compare'] ? $Scenario.compare : $null
    if ($c -and $c.Kind -eq 'variant' -and $c.Layout -notlike '@*') { $walk += ($c.PSObject.Properties['SameLayout'] -and $c.SameLayout -and $own) ? $own : $Config.Layouts[$c.Layout] }
    foreach ($l in @($walk | Where-Object { $_ })) {
        foreach ($fx in @($l.Tracks | ForEach-Object { $_.Fx })) {
            $alone = "$($fx.Plugin)@$($fx.State)|"
            if ($fx.State -and $fx.Params.get_Count() -and -not $out.Contains($alone)) { $out[$alone] = [pscustomobject]@{ Key = $alone; Plugin = $fx.Plugin; State = $fx.State; Params = [ordered]@{} } }
            if (-not $out.Contains($fx.Variant)) { $out[$fx.Variant] = [pscustomobject]@{ Key = $fx.Variant; Plugin = $fx.Plugin; State = $fx.State; Params = $fx.Params } }
        }
    }
    , @($out.get_Values())
}

# Variants: one per configured plugin with no parameters (always: the module proof and the instances kind need them),
# then what the scenarios need (Get-HarnessScenarioLearnKeys), in first-use order. For: the id of the first scenario that
# needs a variant ('' for the defaults). A display text the first use of a setting leaves out and a later one gives is
# checked all the same (two different texts are a usage error, see Test-HarnessConfigData); the layouts are not changed.
function Get-HarnessLearnVariants {
    param([Parameter(Mandatory)]$Config, [object[]]$Scenarios = @())
    $out = [ordered]@{}
    foreach ($id in $Config.Plugins.get_Keys()) { $out["$id|"] = [pscustomobject]@{ Key = "$id|"; Plugin = $id; State = ''; Params = [ordered]@{}; For = '' } }
    foreach ($s in $Scenarios) {
        foreach ($e in (Get-HarnessScenarioLearnKeys -Config $Config -Scenario $s)) {
            if ($out.Contains($e.Key)) {
                $have = $out[$e.Key].Params
                foreach ($pn in $e.Params.get_Keys()) { if ($null -eq $have[$pn].Display -and $null -ne $e.Params[$pn].Display) { $have[$pn].Display = $e.Params[$pn].Display } }
                continue
            }
            $params = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            foreach ($pn in $e.Params.get_Keys()) { $params[$pn] = [pscustomobject]@{ Normalized = $e.Params[$pn].Normalized; Display = $e.Params[$pn].Display } }
            $out[$e.Key] = [pscustomobject]@{ Key = $e.Key; Plugin = $e.Plugin; State = $e.State; Params = $params; For = ($s.PSObject.Properties['id'] ? [string]$s.id : '') }
        }
    }
    , @($out.get_Values())
}

# Pure function: the variants in launches of at most Size. The defaults (For '') all go into the first, never split: it
# holds every plugin, so it proves every binary and names every plugin, whatever its size then. The others follow in
# groups of the same For, in order; a group that does not fit where the last launch is opens a new one, a group larger
# than Size is cut into launches of Size. Returns @{ No; Entries } per launch.
function Get-HarnessLearnBatches {
    param([Parameter(Mandatory)][object[]]$Variants, [Parameter(Mandatory)][int]$Size)
    $groups = [Collections.Generic.List[object]]::new()
    $defaults = [Collections.Generic.List[object]]::new()
    foreach ($v in $Variants) {
        $for = ($v.PSObject.Properties['For'] -and $v.For) ? [string]$v.For : ''
        if (-not $for) { $defaults.Add($v); continue }
        if ($groups.Count -and $groups[$groups.Count - 1].For -ceq $for) { $groups[$groups.Count - 1].Entries.Add($v) }
        else { $groups.Add([pscustomobject]@{ For = $for; Entries = [Collections.Generic.List[object]]::new(@(, $v)) }) }
    }
    $launches = [Collections.Generic.List[object]]::new()
    $launches.Add($defaults)
    foreach ($g in $groups) {
        $last = $launches[$launches.Count - 1]
        if ($last.Count + $g.Entries.Count -le $Size) { $last.AddRange($g.Entries); continue }
        for ($i = 0; $i -lt $g.Entries.Count; $i += $Size) { $launches.Add([Collections.Generic.List[object]]::new($g.Entries.GetRange($i, [Math]::Min($Size, $g.Entries.Count - $i)))) }
    }
    , @(for ($k = 0; $k -lt $launches.Count; $k++) { [pscustomobject]@{ No = $k + 1; Entries = $launches[$k].ToArray() } })
}

function Get-HarnessLearnRowId([int]$BatchNo, [int]$BatchCount) { ($BatchCount -gt 1) ? "learn.$BatchNo" : 'learn' }

# Pure function: the name of each variant's track in the learn project. A variant with a state taken from a template
# gets the name of the template track it came from, because a plugin can save what it sees of other instances into its
# own state: a bus plugin that labels its inputs by the names of their tracks saves its block back changed when its
# inputs sit on tracks named otherwise, although it holds the state it was given. The first variant with a name gets
# it; the others, a state file, and a name that could not be written in quotes, look like a generated one or was taken
# already (in any case: REAPER compares names so) get learn-<n>.
function Get-HarnessLearnTrackNames {
    param([Parameter(Mandatory)][object[]]$Variants, [System.Collections.IDictionary]$States = @{})
    $taken = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $names = [string[]]::new($Variants.Count)
    for ($n = 1; $n -le $Variants.Count; $n++) {
        $v = $Variants[$n - 1]
        $sk = "$($v.Plugin)@$($v.State)"
        $want = ($v.State -and $States.Contains($sk) -and $States[$sk].PSObject.Properties['Track']) ? [string]$States[$sk].Track : ''
        if ($want -and $want -notmatch '["\p{Cc}]' -and $want -notmatch '^(?i)learn-\d+$' -and $taken.Add($want)) { $names[$n - 1] = $want }
    }
    for ($n = 1; $n -le $Variants.Count; $n++) { if (-not $names[$n - 1]) { $names[$n - 1] = "learn-$n" } }
    , $names
}

# Splits fx_ident of a VST3 ("<binary path><uid{CID}") into path and class ID; anything else gives empty parts.
function Split-HarnessFxIdent([string]$Ident) {
    $m = [regex]::Match($Ident, '^(.*)<-?\d+\{([0-9A-Fa-f]{32})\}?$')
    if (-not $m.Success) { return [pscustomobject]@{ Path = ''; Cid = '' } }
    [pscustomobject]@{ Path = $m.Groups[1].Value; Cid = $m.Groups[2].Value.ToUpperInvariant() }
}

# Pure function. Variants, Installed (VST3 id -> install row with Binary and Info) and Jsfx (JSFX id -> row with Name,
# AddName, Ident) describe what was asked; States ("<plugin>@<state>" -> state with Lines) the named states; Report is
# the driver's key=value table; Saved is Get-HarnessFxBlocks of the saved project; TrackNames the names the learn
# project gave the tracks (learn-<n> where missing); SameFile (a, b) decides whether two paths are one file (default
# Test-HarnessSameFile). Returns @{ Fail; Foreign; Blocks (variant key -> lines, only for entries that failed nothing);
# Names (id -> name REAPER shows);
# AddNames (id -> name to add it by); Reads (variant key -> Name, Pdc, Params (name -> Read, Display) as reported, and
# the Sr and Block they were read at) }.
function Test-HarnessLearnReport {
    param([Parameter(Mandatory)][object[]]$Variants, [Parameter(Mandatory)][hashtable]$Installed, [hashtable]$Jsfx = @{}, [System.Collections.IDictionary]$States = @{},
          [Parameter(Mandatory)][hashtable]$Report, $Saved, [string[]]$TrackNames = @(), [scriptblock]$SameFile)
    $same = $SameFile ?? ${function:Test-HarnessSameFile}
    $fail = [Collections.Generic.List[string]]::new()
    $foreign = [Collections.Generic.List[string]]::new()
    $blocks = @{}
    $names = @{}
    $addNames = @{}
    $reads = @{}
    for ($n = 1; $n -le $Variants.Count; $n++) {
        $v = $Variants[$n - 1]
        $js = $Jsfx.ContainsKey($v.Plugin) ? $Jsfx[$v.Plugin] : $null
        $row = $js ? $null : $Installed[$v.Plugin]
        $want = $js ? $js.Name : (Get-HarnessReaperName $row.Info)
        $names[$v.Plugin] = $want
        $addNames[$v.Plugin] = $js ? $js.AddName : $want
        $k = "fx${n}_"
        # What the entry is and where it comes from: n counts in this batch only
        $about = @(@(($v.Params.get_Count()) ? "variant $n" : $null) + @(($v.PSObject.Properties['For'] -and $v.For) ? "first used by $($v.For)" : $null) | Where-Object { $_ }) -join ', '
        $label = "$($v.Plugin)$($v.State ? " state $($v.State)" : '')$($about ? " ($about)" : '')"
        # Only an entry that added no failure of its own is taken (an offline plugin goes on to be checked, and is not)
        $failsBefore = $fail.Count
        $foreignBefore = $foreign.Count
        $idx = $Report["${k}idx"]
        if ($idx -ne '0') {
            $fail.Add($v.State ? "$label did not load from its state block (index $idx)" : "$label could not be added as '$($addNames[$v.Plugin])' (index $idx): the plugin did not load or is not known to REAPER"); continue
        }
        if ($Report["${k}name"] -cne $want) { $fail.Add("$label was added as '$($Report["${k}name"])', expected '$want' (another plugin matched the name)"); continue }
        if ($Report["${k}offline"] -ne 'false') { $fail.Add("$label is offline (the plugin failed to load)") }
        if ($js) {
            if ([string]$Report["${k}ident"] -cne $js.Ident) { $fail.Add("$label has fx_ident '$($Report["${k}ident"])', expected '$($js.Ident)' (another effect of that name)") }
        } else {
            $Ident = Split-HarnessFxIdent ([string]$Report["${k}ident"])
            if (-not $Ident.Path) { $fail.Add("$label has no VST3 fx_ident") }
            else {
                if (-not (& $same $Ident.Path $row.Binary)) { $foreign.Add("$label was loaded from $(Hide-HarnessPaths $Ident.Path), not from the private copy") }
                if ($Ident.Cid -cne $row.Info.Cid) { $fail.Add("$label class ID in fx_ident is $($Ident.Cid), moduleinfo.json says $($row.Info.Cid)") }
            }
        }
        $i = 0
        $readParams = [ordered]@{}
        foreach ($pn in $v.Params.get_Keys()) {
            $i++
            $why = Test-HarnessParamValue $Report["${k}p$i"] $Report["${k}p${i}_display"] $v.Params[$pn]
            if ($why) { $fail.Add("$label parameter '$pn' $why") }
            $readParams[$pn] = [pscustomobject]@{ Read = $Report["${k}p$i"]; Display = $Report["${k}p${i}_display"] }
        }
        $track = ($TrackNames.Count -ge $n -and $TrackNames[$n - 1]) ? $TrackNames[$n - 1] : "learn-$n"
        $list = @(($null -ne $Saved -and $Saved.Contains($track)) ? $Saved[$track] : @())
        if ($list.Count -ne 1) { $fail.Add("$label : the saved project has $($list.Count) plugin blocks on its track, expected 1"); continue }
        if ($js) {
            if ($list[0].Kind -ne 'JS' -or $list[0].File -cne $js.Ident) { $fail.Add("$label : the saved block is not the JS block of $($js.Ident)"); continue }
        } else {
            if ($list[0].Cid -cne $row.Info.Cid) { $fail.Add("$label : the saved block has class ID $($list[0].Cid), moduleinfo.json says $($row.Info.Cid)"); continue }
            if ($list[0].Name -cne $want) { $fail.Add("$label : the saved block is named '$($list[0].Name)', expected '$want'"); continue }
        }
        # A state with nothing set on top must be what the plugin holds after loading it (the header line aside)
        $sk = "$($v.Plugin)@$($v.State)"
        if ($v.State -and -not $v.Params.get_Count() -and $States.Contains($sk)) {
            if ((@($States[$sk].Lines | Select-Object -Skip 1) -join "`n") -cne (@($list[0].Lines | Select-Object -Skip 1) -join "`n")) {
                $fail.Add("$label : the plugin saved its state back changed, so it does not hold the state as given"); continue
            }
        }
        if ($fail.Count -ne $failsBefore -or $foreign.Count -ne $foreignBefore) { continue }
        $blocks[$v.Key] = $list[0].Lines
        $reads[$v.Key] = [pscustomobject]@{ Name = $Report["${k}name"]; Pdc = $Report["${k}pdc"]; Params = $readParams; Sr = $script:LearnRate; Block = $script:LearnBlock }
    }
    [pscustomobject]@{ Fail = $fail.ToArray(); Foreign = $foreign.ToArray(); Blocks = $blocks; Names = $names; AddNames = $addNames; Reads = $reads }
}

# Pure function: the outcome of one learn batch from what its launch showed. Check: Test-HarnessLearnReport of it ($null
# when the launch failed: LaunchWhy); Installed: VST3 id -> install row; Jsfx: JSFX id -> row; Seen: the module list of
# the launch. In this order: a tested binary from outside the private copy (any installed binary in the module list,
# also in a batch of JSFX only, or an fx_ident) is INCOMPLETE and commits nothing (Foreign); a launch that failed is
# INCOMPLETE; an entry that failed is FAIL; a binary of a plugin of this batch never seen loaded is INCOMPLETE
# (binaries of plugins of other batches may be unseen). Commit: the keys of entries that failed nothing whose plugin was
# proven in this launch (a VST3 by its binary Private in the module list, a JSFX of Jsfx by fx_ident and its saved
# block; a plugin that is neither is never committed). Modules: the module verdict over the binaries of this batch's
# plugins (NoBinary when it has none).
function Get-HarnessLearnVerdict {
    param([Parameter(Mandatory)][object[]]$Variants, $Check = $null, [string]$LaunchWhy = '', [hashtable]$Installed = @{}, [hashtable]$Jsfx = @{}, [hashtable]$Seen = @{}, [scriptblock]$SameFile = $null)
    $same = $SameFile ?? ${function:Test-HarnessSameFile}
    $none = [pscustomobject]@{ Verdict = 'NoBinary'; Binaries = [ordered]@{} }
    $every = @{}
    $mine = @{}
    foreach ($id in $Installed.get_Keys()) {
        $row = $Installed[$id]
        $every[$row.BinaryLeaf] = $row.Binary
        if (@($Variants | Where-Object { $_.Plugin -ceq $id }).Count) { $mine[$row.BinaryLeaf] = $row.Binary }
    }
    # Asked about nothing, the module list says Unseen, which is right for it and wrong here: no binary, nothing to prove
    $all = $every.get_Count() ? (Get-HarnessModuleVerdict -Expected $every -Seen $Seen -SameFile $same) : $none
    $mod = $mine.get_Count() ? (Get-HarnessModuleVerdict -Expected $mine -Seen $Seen -SameFile $same) : $none
    $why = @(if ($Check) { $Check.Foreign }) + @($all.Binaries.get_Keys() | Where-Object { $all.Binaries[$_] -eq 'Foreign' } | ForEach-Object { "a module named $_ was loaded from outside the private plugins directory" })
    $commit = @(if (-not $why.Count -and $Check) {
            foreach ($v in $Variants) {
                $vst = $Installed.ContainsKey($v.Plugin) ? $Installed[$v.Plugin] : $null
                if ($Check.Blocks.ContainsKey($v.Key) -and ($vst ? ($mod.Binaries[$vst.BinaryLeaf] -ceq 'Private') : $Jsfx.ContainsKey($v.Plugin))) { $v.Key }
            }
        })
    $proof = ($mod.Verdict -ceq 'NoBinary') ? 'no plugin binary to check (only JSFX), each JSFX found at its private path (fx_ident)' : 'every tested binary loaded from the private copy (module list and fx_ident)'
    $status, $detail = if ($why.Count) { 'INCOMPLETE', ('not the private copy: ' + ($why -join '; ')) }
    elseif ($LaunchWhy) { 'INCOMPLETE', "the learn launch failed: $LaunchWhy" }
    elseif ($Check.Fail.Count) { 'FAIL', ($Check.Fail -join '; ') }
    elseif ($mod.Verdict -cnotin 'Proven', 'NoBinary') { 'INCOMPLETE', "the module list never showed $(@($mod.Binaries.get_Keys() | Where-Object { $mod.Binaries[$_] -eq 'Unseen' }) -join ', ') loaded, so the private copy is not proven" }
    else { 'PASS', "$($Variants.Count) plugin variants learned; $proof" }
    [pscustomobject]@{ Status = $status; Detail = $detail; Commit = $commit; Modules = $mod; Foreign = [bool]$why.Count }
}

# The launch of one learn batch (BatchNo of BatchCount): projects _learn-<k>-in.rpp and _learn-<k>.rpp, Lua step
# _learn-<k>, labelled as its row. Returns an outcome (Status PASS / FAIL / INCOMPLETE, Detail, Facts) with Stop:
# 'foreign' (a tested binary from outside the private copy: nothing more is learned, and nothing that needs learning runs),
# 'launch' (the launch was blocked or could not be ended: a skip marker, a busy lock, StillRunning; no later batch is
# started) or ''. What Get-HarnessLearnVerdict commits goes into Ctx.Blocks, Ctx.LearnReads, Ctx.Names and Ctx.AddNames,
# also when the row is FAIL for other entries. WithListing: the driver also lists the parameters of every entry, and
# Sweep (@{ Names; Values }) sweeps those on a fresh instance of it; the listing of each committed entry goes into
# Ctx.Listing (Read-HarnessParamListing). Nothing else of learning changes.
function Invoke-HarnessLearn {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][object[]]$Variants, [int]$BatchNo = 1, [int]$BatchCount = 1, [scriptblock]$SameFile = $null,
          [switch]$WithListing, [hashtable]$Sweep = $null)
    $same = $SameFile ?? ${function:Test-HarnessSameFile}
    $saveAs = Join-Path $Ctx.Work "_learn-$BatchNo.rpp"
    $project = Join-Path $Ctx.Work "_learn-$BatchNo-in.rpp"
    if (Test-Path -LiteralPath $saveAs) { Remove-Item -LiteralPath $saveAs }
    $Ctx.Files.Add($saveAs); $Ctx.Files.Add($project)
    $stateLines = @{}
    foreach ($v in $Variants) { if ($v.State) { $stateLines[$v.Key] = $Ctx.States["$($v.Plugin)@$($v.State)"].Lines } }
    $learnNames = Get-HarnessLearnTrackNames -Variants $Variants -States $Ctx.States
    Write-HarnessText -Path $project -Text (New-HarnessLearnProjectText -Variants $Variants -States $stateLines -TrackNames $learnNames)
    $fx = @(foreach ($v in $Variants) {
            $js = $Ctx.Jsfx.ContainsKey($v.Plugin) ? $Ctx.Jsfx[$v.Plugin] : $null
            $entry = @{ name = ($js ? $js.AddName : (Get-HarnessReaperName $Ctx.Installed[$v.Plugin].Info)); preloaded = [bool]$v.State
                params = @(foreach ($pn in $v.Params.get_Keys()) { @{ name = $pn; value = [double]$v.Params[$pn].Normalized } }) }
            if ($WithListing) { $entry.list = $true; if ($Sweep) { $entry.sweep = @{ names = @($Sweep.Names); values = @($Sweep['Values'] | ForEach-Object { [double]$_ }) } } }
            $entry
        })
    Set-HarnessAudioConfig -Sr $script:LearnRate -Block $script:LearnBlock
    $lua = Invoke-HarnessLuaStep -Ctx $Ctx -Name "_learn-$BatchNo" -Step learn -Label (Get-HarnessLearnRowId $BatchNo $BatchCount) -Job @{ fx = $fx; saveAs = $saveAs; project = $project } `
        -TimeoutSec ([double]$Ctx.Limits.learnTimeoutSec)
    $learnCheck = $null
    if (-not $lua.Why) {
        $Saved = (Test-Path -LiteralPath $saveAs) ? (Get-HarnessFxBlocks ([IO.File]::ReadAllText($saveAs))) : $null
        $learnCheck = Test-HarnessLearnReport -Variants $Variants -Installed $Ctx.Installed -Jsfx $Ctx.Jsfx -States $Ctx.States -Report $lua.Result -Saved $Saved -TrackNames $learnNames -SameFile $same
    }
    $judged = Get-HarnessLearnVerdict -Variants $Variants -Check $learnCheck -LaunchWhy ([string]$lua.Why) -Installed $Ctx.Installed -Jsfx $Ctx.Jsfx -Seen $lua.Run.Modules -SameFile $same
    foreach ($k in $judged.Commit) { $Ctx.Blocks[$k] = $learnCheck.Blocks[$k]; $Ctx.LearnReads[$k] = $learnCheck.Reads[$k] }
    # Names come from what was installed, per plugin; a plugin with an entry committed has its name
    foreach ($v in @($Variants | Where-Object { $_.Key -cin $judged.Commit })) { $Ctx.Names[$v.Plugin] = $learnCheck.Names[$v.Plugin]; $Ctx.AddNames[$v.Plugin] = $learnCheck.AddNames[$v.Plugin] }
    if ($WithListing) {
        for ($n = 1; $n -le $Variants.Count; $n++) {
            $v = $Variants[$n - 1]
            if ($v.Key -cnotin $judged.Commit) { continue }
            $js = $Ctx.Jsfx.ContainsKey($v.Plugin) ? $Ctx.Jsfx[$v.Plugin] : $null
            $Ctx.Listing[$v.Key] = Read-HarnessParamListing -Report $lua.Result -Key "fx${n}_" -Sweep $Sweep -Installed ($js ? $null : $Ctx.Installed[$v.Plugin]) -Jsfx $js -SameFile $same
        }
    }
    $facts = [ordered]@{ variants = $Variants.Count; batch = $BatchNo; batches = $BatchCount; modules = $judged.Modules.Verdict; binaries = $judged.Modules.Binaries }
    $used = @($Variants | Where-Object { $_.State } | ForEach-Object { "$($_.Plugin)@$($_.State)" } | Select-Object -Unique)
    if ($used.Count) { $facts.states = @($used | ForEach-Object { [ordered]@{ plugin = $Ctx.States[$_].Plugin; state = $Ctx.States[$_].State; sha256 = $Ctx.States[$_].Sha } }) }
    $facts.learned = $judged.Commit.Count
    $stop = $judged.Foreign ? 'foreign' : (($lua.Why -and ($lua.Run.StillRunning -or $lua.Run.Status -cin 'LockBusy', 'SkipMarker', 'Blocked')) ? 'launch' : '')
    New-HarnessOutcome $judged.Status $judged.Detail $facts | Add-Member -NotePropertyName Stop -NotePropertyValue $stop -PassThru
}

# Pure function: the listing the driver reported for learn entry Key ("fx<n>_"). Sweep: @{ Names; Values } or $null;
# Installed: the install row of a VST3 (Binary, Info.Cid), or Jsfx: the row of a JSFX (Ident); SameFile as above.
# Returns @{ Count; Nparams; Params; Sweeps; NotFound; Unclean; HostBy; Problem }. Problem, and nothing else is kept,
# when: the driver stopped listing or sweeping; the count is missing, not a whole number up to 65536 or not the same at the end; a
# parameter has no name; an instance to sweep was not added, is not the plugin that was learned (its name, binary and
# class ID, or its JSFX path) or a swept value was not read back. A parameter whose value is not a number from 0 to 1,
# that has no display text, or whose name is not exact (a control character, or not UTF-8) gets a problem of its own and
# counts in Unclean. REAPER's own parameters (host): an ident that is ':bypass', ':wet' or ':delta' (case-sensitive), with
# nothing or the parameter's own index in decimal in front (REAPER 7.82 gives '612:wet' to parameter 612, and
# '<index>:<number>' to the plugin's own), or without idents the last three named Bypass, Wet and Delta. Settable: what a
# configuration can set by name and learn finds (the first of that name).
# DisplayUsable: a display text a configuration can give as it is (exact, at most 128 characters, no path in it).
function Read-HarnessParamListing {
    param([Parameter(Mandatory)][hashtable]$Report, [Parameter(Mandatory)][string]$Key, [hashtable]$Sweep = $null, $Installed = $null, $Jsfx = $null, [scriptblock]$SameFile = $null)
    $same = $SameFile ?? ${function:Test-HarnessSameFile}
    $float = [Globalization.NumberStyles]::Float
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $problems = [Collections.Generic.List[string]]::new()
    if ($Report.ContainsKey("${Key}lerror")) { $problems.Add("the driver stopped listing: $($Report["${Key}lerror"])") }
    if ($Report.ContainsKey("${Key}serror")) { $problems.Add("the driver stopped sweeping: $($Report["${Key}serror"])") }
    $countText = [string]$Report["${Key}lcount"]
    $count = ($countText -cmatch '^\d{1,5}$' -and [int]$countText -le 65536) ? [int]$countText : -1
    if ($count -lt 0) { $problems.Add("the parameter count '$countText' is not a whole number from 0 to 65536") }
    elseif (-not $problems.Count -and [string]$Report["${Key}lcount_end"] -cne $countText) { $problems.Add("the parameter count changed while it was read ($countText, then '$($Report["${Key}lcount_end"])')") }
    $pattern = Get-HarnessParamNamePattern
    $lastThree = $count -ge 3 -and (@(for ($p = $count - 3; $p -lt $count; $p++) { [string]$Report["${Key}l${p}_name"] }) -join '|') -ceq 'Bypass|Wet|Delta'
    $first = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $hostBy = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $params = [Collections.Generic.List[object]]::new()
    $unclean = 0
    for ($p = 0; $p -lt $count; $p++) {
        $q = "${Key}l${p}_"
        if (-not $Report.ContainsKey("${q}name")) { $problems.Add("parameter $p has no name"); break }
        $name = [string]$Report["${q}name"]
        $why = [Collections.Generic.List[string]]::new()
        $num = 0.0
        $value = ([double]::TryParse([string]$Report["${q}value"], $float, $inv, [ref]$num) -and $num -ge 0 -and $num -le 1) ? $num : $null
        if ($null -eq $value) { $why.Add('its value is not a number from 0 to 1') }
        $display = $Report.ContainsKey("${q}display") ? [string]$Report["${q}display"] : $null
        if ($null -eq $display) { $why.Add('it has no display text') }
        $exact = [string]$Report["${q}exact"] -ceq 'true'
        if (-not $exact) { $why.Add('its name has a control character or is not UTF-8') }
        $paramId = $Report.ContainsKey("${q}ident") ? [string]$Report["${q}ident"] : $null
        $byReaper = ($null -ne $paramId) ? ($paramId -cmatch "\A(${p})?:(bypass|wet|delta)\z") : ($lastThree -and $p -ge $count - 3)
        if ($byReaper) { $null = $hostBy.Add((($null -ne $paramId) ? 'ident' : 'names')) }
        $sameAs = $first.ContainsKey($name) ? $first[$name] : $null
        if ($null -eq $sameAs) { $first[$name] = $p }
        # A path in the display text makes it unusable; one in the name makes the parameter not settable (either way the
        # file holds the masked text, not what REAPER shows)
        $displayMasked = $null -ne $display -and (Hide-HarnessPaths $display) -cne $display
        $masked = (Hide-HarnessPaths $name) -cne $name -or $displayMasked
        if ($why.Count) { $unclean++ }
        $params.Add([ordered]@{
                index = $p; name = $name; normalized = $value; display = $display; ident = $paramId; sameNameAs = $sameAs; host = $byReaper; exact = $exact; masked = $masked
                settable = ($name -cmatch $pattern -and $exact -and $null -eq $sameAs -and -not $masked -and -not $byReaper -and -not $why.Count)
                displayUsable = ($null -ne $display -and [string]$Report["${q}dexact"] -ceq 'true' -and $display.Length -le 128 -and -not $displayMasked)
                problem = ($why.Count ? ($why -join '; ') : $null)
            })
    }
    $sweeps = [Collections.Generic.List[object]]::new()
    $notFound = [Collections.Generic.List[string]]::new()
    $swept = @(if ($Sweep) { $Sweep.Names })
    for ($s = 1; $s -le $swept.Count; $s++) {
        $q = "${Key}s${s}_"
        $label = "the instance to sweep '$($swept[$s - 1])'"
        if ([string]$Report["${q}idx"] -cnotmatch '^\d+$') { $problems.Add("$label could not be added (index '$($Report["${q}idx"])')"); continue }
        if ([string]$Report["${q}name"] -cne [string]$Report["${Key}name"]) { $problems.Add("$label was added as '$($Report["${q}name"])', not as '$($Report["${Key}name"])'"); continue }
        $sid = [string]$Report["${q}ident"]
        $parts = Split-HarnessFxIdent $sid
        $proven = $Jsfx ? ($sid -ceq $Jsfx.Ident) : [bool]($Installed -and $parts.Path -and (& $same $parts.Path $Installed.Binary) -and $parts.Cid -ceq $Installed.Info.Cid)
        if (-not $proven) { $problems.Add("$label is not the plugin that was learned (fx_ident names another binary, class ID or effect)"); continue }
        $at = [string]$Report["${q}index"]
        if ($at -ceq 'missing') { $notFound.Add($swept[$s - 1]); continue }
        if ($at -cnotmatch '^\d+$') { $problems.Add("$label has no parameter index"); continue }
        $read = [Collections.Generic.List[object]]::new()
        for ($k = 1; $k -le @($Sweep['Values']).Count; $k++) {
            $num = 0.0
            if (-not ($Report.ContainsKey("${q}v${k}_display") -and [double]::TryParse([string]$Report["${q}v$k"], $float, $inv, [ref]$num) -and $num -ge 0 -and $num -le 1)) { $problems.Add("${label}: value $k was not read back"); break }
            $text = [string]$Report["${q}v${k}_display"]
            $read.Add([ordered]@{ normalized = [double]@($Sweep['Values'])[$k - 1]; readNormalized = $num; display = $text; displayUsable = ([string]$Report["${q}v${k}_dexact"] -ceq 'true' -and $text.Length -le 128 -and (Hide-HarnessPaths $text) -ceq $text) })
        }
        $sweeps.Add([ordered]@{ name = $swept[$s - 1]; index = [int]$at; values = $read.ToArray() })
    }
    $nparams = 0
    $nparams = [int]::TryParse([string]$Report["${Key}nparams"], [ref]$nparams) ? $nparams : $null
    if ($problems.Count) { return [pscustomobject]@{ Count = $count; Nparams = $nparams; Params = @(); Sweeps = @(); NotFound = @(); Unclean = 0; HostBy = @(); Problem = ($problems -join '; ') } }
    [pscustomobject]@{ Count = $count; Nparams = $nparams; Params = $params.ToArray(); Sweeps = $sweeps.ToArray(); NotFound = $notFound.ToArray(); Unclean = $unclean; HostBy = @($hostBy); Problem = '' }
}

function Format-HarnessCount([int]$Number, [string]$Noun) { "$Number $Noun$(($Number -eq 1) ? '' : 's')" }

# The params row of a parameter listing (run.ps1 -List params) and the listing of the result, from what the learn launch
# committed: per plugin of the round (Ctx.Installed and Ctx.Jsfx, in the order of the configuration) its identity, the
# hash of its learned block (as a kept render's manifest has it), its latency and Ctx.Listing of its default variant.
# Per plugin and for the row: PASS when listed cleanly with every swept name found; FAIL for a swept name the plugin does
# not have (learn treats a missing parameter so); INCOMPLETE when the plugin was not learned (see the learn row), its
# listing has a problem, or parameters were not read cleanly. NotRead: what the result says before anything was read
# (every plugin not listed, for that reason). Returns @{ Status; Detail; Facts; Lines; Listing (masked) }.
function Get-HarnessParamListing {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][hashtable]$Request, [string]$NotRead = '')
    $entries = [Collections.Generic.List[object]]::new()
    $lines = [Collections.Generic.List[string]]::new()
    $whys = [Collections.Generic.List[string]]::new()
    $missing = [Collections.Generic.List[string]]::new()
    $total = 0; $sweepCount = 0; $listedCount = 0
    foreach ($id in @($Ctx.Config.Plugins.get_Keys())) {
        $vst = $Ctx.Installed.ContainsKey($id) ? $Ctx.Installed[$id] : $null
        $js = $Ctx.Jsfx.ContainsKey($id) ? $Ctx.Jsfx[$id] : $null
        if (-not ($vst -or $js)) { continue }
        $k = "$id|"
        $got = (-not $NotRead -and $Ctx.Listing.ContainsKey($k)) ? $Ctx.Listing[$k] : $null
        $listed = $got -and -not $got.Problem
        $why = @(if ($NotRead) { $NotRead } elseif (-not $got) { 'not listed: its learn entry did not pass (see the learn row)' } elseif (-not $listed) { "not listed: $($got.Problem)" }
            if ($listed -and $got.Unclean) { "$(Format-HarnessCount $got.Unclean 'parameter') could not be read cleanly" }
            if ($listed) { foreach ($n in $got.NotFound) { "no parameter named '$n' in $id"; $missing.Add($n) } }) -join '; '
        $status = ($listed -and $got.NotFound.Count) ? 'FAIL' : ($why ? 'INCOMPLETE' : 'PASS')
        if ($why) { $whys.Add("${id}: $why") }
        $read = ($listed -and $Ctx.LearnReads.ContainsKey($k)) ? $Ctx.LearnReads[$k] : $null
        $pdc = 0
        $params = $listed ? @($got.Params) : @()
        $sweeps = $listed ? @($got.Sweeps) : @()
        if ($listed) {
            $listedCount++; $total += $params.Count; $sweepCount += $sweeps.Count
            $dups = @($params | Where-Object { $null -ne $_.sameNameAs } | ForEach-Object { $_.sameNameAs } | Select-Object -Unique).Count
            $lines.Add("${id}: $(Format-HarnessCount $params.Count 'parameter') ($(@($params | Where-Object { $_.host }).Count) of them REAPER's own, $(@($params | Where-Object { $_.settable }).Count) settable), $(Format-HarnessCount $dups 'name') used more than once$(($sweeps.Count) ? ", $($sweeps.Count) swept at $(Format-HarnessCount @($Request['Values']).Count 'value')" : '')")
        } else { $lines.Add("${id}: $why") }
        $entries.Add([ordered]@{
                id = $id; bundle = ($vst ? $vst.Bundle : $null); jsfx = ($js ? $js.Jsfx : $null); sha256 = ($vst ? $vst.Sha256 : $js.Sha256).Substring(0, 12)
                name = ($js ? $js.Name : (Get-HarnessReaperName $vst.Info)); class = ($vst ? [ordered]@{ name = $vst.Info.Name; vendor = $vst.Info.Vendor; cid = $vst.Info.Cid } : $null)
                classFrom = ($vst ? 'moduleinfo' : $null); version = ($vst ? $vst.Info.Version : $null)
                status = $status; listed = [bool]$listed; why = ($why ? $why : $null)
                blockSha256 = (($listed -and $Ctx.Blocks.ContainsKey($k)) ? (Get-HarnessBlockTextSha $Ctx.Blocks[$k]) : $null)
                pdc = (($read -and [int]::TryParse([string]$read.Pdc, [ref]$pdc)) ? $pdc : $null)
                nparams = ($got ? $got.Nparams : $null); paramCount = ($listed ? $got.Count : $null); hostBy = ($listed ? @($got.HostBy) : @())
                params = $params; sweeps = $sweeps; notFound = ($listed ? @($got.NotFound) : @())
            })
    }
    $statuses = @($entries | ForEach-Object { $_.status })
    $status = ('FAIL' -cin $statuses) ? 'FAIL' : ((('INCOMPLETE' -cin $statuses) -or -not $statuses.Count) ? 'INCOMPLETE' : 'PASS')
    $detail = $whys.Count ? ($whys -join '; ') : "$(Format-HarnessCount $listedCount 'plugin') listed, $(Format-HarnessCount $total 'parameter')$(($sweepCount) ? ", $sweepCount swept at $(Format-HarnessCount @($Request['Values']).Count 'value')" : '')"
    if (-not $statuses.Count) { $detail = 'no plugin to list' }
    $listing = [ordered]@{ kind = 'params'; values = ($Request.Params ? @($Request['Values']) : $null); readAt = [ordered]@{ sr = $script:LearnRate; block = $script:LearnBlock }; plugins = $entries.ToArray() }
    [pscustomobject]@{
        Status = $status; Detail = $detail; Lines = $lines.ToArray(); Listing = (Hide-HarnessFacts $listing)
        Facts = [ordered]@{ plugins = $entries.Count; listed = $listedCount; params = $total; sweeps = $sweepCount; notFound = $missing.ToArray() }
    }
}

# Over every launch of the round (Ctx.LaunchLog): any module with a tested binary's file name that is not the
# private copy makes the round INCOMPLETE. OtherPlugins: count of other .vst3 / .clap binaries seen loaded.
function Get-HarnessModuleCheck {
    param([Parameter(Mandatory)]$Ctx, [scriptblock]$SameFile = $null)
    $same = $SameFile ?? ${function:Test-HarnessSameFile}
    $expected = @{}
    foreach ($row in $Ctx.Installed.get_Values()) { $expected[$row.BinaryLeaf] = $row.Binary }
    $foreign = [Collections.Generic.SortedSet[string]]::new()
    $others = [Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($launch in $Ctx.LaunchLog) {
        if ($launch.Modules.get_Count()) {
            $v = Get-HarnessModuleVerdict -Expected $expected -Seen $launch.Modules -SameFile $same
            foreach ($k in $v.Binaries.get_Keys()) { if ($v.Binaries[$k] -eq 'Foreign') { $null = $foreign.Add("$k ($($launch.Label))") } }
        }
        foreach ($p in $launch.PluginModules) { if (-not ($expected.get_Values() | Where-Object { & $same $_ $p })) { $null = $others.Add($p) } }
    }
    $status = $foreign.Count ? 'INCOMPLETE' : 'PASS'
    $detail = $foreign.Count ? "a tested binary was loaded from outside the private plugins directory: $(@($foreign) -join ', ')" : (
        $expected.get_Count() ? "no tested binary was loaded from anywhere but the private copy in $($Ctx.LaunchLog.Count) launches" : "no plugin binary to check (only JSFX) in $($Ctx.LaunchLog.Count) launches")
    if ($others.Count) { $detail += "; $($others.Count) other plugin binaries were loaded" }
    New-HarnessOutcome $status $detail ([ordered]@{ launches = $Ctx.LaunchLog.Count; foreign = @($foreign); otherPlugins = $others.Count })
}

Export-ModuleMember -Function Get-HarnessReaperName, Get-HarnessScenarioLearnKeys, Get-HarnessLearnVariants, Get-HarnessLearnBatches, Get-HarnessLearnRowId, Get-HarnessLearnTrackNames, Split-HarnessFxIdent,
    Test-HarnessLearnReport, Get-HarnessLearnVerdict, Invoke-HarnessLearn, Read-HarnessParamListing, Get-HarnessParamListing, Get-HarnessModuleCheck
