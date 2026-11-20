# SPDX-License-Identifier: MIT
#
# The suite: preflight, plugin install, rounds, verdicts, result file.
#   Get-HarnessPreflight        reasons to skip the whole suite (nothing is started when there is one)
#   Test-HarnessListRequest     what the -List options of run.ps1 ask for (a parameter listing instead of the scenarios)
#   Select-HarnessScenarios     what -Only and -NoNegative pick (nothing picked is a usage error)
#   Get-HarnessWorstStatus      worst of a set of outcomes; an empty set is INCOMPLETE, never PASS
#   Get-HarnessRunVerdict       a round: the worst row, but FAIL whenever the default resource directory changed or a
#                               process of this round was left behind, and at least INCOMPLETE when that directory could
#                               not be listed or a process could not be ended, however green the rows are
#   Get-HarnessNegativeVerdict  a negative case passes only with the expected outcome AND the expected reason
#   Invoke-HarnessGuardNegative the guard negative cases: the real entry point run again in-process
#   Invoke-HarnessSuite         everything above for one configuration (with -List: one round of one learn launch that
#                               also lists the parameters of the picked plugins, and no scenarios). Past the preflight an unexpected error is no
#                               conclusion: the verdict is at least INCOMPLETE, the result says why, and a round that broke
#                               still gets the checks of the end of a round. Outside the rows of a round refused and usage
#                               errors stay exceptions (64). Inside them REAPER may have been started already, so they are a
#                               round-error row like any other (INCOMPLETE): do not rethrow there, the checks would be skipped.
#   Write-HarnessResult         the result json (its name ends -list-params for a listing)
#   Complete-HarnessRun         writes the result json, prints the summary line and returns the exit code of run.ps1
# Exit codes of run.ps1: 0 all PASS, 1 a FAIL, 2 an INCOMPLETE, 3 the whole suite SKIPPED, 64 refused or usage error.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Guard.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Host.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Locks.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Json.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Plugins.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Scenarios.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Learn.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Extensions.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'States.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Transport.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Sources.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Renders.psm1') -ErrorAction Stop

$script:LabelPattern = '^[0-9A-Za-z._-]{1,40}$'

# Reasons to skip the whole suite. Skip markers come first and end the check at once: someone is using the machine.
# PluginIds: only these plugins are checked ($null: every one; a listing checks the plugins it lists, so a bundle it
# was not asked about does not skip it). Returns @{ Reasons; ReaperVersion; Plugins (id -> @{ Info; Sha256 } for
# bundles that could be read) }.
function Get-HarnessPreflight {
    param([Parameter(Mandatory)][string]$ReaperExe, [Parameter(Mandatory)][string]$PluginDir, [Parameter(Mandatory)]$Config, [string[]]$SkipMarkers = @(), [object[]]$ExtensionPreflight = @(),
          [string[]]$PluginIds = $null)
    $why = [Collections.Generic.List[string]]::new()
    $out = [ordered]@{ Reasons = $why; ReaperVersion = ''; Plugins = [ordered]@{} }
    $hit = Get-HarnessSkipMarkerHit $SkipMarkers
    if ($hit) { $why.Add("skip marker present: $(Split-Path -Leaf $hit) (someone is using this machine; REAPER is not started)"); return [pscustomobject]$out }
    if (Test-Path -LiteralPath $ReaperExe -PathType Leaf) { $out.ReaperVersion = [string](Get-Item -LiteralPath $ReaperExe).VersionInfo.ProductVersion } else { $why.Add('reaper.exe not found') }
    if (-not (Test-Path -LiteralPath $PluginDir -PathType Container)) { $why.Add('the plugin directory (-PluginDir) does not exist') }
    else {
        $names = @{}
        $checked = @($Config.Plugins.get_Values() | Where-Object { $null -eq $PluginIds -or $_.Id -cin $PluginIds })
        foreach ($p in @($checked | Where-Object { $_.Kind -eq 'jsfx' })) {
            try { $null = Get-HarnessJsfxInfo $p.Jsfx } catch { $why.Add("plugin $($p.Id): $($_.Exception.Message -replace '^PLUGIN: ', '')") }
        }
        foreach ($p in @($checked | Where-Object { $_.Kind -ne 'jsfx' })) {
            $bundle = Join-Path $PluginDir $p.Bundle
            if (-not (Test-Path -LiteralPath $bundle -PathType Container)) { $why.Add("plugin $($p.Id): bundle $($p.Bundle) not found in the plugin directory"); continue }
            try { $info = Read-HarnessModuleInfo $bundle } catch { $why.Add("plugin $($p.Id): $($_.Exception.Message -replace '^PLUGIN: ', '')"); continue }
            $bin = Get-HarnessBundleBinary $bundle
            if (-not (Test-Path -LiteralPath $bin -PathType Leaf)) { $why.Add("plugin $($p.Id): $($p.Bundle) has no Windows binary (Contents\x86_64-win\$($p.Bundle))"); continue }
            $full = Get-HarnessReaperName $info
            if ($names.ContainsKey($full)) { $why.Add("plugins $($names[$full]) and $($p.Id) have the same name in REAPER ($full); they cannot be told apart"); continue }
            $names[$full] = $p.Id
            $out.Plugins[$p.Id] = [pscustomobject]@{ Info = $info; Sha256 = (Get-HarnessSha256 $bin) }
        }
    }
    if (@(Get-HarnessReaperProcessIds).Count -gt 0) { $why.Add('a reaper.exe not started by this tool is running: the suite does not run alongside it, and changes to the default resource directory could not be attributed') }
    foreach ($r in (Invoke-HarnessExtensionPreflight -Preflight $ExtensionPreflight -Config $Config)) { $why.Add($r) }
    [pscustomobject]$out
}

# Pure function: the default build label from the plugin binaries' sha256 (id order of the configuration). Up to
# five plugins: their hash prefixes joined with '-' (12 hex digits each for up to three, fewer for four or five, so
# the label stays within 40 characters); more plugins: the first 12 hex digits of the sha256 over "id sha256" lines.
function Get-HarnessDefaultLabel([System.Collections.Specialized.OrderedDictionary]$Shas) {
    $n = $Shas.get_Count()
    if ($n -eq 0) { return 'unknown' }
    if ($n -le 5) {
        $len = [Math]::Min(12, [Math]::Floor((40 - ($n - 1)) / $n))
        return (@($Shas.get_Values() | ForEach-Object { $_.Substring(0, $len) }) -join '-')
    }
    $Text = (@($Shas.get_Keys() | ForEach-Object { "$_ $($Shas[$_])" }) -join "`n") + "`n"
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
    ([Convert]::ToHexString($hash)).Substring(0, 12).ToLowerInvariant()
}

# Worst of a set of outcomes. An empty set is "nothing ran": no conclusion, never PASS. SKIPPED only when everything
# was skipped; SKIPPED mixed with PASS is INCOMPLETE (part of it gave no conclusion).
function Get-HarnessWorstStatus([string[]]$StatusList) {
    if ($null -eq $StatusList -or $StatusList.Count -eq 0) { return 'INCOMPLETE' }
    foreach ($s in 'FAIL', 'INCOMPLETE') { if ($s -in $StatusList) { return $s } }
    if (@($StatusList | Where-Object { $_ -ne 'SKIPPED' }).Count -eq 0) { return 'SKIPPED' }
    if ('SKIPPED' -in $StatusList) { return 'INCOMPLETE' }
    'PASS'
}

# Pure function: the changes of the default resource directory that were really seen (Changed and Unreadable as
# Compare-HarnessDefaultCfgSnapshot gives them). An entry listed once and unreadable the other time shows up as changed
# or removed, and so does everything below it: that is the same lack of evidence as the entry being unreadable, not a
# change somebody saw. A change anywhere else counts, whatever could not be read.
function Get-HarnessCfgChangesSeen {
    param([string[]]$Changed = @(), [string[]]$Unreadable = @())
    if ('.' -cin $Unreadable) { return }
    $Changed | Where-Object {
        $rel = $_ -replace '^(?:added|removed|changed):', ''
        @($Unreadable | Where-Object { $rel -ieq $_ -or $rel.StartsWith("$_\", [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0
    }
}

# Pure function. CfgChanged: entries of the default resource directory were seen to change. Residual: processes this
# round started that are still alive and that no launch reported. Those two are a FAIL. CfgUnreadable (part of that
# directory could not be listed) is no conclusion: nothing was seen to change, it just cannot be shown that nothing did.
# StillRunning (the watchdog reported a process it could not end) is no conclusion either: the launch was not finished,
# and whatever came after did not run. Neither can be made green by the rows.
function Get-HarnessRunVerdict {
    param([string[]]$RowStatuses, [bool]$CfgChanged = $false, [bool]$CfgUnreadable = $false, [int]$Residual = 0, [bool]$StillRunning = $false)
    if ($CfgChanged -or $Residual -gt 0) { return 'FAIL' }
    $worst = Get-HarnessWorstStatus $RowStatuses
    if ($worst -cne 'FAIL' -and ($CfgUnreadable -or $StillRunning)) { return 'INCOMPLETE' }
    $worst
}

# Pure function: why no further round may run ('' when one may). A default resource directory that changed or could not
# be listed stops everything at once, and so does a process that could not be ended: REAPER is not started again. A
# round that broke says nothing about the next, and whatever broke it is most likely still there.
function Get-HarnessRoundStop {
    param([bool]$CfgChanged = $false, [bool]$CfgUnreadable = $false, [bool]$StillRunning = $false, [bool]$RoundBroke = $false)
    $why = @(
        if ($CfgChanged) { 'the default resource directory changed' }
        if ($CfgUnreadable) { 'the default resource directory could not be listed in full' }
        if ($StillRunning) { 'a REAPER of this round could not be ended' }
        if ($RoundBroke) { 'the round stopped on an unexpected error' }
    )
    $why -join '; '
}

# Pure function: the outcome of a negative row. The outcome alone is not enough: some outcomes come about without
# the case having run at all (a lock that could not be taken leaves REAPER unstarted, and a watchdog case is then
# INCOMPLETE too, without any watchdog having acted). So both must hold: the observed outcome equals the expected
# one, and the detail matches the case's expectDetail (a case-sensitive regex).
#   expected outcome, matching reason       PASS
#   expected outcome, other reason          INCOMPLETE: the case was not verified (an empty run looks like this)
#   observed INCOMPLETE, expected another   INCOMPLETE: could not run, so not verified; not FAIL
#   any other outcome                       FAIL
function Get-HarnessNegativeVerdict {
    param([Parameter(Mandatory)][string]$Expect, [Parameter(Mandatory)][string]$ExpectDetail, [Parameter(Mandatory)][string]$Observed, [string]$Detail = '')
    if ($Observed -ne $Expect) {
        if ($Observed -eq 'INCOMPLETE') { return [pscustomobject]@{ Status = 'INCOMPLETE'; Detail = "the negative case could not run, so it was not verified (expected $Expect): $Detail" } }
        return [pscustomobject]@{ Status = 'FAIL'; Detail = $Detail }
    }
    if ($Detail -cnotmatch $ExpectDetail) { return [pscustomobject]@{ Status = 'INCOMPLETE'; Detail = "the outcome is $Observed but the reason does not match $ExpectDetail, so the case was not verified: $Detail" } }
    [pscustomobject]@{ Status = 'PASS'; Detail = $Detail }
}

# Guard negative cases: the real entry point is run again in this process, and must refuse or skip as expected
# without starting REAPER.
function Invoke-HarnessGuardNegative {
    param([Parameter(Mandatory)][hashtable]$Params, [Parameter(Mandatory)][string]$Guard, [Parameter(Mandatory)][string]$TempRoot, [Parameter(Mandatory)][string]$FirstScenario)
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $made = [Collections.Generic.List[string]]::new()
    try {
        switch ($Guard) {
            'skip-marker' {
                $marker = Join-Path $TempRoot "skip-marker-$tag"
                Set-Content -LiteralPath $marker -Value x; $made.Add($marker)
                # Clone and override instead of relying on "an explicit argument beats a splatted key of the same name"
                $p2 = $Params.Clone(); $p2.SkipMarker = @($Params['SkipMarker']) + $marker
                $r = Invoke-HarnessSuite @p2 -Only ('^' + [regex]::Escape($FirstScenario) + '$') -NoNegative -Repeat 1
                if ($r.launches -ne 0) { return [pscustomobject]@{ Observed = 'FAIL'; Detail = "the marker was present but REAPER was started $($r.launches) times" } }
                return [pscustomobject]@{ Observed = $r.verdict; Detail = "launches=$($r.launches); $($r.skipReasons -join '; ')" }
            }
            { $_ -in 'sentinel-missing', 'default-dir' } {
                $dir = Get-HarnessDefaultCfgDir
                if ($Guard -eq 'sentinel-missing') {
                    $dir = Join-Path $TempRoot "cfg-$tag"
                    $null = New-Item -ItemType Directory -Path $dir
                    $made.Add($dir); Set-Content -LiteralPath (Join-Path $dir 'reaper.ini') -Value '[REAPER]'; $made.Add((Join-Path $dir 'reaper.ini'))
                }
                $want = ($Guard -eq 'sentinel-missing') ? '*sentinel*' : '*never touched*'
                $p2 = $Params.Clone(); $p2.CfgDir = $dir
                try { $null = Invoke-HarnessSuite @p2 -NoNegative -Repeat 1; return [pscustomobject]@{ Observed = 'FAIL'; Detail = 'not refused' } }
                catch {
                    $msg = $_.Exception.Message -replace '\s+', ' '
                    if ($msg -like 'REFUSED:*' -and $msg -like $want) { return [pscustomobject]@{ Observed = 'REFUSED'; Detail = $msg } }
                    return [pscustomobject]@{ Observed = 'FAIL'; Detail = "refused for the wrong reason: $msg" }
                }
            }
            default { return [pscustomobject]@{ Observed = 'INCOMPLETE'; Detail = "unknown guard $Guard" } }
        }
    } finally {
        # Only the temporary files made above, then the empty directory (not recursive)
        foreach ($m in ($made | Sort-Object Length -Descending)) { if (Test-Path -LiteralPath $m) { Remove-Item -LiteralPath $m -ErrorAction SilentlyContinue } }
    }
}

# One negative row. Guard cases run the entry point again; all others go through the same handlers as positive ones.
function Invoke-HarnessNegativeRow {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Scenario, [Parameter(Mandatory)][hashtable]$GuardParams, [Parameter(Mandatory)][string]$TempRoot, [string]$FirstScenario = '', [string]$NotRun = '')
    $t0 = [Diagnostics.Stopwatch]::StartNew()
    if ($NotRun) { $seen = 'INCOMPLETE'; $note = $NotRun }
    elseif ($Scenario.kind -eq 'guard') {
        $g = Invoke-HarnessGuardNegative -Params $GuardParams -Guard $Scenario.guard -TempRoot $TempRoot -FirstScenario $FirstScenario
        $seen = $g.Observed; $note = $g.Detail
    } else {
        $o = Invoke-HarnessScenario -Ctx $Context -Scenario $Scenario
        $seen = $o.Status; $note = $o.Detail
    }
    $v = Get-HarnessNegativeVerdict -Expect $Scenario.expect -ExpectDetail $Scenario.expectDetail -Observed $seen -Detail $note
    [ordered]@{
        id = $Scenario.id; kind = $Scenario.kind; negative = $true; builtin = [bool]$Scenario.builtin; expected = $Scenario.expect; observed = $seen; status = $v.Status
        seconds = [math]::Round($t0.Elapsed.TotalSeconds, 1); detail = (Hide-HarnessPaths $v.Detail)
    }
}

# Pure function: the positive and negative cases -Only (a regex on the id) and -NoNegative pick. Built-in negative
# cases come after the configuration's own (the one of the transport kind only when the configuration has a transport
# scenario). An invalid regex, or nothing picked, is a usage error: a round with
# zero cases has no conclusion and must not end as PASS.
function Select-HarnessScenarios {
    param([Parameter(Mandatory)]$Config, [string]$Only = '', [switch]$NoNegative)
    if ($Only) { try { $null = [regex]::new($Only) } catch { Stop-Usage "-Only is not a valid regex: $($_.Exception.Message)" } }
    $positive = @($Config.Scenarios | Where-Object { -not $Only -or $_.id -match $Only })
    $all = @($Config.Negative) + @(Get-HarnessBuiltinNegatives -Transport:(@($Config.Scenarios | Where-Object { $_.kind -ceq 'transport' }).Count -gt 0))
    $negative = $NoNegative ? @() : @($all | Where-Object { -not $Only -or $_.id -match $Only })
    if ($positive.Count + $negative.Count -eq 0) {
        Stop-Usage ("-Only '{0}' picked no scenario{1}" -f $Only, ($NoNegative ? ' (negative cases are not run with -NoNegative)' : ''))
    }
    [pscustomobject]@{ Positive = $positive; Negative = $negative }
}

# What -List and its options ask for, from run.ps1's bound parameters (Bound). Every option is one plain string, so a bad
# value is a usage error here (64), never a binding error of PowerShell (1). A list of ids or values is separated by
# commas (or blanks: PowerShell hands an array to a string parameter joined by blanks). $null without -List; otherwise
# @{ Kind; Plugins (ids, $null: every plugin); Params (exact names to sweep, $null: no sweep); Values (normalized values
# of the sweep, in order; $null without one) }. A listing runs once and runs no scenario: -Only, -NoNegative and -Repeat
# do not go with it (-Repeat 1 neither: given is given). A sweep needs exactly one plugin. Invoke-HarnessSuite checks
# the ids against the configuration.
$script:ListOptions = 'ListPlugin', 'ListParam', 'ListParamFile', 'ListValues'
$script:SweepNamePattern = '\A[^\u0000-\u001f]{1,256}\z'
$script:SweepDefault = 0, 0.25, 0.5, 0.75, 1
function Test-HarnessListRequest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Bound)
    $given = [Collections.Generic.HashSet[string]]::new([string[]]@($Bound.get_Keys()), [StringComparer]::OrdinalIgnoreCase)
    $split = { param([string]$Joined) $Joined.Trim() -split '\s*,\s*|\s+' }
    if (-not $given.Contains('List')) {
        foreach ($o in $script:ListOptions) { if ($given.Contains($o)) { Stop-Usage "-$o needs -List params" } }
        return $null
    }
    if ([string]$Bound['List'] -cne 'params') { Stop-Usage '-List: only "params" can be listed' }
    foreach ($o in 'Only', 'NoNegative', 'Repeat') { if ($given.Contains($o)) { Stop-Usage "-$o does not go with -List: a listing runs no scenario, and runs once" } }
    $ids = $null
    if ($given.Contains('ListPlugin')) {
        $ids = @(& $split ([string]$Bound['ListPlugin']))
        $once = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($id in $ids) {
            if (-not $id) { Stop-Usage '-ListPlugin: an empty plugin id (ids are separated by commas)' }
            if (-not $once.Add($id)) { Stop-Usage "-ListPlugin: plugin '$id' is given twice" }
        }
    }
    if ($given.Contains('ListParam') -and $given.Contains('ListParamFile')) { Stop-Usage '-ListParam and -ListParamFile do not go together: one name, or a file of names' }
    $sweep = $null
    if ($given.Contains('ListParam')) { $sweep = @([string]$Bound['ListParam']) }
    elseif ($given.Contains('ListParamFile')) { $sweep = Read-HarnessParamNameFile ([string]$Bound['ListParamFile']) }
    if ($null -ne $sweep) {
        if ($sweep.Count -lt 1 -or $sweep.Count -gt 32) { Stop-Usage "-ListParamFile: 1 to 32 parameter names, one a line (found $($sweep.Count))" }
        $once = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        for ($i = 0; $i -lt $sweep.Count; $i++) {
            if ($sweep[$i] -cnotmatch $script:SweepNamePattern) { Stop-Usage "parameter name $($i + 1) to sweep is empty, longer than 256 characters or has a control character" }
            if (-not $once.Add($sweep[$i])) { Stop-Usage "parameter name $($i + 1) to sweep is given twice" }
        }
        if ($null -eq $ids -or $ids.Count -ne 1) { Stop-Usage 'a sweep (-ListParam or -ListParamFile) needs exactly one plugin in -ListPlugin' }
    }
    $sweepValues = $null
    if ($given.Contains('ListValues')) {
        if ($null -eq $sweep) { Stop-Usage '-ListValues needs -ListParam or -ListParamFile: values are for a sweep' }
        $picked = [Collections.Generic.List[double]]::new()
        foreach ($t in (& $split ([string]$Bound['ListValues']))) {
            $v = 0.0
            if (-not [double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -or -not [double]::IsFinite($v) -or $v -lt 0 -or $v -gt 1) {
                Stop-Usage "-ListValues: '$t' is not a number from 0 to 1 (values are separated by commas, with a dot as the decimal point)"
            }
            $v += 0.0 # -0 is 0
            if ($picked.Contains($v)) { Stop-Usage "-ListValues: $t is given twice" }
            $picked.Add($v)
        }
        if ($picked.Count -gt 101) { Stop-Usage "-ListValues: at most 101 values (found $($picked.Count))" }
        $sweepValues = $picked.ToArray()
    } elseif ($null -ne $sweep) { $sweepValues = [double[]]$script:SweepDefault }
    @{ Kind = 'params'; Plugins = $ids; Params = $sweep; Values = $sweepValues }
}

# The names of -ListParamFile: UTF-8 (a BOM is fine), one name a line, empty lines at the end left out. Nothing of the file
# is echoed.
function Read-HarnessParamNameFile([string]$NameFile) {
    if (-not $NameFile -or -not (Test-Path -LiteralPath $NameFile -PathType Leaf)) { Stop-Usage '-ListParamFile: no such file' }
    $item = Get-Item -LiteralPath $NameFile
    if ($item.Length -gt 65536) { Stop-Usage '-ListParamFile: the file is larger than 64 KiB' }
    $content = ''
    try { $content = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($item.FullName)) } catch { Stop-Usage '-ListParamFile: the file cannot be read as UTF-8' }
    if ($content.StartsWith([char]0xFEFF)) { $content = $content.Substring(1) }
    $lines = [Collections.Generic.List[string]]::new([string[]]($content -split '\r?\n'))
    while ($lines.Count -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    , $lines.ToArray()
}

# Pure function: whether a scenario needs the learned plugin blocks (anything with a configured layout, instances,
# extension kinds). Built-in negative cases never do.
function Test-HarnessNeedsLearn($Scenario) {
    if ($Scenario.builtin) { return $false }
    if ($Scenario.kind -eq 'instances' -or $Scenario.kind -cnotin 'render', 'device', 'savereopen', 'transport') { return $true }
    $p = $Scenario.PSObject.Properties
    if ($p['layout'] -and $Scenario.layout -and $Scenario.layout -notlike '@*') { return $true }
    [bool]($p['compare'] -and $Scenario.compare -and $Scenario.compare.Kind -eq 'variant' -and $Scenario.compare.Layout -notlike '@*')
}

# Why a scenario does not run for want of learned plugin blocks ('' when it runs). Halt: learning saw what no scenario
# may run after (a tested binary from outside the private copy) or broke; it is the reason. A kind of an extension gets
# every block and the proof: it runs only when there were learn rows, every one PASS, and learning did not stop
# (Complete). Every other scenario runs when each plugin variant it needs (Get-HarnessScenarioLearnKeys) was committed.
function Get-HarnessLearnGap {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Scenario, [string]$Halt = '', [bool]$Complete = $false)
    if (-not (Test-HarnessNeedsLearn $Scenario)) { return '' }
    if ($Halt) { return $Halt }
    if ($Scenario.kind -cnotin 'render', 'device', 'savereopen', 'transport', 'instances') {
        return $Complete ? '' : "not run: learning did not pass in every batch, and a kind of an extension gets every block (see the learn row$(($Context.LearnBatchCount -gt 1) ? 's' : ''))"
    }
    foreach ($e in (Get-HarnessScenarioLearnKeys -Config $Context.Config -Scenario $Scenario)) {
        if ($Context.Blocks.ContainsKey($e.Key)) { continue }
        if (-not $Context.LearnBatchOf.ContainsKey($e.Key)) { return "not run: learning did not cover $($e.Plugin) as this scenario uses it" }
        return "not run: learning the plugin blocks it needs did not succeed (see the $(Get-HarnessLearnRowId $Context.LearnBatchOf[$e.Key] $Context.LearnBatchCount) row)"
    }
    ''
}

function Write-HarnessLine([string]$Text) { Write-Host (Hide-HarnessPaths $Text) }

function Invoke-HarnessSuite {
    param(
        [string]$CfgDir = '', [Parameter(Mandatory)][string]$Config, [Parameter(Mandatory)][string]$PluginDir, [Parameter(Mandatory)][string]$ResultDir,
        [Parameter(Mandatory)][string]$ReaperExe, [string[]]$SkipMarker = @(), [string[]]$ExtraGuiLock = @(), [string]$Only = '', [int]$Repeat = 1,
        [switch]$NoNegative, [string]$BuildLabel = '', [switch]$KeepWork,
        [hashtable]$List = $null, # Test-HarnessListRequest: list the parameters of these plugins instead of running the scenarios
        [hashtable]$SelfTestHooks = @{} # self-test only: Launcher (a stand-in for REAPER), ModuleSampler, Stopper, RoundFault (runs after the rows of a round)
    )
    $null = Initialize-HarnessCfg $CfgDir # refuses (REFUSED) before anything is touched
    Assert-HarnessResultDir $ResultDir # the same, for the directory the run writes to
    if ($Repeat -lt 1) { Stop-Usage '-Repeat must be at least 1' }
    if ($BuildLabel -and $BuildLabel -cnotmatch $script:LabelPattern) { Stop-Usage "-BuildLabel must match $($script:LabelPattern)" }
    $locks = Get-HarnessGuiLockSet -Extra $ExtraGuiLock
    $ext = Import-HarnessExtensions (Read-HarnessConfigExtensions $Config)
    $conf = Read-HarnessConfig -Path $Config -Kinds $ext.Kinds
    $states = Read-HarnessStates -Config $conf # a template or state file that does not hold the block: usage error
    Read-HarnessFeeds -Config $conf # a feed file that is not there, not a WAV or at another rate: usage error
    # A listing picks plugins, not scenarios: an id the configuration does not have is a usage error, nothing started
    $listIds = $null
    if ($List) {
        foreach ($id in @($List.Plugins)) { if ($null -ne $id -and $id -cnotin @($conf.Plugins.get_Keys())) { Stop-Usage "-ListPlugin: the configuration has no plugin '$id'" } }
        $listIds = @($conf.Plugins.get_Keys() | Where-Object { $null -eq $List.Plugins -or $_ -cin $List.Plugins })
    }
    $picked = $List ? [pscustomobject]@{ Positive = @(); Negative = @() } : (Select-HarnessScenarios -Config $conf -Only $Only -NoNegative:$NoNegative) # nothing picked: usage error, nothing started
    # A source file of a picked scenario that is not there, not usable or at another rate: usage error
    $sourceFiles = [ordered]@{}
    if (-not $List) { $sourceFiles = Read-HarnessSourceFiles -Config $conf -Scenarios (@($picked.Positive) + @($picked.Negative)) }
    $tool = Get-HarnessToolVersion
    $pre = Get-HarnessPreflight -ReaperExe $ReaperExe -PluginDir $PluginDir -Config $conf -SkipMarkers $SkipMarker -ExtensionPreflight $ext.Preflight -PluginIds $listIds
    $Shas = [ordered]@{}
    foreach ($id in $pre.Plugins.get_Keys()) { $Shas[$id] = $pre.Plugins[$id].Sha256 }
    $result = [ordered]@{
        schema = 1; tool = 'reaper-harness'; toolVersion = $tool.version; toolCommit = $tool.commit; config = $conf.Name; buildLabel = ($BuildLabel ? $BuildLabel : (Get-HarnessDefaultLabel $Shas))
        startedUtc = [DateTime]::UtcNow.ToString('o'); reaper = $pre.ReaperVersion; verdict = 'SKIPPED'; launches = 0
        skipReasons = @($pre.Reasons | ForEach-Object { Hide-HarnessPaths $_ }); locks = $locks; extensions = @($ext.Modules)
        plugins = @(); states = @(); sources = @($sourceFiles.get_Values() | ForEach-Object { ConvertTo-HarnessSourceFact $_ }); manifest = $null; pluginPath = $null; scanShield = $null; runs = @(); error = $null
        # A listing run says so from the start, also when it is skipped or stops before its round
        listing = ($List ? [ordered]@{ kind = 'params'; values = ($List.Params ? @($List['Values']) : $null); readAt = $null; plugins = @() } : $null)
    }
    if ($pre.Reasons.Count) { return [pscustomobject]$result }
    $infos = [ordered]@{}
    foreach ($id in $pre.Plugins.get_Keys()) { $infos[$id] = $pre.Plugins[$id].Info }
    Assert-HarnessStateIdentity -States $states -Infos $infos # a block of another plugin: usage error, nothing started

    $launches = 0
    try {
        # A listing installs the plugins it lists and no other
        $toInstall = $conf.Plugins
        if ($List) { $toInstall = [ordered]@{}; foreach ($id in $listIds) { $toInstall[$id] = $conf.Plugins[$id] } }
        $installed = Install-HarnessPlugins -Plugins $toInstall -PluginDir $PluginDir
        $jsfx = Install-HarnessJsfx -Plugins $toInstall
        $result.plugins = @($installed | ForEach-Object {
                [ordered]@{ id = $_.Id; bundle = $_.Bundle; name = (Get-HarnessReaperName $_.Info); version = $_.Info.Version; classId = $_.Info.Cid; sha256 = $_.Sha256.Substring(0, 12) }
            }) + @($jsfx | ForEach-Object { [ordered]@{ id = $_.Id; jsfx = $_.Jsfx; name = $_.Name; sha256 = $_.Sha256.Substring(0, 12) } })
        $result.states = @($states.get_Values() | ForEach-Object { [ordered]@{ plugin = $_.Plugin; state = $_.State; sha256 = $_.Sha } })
        $null = Set-HarnessPluginPath
        $result.pluginPath = 'system VST3 directories first, the private plugins directory last'
        $shield = Update-HarnessScanCache -Keep @($installed | ForEach-Object { $_.Bundle })
        $result.scanShield = [ordered]@{ directories = $shield.Dirs; files = $shield.Scanned; added = $shield.Added; replaced = $shield.Replaced; removed = $shield.Removed; unshielded = $shield.Unshielded }
        $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
        # Kept renders go to renders/<stamp>/ with a manifest; its lines repeat these fields of the run
        $keeper = New-HarnessKeep -ResultDir $ResultDir -Stamp $stamp -Run ([ordered]@{
                reaper = $pre.ReaperVersion; toolVersion = $tool.version; toolCommit = $tool.commit; buildLabel = $result.buildLabel
                config = [ordered]@{ name = (Split-Path -Leaf $Config); sha256 = $conf.FileSha256 } # the bytes that were read, not the file as it is now
            })
        $driver = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../lua/driver.lua'))
        $all = @($picked.Positive) + @($picked.Negative)
        $toolJsfx = @($all | Where-Object { $_.kind -ceq 'transport' }).Count ? (Install-HarnessToolJsfx) : @{}
        $needLearn = $List -or @($all | Where-Object { Test-HarnessNeedsLearn $_ }).Count -gt 0
        # A listing learns the default variant of each plugin it lists: always one launch (the defaults are never split)
        $variants = $List ? @((Get-HarnessLearnVariants -Config $conf) | Where-Object { $_.Plugin -cin $listIds }) : (Get-HarnessLearnVariants -Config $conf -Scenarios @($all | Where-Object { Test-HarnessNeedsLearn $_ }))
        $plan = $needLearn ? (Get-HarnessLearnBatches -Variants $variants -Size ([int]$conf.Limits.learnBatchSize)) : @()
        $sweep = ($List -and $List.Params) ? @{ Names = @($List.Params); Values = @($List['Values']) } : $null
        if ($List) {
            Write-HarnessLine ("listing the parameters of {0} plugin{1} in one learn launch{2}" -f $listIds.Count, (($listIds.Count -eq 1) ? '' : 's'),
                ($sweep ? " ($($sweep.Names.Count) parameter$(($sweep.Names.Count -eq 1) ? '' : 's') swept at $(@($sweep['Values']).Count) values)" : ''))
        } else {
            Write-HarnessLine ("{0} scenarios and {1} negative cases picked (after matrix and variant expansion); {2} plugin variants to learn in {3} launch{4} per round" -f
                @($picked.Positive).Count, @($picked.Negative).Count, ($needLearn ? $variants.Count : 0), $plan.Count, (($plan.Count -eq 1) ? '' : 'es'))
        }
        $firstId = @($conf.Scenarios)[0].id
        $guardSet = @{ CfgDir = $CfgDir; Config = $Config; PluginDir = $PluginDir; ResultDir = $ResultDir; ReaperExe = $ReaperExe; SkipMarker = $SkipMarker; ExtraGuiLock = $ExtraGuiLock; SelfTestHooks = $SelfTestHooks }
        $rounds = $List ? 1 : $Repeat # a listing reads once
        for ($k = 1; $k -le $rounds; $k++) {
            $work = Join-Path $ResultDir "work/$stamp-run$k"
            $null = New-Item -ItemType Directory -Force -Path $work
            $before = Get-HarnessDefaultCfgSnapshot
            $ctx = New-HarnessContext -ReaperExe $ReaperExe -WorkDir $work -Driver $driver -Config $conf -Installed $installed -Jsfx $jsfx -States $states -Locks $locks -SkipMarkers $SkipMarker `
                -LuaExtensions $ext.Lua -Kinds $ext.Kinds -ToolJsfx $toolJsfx
            if ($SelfTestHooks['Launcher']) { $ctx.Launcher = $SelfTestHooks['Launcher'] }
            if ($SelfTestHooks['ModuleSampler']) { $ctx.ModuleSampler = $SelfTestHooks['ModuleSampler'] }
            if ($SelfTestHooks['Stopper']) { $ctx.Stopper = $SelfTestHooks['Stopper'] }
            Copy-HarnessSourceFiles -Ctx $ctx -Sources $sourceFiles
            # What the result says of a listing when the round breaks before it is read: every plugin, not listed
            if ($List) { $result.listing = (Get-HarnessParamListing -Ctx $ctx -Request $List -NotRead 'not listed: the round stopped before the listing was read').Listing }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $rows = [Collections.Generic.List[object]]::new()
            $learnHalt = '' # why nothing that needs learning runs
            # What the end of the round works with if the rows below never get that far
            $mods = New-HarnessOutcome INCOMPLETE 'the module check did not run' ([ordered]@{ launches = 0; foreign = @(); otherPlugins = 0 })
            $brokenRound = $false
            try {
                # One row per learn batch. A batch whose launch failed leaves its entries unlearned and the next batch still
                # runs: every launch passes every guard on its own. Learning stops at a tested binary from outside the private
                # copy, at a launch that was blocked or could not be ended, and at an error.
                $ctx.LearnBatchCount = $plan.Count
                foreach ($batch in $plan) { foreach ($e in $batch.Entries) { $ctx.LearnBatchOf[$e.Key] = $batch.No } }
                $stoppedAt = ''
                $learnRows = [Collections.Generic.List[object]]::new()
                foreach ($batch in $plan) {
                    $rowId = Get-HarnessLearnRowId $batch.No $plan.Count
                    $t0 = [Diagnostics.Stopwatch]::StartNew()
                    $o = if ($stoppedAt) { New-HarnessOutcome INCOMPLETE "not run: learning stopped at the $stoppedAt row" }
                    else {
                        try { Invoke-HarnessLearn -Ctx $ctx -Variants $batch.Entries -BatchNo $batch.No -BatchCount $plan.Count -WithListing:([bool]$List) -Sweep $sweep }
                        catch { New-HarnessOutcome INCOMPLETE "learning threw: $($_.Exception.Message -replace '\s+', ' ')" | Add-Member -NotePropertyName Stop -NotePropertyValue 'threw' -PassThru }
                    }
                    $learnStop = ($o.PSObject.Properties['Stop'] -and $o.Stop) ? [string]$o.Stop : ''
                    if ($learnStop -and -not $stoppedAt) {
                        $stoppedAt = $rowId
                        if ($learnStop -ceq 'foreign') { $learnHalt = "not run: learning saw a tested binary loaded from outside the private copy (see the $rowId row)" }
                        elseif ($learnStop -ceq 'threw') { $learnHalt = "not run: learning stopped on an error (see the $rowId row)" }
                    }
                    $row = [ordered]@{ id = $rowId; kind = 'learn'; status = $o.Status; seconds = [math]::Round($t0.Elapsed.TotalSeconds, 1); detail = (Hide-HarnessPaths $o.Detail) }
                    # No path in these today (counts, verdicts, file names, state names); masked like every other row all the same.
                    # A batch not started, or one that threw, has its place and size all the same, and nothing learned.
                    $row.facts = Hide-HarnessFacts ($o.PSObject.Properties['Facts'] ? $o.Facts : [ordered]@{ variants = @($batch.Entries).Count; batch = $batch.No; batches = $plan.Count; learned = 0 })
                    $rows.Add($row); $learnRows.Add($row)
                    Write-HarnessLine ("  [{0}] {1}  {2} s  {3}" -f $o.Status, $rowId, $row.seconds, $o.Detail)
                }
                $learnComplete = $learnRows.Count -gt 0 -and -not $stoppedAt -and @($learnRows | Where-Object { $_.status -ne 'PASS' }).Count -eq 0
                if ($List) {
                    # The listing row: what the learn launch read of each plugin it learned (Invoke-HarnessLearn -WithListing)
                    $listed = Get-HarnessParamListing -Ctx $ctx -Request $List
                    $row = [ordered]@{ id = 'params'; kind = 'params'; status = $listed.Status; seconds = 0; detail = (Hide-HarnessPaths $listed.Detail); facts = (Hide-HarnessFacts $listed.Facts) }
                    $rows.Add($row)
                    Write-HarnessLine ("  [{0}] params  {1}" -f $listed.Status, $listed.Detail)
                    foreach ($line in $listed.Lines) { Write-HarnessLine "    $line" }
                    $result.listing = $listed.Listing
                }
                foreach ($s in $picked.Positive) {
                    $gap = Get-HarnessLearnGap -Context $ctx -Scenario $s -Halt $learnHalt -Complete $learnComplete
                    if ($gap) { $o = New-HarnessOutcome INCOMPLETE $gap | Add-Member -NotePropertyName Seconds -NotePropertyValue 0 -PassThru }
                    else { $o = Invoke-HarnessScenario -Ctx $ctx -Scenario $s }
                    $row = [ordered]@{ id = $s.id; kind = $s.kind; status = $o.Status; seconds = $o.Seconds; detail = (Hide-HarnessPaths $o.Detail) }
                    if ($o.PSObject.Properties['Facts']) { $row.facts = Hide-HarnessFacts $o.Facts }
                    $shown = $o
                    if ($s.kind -ceq 'render' -and $s.keep) {
                        # Whatever the verdict: its render and stems move out of the work directory, a line goes into the manifest
                        $kept = Save-HarnessKeptRender -Keep $keeper -Ctx $ctx -Scenario $s -Round $k -Status $o.Status -Detail $o.Detail
                        $shown = $kept
                        $row.status = $kept.Status; $row.detail = Hide-HarnessPaths $kept.Detail
                        if ($kept.Record) {
                            if (-not ($row.Contains('facts') -and $row.facts -is [System.Collections.IDictionary])) { $row.facts = [ordered]@{} }
                            $row.facts['kept'] = ConvertTo-HarnessKeptFacts $kept.Record $keeper.Rel
                        }
                        if ($keeper.Lines) { $result.manifest = "$($keeper.Rel)/manifest.jsonl" }
                    }
                    # A row of a variant names it and the scenario as written, whether or not it ran
                    if ($s.PSObject.Properties['variant'] -and $s.variant) {
                        if (-not ($row.Contains('facts') -and $row.facts -is [System.Collections.IDictionary])) { $row.facts = [ordered]@{} }
                        $row.facts['variant'] = $s.variant; $row.facts['baseScenario'] = $s.PSObject.Properties['baseId'] ? $s.baseId : $s.id
                    }
                    $rows.Add($row)
                    Write-HarnessLine ("  [{0}] {1}  {2} s  {3}" -f $shown.Status, $s.id, $o.Seconds, $shown.Detail)
                }
                foreach ($s in $picked.Negative) {
                    $skip = Get-HarnessLearnGap -Context $ctx -Scenario $s -Halt $learnHalt -Complete $learnComplete
                    $row = Invoke-HarnessNegativeRow -Context $ctx -Scenario $s -GuardParams $guardSet -TempRoot $work -FirstScenario $firstId -NotRun $skip
                    $rows.Add($row)
                    Write-HarnessLine ("  [{0}] {1}  expected {2}, observed {3}  {4}" -f $row.status, $row.id, $row.expected, $row.observed, $row.detail)
                }
                if ($SelfTestHooks['RoundFault']) { & $SelfTestHooks['RoundFault'] }
                $mods = Get-HarnessModuleCheck -Ctx $ctx
                if (-not $KeepWork -and @($rows | Where-Object { $_.status -ne 'PASS' }).Count -eq 0 -and $mods.Status -eq 'PASS') {
                    # All green: delete this round's files one by one (never recursively); otherwise keep them for inspection
                    foreach ($f in $ctx.Files) { if (Test-Path -LiteralPath $f -PathType Leaf) { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue } }
                }
            } catch {
                # No conclusion for this round, and what has to be checked at the end of every round still is: the default
                # resource directory and the processes of this round
                $brokenRound = $true
                $row = [ordered]@{ id = 'round-error'; kind = 'internal'; status = 'INCOMPLETE'; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); detail = (Hide-HarnessPaths "the round stopped on an unexpected error: $($_.Exception.Message -replace '\s+', ' ')") }
                $rows.Add($row)
                Write-HarnessLine ("  [{0}] {1}  {2}" -f $row.status, $row.id, $row.detail)
            }
            $launches += $ctx.Launches
            if (-not (Get-ChildItem -LiteralPath $work -Force)) { Remove-Item -LiteralPath $work -ErrorAction SilentlyContinue }
            $after = Get-HarnessDefaultCfgSnapshot
            $cmp = Compare-HarnessDefaultCfgSnapshot -Before $before -After $after
            $changesSeen = @(Get-HarnessCfgChangesSeen -Changed $cmp.Changed -Unreadable $cmp.Unreadable)
            $dirChanged = $changesSeen.Count -gt 0
            $dirUnreadable = @($cmp.Unreadable).Count -gt 0
            # Only processes this round started count. The locks are free between launches, so a reaper.exe found by name may be
            # another session's, which started after the preflight and says nothing about this round.
            $ownLeft = @(Get-HarnessOwnProcessesLeft -Started $ctx.Started.ToArray())
            $notEnded = [bool]$ctx.StillRunning
            $unreported = @($ownLeft | Where-Object { -not $notEnded -or $_.Pid -ne $ctx.StillRunning.Pid })
            $statuses = @($rows | ForEach-Object { $_.status }) + $mods.Status
            $verdict = Get-HarnessRunVerdict -RowStatuses $statuses -CfgChanged $dirChanged -CfgUnreadable $dirUnreadable -Residual $unreported.Count -StillRunning $notEnded
            $counts = [ordered]@{}
            foreach ($st in 'PASS', 'FAIL', 'INCOMPLETE', 'SKIPPED') { $counts[$st] = @($rows | Where-Object { $_.status -eq $st }).Count }
            $runRow = [ordered]@{
                index = $k; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); verdict = $verdict; launches = $ctx.Launches; counts = $counts
                defaultCfgDir = [ordered]@{ unchanged = $cmp.Same; entries = $cmp.Count; changed = @($changesSeen | Select-Object -First 8 | ForEach-Object { Hide-HarnessPaths $_ }); unreadable = @($cmp.Unreadable | Select-Object -First 8 | ForEach-Object { Hide-HarnessPaths $_ }) }
                reaperProcessesLeft = $ownLeft.Count
                stillRunning = $notEnded
                retries = @($ctx.Retries | ForEach-Object { [ordered]@{ label = $_.Label; reason = $_.Reason } })
                moduleCheck = [ordered]@{ status = $mods.Status; detail = (Hide-HarnessPaths $mods.Detail); launches = $mods.Facts.launches; foreign = @($mods.Facts.foreign); otherPlugins = $mods.Facts.otherPlugins }
                scenarios = $rows.ToArray()
            }
            $result.runs += $runRow
            Write-HarnessLine ("round {0}/{1}: {2}, {3} s, REAPER started {4} times, module check {5}, default resource directory {6}" -f $k, $rounds, $verdict, $runRow.seconds, $ctx.Launches, $mods.Status,
                ($cmp.Same ? 'unchanged' : "$($dirChanged ? "CHANGED: $(@($changesSeen | Select-Object -First 8) -join ', ')" : 'not shown unchanged')$($dirUnreadable ? "; could not be listed: $(@($cmp.Unreadable | Select-Object -First 8) -join ', ')" : '')"))
            $stop = Get-HarnessRoundStop -CfgChanged $dirChanged -CfgUnreadable $dirUnreadable -StillRunning $notEnded -RoundBroke $brokenRound
            if ($stop) { $runRow.stoppedBecause = $stop; Write-HarnessLine "  no further rounds: $stop"; break }
        }
    } catch {
        # A guard or a usage error stays what it is. Anything else (a plugin that changed while it was copied, a disk that is
        # full) is something that could not be done, not a criterion that was checked: no conclusion, and the result says why
        if ($_.Exception.Message -like 'REFUSED:*' -or $_.Exception.Message -like 'USAGE:*') { throw }
        $result.error = Hide-HarnessPaths ($_.Exception.Message -replace '\s+', ' ')
        Write-HarnessLine "the run stopped on an unexpected error: $($result.error)"
    }
    $result.launches = $launches
    $result.verdict = Get-HarnessWorstStatus (@($result.runs | ForEach-Object { $_.verdict }) + @(if ($result.error) { 'INCOMPLETE' }))
    [pscustomobject]$result
}

# <ResultDir>/<yyyyMMdd-HHmmss>-<config name>-<build label>.json (UTF-8 without BOM); a listing's ends -list-<kind>.json.
# Returns the path.
function Write-HarnessResult {
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$ResultDir)
    $null = New-Item -ItemType Directory -Force -Path $ResultDir
    $listing = $Data.PSObject.Properties['listing'] ? $Data.listing : $null
    $path = Join-Path $ResultDir ('{0}-{1}-{2}{3}.json' -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss'), $Data.config, $Data.buildLabel, ($listing ? "-list-$($listing['kind'])" : ''))
    [IO.File]::WriteAllText($path, (ConvertTo-HarnessJsonText -Value $Data -Indent 2) + "`n", [Text.UTF8Encoding]::new($false))
    $path
}

# The end of run.ps1. A verdict stands without its file: a FAIL stays a FAIL, the signal that matters most. Anything else
# has no record, and so no conclusion: a PASS nobody can look up is not a PASS.
function Complete-HarnessRun {
    param([Parameter(Mandatory)]$Outcome, [Parameter(Mandatory)][string]$ResultDir)
    $exitCodes = @{ PASS = 0; FAIL = 1; INCOMPLETE = 2; SKIPPED = 3 }
    if ($Outcome.verdict -ceq 'SKIPPED') { Write-Host "SKIPPED: $($Outcome.skipReasons -join '; ')" }
    try {
        $resultFile = Write-HarnessResult -Data $Outcome -ResultDir $ResultDir
    } catch {
        $said = ($Outcome.verdict -ceq 'FAIL') ? 'FAIL' : 'INCOMPLETE'
        Write-Host "${said}: the run ended $($Outcome.verdict) but its result file could not be written: $(Hide-HarnessPaths ($_.Exception.Message -replace '\s+', ' '))"
        return $exitCodes[$said]
    }
    Write-Host ('reaper-harness {0}  config {1}  build {2}  {3} rounds  REAPER started {4} times  result {5}' -f $Outcome.verdict, $Outcome.config, $Outcome.buildLabel, $Outcome.runs.Count, $Outcome.launches, (Split-Path -Leaf $resultFile))
    $exitCodes[$Outcome.verdict]
}

Export-ModuleMember -Function Get-HarnessPreflight, Test-HarnessListRequest, Get-HarnessDefaultLabel, Get-HarnessWorstStatus, Get-HarnessCfgChangesSeen, Get-HarnessRunVerdict, Get-HarnessRoundStop, Get-HarnessNegativeVerdict,
    Invoke-HarnessGuardNegative, Invoke-HarnessNegativeRow, Select-HarnessScenarios, Test-HarnessNeedsLearn, Get-HarnessLearnGap, Invoke-HarnessSuite, Write-HarnessResult, Complete-HarnessRun
