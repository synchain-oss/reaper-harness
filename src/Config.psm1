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
function SArr($Items, [int]$Min = 0, [switch]$Unique, [string]$Doc = '', [int]$Max = 0) { @{ t = 'array'; items = $Items; min = $Min; max = $Max; unique = [bool]$Unique; doc = $Doc } }
function SStr([string]$Pattern = '', [string[]]$Enum = @(), [string]$Doc = '') { @{ t = 'string'; pattern = $Pattern; enum = $Enum; doc = $Doc } }
function SInt([long]$Min, [long]$Max, [string]$Doc = '') { @{ t = 'integer'; min = $Min; max = $Max; doc = $Doc } }
function SNum([double]$Min, [double]$Max, [switch]$ExclusiveMin, [string]$Doc = '') { @{ t = 'number'; min = $Min; max = $Max; exmin = [bool]$ExclusiveMin; doc = $Doc } }
function SBool([string]$Doc = '') { @{ t = 'boolean'; doc = $Doc } }
function SAny([object[]]$Options, [string]$Label, [string]$Doc = '') { @{ t = 'any'; options = $Options; label = $Label; doc = $Doc } }
function SRef([string]$Name) { @{ t = 'ref'; name = $Name } }

$script:IdPattern = '^[a-z][a-z0-9-]{0,39}$'
$script:ScenarioIdPattern = '^[a-z0-9][a-z0-9-]{0,59}$'
$script:StatePattern = '^[a-z0-9][a-z0-9-]{0,39}$'
$script:TrackNamePattern = '^[^"\u0000-\u001f]{1,64}$'
$script:ChannelPattern = '^(L|R|[1-9][0-9]?)$'
# Stem files are named after their track: plain ASCII without characters Windows refuses, not ending in a space or a dot
$script:StemNamePattern = '^[A-Za-z0-9()+_.-]([A-Za-z0-9 ()+_.-]*[A-Za-z0-9()+_-])?$'
$script:Modes = 'offline', '1x', 'online'
$script:Expectable = 'PASS', 'FAIL', 'SKIPPED', 'INCOMPLETE', 'REFUSED'
$script:BuiltinKinds = 'render', 'device', 'savereopen', 'instances'
$script:InternalKinds = 'hang', 'guard' # built-in negative cases only; never accepted from a configuration file
$script:SendModes = @{ post = 0; prefx = 1; pre = 3 } # REAPER's send modes: post-fader, pre-FX, post-FX (pre-fader)
$script:JsfxNames = 'harness-pdc-delay' # the JSFX shipped in jsfx/

function New-HarnessSpec {
    $defs = [ordered]@{}
    $rate = SInt 8000 384000 'sample rate in Hz'
    $block = SInt 16 8192 'audio device block size in samples'
    $mode = SStr -Enum $script:Modes -Doc 'offline: full-speed offline render; 1x: real-time speed but plugins are told it is offline; online: real-time render, plugins are told it is real time'
    $range = SArr (SNum -400 24) -Min 2 -Max 2 -Doc '[min, max] in dB'
    $defs.paramValue = SAny @((SNum 0 1), (SObj ([ordered]@{ normalized = (SNum 0 1); display = (SStr '^[^\u0000-\u001f]{0,128}$') }) @('normalized'))) 'a normalized value 0..1, or { normalized, display }'
    $params = SMap '^[^\u0000-\u001f]{1,128}$' (SRef paramValue) -Doc 'parameter name -> value, set by name and read back by the Lua driver'
    $relPath = SStr '^[^\u0000-\u001f]{1,260}$' -Doc 'a path relative to the configuration file, inside its directory'
    $defs.stateSource = SAny @(
        (SObj ([ordered]@{ template = $relPath; track = (SStr $script:TrackNamePattern -Doc 'name of the track in the template project'); fx = (SInt 1 1000 -Doc 'which FX of that track, counted from 1') }) @('template', 'track', 'fx'))
        (SObj ([ordered]@{ stateFile = $relPath }) @('stateFile'))
    ) '{ template, track, fx } or { stateFile }'
    $defs.plugin = SObj ([ordered]@{
            bundle    = (SStr '^[^\\/:*?"<>|\u0000-\u001f]{1,120}\.vst3$' -Doc 'VST3 bundle directory name, looked up in -PluginDir')
            jsfx      = (SStr -Enum $script:JsfxNames -Doc 'a JSFX shipped with the tool, instead of a bundle')
            expectPdc = (SInt 0 1000000)
            params    = $params
            states    = (SMap $script:StatePattern (SRef stateSource) -Min 1 -Doc 'named plugin states taken from a project or a file')
        })
    $defs.fx = SObj ([ordered]@{
            plugin = (SStr $script:IdPattern -Doc 'id from plugins')
            state  = (SStr $script:StatePattern -Doc 'name of a state of that plugin')
            bypass = (SBool)
            params = $params
        }) @('plugin')
    $defs.send = SObj ([ordered]@{
            to     = (SStr $script:TrackNamePattern -Doc 'name of the receiving track')
            mode   = (SStr -Enum 'post', 'pre', 'prefx' -Doc 'post: after the fader (default); pre: after the FX, before the fader; prefx: before the FX')
            volume = (SNum 0 4 -Doc 'linear send volume, default 1')
        }) @('to')
    $sine = SObj ([ordered]@{ hz = (SNum 0 20000 -ExclusiveMin); db = (SNum -200 0) }) @('hz')
    $defs.track = SObj ([ordered]@{
            name       = (SStr $script:TrackNamePattern)
            source     = (SBool -Doc 'the track carries the test signal')
            signal     = (SObj ([ordered]@{ seed = (SInt 0 4294967295); noiseDb = (SNum -200 0); sine = $sine }) -Doc 'this track''s signal: each field given replaces the one of the top-level signal')
            folder     = (SBool -Doc 'a REAPER folder (bus) track; its children are the following tracks that name it as parent')
            parent     = (SStr $script:TrackNamePattern -Doc 'name of the folder track this track belongs to')
            volume     = (SNum 0 4 -Doc 'linear track volume')
            pan        = (SNum -1 1 -Doc 'pan, -1 left … 1 right, default 0')
            mute       = (SBool)
            masterSend = (SBool -Doc 'master / parent send, default true; false keeps the track out of the master (or out of its folder)')
            sends      = (SArr (SRef send))
            fx         = (SArr (SRef fx))
        }) @('name', 'source')
    $defs.layout = SObj ([ordered]@{ tracks = (SArr (SRef track) -Min 1) }) @('tracks')
    $bypass = SAny @((SBool), (SArr (SStr $script:IdPattern) -Min 1 -Unique)) 'true (every FX) or a list of plugin ids'
    $defs.compareVariant = SObj ([ordered]@{ layout = (SStr $script:IdPattern); block = $block; mode = $mode; bypass = $bypass })
    $defs.matrix = SObj ([ordered]@{ mode = (SArr $mode -Min 1 -Unique); sr = (SArr $rate -Min 1 -Unique); block = (SArr $block -Min 1 -Unique) })
    # The device step renders nothing, so a render mode would only multiply identical scenarios
    $defs.deviceMatrix = SObj ([ordered]@{ sr = (SArr $rate -Min 1 -Unique); block = (SArr $block -Min 1 -Unique) })
    $defs.host = SObj ([ordered]@{ anticipativeFx = (SBool -Doc 'REAPER''s anticipative FX processing (default true, as REAPER ships)') })
    # Criteria of one render file, also used by stems
    $criteria = [ordered]@{
        maxDiffDb     = (SNum -400 24 -Doc 'allowed residual in dBFS (a mix of several tracks can differ by more than full scale); absent means bit-identical')
        lag           = (SInt -4096 4096 -Doc 'expected lag in samples (the test render later than the reference is positive), default 0')
        peakMaxDb     = (SNum -400 24 -Doc 'the test render must not peak above this')
        notSilent     = (SBool -Doc 'the test render must peak above -120 dBFS')
        rmsDb         = (SMap $script:ChannelPattern $range -Min 1 -Doc 'channel (L, R or 1, 2, …) -> [min, max] RMS in dBFS; digital silence counts as -400')
        energyRatioDb = (SMap '^(L|R|[1-9][0-9]?)/(L|R|[1-9][0-9]?)$' $range -Min 1 -Doc '"A/B" -> [min, max] of RMS(A) - RMS(B) in dB')
        rmsChangeDb   = (SMap $script:ChannelPattern $range -Min 1 -Doc 'channel -> [min, max] of RMS(test) - RMS(reference) in dB')
    }
    $stemProps = [ordered]@{ track = (SStr $script:TrackNamePattern); compare = (SStr -Enum 'reference', 'none' -Doc 'reference: with the same stem of the reference render (default unless the scenario compares with none); none: on its own') }
    foreach ($e in $criteria.GetEnumerator()) { $stemProps[$e.Key] = $e.Value }
    $defs.stem = SAny @((SStr $script:TrackNamePattern), (SObj $stemProps @('track'))) 'a track name or { track, criteria }'
    $common = { [ordered]@{ id = (SStr $script:ScenarioIdPattern); kind = (SStr -Enum $args[0]) } }
    $Kinds = [ordered]@{}
    # The render criteria are fields of the scenario itself (not an "expect" object): in negative cases "expect" is
    # the expected outcome
    $renderProps = [ordered]@{
        layout = (SStr $script:IdPattern); mode = $mode; sr = $rate; block = $block; mono = (SBool); bypass = $bypass
        compare = (SAny @((SStr -Enum 'dry', 'repeat', 'none'), (SRef compareVariant)) '"dry" (default), "repeat", "none" or a variant object')
    }
    foreach ($e in $criteria.GetEnumerator()) { $renderProps[$e.Key] = $e.Value }
    $renderProps.stems = SArr (SRef stem) -Min 1 -Doc 'tracks rendered as stems of their own, next to the master'
    $renderProps.host = SRef host
    $renderProps.matrix = SRef matrix
    $p = & $common 'render'; foreach ($e in $renderProps.GetEnumerator()) { $p[$e.Key] = $e.Value }
    $Kinds.render = SObj $p @('id', 'kind', 'layout')
    $p = & $common 'device'; foreach ($e in ([ordered]@{ layout = (SStr $script:IdPattern); sr = $rate; block = $block; host = (SRef host); matrix = (SRef deviceMatrix) }).GetEnumerator()) { $p[$e.Key] = $e.Value }
    $Kinds.device = SObj $p @('id', 'kind', 'layout')
    $p = & $common 'savereopen'
    foreach ($e in ([ordered]@{ layout = (SStr $script:IdPattern); mode = $mode; sr = $rate; block = $block; bypass = $bypass; cycles = (SInt 1 100 -Doc 'save and reopen this many times, default 1'); host = (SRef host); matrix = (SRef matrix) }).GetEnumerator()) { $p[$e.Key] = $e.Value }
    $Kinds.savereopen = SObj $p @('id', 'kind', 'layout')
    $p = & $common 'instances'
    foreach ($e in ([ordered]@{ plugins = (SArr (SStr $script:IdPattern) -Min 1 -Unique); cycles = (SInt 1 10000); warmup = (SInt 0 10000); play = (SBool); maxHandleGrowth = (SInt 0 1000000); maxPrivateGrowthMB = (SNum 0 1000000); sr = $rate; block = $block; host = (SRef host) }).GetEnumerator()) { $p[$e.Key] = $e.Value }
    $Kinds.instances = SObj $p @('id', 'kind')
    $root = SObj ([ordered]@{
            '$schema'  = (SStr)
            schema     = (SInt 1 1)
            name       = (SStr '^[a-z0-9-]{1,40}$' -Doc 'goes into result file names')
            notes      = (SStr)
            plugins    = (SMap $script:IdPattern (SRef plugin) -Min 1)
            signal     = (SObj ([ordered]@{ seconds = (SNum 0.5 600); seed = (SInt 0 4294967295); noiseDb = (SNum -200 0); sine = $sine }))
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
            if ($Spec.max -and $Value.Count -gt $Spec.max) { $Problems.Add("${Path}: has more than $($Spec.max) item$($Spec.max -eq 1 ? '' : 's')") }
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
            $tries = [Collections.Generic.List[object]]::new()
            foreach ($o in $Spec.options) {
                $sub = [Collections.Generic.List[string]]::new()
                Test-SpecValue $o $Value $Path $sub $Kinds
                if ($sub.Count -eq 0) { return }
                $tries.Add([pscustomobject]@{ Spec = $o; Problems = $sub })
            }
            # One option of the same shape (an object that uses its keys, a string, ...): its own problems say more
            $near = @($tries | Where-Object { Test-SpecShape $_.Spec $Value })
            if ($near.Count -eq 1) { foreach ($x in $near[0].Problems) { $Problems.Add($x) }; return }
            $Problems.Add("${Path}: must be $($Spec.label)")
        }
    }
}

# Whether a value has the shape of a spec (used to pick the option whose problems are reported). An object only
# counts when it uses a key of the spec, so { stateFile } is not reported against { template, track, fx }.
function Test-SpecShape($Spec, $Value) {
    $s = ($Spec.t -eq 'ref') ? $script:Spec.Defs[$Spec.name] : $Spec
    switch ($s.t) {
        'object' { return $Value -is [System.Collections.IDictionary] -and @($Value.get_Keys() | Where-Object { $_ -cin @($s.props.get_Keys()) }).Count -gt 0 }
        'map' { return $Value -is [System.Collections.IDictionary] }
        'array' { return $Value -is [object[]] }
        'string' { return $Value -is [string] }
        'boolean' { return $Value -is [bool] }
        default { return $Value -isnot [bool] -and (Test-IsNumber $Value) }
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
            if ($Spec.max) { $n.maxItems = $Spec.max }
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
    $render = { param($h) foreach ($e in (New-RenderDefaults).GetEnumerator()) { if (-not $h.ContainsKey($e.Key)) { $h[$e.Key] = $e.Value } }; [pscustomobject]$h }
    @(
        (& $render @{ id = 'neg-offset-1-sample'; kind = 'render'; negative = $true; builtin = $true; layout = $dry; mode = 'offline'; sr = 48000; block = 512; mono = $false; bypass = @(); compare = [pscustomobject]@{ Kind = 'dry' }
                mutate = [pscustomobject]@{ sourceOffsetSamples = 1; trackVolume = 1.0 }; expect = 'FAIL'; expectDetail = '^identical=no lag=1 ' })
        (& $render @{ id = 'neg-track-minus-6db'; kind = 'render'; negative = $true; builtin = $true; layout = $dry; mode = 'offline'; sr = 48000; block = 512; mono = $false; bypass = @(); compare = [pscustomobject]@{ Kind = 'dry' }
                mutate = [pscustomobject]@{ sourceOffsetSamples = 0; trackVolume = 0.5 }; expect = 'FAIL'; expectDetail = '^identical=no lag=0 maxdiff=-6\.0' })
        (& $make @{ id = 'neg-timeout'; kind = 'hang'; negative = $true; builtin = $true; timeoutSec = 8.0; killAfterSec = 0.0; expect = 'INCOMPLETE'; expectDetail = '^timed out after .*; the process has ended and the GUI locks are free$' })
        (& $make @{ id = 'neg-killed'; kind = 'hang'; negative = $true; builtin = $true; timeoutSec = 0.0; killAfterSec = 4.0; expect = 'INCOMPLETE'; expectDetail = '^killed at the deadline .*; the process has ended and the GUI locks are free$' })
        (& $make @{ id = 'neg-skip-marker'; kind = 'guard'; negative = $true; builtin = $true; guard = 'skip-marker'; expect = 'SKIPPED'; expectDetail = '^launches=0; skip marker present' })
        (& $make @{ id = 'neg-sentinel-missing'; kind = 'guard'; negative = $true; builtin = $true; guard = 'sentinel-missing'; expect = 'REFUSED'; expectDetail = '^REFUSED: .*sentinel' })
        (& $make @{ id = 'neg-default-dir'; kind = 'guard'; negative = $true; builtin = $true; guard = 'default-dir'; expect = 'REFUSED'; expectDetail = '^REFUSED: .*never touched' })
    )
}

# The criteria fields of a render scenario (and of a stem) when the configuration gives none.
function New-CriteriaDefaults { [ordered]@{ maxDiffDb = $null; lag = 0; peakMaxDb = $null; notSilent = $false; rmsDb = $null; energyRatioDb = $null; rmsChangeDb = $null } }
function New-RenderDefaults {
    $d = New-CriteriaDefaults
    $d.stems = @(); $d.host = (New-HostDefaults); $d.mutate = $null
    $d
}
function New-HostDefaults { [pscustomobject]@{ AnticipativeFx = $true } }

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

# Parameter values: name -> @{ Normalized; Display }, names in ordinal order.
function ConvertTo-ParamTable($Raw) {
    $params = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    if ($Raw) {
        foreach ($pn in @($Raw.get_Keys() | Sort-Object -CaseSensitive)) {
            $pv = $Raw[$pn]
            $params[$pn] = ($pv -is [System.Collections.IDictionary]) ? [pscustomobject]@{ Normalized = [double]$pv['normalized']; Display = (Get-Or $pv 'display' $null) } : [pscustomobject]@{ Normalized = [double]$pv; Display = $null }
        }
    }
    $params
}

# The plugins: id -> @{ Id; Kind (vst3 | jsfx); Bundle; Jsfx; ExpectPdc; Params; States (name -> source) }.
function ConvertTo-Plugins($Raw, $Problems) {
    $Plugins = [ordered]@{}
    foreach ($k in $Raw.get_Keys()) {
        $r = $Raw[$k]
        $hasBundle = $r.Contains('bundle'); $hasJs = $r.Contains('jsfx')
        if ($hasBundle -eq $hasJs) { $Problems.Add("config.plugins.${k}: needs exactly one of bundle (a VST3) and jsfx") }
        $States = [ordered]@{}
        $rawStates = Get-Or $r 'states' $null
        if ($rawStates) {
            if ($hasJs) { $Problems.Add("config.plugins.${k}.states: states are only for VST3 plugins") }
            foreach ($sn in $rawStates.get_Keys()) {
                $src = $rawStates[$sn]
                $States[$sn] = [pscustomobject]@{
                    Name = $sn; Template = [string](Get-Or $src 'template' ''); Track = [string](Get-Or $src 'track' ''); Fx = [int](Get-Or $src 'fx' 0); StateFile = [string](Get-Or $src 'stateFile' '')
                }
            }
        }
        $Plugins[$k] = [pscustomobject]@{
            Id = $k; Kind = ($hasJs ? 'jsfx' : 'vst3'); Bundle = [string](Get-Or $r 'bundle' ''); Jsfx = [string](Get-Or $r 'jsfx' ''); ExpectPdc = [int](Get-Or $r 'expectPdc' 0)
            Params = (ConvertTo-ParamTable (Get-Or $r 'params' $null)); States = $States
        }
    }
    $Plugins
}

# A track's own signal: $null when it has none (the top-level signal is used), otherwise the top-level signal with
# the fields the track gives replaced.
function ConvertTo-TrackSignal($Raw, $Global) {
    if ($null -eq $Raw) { return $null }
    $sine = Get-Or $Raw 'sine' $null
    [pscustomobject]@{
        Seed = [uint32](Get-Or $Raw 'seed' $Global.Seed); NoiseDb = [double](Get-Or $Raw 'noiseDb' $Global.NoiseDb)
        SineHz = ($null -ne $sine) ? [double]$sine['hz'] : $Global.SineHz; SineDb = ($null -ne $sine) ? [double](Get-Or $sine 'db' $script:Defaults.sineDb) : $Global.SineDb
    }
}

function ConvertTo-Layout([string]$Id, $Raw, $Plugins, $Signal, $Problems) {
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
            $def = $Plugins.Contains($plugin) ? $Plugins[$plugin] : $null
            if (-not $def) { $Problems.Add("${Path}.fx[$j]: plugin '$plugin' is not defined in plugins") }
            $state = [string](Get-Or $fx 'state' '')
            if ($state -and $def -and -not $def.States.Contains($state)) { $Problems.Add("${Path}.fx[$j]: plugin '$plugin' has no state '$state'") }
            # The plugin's own parameters first, the FX's on top
            $params = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            $own = ConvertTo-ParamTable (Get-Or $fx 'params' $null)
            $pluginParams = $def ? $def.Params : @{}
            foreach ($pn in @(@($pluginParams.get_Keys()) + @($own.get_Keys()) | Sort-Object -Unique -CaseSensitive)) { $params[$pn] = $own.Contains($pn) ? $own[$pn] : $pluginParams[$pn] }
            $variantKey = $plugin + ($state ? "@$state" : '') + '|' + (@($params.get_Keys() | ForEach-Object { '{0}={1}' -f $_, $params[$_].Normalized.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }) -join ';')
            $fxList.Add([pscustomobject]@{ Plugin = $plugin; State = $state; Bypass = [bool](Get-Or $fx 'bypass' $false); Params = $params; Variant = $variantKey })
            $j++
        }
        $sends = @(Get-Or $t 'sends' @() | ForEach-Object { [pscustomobject]@{ To = [string]$_['to']; Mode = [string](Get-Or $_ 'mode' 'post'); Volume = [double](Get-Or $_ 'volume' 1.0) } })
        $track = [pscustomobject]@{
            Name = $Name; Source = [bool]$t.source; Signal = (ConvertTo-TrackSignal (Get-Or $t 'signal' $null) $Signal); Folder = [bool](Get-Or $t 'folder' $false); Parent = $parent
            Volume = [double](Get-Or $t 'volume' 1.0); Pan = [double](Get-Or $t 'pan' 0.0); Mute = [bool](Get-Or $t 'mute' $false); MasterSend = [bool](Get-Or $t 'masterSend' $true)
            Sends = $sends; Fx = $fxList.ToArray(); Depth = $open.Count
        }
        if ($track.Signal -and -not $track.Source) { $Problems.Add("${Path}: signal is given but the track carries no signal (source is false)") }
        $names[$Name] = $track
        $tracks.Add($track)
        if ($track.Folder) { $open.Add($Name) }
        $i++
    }
    foreach ($t in $tracks) {
        if ($t.Folder -and -not @($tracks | Where-Object { $_.Parent -ceq $t.Name }).Count) { $Problems.Add("layouts.${Id}: folder track '$($t.Name)' has no tracks in it") }
        foreach ($s in $t.Sends) {
            if (-not $names.ContainsKey($s.To)) { $Problems.Add("layouts.${Id}: track '$($t.Name)' sends to '$($s.To)', which is not a track of this layout") }
            elseif ($s.To -ceq $t.Name) { $Problems.Add("layouts.${Id}: track '$($t.Name)' sends to itself") }
        }
    }
    $loop = Find-RoutingCycle $tracks.ToArray()
    if ($loop) { $Problems.Add("layouts.${Id}: the routing has a loop: $loop") }
    if (-not @($tracks | Where-Object { $_.Source }).Count) { $Problems.Add("layouts.${Id}: no track has source: true, so nothing would be rendered") }
    [pscustomobject]@{ Id = $Id; Tracks = $tracks.ToArray(); Plugins = @($tracks | ForEach-Object { $_.Fx } | ForEach-Object { $_.Plugin } | Sort-Object -Unique -CaseSensitive) }
}

# Signal flow between tracks: a send goes from its track to the receiving one; a track with its master / parent send
# on feeds its folder. Returns the first loop as "A -> B -> A", or '' when there is none.
function Find-RoutingCycle([object[]]$Nodes) {
    $edges = @{}
    foreach ($t in $Nodes) {
        $out = [Collections.Generic.List[string]]::new()
        foreach ($s in $t.Sends) { if ($s.To -cne $t.Name) { $out.Add($s.To) } }
        if ($t.Parent -and $t.MasterSend) { $out.Add($t.Parent) }
        $edges[$t.Name] = $out
    }
    $state = @{} # name -> 1 on the current path, 2 done
    $trail = [Collections.Generic.List[string]]::new()
    $visit = $null
    $visit = {
        param([string]$n)
        $state[$n] = 1; $trail.Add($n)
        foreach ($m in @($edges[$n])) {
            if (-not $edges.ContainsKey($m)) { continue }
            if ($state[$m] -eq 1) { return ((@($trail[$trail.IndexOf($m)..($trail.Count - 1)]) + $m) -join ' -> ') }
            if (-not $state[$m]) { $r = & $visit $m; if ($r) { return $r } }
        }
        $state[$n] = 2; $trail.RemoveAt($trail.Count - 1)
        ''
    }
    foreach ($t in $Nodes) { if (-not $state[$t.Name]) { $r = & $visit $t.Name; if ($r) { return $r } } }
    ''
}

# The internal layout of the comparer negatives: one source track, no FX.
function Get-HarnessDryLayout {
    [pscustomobject]@{
        Id = '@dry'; Plugins = @()
        Tracks = @([pscustomobject]@{ Name = 'Dry'; Source = $true; Signal = $null; Folder = $false; Parent = ''; Volume = 1.0; Pan = 0.0; Mute = $false; MasterSend = $true; Sends = @(); Fx = @(); Depth = 0 })
    }
}

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

# Channel key (L, R, 1, 2, ...) -> 1-based channel number.
function ConvertTo-ChannelNumber([string]$Key) { switch -CaseSensitive ($Key) { 'L' { 1 } 'R' { 2 } default { [int]$Key } } }

# A channel criterion (rmsDb, rmsChangeDb: channel -> range; energyRatioDb: "A/B" -> range) as an ordered table of
# key -> @{ Key; Channels (numbers); Min; Max }, checked against the channel count of the render.
function ConvertTo-ChannelCriterion($Raw, [string]$Path, [int]$Channels, [switch]$Ratio, $Problems) {
    if ($null -eq $Raw) { return $null }
    $out = [ordered]@{}
    foreach ($k in $Raw.get_Keys()) {
        $r = @($Raw[$k])
        $nums = @($k -split '/' | ForEach-Object { ConvertTo-ChannelNumber $_ })
        foreach ($n in $nums) { if ($n -gt $Channels) { $Problems.Add("${Path}.${k}: the render has $Channels channel$($Channels -eq 1 ? '' : 's')") } }
        if ($Ratio -and $nums[0] -eq $nums[1]) { $Problems.Add("${Path}.${k}: a ratio needs two different channels") }
        if ([double]$r[0] -gt [double]$r[1]) { $Problems.Add("${Path}.${k}: min $($r[0]) is above max $($r[1])") }
        $out[$k] = [pscustomobject]@{ Key = $k; Channels = $nums; Min = [double]$r[0]; Max = [double]$r[1] }
    }
    $out
}

# The criteria of one render (the scenario's own, or a stem's on top of the scenario's).
function ConvertTo-Criteria($Raw, $Base, [string]$Path, [int]$Channels, [bool]$HasReference, $Problems) {
    $c = [ordered]@{}
    foreach ($k in 'maxDiffDb', 'lag', 'peakMaxDb', 'notSilent') { $c[$k] = $Raw.Contains($k) ? $Raw[$k] : $Base[$k] }
    $c.lag = [int]$c.lag; $c.notSilent = [bool]$c.notSilent
    $c.rmsDb = $Raw.Contains('rmsDb') ? (ConvertTo-ChannelCriterion $Raw['rmsDb'] "$Path.rmsDb" $Channels $Problems) : $Base.rmsDb
    $c.energyRatioDb = $Raw.Contains('energyRatioDb') ? (ConvertTo-ChannelCriterion $Raw['energyRatioDb'] "$Path.energyRatioDb" $Channels -Ratio $Problems) : $Base.energyRatioDb
    $c.rmsChangeDb = $Raw.Contains('rmsChangeDb') ? (ConvertTo-ChannelCriterion $Raw['rmsChangeDb'] "$Path.rmsChangeDb" $Channels $Problems) : $Base.rmsChangeDb
    if (-not $HasReference) {
        foreach ($k in 'maxDiffDb', 'lag', 'rmsChangeDb') { if ($Raw.Contains($k)) { $Problems.Add("${Path}: $k needs a reference, but this render is compared with none") } }
    }
    $c
}

function ConvertTo-Host($Raw) {
    $h = New-HostDefaults
    if ($null -ne $Raw -and $Raw.Contains('anticipativeFx')) { $h.AnticipativeFx = [bool]$Raw['anticipativeFx'] }
    $h
}

function ConvertTo-Scenario($Raw, [string]$Path, [bool]$Negative, $Layouts, $PluginTable, $Limits, $Problems, [hashtable]$Kinds) {
    $Plugins = @($PluginTable.get_Keys())
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
    $layout = $null
    if ($Raw.Contains('layout')) {
        $o.layout = [string]$Raw['layout']
        if (-not $Layouts.Contains($o.layout)) { $Problems.Add("${Path}: layout '$($o.layout)' is not defined in layouts") } else { $layout = $Layouts[$o.layout]; $LayoutPlugins = $layout.Plugins }
    }
    $o.sr = [int](Get-Or $Raw 'sr' $script:Defaults.sr)
    $o.block = [int](Get-Or $Raw 'block' $script:Defaults.block)
    $o.host = ConvertTo-Host (Get-Or $Raw 'host' $null)
    switch ($Kind) {
        'render' {
            $o.mode = [string](Get-Or $Raw 'mode' $script:Defaults.mode); $o.mono = [bool](Get-Or $Raw 'mono' $false)
            $o.bypass = ConvertTo-Bypass (Get-Or $Raw 'bypass' $null) "$Path.bypass" $LayoutPlugins $Problems $Plugins
            $c = Get-Or $Raw 'compare' 'dry'
            $variantLayout = $null
            if ($c -is [string]) { $o.compare = [pscustomobject]@{ Kind = $c } }
            else {
                if ($c.get_Count() -eq 0) { $Problems.Add("$Path.compare: a variant needs at least one of layout, block, mode, bypass") }
                $vl = [string](Get-Or $c 'layout' $o.layout)
                $vlPlugins = $null
                if ($c.Contains('layout')) { if (-not $Layouts.Contains($vl)) { $Problems.Add("$Path.compare.layout: layout '$vl' is not defined in layouts") } else { $variantLayout = $Layouts[$vl]; $vlPlugins = $variantLayout.Plugins } } else { $vlPlugins = $LayoutPlugins; $variantLayout = $layout }
                $o.compare = [pscustomobject]@{
                    Kind = 'variant'; Layout = $vl; Block = [int](Get-Or $c 'block' $o.block); Mode = [string](Get-Or $c 'mode' $o.mode)
                    Bypass = $c.Contains('bypass') ? (ConvertTo-Bypass $c['bypass'] "$Path.compare.bypass" $vlPlugins $Problems $Plugins) : $o.bypass
                }
            }
            $Channels = $o.mono ? 1 : 2
            $hasRef = $o.compare.Kind -ne 'none'
            $crit = ConvertTo-Criteria $Raw (New-CriteriaDefaults) $Path $Channels $hasRef $Problems
            foreach ($k in $crit.get_Keys()) { $o[$k] = $crit[$k] }
            # A stem takes the scenario's maxDiffDb, lag, peakMaxDb and notSilent unless it gives its own; levels and
            # balances describe one signal, so the channel criteria are a stem's own only
            $stemBase = [ordered]@{}
            foreach ($k in $crit.get_Keys()) { $stemBase[$k] = ($k -in 'rmsDb', 'energyRatioDb', 'rmsChangeDb') ? $null : $crit[$k] }
            $stems = [Collections.Generic.List[object]]::new()
            $seenStems = @{}
            $si = 0
            foreach ($st in @(Get-Or $Raw 'stems' @())) {
                $sp = "$Path.stems[$si]"
                $sraw = ($st -is [string]) ? [ordered]@{ track = $st } : $st
                $tn = [string]$sraw['track']
                if ($layout -and -not @($layout.Tracks | Where-Object { $_.Name -ceq $tn }).Count) { $Problems.Add("${sp}: '$tn' is not a track of layout '$($o.layout)'") }
                if ($tn -cnotmatch $script:StemNamePattern -or $tn.Contains("`n")) { $Problems.Add("${sp}: '$tn' cannot name a stem file: use letters, digits, space and ( ) + _ . - only, not ending in a space or a dot") }
                if ($tn -ieq 'Master') { $Problems.Add("${sp}: a track named Master cannot be a stem (REAPER names the master file so)") }
                if ($seenStems.ContainsKey($tn.ToLowerInvariant())) { $Problems.Add("${sp}: '$tn' is listed twice (file names ignore case)") }
                $seenStems[$tn.ToLowerInvariant()] = $true
                $sc = [string](Get-Or $sraw 'compare' ($hasRef ? 'reference' : 'none'))
                if ($sc -eq 'reference' -and -not $hasRef) { $Problems.Add("${sp}: compare reference needs a reference, but the scenario compares with none") }
                if ($sc -eq 'reference' -and $o.compare.Kind -eq 'variant' -and $variantLayout -and -not @($variantLayout.Tracks | Where-Object { $_.Name -ceq $tn }).Count) {
                    $Problems.Add("${sp}: the layout compared with ('$($o.compare.Layout)') has no track '$tn'")
                }
                $sCrit = ConvertTo-Criteria $sraw $stemBase $sp $Channels ($sc -eq 'reference') $Problems
                $stems.Add([pscustomobject]@{ Track = $tn; Compare = $sc; Criteria = [pscustomobject]$sCrit })
                $si++
            }
            $o.stems = $stems.ToArray()
            $o.mutate = $null
        }
        'device' { }
        'savereopen' {
            $o.mode = [string](Get-Or $Raw 'mode' $script:Defaults.mode)
            $o.bypass = ConvertTo-Bypass (Get-Or $Raw 'bypass' $null) "$Path.bypass" $LayoutPlugins $Problems $Plugins
            $o.cycles = [int](Get-Or $Raw 'cycles' 1)
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
# directory of the file (extension and state paths are relative to it).
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
    $Plugins = ConvertTo-Plugins $Raw.plugins $Problems
    $bundles = @($Plugins.get_Values() | Where-Object { $_.Bundle } | ForEach-Object { $_.Bundle.ToLowerInvariant() })
    if (@($bundles | Sort-Object -Unique).Count -ne $bundles.Count) { $Problems.Add('config.plugins: two plugins use the same bundle') }
    $sig = Get-Or $Raw 'signal' $null
    $Signal = [pscustomobject]@{
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
    foreach ($k in $Raw.layouts.get_Keys()) { $Layouts[$k] = ConvertTo-Layout $k $Raw.layouts[$k] $Plugins $Signal $Problems }
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
                if ($item['matrix'].get_Count() -eq 0) { $Problems.Add("${Path}.matrix: needs at least one of mode, sr, block (device: sr, block)") }
            }
            foreach ($expanded in (Expand-Matrix $item)) { $all.Add((ConvertTo-Scenario $expanded $Path ($section -eq 'negative') $Layouts $Plugins $Limits $Problems $Kinds)) }
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
        Schema = 1; Name = [string]$Raw.name; Plugins = $Plugins; Signal = $Signal; Limits = $Limits; Layouts = $Layouts
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
    Get-HarnessConfigDefaults, Get-HarnessDryLayout, Stop-Usage, Find-RoutingCycle, ConvertTo-ChannelNumber
