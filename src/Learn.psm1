# SPDX-License-Identifier: MIT
#
# Learning the plugin blocks, and proving which plugin binary REAPER loaded.
# Once per round, one REAPER launch adds every plugin variant the round needs (each configured plugin with its
# default state, plus every distinct parameter set and named state a layout asks for) by name, sets the parameters
# by name, reads them back, and saves the project. A variant with a named state is not added by name: the project
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
#   Get-HarnessLearnVariants  the variants a set of scenarios needs (pure)
#   Get-HarnessReaperName     "VST3: <Name> (<Vendor>)" from moduleinfo
#   Test-HarnessLearnReport   the driver's report and the saved project against what was asked (pure)
#   Invoke-HarnessLearn       the launch itself; fills Ctx.Blocks and Ctx.Names
#   Get-HarnessModuleCheck    the module proof over every launch of the round (pure over Ctx.LaunchLog)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Guard.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Host.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Rpp.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Scenarios.psm1') -ErrorAction Stop

function Get-HarnessReaperName($Info) { "VST3: $($Info.Name) ($($Info.Vendor))" }

# Variants: one per configured plugin with no parameters (always: the module proof and the instances kind need
# them), then every distinct FX variant of the layouts the scenarios use, in first-use order, a state with parameters
# on top preceded by that state alone. State: the name of a state of the plugin ('' for its default state).
function Get-HarnessLearnVariants {
    param([Parameter(Mandatory)]$Config, [object[]]$Scenarios = @())
    $out = [ordered]@{}
    foreach ($id in $Config.Plugins.get_Keys()) { $out["$id|"] = [pscustomobject]@{ Key = "$id|"; Plugin = $id; State = ''; Params = [ordered]@{} } }
    $layoutIds = [Collections.Generic.List[string]]::new()
    foreach ($s in $Scenarios) {
        foreach ($name in 'layout') { if ($s.PSObject.Properties[$name] -and $s.$name -and $s.$name -notlike '@*' -and $s.$name -cnotin $layoutIds) { $layoutIds.Add($s.$name) } }
        if ($s.PSObject.Properties['compare'] -and $s.compare -and $s.compare.Kind -eq 'variant' -and $s.compare.Layout -cnotin $layoutIds) { $layoutIds.Add($s.compare.Layout) }
    }
    foreach ($lid in $layoutIds) {
        foreach ($t in $Config.Layouts[$lid].Tracks) {
            foreach ($fx in $t.Fx) {
                # A state with parameters on top is also learned on its own first: only a state with nothing set on top can
                # be compared with the block it was given, and that is what proves the plugin loads it
                $alone = "$($fx.Plugin)@$($fx.State)|"
                if ($fx.State -and $fx.Params.get_Count() -and -not $out.Contains($alone)) { $out[$alone] = [pscustomobject]@{ Key = $alone; Plugin = $fx.Plugin; State = $fx.State; Params = [ordered]@{} } }
                if (-not $out.Contains($fx.Variant)) { $out[$fx.Variant] = [pscustomobject]@{ Key = $fx.Variant; Plugin = $fx.Plugin; State = $fx.State; Params = $fx.Params } }
            }
        }
    }
    , @($out.get_Values())
}

# Splits fx_ident of a VST3 ("<binary path><uid{CID}") into path and class ID; anything else gives empty parts.
function Split-HarnessFxIdent([string]$Ident) {
    $m = [regex]::Match($Ident, '^(.*)<-?\d+\{([0-9A-Fa-f]{32})\}?$')
    if (-not $m.Success) { return [pscustomobject]@{ Path = ''; Cid = '' } }
    [pscustomobject]@{ Path = $m.Groups[1].Value; Cid = $m.Groups[2].Value.ToUpperInvariant() }
}

# Pure function. Variants, Installed (VST3 id -> install row with Binary and Info) and Jsfx (JSFX id -> row with Name,
# AddName, Ident) describe what was asked; States ("<plugin>@<state>" -> state with Lines) the named states; Report is
# the driver's key=value table; Saved is Get-HarnessFxBlocks of the saved project; SameFile (a, b) decides whether
# two paths are one file (default Test-HarnessSameFile). Returns @{ Fail; Foreign; Blocks (variant key -> lines);
# Names (id -> name REAPER shows); AddNames (id -> name to add it by) }.
function Test-HarnessLearnReport {
    param([Parameter(Mandatory)][object[]]$Variants, [Parameter(Mandatory)][hashtable]$Installed, [hashtable]$Jsfx = @{}, [System.Collections.IDictionary]$States = @{},
          [Parameter(Mandatory)][hashtable]$Report, $Saved, [scriptblock]$SameFile)
    $same = $SameFile ?? ${function:Test-HarnessSameFile}
    $fail = [Collections.Generic.List[string]]::new()
    $foreign = [Collections.Generic.List[string]]::new()
    $blocks = @{}
    $names = @{}
    $addNames = @{}
    for ($n = 1; $n -le $Variants.Count; $n++) {
        $v = $Variants[$n - 1]
        $js = $Jsfx.ContainsKey($v.Plugin) ? $Jsfx[$v.Plugin] : $null
        $row = $js ? $null : $Installed[$v.Plugin]
        $want = $js ? $js.Name : (Get-HarnessReaperName $row.Info)
        $names[$v.Plugin] = $want
        $addNames[$v.Plugin] = $js ? $js.AddName : $want
        $k = "fx${n}_"
        $label = "$($v.Plugin)$($v.State ? " state $($v.State)" : '')$($v.Params.get_Count() ? " (variant $n)" : '')"
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
        foreach ($pn in $v.Params.get_Keys()) {
            $i++
            $why = Test-HarnessParamValue $Report["${k}p$i"] $Report["${k}p${i}_display"] $v.Params[$pn]
            if ($why) { $fail.Add("$label parameter '$pn' $why") }
        }
        $track = "learn-$n"
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
        $blocks[$v.Key] = $list[0].Lines
    }
    [pscustomobject]@{ Fail = $fail.ToArray(); Foreign = $foreign.ToArray(); Blocks = $blocks; Names = $names; AddNames = $addNames }
}

# The learn launch. Returns an outcome (Status PASS / FAIL / INCOMPLETE, Detail, Facts) and fills Ctx.Blocks and
# Ctx.Names on success. A plugin loaded from anywhere but the private copy makes it INCOMPLETE (whatever else was
# found would be about another build); a plugin that did not load, or a wrong class ID, is FAIL.
function Invoke-HarnessLearn {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][object[]]$Variants, [scriptblock]$SameFile = $null)
    $same = $SameFile ?? ${function:Test-HarnessSameFile}
    $saveAs = Join-Path $Ctx.Work 'learn.rpp'
    $project = Join-Path $Ctx.Work 'learn-in.rpp'
    if (Test-Path -LiteralPath $saveAs) { Remove-Item -LiteralPath $saveAs }
    $Ctx.Files.Add($saveAs); $Ctx.Files.Add($project)
    $stateLines = @{}
    foreach ($v in $Variants) { if ($v.State) { $stateLines[$v.Key] = $Ctx.States["$($v.Plugin)@$($v.State)"].Lines } }
    Write-HarnessText -Path $project -Text (New-HarnessLearnProjectText -Variants $Variants -States $stateLines)
    $fx = @(foreach ($v in $Variants) {
            $js = $Ctx.Jsfx.ContainsKey($v.Plugin) ? $Ctx.Jsfx[$v.Plugin] : $null
            @{ name = ($js ? $js.AddName : (Get-HarnessReaperName $Ctx.Installed[$v.Plugin].Info)); preloaded = [bool]$v.State
               params = @(foreach ($pn in $v.Params.get_Keys()) { @{ name = $pn; value = [double]$v.Params[$pn].Normalized } }) }
        })
    Set-HarnessAudioConfig -Sr 48000 -Block 512
    $lua = Invoke-HarnessLuaStep -Ctx $Ctx -Name 'learn' -Step learn -Job @{ fx = $fx; saveAs = $saveAs; project = $project } -TimeoutSec ([double]$Ctx.Limits.learnTimeoutSec)
    $expected = @{}
    foreach ($row in $Ctx.Installed.get_Values()) { $expected[$row.BinaryLeaf] = $row.Binary }
    # Only JSFX shipped with the tool, no plugin binary: the module list has nothing to prove (asked about nothing it
    # says Unseen, which is right for it and wrong here), so it is not asked, and the facts say there was nothing to
    # check. A JSFX is proven by fx_ident and its saved block instead.
    $mod = $expected.get_Count() ? (Get-HarnessModuleVerdict -Expected $expected -Seen $lua.Run.Modules -SameFile $same) : [pscustomobject]@{ Verdict = 'NoBinary'; Binaries = [ordered]@{} }
    $facts = [ordered]@{ variants = $Variants.Count; modules = $mod.Verdict; binaries = $mod.Binaries }
    $used = @($Variants | Where-Object { $_.State } | ForEach-Object { "$($_.Plugin)@$($_.State)" } | Select-Object -Unique)
    if ($used.Count) { $facts.states = @($used | ForEach-Object { [ordered]@{ plugin = $Ctx.States[$_].Plugin; state = $Ctx.States[$_].State; sha256 = $Ctx.States[$_].Sha } }) }
    if ($lua.Why) { return New-HarnessOutcome INCOMPLETE "the learn launch failed: $($lua.Why)" $facts }
    $Saved = (Test-Path -LiteralPath $saveAs) ? (Get-HarnessFxBlocks ([IO.File]::ReadAllText($saveAs))) : $null
    $check = Test-HarnessLearnReport -Variants $Variants -Installed $Ctx.Installed -Jsfx $Ctx.Jsfx -States $Ctx.States -Report $lua.Result -Saved $Saved -SameFile $same
    $foreignMods = @($mod.Binaries.get_Keys() | Where-Object { $mod.Binaries[$_] -eq 'Foreign' })
    $why = @($check.Foreign) + @($foreignMods | ForEach-Object { "a module named $_ was loaded from outside the private plugins directory" })
    if ($why.Count) { return New-HarnessOutcome INCOMPLETE ("not the private copy: " + ($why -join '; ')) $facts }
    if ($check.Fail.Count) { return New-HarnessOutcome FAIL ($check.Fail -join '; ') $facts }
    if ($mod.Verdict -cnotin 'Proven', 'NoBinary') {
        $unseen = @($mod.Binaries.get_Keys() | Where-Object { $mod.Binaries[$_] -eq 'Unseen' })
        return New-HarnessOutcome INCOMPLETE "the module list never showed $($unseen -join ', ') loaded, so the private copy is not proven" $facts
    }
    foreach ($k in $check.Blocks.get_Keys()) { $Ctx.Blocks[$k] = $check.Blocks[$k] }
    foreach ($k in $check.Names.get_Keys()) { $Ctx.Names[$k] = $check.Names[$k]; $Ctx.AddNames[$k] = $check.AddNames[$k] }
    $proof = ($mod.Verdict -ceq 'NoBinary') ? 'no plugin binary to check (only JSFX), each JSFX found at its private path (fx_ident)' : 'every tested binary loaded from the private copy (module list and fx_ident)'
    New-HarnessOutcome PASS "$($Variants.Count) plugin variants learned; $proof" $facts
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

Export-ModuleMember -Function Get-HarnessReaperName, Get-HarnessLearnVariants, Split-HarnessFxIdent, Test-HarnessLearnReport, Invoke-HarnessLearn, Get-HarnessModuleCheck
