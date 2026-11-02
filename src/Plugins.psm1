# SPDX-License-Identifier: MIT
#
# Plugin bundles under test, and keeping every other plugin on the machine out of the test process.
#   Read-HarnessModuleInfo -Bundle <dir>
#       the bundle's Contents\Resources\moduleinfo.json: Name, Vendor, Version and the class ID of the audio
#       processor (the "Audio Module Class"); throws "PLUGIN: ..." when it is missing or unreadable
#   Get-HarnessBundleBinary -Bundle <dir>
#       Contents\x86_64-win\<name>.vst3 inside the bundle (the file Windows actually loads)
#   Install-HarnessPlugins -Plugins <config plugins> -PluginDir <dir>
#       copies each configured bundle into the private configuration directory (plugins\), replacing an older
#       copy, and returns one row per plugin (paths, sha256 of the binary, moduleinfo)
#   Get-HarnessJsfxInfo / Install-HarnessJsfx
#       the JSFX shipped in jsfx/ (name REAPER shows, how to add it, its path under Effects), copied into the
#       private configuration directory (Effects\reaper-harness\) for the plugins configured with "jsfx"
#   Update-HarnessScanCache -Keep <bundle names>
#       the scan shield, see below
#   Set-HarnessPluginPath
#       vstpath64 of the private ini with the private plugins directory last (see Get-HarnessPluginPathValue)
#
# Why the scan shield: REAPER appends the system VST3 directories to the plugin path itself, whatever the private
# reaper.ini says, and on startup it loads every plugin file it has no up-to-date cache entry for. On a machine with
# many plugins that means third-party code runs inside the test process: a newly installed plugin can show an
# activation dialog or hang the scan for minutes, and a release build of the plugin under test in a system directory
# shares the file name (and the class ID) with the private copy. The cache (reaper-vstplugins64.ini, keyed by file
# name; the value starts with the binary's last write time) is what REAPER trusts, so before every round each file
# REAPER would scan outside the private plugins directory gets an entry that says "scanned, nothing here" when it
# has no current one. REAPER then never loads them. The entries of the configured bundles are removed instead, so
# REAPER scans the private copies afresh. Only the private configuration directory is written; the plugins
# themselves and the system directories are only listed.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Guard.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Json.psm1') -ErrorAction Stop

function Stop-Plugin([string]$Why) { throw [System.InvalidOperationException]::new("PLUGIN: $Why") }

function Get-HarnessBundleBinary([Parameter(Mandatory)][string]$Bundle) {
    $leaf = Split-Path -Leaf $Bundle
    Join-Path $Bundle (Join-Path 'Contents\x86_64-win' $leaf)
}

function Read-HarnessModuleInfo([Parameter(Mandatory)][string]$Bundle) {
    $leaf = Split-Path -Leaf $Bundle
    $file = Join-Path $Bundle 'Contents\Resources\moduleinfo.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Stop-Plugin "$leaf has no Contents\Resources\moduleinfo.json" }
    try { $info = ConvertFrom-HarnessJson ([IO.File]::ReadAllText($file)) -Lenient } catch { Stop-Plugin "$leaf moduleinfo.json cannot be read: $($_.Exception.Message)" }
    $audio = @()
    if ($info -is [System.Collections.IDictionary] -and $info['Classes'] -is [object[]]) {
        $audio = @($info['Classes'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['Category'] -ceq 'Audio Module Class' })
    }
    if ($audio.Count -ne 1) { Stop-Plugin "$leaf moduleinfo.json must list exactly one Audio Module Class (found $($audio.Count))" }
    $c = $audio[0]
    $cid = [string]$c['CID']
    if ($cid -notmatch '^[0-9A-Fa-f]{32}$') { Stop-Plugin "$leaf moduleinfo.json has no valid CID for its Audio Module Class" }
    $factory = $info['Factory Info']
    $vendor = [string]($c['Vendor'] ?? ($factory -is [System.Collections.IDictionary] ? $factory['Vendor'] : ''))
    $className = [string]($c['Name'] ?? $info['Name'])
    if (-not $className -or -not $vendor) { Stop-Plugin "$leaf moduleinfo.json has no Name or Vendor for its Audio Module Class" }
    [pscustomobject]@{ Name = $className; Vendor = $vendor; Version = [string]($c['Version'] ?? $info['Version'] ?? ''); Cid = $cid.ToUpperInvariant() }
}

function Get-HarnessSha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

# Plugins: the Plugins table of a normalised configuration (id -> @{ Id; Kind; Bundle; ... }); JSFX are left to
# Install-HarnessJsfx. Returns rows with Id,
# Bundle, Source (bundle under PluginDir), Private (bundle in the private plugins directory), Binary (private binary),
# BinaryLeaf, Sha256 (of the binary, full), Info (moduleinfo).
function Install-HarnessPlugins {
    param([Parameter(Mandatory)]$Plugins, [Parameter(Mandatory)][string]$PluginDir)
    $cfgDir = Get-HarnessPinnedCfgDir
    $target = Join-Path $cfgDir 'plugins'
    if (-not (Test-HarnessUnder $target $cfgDir)) { throw "the private plugins directory is not inside the configuration directory" }
    $null = New-Item -ItemType Directory -Force -Path $target
    $rows = foreach ($p in @($Plugins.get_Values() | Where-Object { $_.Kind -ne 'jsfx' })) {
        $src = Join-Path $PluginDir $p.Bundle
        $info = Read-HarnessModuleInfo $src
        $bin = Get-HarnessBundleBinary $src
        if (-not (Test-Path -LiteralPath $bin -PathType Leaf)) { Stop-Plugin "$($p.Bundle) has no Contents\x86_64-win\$($p.Bundle) binary" }
        $dst = Join-Path $target $p.Bundle
        if (Test-Path -LiteralPath $dst) {
            if (-not (Test-HarnessUnder $dst $target)) { throw "refusing to replace $($p.Bundle): not inside the private plugins directory" }
            Remove-Item -LiteralPath $dst -Recurse -Force
        }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse
        $privateBin = Get-HarnessBundleBinary $dst
        $sha = Get-HarnessSha256 $privateBin
        if ($sha -cne (Get-HarnessSha256 $bin)) { Stop-Plugin "$($p.Bundle) changed while it was being copied" }
        [pscustomobject]@{ Id = $p.Id; Bundle = $p.Bundle; Source = $src; Private = $dst; Binary = $privateBin; BinaryLeaf = (Split-Path -Leaf $privateBin); Sha256 = $sha; Info = $info }
    }
    , @($rows)
}

$script:JsfxDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../jsfx'))

# A JSFX shipped with the tool (jsfx/<name>.jsfx): the name REAPER shows ("JS: " and its desc line), the name to add
# it by, and its path under the Effects directory as fx_ident and the saved block give it.
function Get-HarnessJsfxInfo([Parameter(Mandatory)][string]$Name) {
    $file = Join-Path $script:JsfxDir "$Name.jsfx"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Stop-Plugin "the JSFX $Name.jsfx is missing from the tool's jsfx directory" }
    $desc = @([IO.File]::ReadAllLines($file) | Where-Object { $_ -match '^desc:' } | Select-Object -First 1)
    if (-not $desc.Count) { Stop-Plugin "$Name.jsfx has no desc line" }
    $rel = "reaper-harness/$Name.jsfx"
    [pscustomobject]@{ Name = 'JS: ' + ($desc[0] -replace '^desc:', '').Trim(); AddName = "JS:$rel"; Ident = $rel; Source = $file; Sha256 = (Get-HarnessSha256 $file) }
}

# Copies the JSFX of the plugins configured with "jsfx" into Effects\reaper-harness\ of the private configuration
# directory. Returns one row per such plugin: Id, Jsfx, Name, AddName, Ident, Sha256.
function Install-HarnessJsfx {
    param([Parameter(Mandatory)]$Plugins)
    $cfgDir = Get-HarnessPinnedCfgDir
    $target = Join-Path $cfgDir 'Effects\reaper-harness'
    if (-not (Test-HarnessUnder $target $cfgDir)) { throw 'the private Effects directory is not inside the configuration directory' }
    $rows = foreach ($p in @($Plugins.get_Values() | Where-Object { $_.Kind -eq 'jsfx' })) {
        $info = Get-HarnessJsfxInfo $p.Jsfx
        $null = New-Item -ItemType Directory -Force -Path $target
        $dst = Join-Path $target "$($p.Jsfx).jsfx"
        Copy-Item -LiteralPath $info.Source -Destination $dst -Force
        if ((Get-HarnessSha256 $dst) -cne $info.Sha256) { Stop-Plugin "$($p.Jsfx).jsfx changed while it was being copied" }
        [pscustomobject]@{ Id = $p.Id; Jsfx = $p.Jsfx; Name = $info.Name; AddName = $info.AddName; Ident = $info.Ident; Sha256 = $info.Sha256 }
    }
    , @($rows)
}

# REAPER's cache key for a plugin file: the file name with every character other than ASCII letters, digits and '.'
# replaced by '_' (checked against the cache REAPER writes). Returns $null for names with non-ASCII characters,
# whose mapping is not known; those are reported as not shielded.
function Get-HarnessCacheKey([Parameter(Mandatory)][string]$Name) {
    if ($Name -match '[^\x20-\x7e]') { return $null }
    $Name -replace '[^A-Za-z0-9.]', '_'
}

# The time stamp REAPER stores: the FILETIME of the binary's last write, as 16 hex digits in little-endian byte order.
function ConvertTo-HarnessCacheStamp([datetime]$LastWriteUtc) {
    -join ([BitConverter]::GetBytes($LastWriteUtc.ToFileTimeUtc()) | ForEach-Object { $_.ToString('X2') })
}

# Pure function (the self-test drives it directly). Text: the cache file. Items: what REAPER would scan, in its order,
# each @{ Key; Stamp } (several items can share a key). Keep: keys of the configured bundles. Every [vstcache] line of
# a kept key is removed. For any other key whose cached stamp matches none of its items (or that has no line), its
# lines (including "key<n=" sub-entries of shell plugins) are replaced by one "key=<stamp of the first item>".
# Everything else stays byte for byte. Returns @{ Text; Added; Replaced; Removed }.
function Update-HarnessScanCacheText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [object[]]$Items = @(), [string[]]$Keep = @())
    $eol = $Text.Contains("`r`n") ? "`r`n" : "`n"
    $lines = [Collections.Generic.List[string]]::new([string[]]($Text -split '\r?\n'))
    if ($lines.Count -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    $head = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq '[vstcache]') { $head = $i; break } }
    if ($head -lt 0) { $lines.Insert(0, '[vstcache]'); $head = 0 }
    $end = $head + 1
    while ($end -lt $lines.Count -and -not $lines[$end].TrimStart().StartsWith('[')) { $end++ }
    $keyOf = {
        param([string]$Line)
        $eq = $Line.IndexOf('='); if ($eq -lt 1) { return $null }
        $k = $Line.Substring(0, $eq); $lt = $k.IndexOf('<')
        ($lt -ge 0) ? $k.Substring(0, $lt) : $k
    }
    $stamps = @{}
    for ($i = $head + 1; $i -lt $end; $i++) {
        $eq = $lines[$i].IndexOf('=')
        if ($eq -lt 1 -or $lines[$i].Substring(0, $eq).Contains('<')) { continue }
        $stamps[$lines[$i].Substring(0, $eq)] = $lines[$i].Substring($eq + 1).Split(',')[0]
    }
    $want = [ordered]@{}
    foreach ($it in $Items) {
        if ($it.Key -cin $Keep) { continue }
        if (-not $want.Contains($it.Key)) { $want[$it.Key] = [Collections.Generic.List[string]]::new() }
        $want[$it.Key].Add($it.Stamp)
    }
    $drop = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($k in $Keep) { $null = $drop.Add($k) }
    $write = [Collections.Generic.List[string]]::new()
    $added = 0; $replaced = 0
    foreach ($k in $want.get_Keys()) {
        if ($stamps.ContainsKey($k) -and $want[$k] -ccontains $stamps[$k]) { continue }
        if ($stamps.ContainsKey($k)) { $replaced++ } else { $added++ }
        $null = $drop.Add($k)
        $write.Add("$k=$($want[$k][0])")
    }
    $removed = 0
    $out = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -gt $head -and $i -lt $end) {
            $k = & $keyOf $lines[$i]
            if ($null -ne $k -and $drop.Contains($k)) { if ($k -cin $Keep) { $removed++ }; continue }
        }
        $out.Add($lines[$i])
        if ($i -eq $head) { $out.AddRange($write) }
    }
    [pscustomobject]@{ Text = ($out -join $eol) + $eol; Added = $added; Replaced = $replaced; Removed = $removed }
}

# Pure function: the vstpath64 value with the private plugins directory last. REAPER keeps one plugin per file name
# and the directory scanned last wins (measured on REAPER 7: with the private directory first, a release build of the
# same name in the system VST3 directory was loaded instead of the private copy). REAPER appends its two system VST3
# directories when they are missing, so they are written explicitly before the private directory.
function Get-HarnessPluginPathValue {
    param([AllowEmptyString()][string]$Current = '', [Parameter(Mandatory)][string]$Private)
    $same = { param($a, $b) [string]::Equals($a.TrimEnd('\'), $b.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) }
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($p in @($Current -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if (& $same ([Environment]::ExpandEnvironmentVariables($p)) $Private) { continue }
        if (-not ($parts | Where-Object { & $same $_ $p })) { $parts.Add($p) }
    }
    foreach ($d in $script:SystemVst3Dirs) { if (-not ($parts | Where-Object { & $same $_ $d })) { $parts.Add($d) } }
    $parts.Add($Private)
    $parts -join ';'
}

$script:SystemVst3Dirs = '%COMMONPROGRAMFILES%\VST3', '%LOCALAPPDATA%\Programs\Common\VST3'

# Writes that order into the pinned private ini. Returns whether the ini changed.
function Set-HarnessPluginPath {
    $cfgDir = Get-HarnessPinnedCfgDir
    $ini = [IO.File]::ReadAllText((Join-Path $cfgDir 'reaper.ini'), [Text.Encoding]::Latin1)
    $m = [regex]::Match($ini, '(?im)^vstpath64=(.*)$')
    $value = Get-HarnessPluginPathValue -Current ($m.Success ? $m.Groups[1].Value.Trim() : '') -Private (Join-Path $cfgDir 'plugins')
    Set-HarnessIniValue -Section REAPER -Key vstpath64 -Value $value
}

# The directories REAPER scans for VST plugins: the vstpath64 of the private ini plus the two system VST3 directories
# REAPER always appends. The private plugins directory is excluded (its bundles are the ones under test).
function Get-HarnessForeignScanDirs {
    $cfgDir = Get-HarnessPinnedCfgDir
    $privateDir = Join-Path $cfgDir 'plugins'
    $ini = [IO.File]::ReadAllText((Join-Path $cfgDir 'reaper.ini'), [Text.Encoding]::Latin1)
    $m = [regex]::Match($ini, '(?im)^vstpath64=(.*)$')
    $listed = $m.Success ? @($m.Groups[1].Value.Trim() -split ';' | Where-Object { $_ }) : @()
    $found = [Collections.Generic.List[string]]::new()
    foreach ($d in @($listed) + $script:SystemVst3Dirs) {
        $x = [Environment]::ExpandEnvironmentVariables($d).TrimEnd('\')
        if (-not $x -or -not [IO.Path]::IsPathRooted($x)) { continue }
        if ([string]::Equals([IO.Path]::GetFullPath($x), [IO.Path]::GetFullPath($privateDir), [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not ($found | Where-Object { [string]::Equals($_, $x, [StringComparison]::OrdinalIgnoreCase) })) { $found.Add($x) }
    }
    , $found.ToArray()
}

# Files REAPER would scan under Dirs: *.vst3 bundles and files and *.dll files, recursively, but nothing inside a
# .vst3 bundle. Stamp: the last write time of the binary (inside a bundle: Contents\x86_64-win\<name>). Bundles
# without a Windows binary are skipped (REAPER cannot load them). Returns @{ Items; Unshielded (count of names
# without a known key) }.
function Get-HarnessScanItems([string[]]$Dirs) {
    $scanned = [Collections.Generic.List[object]]::new()
    $unshielded = 0
    foreach ($d in $Dirs) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        $queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue($d)
        while ($queue.Count) {
            $dir = $queue.Dequeue()
            $children = try { @([IO.DirectoryInfo]::new($dir).GetFileSystemInfos() | Sort-Object Name) } catch { @() }
            foreach ($c in $children) {
                $isDir = $c -is [IO.DirectoryInfo]
                if ($c.Name -match '\.vst3$') {
                    $bin = $isDir ? (Join-Path $c.FullName (Join-Path 'Contents\x86_64-win' $c.Name)) : $c.FullName
                    if (-not (Test-Path -LiteralPath $bin -PathType Leaf)) { continue }
                } elseif (-not $isDir -and $c.Name -match '\.dll$') {
                    $bin = $c.FullName
                } else {
                    if ($isDir -and -not ($c.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $queue.Enqueue($c.FullName) }
                    continue
                }
                $key = Get-HarnessCacheKey $c.Name
                if ($null -eq $key) { $unshielded++; continue }
                $scanned.Add([pscustomobject]@{ Key = $key; Stamp = (ConvertTo-HarnessCacheStamp ([IO.File]::GetLastWriteTimeUtc($bin))) })
            }
        }
    }
    [pscustomobject]@{ Items = $scanned.ToArray(); Unshielded = $unshielded }
}

# The scan shield for the pinned private configuration. Keep: bundle directory names of the configured plugins.
# Returns @{ Dirs; Scanned; Added; Replaced; Removed; Unshielded }.
function Update-HarnessScanCache {
    param([string[]]$Keep = @())
    $cfgDir = Get-HarnessPinnedCfgDir
    $cache = Join-Path $cfgDir 'reaper-vstplugins64.ini'
    $scanDirs = Get-HarnessForeignScanDirs
    $scan = Get-HarnessScanItems $scanDirs
    $enc = [Text.Encoding]::Latin1
    $old = (Test-Path -LiteralPath $cache -PathType Leaf) ? $enc.GetString([IO.File]::ReadAllBytes($cache)) : "[vstcache]`r`n"
    $keys = @($Keep | ForEach-Object { Get-HarnessCacheKey $_ } | Where-Object { $_ })
    $r = Update-HarnessScanCacheText -Text $old -Items $scan.Items -Keep $keys
    if ($r.Text -cne $old) { [IO.File]::WriteAllBytes($cache, $enc.GetBytes($r.Text)) }
    [pscustomobject]@{ Dirs = $scanDirs.Count; Scanned = $scan.Items.Count; Added = $r.Added; Replaced = $r.Replaced; Removed = $r.Removed; Unshielded = $scan.Unshielded }
}

Export-ModuleMember -Function Read-HarnessModuleInfo, Get-HarnessBundleBinary, Install-HarnessPlugins, Get-HarnessJsfxInfo, Install-HarnessJsfx, Get-HarnessCacheKey, ConvertTo-HarnessCacheStamp, Update-HarnessScanCacheText,
    Get-HarnessForeignScanDirs, Get-HarnessScanItems, Update-HarnessScanCache, Get-HarnessSha256, Get-HarnessPluginPathValue, Set-HarnessPluginPath
