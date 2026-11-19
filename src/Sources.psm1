# SPDX-License-Identifier: MIT
#
# WAV files of the configuration as the sources of tracks (layouts.<id>.tracks[].file).
#   Read-HarnessSourceFiles -Config <config> -Scenarios <picked>
#       before REAPER starts: every file the layouts of the picked scenarios use (their own layout and the layout they
#       compare with) is resolved like an extension path, its header read once (no samples) and checked: pcm16, pcm24
#       or float32 (what a 32-bit float render carries exactly), 1 or 2 channels, 1 frame to 600 s; its SHA-256 taken.
#       Every such scenario must run at the file's rate (nothing is resampled), and a mono render cannot take a file of
#       two channels (nothing is mixed down). All problems are one usage error: REAPER is never started. Returns the
#       files by key (Get-HarnessSourceKey): Rel, Path, Sha256 (full), Frames, Channels, Rate, Format, Length.
#   Copy-HarnessSourceFiles -Ctx -Sources   each round: every file once into the work directory as _source-<12 hex>.wav,
#       registered for cleanup, its hash and its header checked against those taken before the start (a copy that fails
#       is deleted); REAPER only sees the copy (it writes peak files next to a source, never into the directory of the
#       configuration)
#   Get-HarnessSourceGap -Ctx -Scenario      why a scenario cannot use its files in this round, or $null
#   Get-HarnessSourceCopy -Ctx -File         the checked copy of a track's file (throws when there is none)
#   Get-HarnessItemLength -Frames -Rate      (pure) the item length that holds every frame of a file
#   Get-HarnessSourceKey -ConfigDir -Relative (pure) a file as the result names it: relative, forward slashes
#   ConvertTo-HarnessSourceFact <file>       a file as the result and the manifest list it

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Extensions.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Plugins.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Wav.psm1') -ErrorAction Stop

$script:Formats = 'pcm16', 'pcm24', 'float32'
$script:MaxSeconds = 600 # the same cap as signal.seconds

# A path that is not relative stays as it is written (Resolve-HarnessExtensionPath refuses it)
function Get-HarnessSourceKey([Parameter(Mandatory)][string]$ConfigDir, [Parameter(Mandatory)][string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '^[A-Za-z]:') { return $Relative }
    [IO.Path]::GetRelativePath($ConfigDir, [IO.Path]::GetFullPath((Join-Path $ConfigDir $Relative))) -replace '\\', '/'
}

# Frames / rate is not always enough: 13 / 44100 * 44100 is 12.999999999999998, and a length REAPER turns into samples
# by cutting off the fraction would lose the last frame. The length is the double whose product with the rate is frames
# exactly, or else the smallest one above.
function Get-HarnessItemLength([long]$Frames, [int]$Rate) {
    $l = $Frames / [double]$Rate
    foreach ($c in [Math]::BitDecrement($l), $l, [Math]::BitIncrement($l)) { if ($c * $Rate -eq $Frames) { return $c } }
    while ($l * $Rate -lt $Frames) { $l = [Math]::BitIncrement($l) }
    $l
}

function Get-HarnessTrackFile($Track) { ($Track.PSObject.Properties['File'] -and $Track.File) ? [string]$Track.File : '' }

# The file keys a scenario's layouts use (its own and the one it compares with), each once.
function Get-HarnessScenarioSourceKeys($Config, $Scenario) {
    $ids = [Collections.Generic.List[string]]::new()
    if ($Scenario.PSObject.Properties['layout'] -and $Scenario.layout -is [string]) { $ids.Add($Scenario.layout) }
    if ($Scenario.PSObject.Properties['compare'] -and $Scenario.compare -and $Scenario.compare.Kind -ceq 'variant') { $ids.Add($Scenario.compare.Layout) }
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $ids) {
        if (-not $Config.Layouts.Contains($id)) { continue }
        foreach ($t in $Config.Layouts[$id].Tracks) { $f = Get-HarnessTrackFile $t; if ($t.Source -and $f) { $null = $keys.Add((Get-HarnessSourceKey $Config.ConfigDir $f)) } }
    }
    , @($keys)
}

function Read-HarnessSourceFiles {
    param([Parameter(Mandatory)]$Config, [object[]]$Scenarios = @())
    $bad = [Collections.Generic.List[string]]::new()
    $files = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::OrdinalIgnoreCase)
    $unusable = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $Scenarios) {
        foreach ($key in (Get-HarnessScenarioSourceKeys $Config $s)) {
            if (-not $files.Contains($key) -and -not $unusable.Contains($key)) {
                $why = @()
                try {
                    $path = Resolve-HarnessExtensionPath -ConfigDir $Config.ConfigDir -Relative $key -What 'source'
                    $w = Read-HarnessWavHeader $path
                    if ($w.Format -cnotin $script:Formats) { $why += "is $($w.Format): only pcm16, pcm24 and float32 are accepted (what a 32-bit float render carries exactly)" }
                    if ($w.Channels -notin 1, 2) { $why += "has $($w.Channels) channels: 1 or 2 are accepted" }
                    if ($w.Frames -lt 1) { $why += 'holds no samples' }
                    elseif ($w.Frames / [double]$w.Rate -gt $script:MaxSeconds) { $why += "is longer than $($script:MaxSeconds) s" }
                } catch { $why = @("cannot be used: $($_.Exception.Message -replace '^(USAGE|WAV): ', '')") }
                if ($why.Count) { $null = $unusable.Add($key); $bad.Add("source $key $($why -join ', ')"); continue }
                $files[$key] = [pscustomobject]@{
                    Rel = $key; Path = $path; Sha256 = (Get-HarnessSha256 $path); Frames = $w.Frames; Channels = $w.Channels; Rate = $w.Rate; Format = $w.Format
                    Length = (Get-HarnessItemLength $w.Frames $w.Rate)
                }
            }
            if (-not $files.Contains($key)) { continue }
            $f = $files[$key]
            # Kinds of extensions have no sr of their own: New-HarnessRun refuses a file at another rate for them
            if ($s.PSObject.Properties['sr'] -and $f.Rate -ne [int]$s.sr) { $bad.Add("$($s.id): source $key is at $($f.Rate) Hz and the scenario runs at $($s.sr) Hz: nothing is resampled") }
            if ($s.PSObject.Properties['mono'] -and $s.mono -and $f.Channels -eq 2) { $bad.Add("$($s.id): source $key has two channels and the scenario renders one (mono): nothing is mixed down") }
        }
    }
    if ($bad.Count) { Stop-Usage ("sources: $($bad.Count) problem(s): " + ($bad -join '; ')) }
    $files
}

# The header of a file says what the check before the start found: format, channels, rate and frames
function Test-HarnessSourceHeader([string]$CopyPath, $File) {
    try { $h = Read-HarnessWavHeader $CopyPath } catch { return $false }
    $h.Format -ceq $File.Format -and $h.Channels -eq $File.Channels -and $h.Rate -eq $File.Rate -and $h.Frames -eq $File.Frames
}

function Copy-HarnessSourceFiles {
    param([Parameter(Mandatory)]$Ctx, $Sources = $null)
    if ($null -eq $Sources) { return }
    foreach ($key in @($Sources.get_Keys())) {
        $f = $Sources[$key]
        $copy = Join-Path $Ctx.Work "_source-$($f.Sha256.Substring(0, 12)).wav"
        $why = $null
        if (-not $Ctx.Files.Contains($copy)) { # two names of the same content share one copy
            $Ctx.Files.Add($copy)
            try { [IO.File]::Copy($f.Path, $copy, $true); [IO.File]::SetAttributes($copy, [IO.FileAttributes]::Normal) }
            catch { $why = "source file $key could not be copied: $($_.Exception.Message -replace '\s+', ' ')" }
        }
        # The copy is what REAPER plays: its bytes must be the ones hashed before the start, and its header the one checked
        # then (header and hash were two reads of the file, and a file written over in between would pair them wrongly)
        if (-not $why -and -not ((Test-Path -LiteralPath $copy -PathType Leaf) -and (Get-HarnessSha256 $copy) -ceq $f.Sha256 -and (Test-HarnessSourceHeader $copy $f))) { $why = "source file $key changed since it was checked" }
        if ($why) {
            # Not left under the name of the content that was checked; another name of that content may still make it
            Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $copy)) { $null = $Ctx.Files.Remove($copy) }
        }
        $Ctx.SourceCopies[$key] = [pscustomobject]@{ Path = $copy; Length = $f.Length; Why = $why; File = $f }
    }
}

function Get-HarnessSourceGap {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Scenario)
    foreach ($key in (Get-HarnessScenarioSourceKeys $Ctx.Config $Scenario)) {
        if (-not $Ctx.SourceCopies.ContainsKey($key)) { return "source file $key was not checked before the start" }
        if ($Ctx.SourceCopies[$key].Why) { return $Ctx.SourceCopies[$key].Why }
    }
    $null
}

function Get-HarnessSourceCopy {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$File)
    $key = Get-HarnessSourceKey $Ctx.Config.ConfigDir $File
    if (-not $Ctx.SourceCopies.ContainsKey($key)) { throw "source file $key was not checked before the start" }
    $c = $Ctx.SourceCopies[$key]
    if ($c.Why) { throw $c.Why }
    $c
}

function ConvertTo-HarnessSourceFact($File) {
    [ordered]@{ path = $File.Rel; sha256 = $File.Sha256; frames = $File.Frames; channels = $File.Channels; sampleRate = $File.Rate; format = $File.Format }
}

Export-ModuleMember -Function Read-HarnessSourceFiles, Copy-HarnessSourceFiles, Get-HarnessSourceGap, Get-HarnessSourceCopy, Get-HarnessItemLength, Get-HarnessSourceKey,
    Get-HarnessTrackFile, Get-HarnessScenarioSourceKeys, ConvertTo-HarnessSourceFact
