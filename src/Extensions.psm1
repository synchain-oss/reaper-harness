# SPDX-License-Identifier: MIT
#
# Extensions: PowerShell modules that add scenario kinds (and optional preflight checks), and Lua files that add
# driver steps. Both are listed in the configuration (extensions.modules / extensions.lua) relative to the directory
# of the configuration file. Everything here happens before REAPER is started, and every problem is a usage error
# (exit 64): a path that leaves the configuration directory (also after junctions and symbolic links are resolved),
# a missing file, a module that does not export Register-HarnessExtension or returns something else than the
# contract, a kind or step name that is already taken.
#   Resolve-HarnessExtensionPath  one listed path, checked
#   Get-HarnessLuaSteps           the step names a Lua file declares in its "-- harness-steps:" line
#   Test-HarnessRegistration      checks what a registration function returned (pure)
#   Import-HarnessExtensions      all of it for one configuration
# Contract (docs/EXTENDING.md): Register-HarnessExtension takes no arguments and returns
#   @{ Name = '<id>'
#      Kinds = @{ '<kind>' = @{ Validate = { param($Item) <problem strings> }; Run = { param($Ctx, $Scenario) <outcome> } } }
#      Preflight = { param($Config) <reasons to skip the whole suite> } }   # Kinds or Preflight, or both

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Guard.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -ErrorAction Stop

$script:NamePattern = '^[a-z][a-z0-9-]{0,39}$'
$script:TakenKinds = 'render', 'device', 'savereopen', 'instances', 'transport', 'hang', 'guard'
$script:TakenSteps = 'learn', 'device', 'savereopen', 'instances', 'transport', 'hang'
$script:Loaded = @{}
$script:OwnModules ='Config', 'Extensions', 'Guard', 'Host', 'Json', 'Learn', 'Locks', 'Plugins', 'Rpp', 'Scenarios', 'States', 'Suite', 'Transport', 'Wav', 'SelfTest', 'TempDir'

# Relative is a path from the configuration file; the result is the real full path of an existing file inside
# ConfigDir. Absolute paths, drive-relative paths and anything that resolves outside are refused. What names the
# kind of file in the messages (state files and templates use the same rules).
function Resolve-HarnessExtensionPath {
    param([Parameter(Mandatory)][string]$ConfigDir, [Parameter(Mandatory)][string]$Relative, [string]$What = 'extension')
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '^[A-Za-z]:') { Stop-Usage "$What path '$Relative' must be relative to the configuration file" }
    $full = [IO.Path]::GetFullPath((Join-Path $ConfigDir $Relative))
    $realDir = Resolve-HarnessRealPath $ConfigDir
    $real = Resolve-HarnessRealPath $full
    if (-not (Test-HarnessUnder $full $ConfigDir) -or -not (Test-HarnessUnder $real $realDir)) {
        Stop-Usage "$What path '$Relative' leaves the directory of the configuration file"
    }
    if (-not (Test-Path -LiteralPath $real -PathType Leaf)) { Stop-Usage "$What file not found: $Relative" }
    $real
}

# The first line of the form "-- harness-steps: a, b" (within the first 20 lines) names the steps the file adds.
function Get-HarnessLuaSteps([Parameter(Mandatory)][string]$Path) {
    $head = @([IO.File]::ReadLines($Path) | Select-Object -First 20)
    $line = $head | Where-Object { $_ -cmatch '^--\s*harness-steps:' } | Select-Object -First 1
    if (-not $line) { Stop-Usage "$(Split-Path -Leaf $Path): no '-- harness-steps: <names>' line in the first 20 lines" }
    $names = @(($line -creplace '^--\s*harness-steps:', '') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $names.Count) { Stop-Usage "$(Split-Path -Leaf $Path): the harness-steps line names no step" }
    foreach ($n in $names) { if ($n -cnotmatch '^[a-z][a-z0-9_]{0,39}$') { Stop-Usage "$(Split-Path -Leaf $Path): step name '$n' must match ^[a-z][a-z0-9_]{0,39}$" } }
    , $names
}

# Pure function: problems with one registration. Taken: kind names already in use (built-in or registered before).
function Test-HarnessRegistration {
    param([AllowNull()]$Registration, [string]$Source, [string[]]$Taken = @(), [string[]]$TakenNames = @())
    $bad = [Collections.Generic.List[string]]::new()
    if ($Registration -isnot [System.Collections.IDictionary]) { $bad.Add("${Source}: Register-HarnessExtension must return a hashtable"); return , $bad.ToArray() }
    foreach ($k in $Registration.get_Keys()) { if ($k -cnotin 'Name', 'Kinds', 'Preflight') { $bad.Add("${Source}: unknown key '$k' in the registration") } }
    $name = $Registration['Name']
    if ($name -isnot [string] -or $name -cnotmatch $script:NamePattern) { $bad.Add("${Source}: Name must match $($script:NamePattern)") }
    elseif ($name -cin $TakenNames) { $bad.Add("${Source}: extension name '$name' is already registered") }
    $kinds = $Registration['Kinds']
    $pre = $Registration['Preflight']
    if ($null -eq $kinds -and $null -eq $pre) { $bad.Add("${Source}: the registration has neither Kinds nor Preflight") }
    if ($null -ne $pre -and $pre -isnot [scriptblock]) { $bad.Add("${Source}: Preflight must be a script block") }
    if ($null -ne $kinds) {
        if ($kinds -isnot [System.Collections.IDictionary]) { $bad.Add("${Source}: Kinds must be a hashtable") }
        else {
            foreach ($k in $kinds.get_Keys()) {
                if ($k -isnot [string] -or $k -cnotmatch $script:NamePattern) { $bad.Add("${Source}: kind name '$k' must match $($script:NamePattern)"); continue }
                if ($k -cin $Taken) { $bad.Add("${Source}: kind '$k' is already defined"); continue }
                $d = $kinds[$k]
                if ($d -isnot [System.Collections.IDictionary]) { $bad.Add("${Source}: kind '$k' must be a hashtable with Validate and Run"); continue }
                foreach ($x in $d.get_Keys()) { if ($x -cnotin 'Validate', 'Run') { $bad.Add("${Source}: kind '$k' has an unknown key '$x'") } }
                foreach ($x in 'Validate', 'Run') { if ($d[$x] -isnot [scriptblock]) { $bad.Add("${Source}: kind '$k' needs $x as a script block") } }
            }
        }
    }
    , $bad.ToArray()
}

# Imports the extensions of one configuration (the result of Read-HarnessConfigExtensions). Returns @{ Kinds (kind
# -> @{ Validate; Run; Extension }); Preflight (list of @{ Extension; Run }); Modules (names); Lua (real paths);
# LuaSteps (names) }.
function Import-HarnessExtensions {
    param([Parameter(Mandatory)]$Extensions)
    $kinds = @{}
    $Preflight = [Collections.Generic.List[object]]::new()
    $names = [Collections.Generic.List[string]]::new()
    $bases = [Collections.Generic.List[string]]::new()
    foreach ($rel in $Extensions.Modules) {
        $Path = Resolve-HarnessExtensionPath -ConfigDir $Extensions.ConfigDir -Relative $rel
        $base = [IO.Path]::GetFileNameWithoutExtension($Path)
        if ($base -in $script:OwnModules) { Stop-Usage "extension module '$rel' has the name of one of the harness's own modules" }
        if ($base -in $bases) { Stop-Usage "two extension modules are named '$base'" }
        $bases.Add($base)
        # Imported once per process: the guard negative cases run the entry point again, and a forced re-import would
        # replace the module whose handlers the running round holds
        $m = $script:Loaded[$Path]
        if (-not $m) {
            $m = try { Import-Module -Name $Path -PassThru -DisableNameChecking -ErrorAction Stop } catch { Stop-Usage "extension module '$rel' failed to load: $($_.Exception.Message)" }
            $script:Loaded[$Path] = $m
        }
        $fn = $m.ExportedCommands['Register-HarnessExtension']
        if (-not $fn) { Stop-Usage "extension module '$rel' does not export Register-HarnessExtension" }
        $reg = try { & $fn } catch { Stop-Usage "Register-HarnessExtension of '$rel' threw: $($_.Exception.Message)" }
        $bad = Test-HarnessRegistration -Registration $reg -Source $rel -Taken (@($script:TakenKinds) + @($kinds.get_Keys())) -TakenNames $names
        if ($bad.Count) { Stop-Usage ($bad -join '; ') }
        $names.Add($reg.Name)
        if ($reg['Kinds']) { foreach ($k in $reg.Kinds.get_Keys()) { $kinds[$k] = @{ Validate = $reg.Kinds[$k].Validate; Run = $reg.Kinds[$k].Run; Extension = $reg.Name } } }
        if ($reg['Preflight']) { $Preflight.Add([pscustomobject]@{ Extension = $reg.Name; Run = $reg.Preflight }) }
    }
    $lua = [Collections.Generic.List[string]]::new()
    $steps = [Collections.Generic.List[string]]::new()
    foreach ($rel in $Extensions.Lua) {
        $Path = Resolve-HarnessExtensionPath -ConfigDir $Extensions.ConfigDir -Relative $rel
        foreach ($s in (Get-HarnessLuaSteps $Path)) {
            if ($s -cin $script:TakenSteps -or $s -cin $steps) { Stop-Usage "Lua step '$s' of '$rel' is already defined" }
            $steps.Add($s)
        }
        $lua.Add($Path)
    }
    [pscustomobject]@{ Kinds = $kinds; Preflight = $Preflight.ToArray(); Modules = $names.ToArray(); Lua = $lua.ToArray(); LuaSteps = $steps.ToArray() }
}

# Runs the preflight checks of the extensions; each returns reasons (strings) to skip the whole suite. A check that
# throws is a reason too (it could not prove that running is safe).
function Invoke-HarnessExtensionPreflight {
    param([object[]]$Preflight = @(), [Parameter(Mandatory)]$Config)
    $why = [Collections.Generic.List[string]]::new()
    foreach ($p in $Preflight) {
        try { foreach ($r in @(& $p.Run $Config)) { if ($r) { $why.Add("extension $($p.Extension): $r") } } }
        catch { $why.Add("extension $($p.Extension): the preflight check threw: $($_.Exception.Message -replace '\s+', ' ')") }
    }
    , $why.ToArray()
}

Export-ModuleMember -Function Resolve-HarnessExtensionPath, Get-HarnessLuaSteps, Test-HarnessRegistration, Import-HarnessExtensions, Invoke-HarnessExtensionPreflight
