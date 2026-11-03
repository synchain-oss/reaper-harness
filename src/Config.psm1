# SPDX-License-Identifier: MIT
#
# The configuration file (schema 1): strict reading, validation and normalisation.
#   Read-HarnessConfig -Path <file> [-Kinds <extension kind table>]
#       reads and validates; returns the normalised configuration (defaults filled in, matrices expanded, built-in
#       negative cases appended). Any problem throws "USAGE: config: ..." listing every problem: the caller exits
#       with 64 and REAPER is never started.
#   Get-HarnessConfigSpec / ConvertTo-HarnessJsonSchema
#       the structure as data, and the JSON Schema generated from it (schema/config.schema.json is that output;
#       the self-test regenerates it and compares, and checks Test-Json agrees with this validator on fixtures)
#   Get-HarnessBuiltinNegatives
#       the product-independent negative cases run every round unless -NoNegative
# Structural rules (types, unknown keys, required keys, ranges, patterns) come from the spec table; cross-reference
# rules (layouts, plugins, parent tracks, ids, matrices, regexes, extension paths) are checked in code after it.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Json.psm1') -ErrorAction Stop

function Stop-Usage([string]$Reason) { throw [System.InvalidOperationException]::new("USAGE: $Reason") }

# ---- spec constructors (a small subset of JSON Schema, as data) ----
function SObj([System.Collections.Specialized.OrderedDictionary]$Props, [string[]]$Required = @(), [string]$Doc = '') { @{ t = 'object'; props = $Props; req = $Required; doc = $Doc } }
function SMap([string]$Key, $Value, [int]$Min = 0, [string]$Doc = '') { @{ t = 'map'; key = $Key; value = $Value; min = $Min; doc = $Doc } }
function SArr($Items, [int]$Min = 0, [switch]$Unique, [string]$Doc = '') { @{ t = 'array'; items = $Items; min = $Min; unique = [bool]$Unique; doc = $Doc } }
function SStr([string]$Pattern = '', [string[]]$Enum = @(), [string]$Doc = '') { @{ t = 'string'; pattern = $Pattern; enum = $Enum; doc = $Doc } }
function SInt([long]$Min, [long]$Max, [string]$Doc = '') { @{ t = 'integer'; min = $Min; max = $Max; doc = $Doc } }
function SNum([double]$Min, [double]$Max, [switch]$ExclusiveMin, [string]$Doc = '') { @{ t = 'number'; min = $Min; max = $Max; exmin = [bool]$ExclusiveMin; doc = $Doc } }
function SBool([string]$Doc = '') { @{ t = 'boolean'; doc = $Doc } }
function SAny([object[]]$Options, [string]$Label, [string]$Doc = '') { @{ t = 'any'; options = $Options; label = $Label; doc = $Doc } }
function SRef([string]$Name) { @{ t = 'ref'; name = $Name } }

$script:IdPattern = '^[a-z][a-z0-9-]{0,39}$'
$script:ScenarioIdPattern = '^[a-z0-9][a-z0-9-]{0,59}$'
$script:Modes = 'offline', '1x', 'online'
$script:Expectable = 'PASS', 'FAIL', 'SKIPPED', 'INCOMPLETE', 'REFUSED'
$script:BuiltinKinds = 'render', 'device', 'savereopen', 'instances'
$script:InternalKinds = 'hang', 'guard' # built-in negative cases only; never accepted from a configuration file

function New-HarnessSpec {
    $defs = [ordered]@{}
    $rate = SInt 8000 384000 'sample rate in Hz'
    $block = SInt 16 8192 'audio device block size in samples'
    $mode = SStr -Enum $script:Modes -Doc 'offline: full-speed offline render; 1x: real-time speed but plugins are told it is offline; online: real-time render, plugins are told it is real time'
    $defs.paramValue = SAny @((SNum 0 1), (SObj ([ordered]@{ normalized = (SNum 0 1); display = (SStr '^[^\u0000-\u001f]{0,128}$') }) @('normalized'))) 'a normalized value 0..1, or { normalized, display }'
    $defs.fx = SObj ([ordered]@{
            plugin = (SStr $script:IdPattern -Doc 'id from plugins')
            bypass = (SBool)
            params = (SMap '^[^\u0000-\u001f]{1,128}$' (SRef paramValue) -Doc 'parameter name -> value, set by name and read back by the Lua driver')
        }) @('plugin')
    $defs.track = SObj ([ordered]@{
            name   = (SStr '^[^"\u0000-\u001f]{1,64}$')
            source = (SBool -Doc 'the track carries the test signal')
            folder = (SBool -Doc 'a REAPER folder (bus) track; its children are the following tracks that name it as parent')
            parent = (SStr '^[^"\u0000-\u001f]{1,64}$' -Doc 'name of the folder track this track belongs to')
            volume = (SNum 0 4 -Doc 'linear track volume')
            fx     = (SArr (SRef fx))
        }) @('name', 'source')
    $defs.layout = SObj ([ordered]@{ tracks = (SArr (SRef track) -Min 1) }) @('tracks')
    $bypass = SAny @((SBool), (SArr (SStr $script:IdPattern) -Min 1 -Unique)) 'true (every FX) or a list of plugin ids'
    $defs.compareVariant = SObj ([ordered]@{ layout = (SStr $script:IdPattern); block = $block; mode = $mode; bypass = $bypass })
    $defs.matrix = SObj ([ordered]@{ mode = (SArr $mode -Min 1 -Unique); sr = (SArr $rate -Min 1 -Unique); block = (SArr $block -Min 1 -Unique) })
    $common = { [ordered]@{ id = (SStr $script:ScenarioIdPattern); kind = (SStr -Enum $args[0]) } }
    $Kinds = [ordered]@{}
    # The render criteria are fields of the scenario itself (not an "expect" object): in negative cases "expect" is
    # the expected outcome
    $renderProps = [ordered]@{
        layout = (SStr $script:IdPattern); mode = $mode; sr = $rate; block = $block; mono = (SBool); bypass = $bypass
        compare   = (SAny @((SStr -Enum 'dry', 'repeat'), (SRef compareVariant)) '"dry" (default), "repeat" or a variant object')
        maxDiffDb = (SNum -400 0 -Doc 'allowed residual in dBFS; absent means bit-identical')
        lag       = (SInt -4096 4096 -Doc 'expected lag in samples (the test render later than the reference is positive), default 0')
        peakMaxDb = (SNum -400 24 -Doc 'the test render must not peak above this')
        notSilent = (SBool -Doc 'the test render must peak above -120 dBFS')
        matrix = (SRef matrix)
    }
    $p = & $common 'render'; foreach ($e in $renderProps.GetEnumerator()) { $p[$e.Key] = $e.Value }
    $Kinds.render = SObj $p @('id', 'kind', 'layout')
    $p = & $common 'device'; foreach ($e in ([ordered]@{ layout = (SStr $script:IdPattern); sr = $rate; block = $block; matrix = (SRef matrix) }).GetEnumerator()) { $p[$e.Key] = $e.Value }
    $Kinds.device = SObj $p @('id', 'kind', 'layout')
    $p = & $common 'savereopen'; foreach ($e in ([ordered]@{ layout = (SStr $script:IdPattern); mode = $mode; sr = $rate; block = $block; bypass = $bypass; matrix = (SRef matrix) }).GetEnumerator()) { $p[$e.Key] = $e.Value }
    $Kinds.savereopen = SObj $p @('id', 'kind', 'layout')
    $p = & $common 'instances'
    foreach ($e in ([ordered]@{ plugins = (SArr (SStr $script:IdPattern) -Min 1 -Unique); cycles = (SInt 1 10000); warmup = (SInt 0 10000); play = (SBool); maxHandleGrowth = (SInt 0 1000000); maxPrivateGrowthMB = (SNum 0 1000000); sr = $rate; block = $block }).GetEnumerator()) { $p[$e.Key] = $e.Value }
    $Kinds.instances = SObj $p @('id', 'kind')
    $root = SObj ([ordered]@{
            '$schema'  = (SStr)
            schema     = (SInt 1 1)
            name       = (SStr '^[a-z0-9-]{1,40}$' -Doc 'goes into result file names')
            notes      = (SStr)
            plugins    = (SMap $script:IdPattern (SObj ([ordered]@{ bundle = (SStr '^[^\\/:*?"<>|\u0000-\u001f]{1,120}\.vst3$' -Doc 'bundle directory name, looked up in -PluginDir'); expectPdc = (SInt 0 1000000) }) @('bundle')) -Min 1)
            signal     = (SObj ([ordered]@{ seconds = (SNum 0.5 600); seed = (SInt 0 4294967295); noiseDb = (SNum -200 0); sine = (SObj ([ordered]@{ hz = (SNum 0 20000 -ExclusiveMin); db = (SNum -200 0) }) @('hz')) }))
            limits     = (SObj ([ordered]@{
                        renderTimeoutSec = (SNum 1 3600); luaTimeoutSec = (SNum 1 3600); learnTimeoutSec = (SNum 1 3600); lockWaitSec = (SNum 0 86400)
                        lagSearch = (SInt 0 4096); headSeconds = (SNum 0 600 -ExclusiveMin)
                        instances = (SObj ([ordered]@{ cycles = (SInt 1 10000); warmup = (SInt 0 10000); play = (SBool); maxHandleGrowth = (SInt 0 1000000); maxPrivateGrowthMB = (SNum 0 1000000) }))
                    }))
            layouts    = (SMap $script:IdPattern (SRef layout) -Min 1)
            scenarios  = (SArr (SRef scenario) -Min 1)
            negative   = (SArr (SRef negativeScenario))
            extensions = (SObj ([ordered]@{ modules = (SArr (SStr '^[^\u0000-\u001f]{1,260}\.psm1$') -Unique); lua = (SArr (SStr '^[^\u0000-\u001f]{1,260}\.lua$') -Unique) }))
        }) @('schema', 'name', 'plugins', 'layouts', 'scenarios')
    @{ Root = $root; Defs = $defs; Kinds = $Kinds }
}

$script:Spec = New-HarnessSpec
function Get-HarnessConfigSpec { $script:Spec }

# Negative variant of a kind: the same fields without matrix, plus expect and expectDetail (both required).
function Get-NegativeKindSpec([string]$Kind) {
    $k = $script:Spec.Kinds[$Kind]
    $Props = [ordered]@{}
    foreach ($e in $k.props.GetEnumerator()) { if ($e.Key -cne 'matrix') { $Props[$e.Key] = $e.Value } }
    $Props.expect = SStr -Enum $script:Expectable
    $Props.expectDetail = SStr -Doc 'regex (.NET, case sensitive) the outcome detail must match'
    SObj $Props (@($k.req) + 'expect', 'expectDetail')
}

# ---- structural validation ----
function Test-IsInteger($v) { ($v -is [long] -or $v -is [int]) -or ($v -is [double] -and -not [double]::IsInfinity($v) -and [Math]::Floor($v) -eq $v) }
function Test-IsNumber($v) { $v -is [long] -or $v -is [int] -or $v -is [double] }
function Get-SpecText($v) { ConvertTo-HarnessJsonText -Value $v }

# Walks Spec over Value and adds one problem per violation to Problems (paths like scenarios[2].expect.lag).
# Kinds: extension kinds (kind name -> registration); their items only get id / kind checked here.
function Test-SpecValue($Spec, $Value, [string]$Path, [Collections.Generic.List[string]]$Problems, [hashtable]$Kinds = @{}, [switch]$NegativeContext) {
    switch ($Spec.t) {
        'ref' {
            if ($Spec.name -in 'scenario', 'negativeScenario') { return Test-ScenarioItem $Value $Path $Problems $Kinds -Negative:($Spec.name -eq 'negativeScenario') }
            return Test-SpecValue $script:Spec.Defs[$Spec.name] $Value $Path $Problems $Kinds
        }
        'object' {
            if ($Value -isnot [System.Collections.IDictionary]) { $Problems.Add("${Path}: must be an object"); return }
            foreach ($k in $Value.get_Keys()) { if ($k -cnotin @($Spec.props.get_Keys())) { $Problems.Add("${Path}: unknown key '$k'") } }
            foreach ($r in $Spec.req) { if (-not $Value.Contains($r)) { $Problems.Add("${Path}: missing '$r'") } }
            foreach ($k in $Spec.props.get_Keys()) { if ($Value.Contains($k)) { Test-SpecValue $Spec.props[$k] $Value[$k] "$Path.$k" $Problems $Kinds } }
        }
        'map' {
            if ($Value -isnot [System.Collections.IDictionary]) { $Problems.Add("${Path}: must be an object"); return }
            if ($Value.get_Count() -lt $Spec.min) { $Problems.Add("${Path}: needs at least $($Spec.min) entr$($Spec.min -eq 1 ? 'y' : 'ies')") }
            foreach ($k in $Value.get_Keys()) {
                if (-not (Test-Pattern $k $Spec.key)) { $Problems.Add("${Path}: key '$k' does not match $($Spec.key)") }
                Test-SpecValue $Spec.value $Value[$k] "$Path.$k" $Problems $Kinds
            }
        }
        'array' {
            if ($Value -isnot [object[]]) { $Problems.Add("${Path}: must be an array"); return }
            if ($Value.Count -lt $Spec.min) { $Problems.Add("${Path}: needs at least $($Spec.min) item$($Spec.min -eq 1 ? '' : 's')") }
            if ($Spec.unique) {
                $texts = @($Value | ForEach-Object { Get-SpecText $_ })
                if (@($texts | Sort-Object -Unique -CaseSensitive).Count -ne $texts.Count) { $Problems.Add("${Path}: items must be unique") }
            }
            for ($i = 0; $i -lt $Value.Count; $i++) { Test-SpecValue $Spec.items $Value[$i] "$Path[$i]" $Problems $Kinds }
        }
        'string' {
            if ($Value -isnot [string]) { $Problems.Add("${Path}: must be a string"); return }
            if ($Spec.enum.Count -and $Value -cnotin $Spec.enum) { $Problems.Add("${Path}: must be one of $($Spec.enum -join ', ')") }
            if ($Spec.pattern -and -not (Test-Pattern $Value $Spec.pattern)) { $Problems.Add("${Path}: '$Value' does not match $($Spec.pattern)") }
        }
        'integer' {
            if ($Value -is [bool] -or -not (Test-IsInteger $Value)) { $Problems.Add("${Path}: must be an integer"); return }
            if ([double]$Value -lt $Spec.min -or [double]$Value -gt $Spec.max) { $Problems.Add("${Path}: must be between $($Spec.min) and $($Spec.max)") }
        }
        'number' {
            if ($Value -is [bool] -or -not (Test-IsNumber $Value)) { $Problems.Add("${Path}: must be a number"); return }
            $low = $Spec.exmin ? ([double]$Value -le $Spec.min) : ([double]$Value -lt $Spec.min)
            if ($low -or [double]$Value -gt $Spec.max) { $Problems.Add("${Path}: must be $($Spec.exmin ? 'above' : 'at least') $($Spec.min) and at most $($Spec.max)") }
        }
        'boolean' { if ($Value -isnot [bool]) { $Problems.Add("${Path}: must be true or false") } }
        'any' {
            foreach ($o in $Spec.options) {
                $sub = [Collections.Generic.List[string]]::new()
                Test-SpecValue $o $Value $Path $sub $Kinds
                if ($sub.Count -eq 0) { return }
            }
            $Problems.Add("${Path}: must be $($Spec.label)")
        }
    }
}

# Anchored patterns: a trailing newline never counts as the end (.NET $ would accept "abc`n").
function Test-Pattern([string]$Text, [string]$Pattern) { -not $Text.Contains("`n") -and $Text -cmatch $Pattern }

function Test-ScenarioItem($Value, [string]$Path, [Collections.Generic.List[string]]$Problems, [hashtable]$Kinds, [switch]$Negative) {
    if ($Value -isnot [System.Collections.IDictionary]) { $Problems.Add("${Path}: must be an object"); return }
    $Kind = $Value['kind']
    if ($Kind -isnot [string]) { $Problems.Add("${Path}: missing 'kind' (a string)"); return }
    if ($Kind -cin $script:BuiltinKinds) {
        $kindSpec = $Negative ? (Get-NegativeKindSpec $Kind) : $script:Spec.Kinds[$Kind]
        return Test-SpecValue $kindSpec $Value $Path $Problems $Kinds
    }
    if ($Kinds.ContainsKey($Kind)) {
        $Id = $Value['id']
        if ($Id -isnot [string] -or -not (Test-Pattern $Id $script:ScenarioIdPattern)) { $Problems.Add("${Path}: 'id' must match $($script:ScenarioIdPattern)") }
        if ($Negative) {
            if ($Value['expect'] -cnotin $script:Expectable) { $Problems.Add("${Path}: 'expect' must be one of $($script:Expectable -join ', ')") }
            if ($Value['expectDetail'] -isnot [string]) { $Problems.Add("${Path}: missing 'expectDetail' (a regex string)") }
        }
        $copy = [ordered]@{}
        foreach ($k in $Value.get_Keys()) { if ($k -cnotin 'id', 'kind', 'expect', 'expectDetail') { $copy[$k] = $Value[$k] } }
        try { foreach ($x in @(& $Kinds[$Kind].Validate $copy)) { if ($x) { $Problems.Add("${Path}: $x") } } }
        catch { $Problems.Add("${Path}: the validator of extension kind '$Kind' threw: $($_.Exception.Message)") }
        return
    }
    $known = @($script:BuiltinKinds) + @($Kinds.get_Keys() | Sort-Object)
    $Problems.Add("${Path}: unknown kind '$Kind' (known: $($known -join ', '))")
}

# ---- JSON Schema generation ----
function ConvertTo-SchemaNode($Spec) {
    $n = [ordered]@{}
    switch ($Spec.t) {
        'ref' { $n['$ref'] = "#/`$defs/$($Spec.name)"; return $n }
        'object' {
            $n.type = 'object'
            $Props = [ordered]@{}
            foreach ($k in $Spec.props.get_Keys()) { $Props[$k] = ConvertTo-SchemaNode $Spec.props[$k] }
            $n.properties = $Props
            if ($Spec.req.Count) { $n.required = @($Spec.req) }
            $n.additionalProperties = $false
        }
        'map' {
            $n.type = 'object'
            $n.propertyNames = [ordered]@{ pattern = $Spec.key }
            $n.additionalProperties = ConvertTo-SchemaNode $Spec.value
            if ($Spec.min) { $n.minProperties = $Spec.min }
        }
        'array' {
            $n.type = 'array'
            $n.items = ConvertTo-SchemaNode $Spec.items
            if ($Spec.min) { $n.minItems = $Spec.min }
            if ($Spec.unique) { $n.uniqueItems = $true }
        }
        'string' {
            $n.type = 'string'
            if ($Spec.enum.Count -eq 1) { $n.const = $Spec.enum[0] } elseif ($Spec.enum.Count) { $n.enum = @($Spec.enum) }
            if ($Spec.pattern) { $n.pattern = $Spec.pattern }
        }
        'integer' { $n.type = 'integer'; $n.minimum = $Spec.min; $n.maximum = $Spec.max }
        'number' {
            $n.type = 'number'
            if ($Spec.exmin) { $n.exclusiveMinimum = $Spec.min } else { $n.minimum = $Spec.min }
            $n.maximum = $Spec.max
        }
        'boolean' { $n.type = 'boolean' }
        'any' { $n.anyOf = @($Spec.options | ForEach-Object { ConvertTo-SchemaNode $_ }) }
    }
    if ($Spec.Contains('doc') -and $Spec.doc) { $n.description = $Spec.doc }
    $n
}

# Scenario items: id and kind always; built-in kinds must match their own object; other kinds (extensions) are left
# open here and validated by the extension.
function ConvertTo-ScenarioSchema([switch]$Negative) {
    $branches = foreach ($Kind in $script:BuiltinKinds) {
        $kindSpec = $Negative ? (Get-NegativeKindSpec $Kind) : $script:Spec.Kinds[$Kind]
        [ordered]@{ if = [ordered]@{ properties = [ordered]@{ kind = [ordered]@{ const = $Kind } }; required = @('kind') }; then = (ConvertTo-SchemaNode $kindSpec) }
    }
    $req = $Negative ? @('id', 'kind', 'expect', 'expectDetail') : @('id', 'kind')
    $Props = [ordered]@{ id = [ordered]@{ type = 'string'; pattern = $script:ScenarioIdPattern }; kind = [ordered]@{ type = 'string'; not = [ordered]@{ enum = @($script:InternalKinds) } } }
    if ($Negative) { $Props.expect = [ordered]@{ enum = @($script:Expectable) }; $Props.expectDetail = [ordered]@{ type = 'string' } }
    [ordered]@{ type = 'object'; required = $req; properties = $Props; allOf = @($branches) }
}

function ConvertTo-HarnessJsonSchema {
    $schema = [ordered]@{ '$schema' = 'https://json-schema.org/draft/2020-12/schema'; '$id' = 'https://github.com/synchain-oss/reaper-harness/schema/config.schema.json' }
    $schema.title = 'reaper-harness configuration (schema 1)'
    $schema.description = 'Generated from src/Config.psm1 (Get-HarnessConfigSpec); the validator there is authoritative. Do not edit by hand: run.ps1 -WriteSchema regenerates it.'
    foreach ($e in (ConvertTo-SchemaNode $script:Spec.Root).GetEnumerator()) { $schema[$e.Key] = $e.Value }
    $defs = [ordered]@{}
    foreach ($k in $script:Spec.Defs.get_Keys()) { $defs[$k] = ConvertTo-SchemaNode $script:Spec.Defs[$k] }
    $defs.scenario = ConvertTo-ScenarioSchema
    $defs.negativeScenario = ConvertTo-ScenarioSchema -Negative
    $schema['$defs'] = $defs
    (ConvertTo-HarnessJsonText -Value $schema -Indent 2) + "`n"
}

# ---- defaults ----
$script:Defaults = @{
    signal    = [ordered]@{ seconds = 4.0; seed = 1; noiseDb = -20.0 }
    limits    = [ordered]@{ renderTimeoutSec = 90.0; luaTimeoutSec = 120.0; learnTimeoutSec = 120.0; lockWaitSec = 1800.0; lagSearch = 64; headSeconds = 2.0 }
    instances = [ordered]@{ cycles = 25; warmup = 5; play = $false; maxHandleGrowth = 150; maxPrivateGrowthMB = 150.0 }
    sineDb    = -20.0
    sr        = 48000
    block     = 512
    mode      = 'offline'
}
function Get-HarnessConfigDefaults { $script:Defaults }

function Get-Or($Dict, [string]$Key, $Default) { ($null -ne $Dict -and $Dict.Contains($Key)) ? $Dict[$Key] : $Default }

# ---- built-in negative cases ----
# Product independent: two that prove the comparer (on a layout without plugins), two that prove the watchdog, three
# that prove the entry guards. Like every negative case, a row only passes when both the outcome and the reason
# (expectDetail) match; a case that could not run is INCOMPLETE, never PASS.
function Get-HarnessBuiltinNegatives {
    $dry = '@dry' # internal layout: one source track, no FX ('@' cannot appear in configuration ids)
    $make = { param($h) [pscustomobject]$h }
    @(
        (& $make @{ id = 'neg-offset-1-sample'; kind = 'render'; negative = $true; builtin = $true; layout = $dry; mode = 'offline'; sr = 48000; block = 512; mono = $false; bypass = @(); compare = [pscustomobject]@{ Kind = 'dry' }
                maxDiffDb = $null; lag = 0; peakMaxDb = $null; notSilent = $false; mutate = [pscustomobject]@{ sourceOffsetSamples = 1; trackVolume = 1.0 }; expect = 'FAIL'; expectDetail = '^identical=no lag=1 ' })
        (& $make @{ id = 'neg-track-minus-6db'; kind = 'render'; negative = $true; builtin = $true; layout = $dry; mode = 'offline'; sr = 48000; block = 512; mono = $false; bypass = @(); compare = [pscustomobject]@{ Kind = 'dry' }
                maxDiffDb = $null; lag = 0; peakMaxDb = $null; notSilent = $false; mutate = [pscustomobject]@{ sourceOffsetSamples = 0; trackVolume = 0.5 }; expect = 'FAIL'; expectDetail = '^identical=no lag=0 maxdiff=-6\.0' })
        (& $make @{ id = 'neg-timeout'; kind = 'hang'; negative = $true; builtin = $true; timeoutSec = 8.0; killAfterSec = 0.0; expect = 'INCOMPLETE'; expectDetail = '^timed out after .*; the process has ended and the GUI locks are free$' })
        (& $make @{ id = 'neg-killed'; kind = 'hang'; negative = $true; builtin = $true; timeoutSec = 0.0; killAfterSec = 4.0; expect = 'INCOMPLETE'; expectDetail = '^killed at the deadline .*; the process has ended and the GUI locks are free$' })
        (& $make @{ id = 'neg-skip-marker'; kind = 'guard'; negative = $true; builtin = $true; guard = 'skip-marker'; expect = 'SKIPPED'; expectDetail = '^launches=0; skip marker present' })
        (& $make @{ id = 'neg-sentinel-missing'; kind = 'guard'; negative = $true; builtin = $true; guard = 'sentinel-missing'; expect = 'REFUSED'; expectDetail = '^REFUSED: .*sentinel' })
        (& $make @{ id = 'neg-default-dir'; kind = 'guard'; negative = $true; builtin = $true; guard = 'default-dir'; expect = 'REFUSED'; expectDetail = '^REFUSED: .*never touched' })
    )
}

# ---- normalisation and cross-reference checks ----
function ConvertTo-Bypass($Value, [string]$Path, $LayoutPlugins, $Problems, $AllPlugins) {
    if ($null -eq $Value -or $Value -is [bool] -and -not $Value) { return , @() }
    if ($Value -is [bool]) { return , @('*') }
    $ids = @($Value | ForEach-Object { [string]$_ })
    foreach ($i in $ids) {
        if ($i -cnotin $AllPlugins) { $Problems.Add("${Path}: plugin '$i' is not defined in plugins") }
        elseif ($null -ne $LayoutPlugins -and $i -cnotin $LayoutPlugins) { $Problems.Add("${Path}: plugin '$i' is not used in that layout") }
    }
    , $ids
}

function ConvertTo-Layout([string]$Id, $Raw, [string[]]$Plugins, $Problems) {
    $tracks = [Collections.Generic.List[object]]::new()
    $names = @{}
    $open = [Collections.Generic.List[string]]::new() # folder names enclosing the current position, outermost first
    $i = 0
    foreach ($t in $Raw.tracks) {
        $Path = "layouts.$Id.tracks[$i]"
        $Name = [string]$t.name
        if ($names.ContainsKey($Name)) { $Problems.Add("${Path}: track name '$Name' is used twice in layout '$Id'") }
        $parent = Get-Or $t 'parent' ''
        if ($parent) {
            if (-not $names.ContainsKey($parent)) { $Problems.Add("${Path}: parent '$parent' is not a track listed before this one") }
            elseif (-not $names[$parent].Folder) { $Problems.Add("${Path}: parent '$parent' is not a folder track") }
            elseif ($parent -cnotin $open) { $Problems.Add("${Path}: tracks of folder '$parent' must follow it without other tracks in between") }
            else { while ($open.Count -and $open[$open.Count - 1] -cne $parent) { $open.RemoveAt($open.Count - 1) } }
        } else { $open.Clear() }
        $fxList = [Collections.Generic.List[object]]::new()
        $j = 0
        foreach ($fx in @(Get-Or $t 'fx' @())) {
            $plugin = [string]$fx.plugin
            if ($plugin -cnotin $Plugins) { $Problems.Add("${Path}.fx[$j]: plugin '$plugin' is not defined in plugins") }
            $params = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            $rawParams = Get-Or $fx 'params' $null
            if ($rawParams) {
                foreach ($pn in @($rawParams.get_Keys() | Sort-Object -CaseSensitive)) {
                    $pv = $rawParams[$pn]
                    $params[$pn] = ($pv -is [System.Collections.IDictionary]) ? [pscustomobject]@{ Normalized = [double]$pv['normalized']; Display = (Get-Or $pv 'display' $null) } : [pscustomobject]@{ Normalized = [double]$pv; Display = $null }
                }
            }
            $variantKey = $plugin + '|' + (@($params.get_Keys() | ForEach-Object { '{0}={1}' -f $_, $params[$_].Normalized.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }) -join ';')
            $fxList.Add([pscustomobject]@{ Plugin = $plugin; Bypass = [bool](Get-Or $fx 'bypass' $false); Params = $params; Variant = $variantKey })
            $j++
        }
        $track = [pscustomobject]@{ Name = $Name; Source = [bool]$t.source; Folder = [bool](Get-Or $t 'folder' $false); Parent = $parent; Volume = [double](Get-Or $t 'volume' 1.0); Fx = $fxList.ToArray(); Depth = $open.Count }
        $names[$Name] = $track
        $tracks.Add($track)
        if ($track.Folder) { $open.Add($Name) }
        $i++
    }
    foreach ($t in $tracks) {
        if ($t.Folder -and -not @($tracks | Where-Object { $_.Parent -ceq $t.Name }).Count) { $Problems.Add("layouts.${Id}: folder track '$($t.Name)' has no tracks in it") }
    }
    if (-not @($tracks | Where-Object { $_.Source }).Count) { $Problems.Add("layouts.${Id}: no track has source: true, so nothing would be rendered") }
    [pscustomobject]@{ Id = $Id; Tracks = $tracks.ToArray(); Plugins = @($tracks | ForEach-Object { $_.Fx } | ForEach-Object { $_.Plugin } | Sort-Object -Unique -CaseSensitive) }
}

# The internal layout of the comparer negatives: one source track, no FX.
function Get-HarnessDryLayout { [pscustomobject]@{ Id = '@dry'; Tracks = @([pscustomobject]@{ Name = 'Dry'; Source = $true; Folder = $false; Parent = ''; Volume = 1.0; Fx = @(); Depth = 0 }); Plugins = @() } }

function Expand-Matrix($Raw) {
    $m = Get-Or $Raw 'matrix' $null
    if ($null -eq $m) { return , @(, $Raw) }
    $axes = @('mode', 'sr', 'block' | Where-Object { $m.Contains($_) })
    $out = [Collections.Generic.List[object]]::new()
    $out.Add([ordered]@{ suffix = ''; picked = @{} })
    foreach ($axis in $axes) {
        $next = [Collections.Generic.List[object]]::new()
        foreach ($partial in $out) { foreach ($v in $m[$axis]) { $vals = $partial.picked.Clone(); $vals[$axis] = $v; $next.Add([ordered]@{ suffix = "$($partial.suffix)-$v"; picked = $vals }) } }
        $out = $next
    }
    , @(foreach ($o in $out) {
        $copy = [ordered]@{}
        foreach ($k in $Raw.get_Keys()) { if ($k -cne 'matrix') { $copy[$k] = $Raw[$k] } }
        $copy['id'] = [string]$Raw['id'] + $o.suffix
        foreach ($k in $o.picked.get_Keys()) { $copy[$k] = $o.picked[$k] }
        $copy
    })
}

function ConvertTo-Scenario($Raw, [string]$Path, [bool]$Negative, $Layouts, [string[]]$Plugins, $Limits, $Problems, [hashtable]$Kinds) {
    $Kind = [string]$Raw['kind']
    $o = [ordered]@{ id = [string]$Raw['id']; kind = $Kind; negative = $Negative; builtin = $false }
    if ($Negative) {
        $o.expect = [string]$Raw['expect']; $o.expectDetail = [string]$Raw['expectDetail']
        # A regex that matches the empty text (nothing at all, .*, ^, a?) matches every reason: the case would pass on its outcome alone
        try { if ([regex]::IsMatch('', $o.expectDetail)) { $Problems.Add("${Path}: expectDetail must not match an empty text: it would accept any reason") } }
        catch { $Problems.Add("${Path}: expectDetail is not a valid regex") }
    }
    if ($Kind -cnotin $script:BuiltinKinds) {
        # Extension kinds: a string 'layout' is checked here and its plugin variants are learned like any other
        if ($Raw['layout'] -is [string]) {
            $o.layout = $Raw['layout']
            if (-not $Layouts.Contains($o.layout)) { $Problems.Add("${Path}: layout '$($o.layout)' is not defined in layouts") }
        }
        $o.raw = $Raw
        return [pscustomobject]$o
    }
    $LayoutPlugins = $null
    if ($Raw.Contains('layout')) {
        $o.layout = [string]$Raw['layout']
        if (-not $Layouts.Contains($o.layout)) { $Problems.Add("${Path}: layout '$($o.layout)' is not defined in layouts") } else { $LayoutPlugins = $Layouts[$o.layout].Plugins }
    }
    $o.sr = [int](Get-Or $Raw 'sr' $script:Defaults.sr)
    $o.block = [int](Get-Or $Raw 'block' $script:Defaults.block)
    switch ($Kind) {
        'render' {
            $o.mode = [string](Get-Or $Raw 'mode' $script:Defaults.mode); $o.mono = [bool](Get-Or $Raw 'mono' $false)
            $o.bypass = ConvertTo-Bypass (Get-Or $Raw 'bypass' $null) "$Path.bypass" $LayoutPlugins $Problems $Plugins
            $c = Get-Or $Raw 'compare' 'dry'
            if ($c -is [string]) { $o.compare = [pscustomobject]@{ Kind = $c } }
            else {
                if ($c.get_Count() -eq 0) { $Problems.Add("$Path.compare: a variant needs at least one of layout, block, mode, bypass") }
                $vl = [string](Get-Or $c 'layout' $o.layout)
                $vlPlugins = $null
                if ($c.Contains('layout')) { if (-not $Layouts.Contains($vl)) { $Problems.Add("$Path.compare.layout: layout '$vl' is not defined in layouts") } else { $vlPlugins = $Layouts[$vl].Plugins } } else { $vlPlugins = $LayoutPlugins }
                $o.compare = [pscustomobject]@{
                    Kind = 'variant'; Layout = $vl; Block = [int](Get-Or $c 'block' $o.block); Mode = [string](Get-Or $c 'mode' $o.mode)
                    Bypass = $c.Contains('bypass') ? (ConvertTo-Bypass $c['bypass'] "$Path.compare.bypass" $vlPlugins $Problems $Plugins) : $o.bypass
                }
            }
            $o.maxDiffDb = Get-Or $Raw 'maxDiffDb' $null; $o.lag = [int](Get-Or $Raw 'lag' 0); $o.peakMaxDb = Get-Or $Raw 'peakMaxDb' $null; $o.notSilent = [bool](Get-Or $Raw 'notSilent' $false)
            $o.mutate = $null
        }
        'device' { }
        'savereopen' {
            $o.mode = [string](Get-Or $Raw 'mode' $script:Defaults.mode)
            $o.bypass = ConvertTo-Bypass (Get-Or $Raw 'bypass' $null) "$Path.bypass" $LayoutPlugins $Problems $Plugins
        }
        'instances' {
            $o.plugins = @(Get-Or $Raw 'plugins' $Plugins | ForEach-Object { [string]$_ })
            foreach ($i in $o.plugins) { if ($i -cnotin $Plugins) { $Problems.Add("${Path}.plugins: plugin '$i' is not defined in plugins") } }
            foreach ($k in 'cycles', 'warmup', 'play', 'maxHandleGrowth', 'maxPrivateGrowthMB') { $o[$k] = Get-Or $Raw $k $Limits.instances[$k] }
            if ([int]$o.warmup -ge [int]$o.cycles) { $Problems.Add("${Path}: warmup ($($o.warmup)) must be smaller than cycles ($($o.cycles))") }
        }
    }
    [pscustomobject]$o
}

# Reads, validates and normalises one configuration file. Kinds: extension kinds already registered (kind -> @{
# Validate; Handler; ... }); pass them so scenarios of those kinds validate. ConfigDir of the result is the real
# directory of the file (extension paths are relative to it).
function Read-HarnessConfig {
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Kinds = @{})
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-Usage "config: file not found: $(Split-Path -Leaf $Path)" }
    $Text = [IO.File]::ReadAllText($Path)
    try { $Raw = ConvertFrom-HarnessJson $Text } catch { Stop-Usage "config: $($_.Exception.Message)" }
    $result = Test-HarnessConfigData -Raw $Raw -Kinds $Kinds
    if ($result.Problems.Count) { Stop-Usage ("config has $($result.Problems.Count) problem(s): " + ($result.Problems -join '; ')) }
    $result.Config | Add-Member -NotePropertyName ConfigDir -NotePropertyValue (Split-Path -Parent ([IO.Path]::GetFullPath($Path))) -PassThru
}

# Pure function (no files): structural and cross-reference checks of parsed data. Returns @{ Problems; Config }.
function Test-HarnessConfigData {
    param([AllowNull()]$Raw, [hashtable]$Kinds = @{})
    $Problems = [Collections.Generic.List[string]]::new()
    Test-SpecValue $script:Spec.Root $Raw 'config' $Problems $Kinds
    if ($Problems.Count) { return [pscustomobject]@{ Problems = $Problems.ToArray(); Config = $null } }
    $Plugins = [ordered]@{}
    foreach ($k in $Raw.plugins.get_Keys()) { $Plugins[$k] = [pscustomobject]@{ Id = $k; Bundle = [string]$Raw.plugins[$k].bundle; ExpectPdc = [int](Get-Or $Raw.plugins[$k] 'expectPdc' 0) } }
    $bundles = @($Plugins.get_Values() | ForEach-Object { $_.Bundle.ToLowerInvariant() })
    if (@($bundles | Sort-Object -Unique).Count -ne $bundles.Count) { $Problems.Add('config.plugins: two plugins use the same bundle') }
    $pluginIds = @($Plugins.get_Keys())
    $sig = Get-Or $Raw 'signal' $null
    $signal = [pscustomobject]@{
        Seconds = [double](Get-Or $sig 'seconds' $script:Defaults.signal.seconds); Seed = [uint32](Get-Or $sig 'seed' $script:Defaults.signal.seed); NoiseDb = [double](Get-Or $sig 'noiseDb' $script:Defaults.signal.noiseDb)
        SineHz = [double](Get-Or (Get-Or $sig 'sine' $null) 'hz' 0); SineDb = [double](Get-Or (Get-Or $sig 'sine' $null) 'db' $script:Defaults.sineDb)
    }
    $lim = Get-Or $Raw 'limits' $null
    $Limits = [ordered]@{}
    foreach ($k in $script:Defaults.limits.get_Keys()) { $Limits[$k] = Get-Or $lim $k $script:Defaults.limits[$k] }
    $inst = Get-Or $lim 'instances' $null
    $Limits.instances = [ordered]@{}
    foreach ($k in $script:Defaults.instances.get_Keys()) { $Limits.instances[$k] = Get-Or $inst $k $script:Defaults.instances[$k] }
    $Layouts = [ordered]@{}
    foreach ($k in $Raw.layouts.get_Keys()) { $Layouts[$k] = ConvertTo-Layout $k $Raw.layouts[$k] $pluginIds $Problems }
    $all = [Collections.Generic.List[object]]::new()
    $reserved = @(Get-HarnessBuiltinNegatives | ForEach-Object { $_.id })
    foreach ($section in 'scenarios', 'negative') {
        $Items = @(Get-Or $Raw $section @())
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $Path = "config.$section[$i]"
            $item = $Items[$i]
            if ($section -eq 'negative' -and $item.Contains('matrix')) { $Problems.Add("${Path}: matrix is not allowed in negative cases"); continue }
            if ($item.Contains('matrix')) {
                foreach ($axis in $item['matrix'].get_Keys()) { if ($item.Contains($axis)) { $Problems.Add("${Path}: '$axis' is given both directly and in matrix") } }
                if ($item['matrix'].get_Count() -eq 0) { $Problems.Add("${Path}.matrix: needs at least one of mode, sr, block") }
            }
            foreach ($expanded in (Expand-Matrix $item)) { $all.Add((ConvertTo-Scenario $expanded $Path ($section -eq 'negative') $Layouts $pluginIds $Limits $Problems $Kinds)) }
        }
    }
    $seen = @{}
    foreach ($s in $all) {
        if ($s.id.Length -gt 80) { $Problems.Add("scenario id '$($s.id)' is longer than 80 characters after matrix expansion") }
        if ($s.id -cin $reserved) { $Problems.Add("scenario id '$($s.id)' is reserved for a built-in negative case") }
        if ($seen.ContainsKey($s.id)) { $Problems.Add("scenario id '$($s.id)' is used twice") }
        $seen[$s.id] = $true
    }
    $ext = Get-Or $Raw 'extensions' $null
    $config = [pscustomobject]@{
        Schema = 1; Name = [string]$Raw.name; Plugins = $Plugins; Signal = $signal; Limits = $Limits; Layouts = $Layouts
        Scenarios = @($all | Where-Object { -not $_.negative }); Negative = @($all | Where-Object { $_.negative })
        Extensions = [pscustomobject]@{ Modules = @(Get-Or $ext 'modules' @() | ForEach-Object { [string]$_ }); Lua = @(Get-Or $ext 'lua' @() | ForEach-Object { [string]$_ }) }
    }
    [pscustomobject]@{ Problems = $Problems.ToArray(); Config = $config }
}

# Only the extensions section, read before full validation (extension kinds must be registered first). Returns the
# parsed data and the extension paths; structural problems of the section itself are usage errors.
function Read-HarnessConfigExtensions([Parameter(Mandatory)][string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-Usage "config: file not found: $(Split-Path -Leaf $Path)" }
    try { $Raw = ConvertFrom-HarnessJson ([IO.File]::ReadAllText($Path)) } catch { Stop-Usage "config: $($_.Exception.Message)" }
    if ($Raw -isnot [System.Collections.IDictionary]) { Stop-Usage 'config: must be an object' }
    $ext = Get-Or $Raw 'extensions' $null
    $Problems = [Collections.Generic.List[string]]::new()
    if ($null -ne $ext) { Test-SpecValue $script:Spec.Root.props['extensions'] $ext 'config.extensions' $Problems }
    if ($Problems.Count) { Stop-Usage ("config has $($Problems.Count) problem(s): " + ($Problems -join '; ')) }
    [pscustomobject]@{ Modules = @(Get-Or $ext 'modules' @()); Lua = @(Get-Or $ext 'lua' @()); ConfigDir = (Split-Path -Parent ([IO.Path]::GetFullPath($Path))) }
}

Export-ModuleMember -Function Read-HarnessConfig, Read-HarnessConfigExtensions, Test-HarnessConfigData, Get-HarnessConfigSpec, ConvertTo-HarnessJsonSchema, Get-HarnessBuiltinNegatives,
    Get-HarnessConfigDefaults, Get-HarnessDryLayout, Stop-Usage
