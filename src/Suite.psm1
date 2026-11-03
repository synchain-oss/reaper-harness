# SPDX-License-Identifier: MIT
#
# The suite: preflight, plugin install, rounds, verdicts, result file.
#   Get-HarnessPreflight        reasons to skip the whole suite (nothing is started when there is one)
#   Select-HarnessScenarios     what -Only and -NoNegative pick (nothing picked is a usage error)
#   Get-HarnessWorstStatus      worst of a set of outcomes; an empty set is INCOMPLETE, never PASS
#   Get-HarnessRunVerdict       a round: the worst row, but FAIL whenever the default resource directory changed or a
#                               process of this round was left behind, and at least INCOMPLETE when that directory could
#                               not be listed or a process could not be ended, however green the rows are
#   Get-HarnessNegativeVerdict  a negative case passes only with the expected outcome AND the expected reason
#   Invoke-HarnessGuardNegative the guard negative cases: the real entry point run again in-process
#   Invoke-HarnessSuite         everything above for one configuration. Past the preflight an unexpected error is no
#                               conclusion: the verdict is at least INCOMPLETE, the result says why, and a round that broke
#                               still gets the checks of the end of a round. Outside the rows of a round refused and usage
#                               errors stay exceptions (64). Inside them REAPER may have been started already, so they are a
#                               round-error row like any other (INCOMPLETE): do not rethrow there, the checks would be skipped.
#   Write-HarnessResult         the result json
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

$script:LabelPattern = '^[0-9A-Za-z._-]{1,40}$'

# Reasons to skip the whole suite. Skip markers come first and end the check at once: someone is using the machine.
# Returns @{ Reasons; ReaperVersion; Plugins (id -> @{ Info; Sha256 } for bundles that could be read) }.
function Get-HarnessPreflight {
    param([Parameter(Mandatory)][string]$ReaperExe, [Parameter(Mandatory)][string]$PluginDir, [Parameter(Mandatory)]$Config, [string[]]$SkipMarkers = @(), [object[]]$ExtensionPreflight = @())
    $why = [Collections.Generic.List[string]]::new()
    $out = [ordered]@{ Reasons = $why; ReaperVersion = ''; Plugins = [ordered]@{} }
    $hit = Get-HarnessSkipMarkerHit $SkipMarkers
    if ($hit) { $why.Add("skip marker present: $(Split-Path -Leaf $hit) (someone is using this machine; REAPER is not started)"); return [pscustomobject]$out }
    if (Test-Path -LiteralPath $ReaperExe -PathType Leaf) { $out.ReaperVersion = [string](Get-Item -LiteralPath $ReaperExe).VersionInfo.ProductVersion } else { $why.Add('reaper.exe not found') }
    if (-not (Test-Path -LiteralPath $PluginDir -PathType Container)) { $why.Add('the plugin directory (-PluginDir) does not exist') }
    else {
        $names = @{}
        foreach ($p in @($Config.Plugins.get_Values() | Where-Object { $_.Kind -eq 'jsfx' })) {
            try { $null = Get-HarnessJsfxInfo $p.Jsfx } catch { $why.Add("plugin $($p.Id): $($_.Exception.Message -replace '^PLUGIN: ', '')") }
        }
        foreach ($p in @($Config.Plugins.get_Values() | Where-Object { $_.Kind -ne 'jsfx' })) {
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
# cases come after the configuration's own. An invalid regex, or nothing picked, is a usage error: a round with
# zero cases has no conclusion and must not end as PASS.
function Select-HarnessScenarios {
    param([Parameter(Mandatory)]$Config, [string]$Only = '', [switch]$NoNegative)
    if ($Only) { try { $null = [regex]::new($Only) } catch { Stop-Usage "-Only is not a valid regex: $($_.Exception.Message)" } }
    $positive = @($Config.Scenarios | Where-Object { -not $Only -or $_.id -match $Only })
    $all = @($Config.Negative) + @(Get-HarnessBuiltinNegatives)
    $negative = $NoNegative ? @() : @($all | Where-Object { -not $Only -or $_.id -match $Only })
    if ($positive.Count + $negative.Count -eq 0) {
        Stop-Usage ("-Only '{0}' picked no scenario{1}" -f $Only, ($NoNegative ? ' (negative cases are not run with -NoNegative)' : ''))
    }
    [pscustomobject]@{ Positive = $positive; Negative = $negative }
}

# Pure function: whether a scenario needs the learned plugin blocks (anything with a configured layout, instances,
# extension kinds). Built-in negative cases never do.
function Test-HarnessNeedsLearn($Scenario) {
    if ($Scenario.builtin) { return $false }
    if ($Scenario.kind -eq 'instances' -or $Scenario.kind -cnotin 'render', 'device', 'savereopen') { return $true }
    $p = $Scenario.PSObject.Properties
    if ($p['layout'] -and $Scenario.layout -and $Scenario.layout -notlike '@*') { return $true }
    [bool]($p['compare'] -and $Scenario.compare -and $Scenario.compare.Kind -eq 'variant' -and $Scenario.compare.Layout -notlike '@*')
}

function Write-HarnessLine([string]$Text) { Write-Host (Hide-HarnessPaths $Text) }

function Invoke-HarnessSuite {
    param(
        [string]$CfgDir = '', [Parameter(Mandatory)][string]$Config, [Parameter(Mandatory)][string]$PluginDir, [Parameter(Mandatory)][string]$ResultDir,
        [Parameter(Mandatory)][string]$ReaperExe, [string[]]$SkipMarker = @(), [string[]]$ExtraGuiLock = @(), [string]$Only = '', [int]$Repeat = 1,
        [switch]$NoNegative, [string]$BuildLabel = '', [switch]$KeepWork,
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
    $picked = Select-HarnessScenarios -Config $conf -Only $Only -NoNegative:$NoNegative # nothing picked: usage error, nothing started
    $pre = Get-HarnessPreflight -ReaperExe $ReaperExe -PluginDir $PluginDir -Config $conf -SkipMarkers $SkipMarker -ExtensionPreflight $ext.Preflight
    $Shas = [ordered]@{}
    foreach ($id in $pre.Plugins.get_Keys()) { $Shas[$id] = $pre.Plugins[$id].Sha256 }
    $result = [ordered]@{
        schema = 1; tool = 'reaper-harness'; config = $conf.Name; buildLabel = ($BuildLabel ? $BuildLabel : (Get-HarnessDefaultLabel $Shas))
        startedUtc = [DateTime]::UtcNow.ToString('o'); reaper = $pre.ReaperVersion; verdict = 'SKIPPED'; launches = 0
        skipReasons = @($pre.Reasons | ForEach-Object { Hide-HarnessPaths $_ }); locks = $locks; extensions = @($ext.Modules)
        plugins = @(); states = @(); pluginPath = $null; scanShield = $null; runs = @(); error = $null
    }
    if ($pre.Reasons.Count) { return [pscustomobject]$result }
    $infos = [ordered]@{}
    foreach ($id in $pre.Plugins.get_Keys()) { $infos[$id] = $pre.Plugins[$id].Info }
    Assert-HarnessStateIdentity -States $states -Infos $infos # a block of another plugin: usage error, nothing started

    $launches = 0
    try {
        $installed = Install-HarnessPlugins -Plugins $conf.Plugins -PluginDir $PluginDir
        $jsfx = Install-HarnessJsfx -Plugins $conf.Plugins
        $result.plugins = @($installed | ForEach-Object {
                [ordered]@{ id = $_.Id; bundle = $_.Bundle; name = (Get-HarnessReaperName $_.Info); version = $_.Info.Version; classId = $_.Info.Cid; sha256 = $_.Sha256.Substring(0, 12) }
            }) + @($jsfx | ForEach-Object { [ordered]@{ id = $_.Id; jsfx = $_.Jsfx; name = $_.Name; sha256 = $_.Sha256.Substring(0, 12) } })
        $result.states = @($states.get_Values() | ForEach-Object { [ordered]@{ plugin = $_.Plugin; state = $_.State; sha256 = $_.Sha } })
        $null = Set-HarnessPluginPath
        $result.pluginPath = 'system VST3 directories first, the private plugins directory last'
        $shield = Update-HarnessScanCache -Keep @($installed | ForEach-Object { $_.Bundle })
        $result.scanShield = [ordered]@{ directories = $shield.Dirs; files = $shield.Scanned; added = $shield.Added; replaced = $shield.Replaced; removed = $shield.Removed; unshielded = $shield.Unshielded }
        $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
        $driver = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../lua/driver.lua'))
        $all = @($picked.Positive) + @($picked.Negative)
        $needLearn = @($all | Where-Object { Test-HarnessNeedsLearn $_ }).Count -gt 0
        $variants = Get-HarnessLearnVariants -Config $conf -Scenarios @($all | Where-Object { Test-HarnessNeedsLearn $_ })
        $firstId = @($conf.Scenarios)[0].id
        $guardSet = @{ CfgDir = $CfgDir; Config = $Config; PluginDir = $PluginDir; ResultDir = $ResultDir; ReaperExe = $ReaperExe; SkipMarker = $SkipMarker; ExtraGuiLock = $ExtraGuiLock; SelfTestHooks = $SelfTestHooks }
        for ($k = 1; $k -le $Repeat; $k++) {
            $work = Join-Path $ResultDir "work/$stamp-run$k"
            $null = New-Item -ItemType Directory -Force -Path $work
            $before = Get-HarnessDefaultCfgSnapshot
            $ctx = New-HarnessContext -ReaperExe $ReaperExe -WorkDir $work -Driver $driver -Config $conf -Installed $installed -Jsfx $jsfx -States $states -Locks $locks -SkipMarkers $SkipMarker `
                -LuaExtensions $ext.Lua -Kinds $ext.Kinds
            if ($SelfTestHooks['Launcher']) { $ctx.Launcher = $SelfTestHooks['Launcher'] }
            if ($SelfTestHooks['ModuleSampler']) { $ctx.ModuleSampler = $SelfTestHooks['ModuleSampler'] }
            if ($SelfTestHooks['Stopper']) { $ctx.Stopper = $SelfTestHooks['Stopper'] }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $rows = [Collections.Generic.List[object]]::new()
            $NotRun = ''
            # What the end of the round works with if the rows below never get that far
            $mods = New-HarnessOutcome INCOMPLETE 'the module check did not run' ([ordered]@{ launches = 0; foreign = @(); otherPlugins = 0 })
            $brokenRound = $false
            try {
                if ($needLearn) {
                    $t0 = [Diagnostics.Stopwatch]::StartNew()
                    $o = try { Invoke-HarnessLearn -Ctx $ctx -Variants $variants } catch { New-HarnessOutcome INCOMPLETE "learning threw: $($_.Exception.Message -replace '\s+', ' ')" }
                    $row = [ordered]@{ id = 'learn'; kind = 'learn'; status = $o.Status; seconds = [math]::Round($t0.Elapsed.TotalSeconds, 1); detail = (Hide-HarnessPaths $o.Detail) }
                    # No path in these today (counts, verdicts, file names, state names); masked like every other row all the same
                    if ($o.PSObject.Properties['Facts']) { $row.facts = Hide-HarnessFacts $o.Facts }
                    $rows.Add($row)
                    Write-HarnessLine ("  [{0}] learn  {1} s  {2}" -f $o.Status, $row.seconds, $o.Detail)
                    if ($o.Status -ne 'PASS') { $NotRun = 'not run: learning the plugin blocks did not succeed (see the learn row)' }
                }
                foreach ($s in $picked.Positive) {
                    if ($NotRun -and (Test-HarnessNeedsLearn $s)) { $o = New-HarnessOutcome INCOMPLETE $NotRun | Add-Member -NotePropertyName Seconds -NotePropertyValue 0 -PassThru }
                    else { $o = Invoke-HarnessScenario -Ctx $ctx -Scenario $s }
                    $row = [ordered]@{ id = $s.id; kind = $s.kind; status = $o.Status; seconds = $o.Seconds; detail = (Hide-HarnessPaths $o.Detail) }
                    if ($o.PSObject.Properties['Facts']) { $row.facts = Hide-HarnessFacts $o.Facts }
                    $rows.Add($row)
                    Write-HarnessLine ("  [{0}] {1}  {2} s  {3}" -f $o.Status, $s.id, $o.Seconds, $o.Detail)
                }
                foreach ($s in $picked.Negative) {
                    $skip = ($NotRun -and (Test-HarnessNeedsLearn $s)) ? $NotRun : ''
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
                moduleCheck = [ordered]@{ status = $mods.Status; detail = (Hide-HarnessPaths $mods.Detail); launches = $mods.Facts.launches; foreign = @($mods.Facts.foreign); otherPlugins = $mods.Facts.otherPlugins }
                scenarios = $rows.ToArray()
            }
            $result.runs += $runRow
            Write-HarnessLine ("round {0}/{1}: {2}, {3} s, REAPER started {4} times, module check {5}, default resource directory {6}" -f $k, $Repeat, $verdict, $runRow.seconds, $ctx.Launches, $mods.Status,
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

# <ResultDir>/<yyyyMMdd-HHmmss>-<config name>-<build label>.json (UTF-8 without BOM). Returns the path.
function Write-HarnessResult {
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$ResultDir)
    $null = New-Item -ItemType Directory -Force -Path $ResultDir
    $path = Join-Path $ResultDir ('{0}-{1}-{2}.json' -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss'), $Data.config, $Data.buildLabel)
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

Export-ModuleMember -Function Get-HarnessPreflight, Get-HarnessDefaultLabel, Get-HarnessWorstStatus, Get-HarnessCfgChangesSeen, Get-HarnessRunVerdict, Get-HarnessRoundStop, Get-HarnessNegativeVerdict,
    Invoke-HarnessGuardNegative, Invoke-HarnessNegativeRow, Select-HarnessScenarios, Test-HarnessNeedsLearn, Invoke-HarnessSuite, Write-HarnessResult, Complete-HarnessRun
