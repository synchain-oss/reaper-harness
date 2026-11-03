# SPDX-License-Identifier: MIT
#
# WAV reading, comparison and test signals, in C# compiled at load time (no external program).
#   Read-HarnessWav           reads PCM 16/24/32, float 32/64 and WAVE_FORMAT_EXTENSIBLE; a damaged or unsupported
#                             file throws an error whose message starts with "WAV:" (never a crash)
#   Compare-HarnessWavFiles   reads two files and compares them; returns facts (Get-HarnessCompareFacts) and the
#                             verdict (Get-HarnessCompareVerdict)
#   Get-HarnessCompareVerdict pure function: facts + criteria -> PASS / FAIL / INCOMPLETE and one stable English line
#   New-HarnessSignalFile     deterministic test signal: one impulse + seeded noise (+ optional sine), float32
#   Write-HarnessWav          writes samples in any supported format (signals, and the self-test's hand-made files)
# Samples are decoded to double, which is lossless for every supported format, so "identical" can be decided on
# the decoded values together with the format.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('HarnessWav' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;

public sealed class HarnessWavData {
    public int Rate; public int Channels; public long Frames; public string Format; public bool Extensible;
    public double[] Samples; // interleaved
}

public sealed class HarnessCompareFacts {
    public int RateA, RateB, ChannelsA, ChannelsB; public long FramesA, FramesB; public string FormatA, FormatB;
    public bool Comparable;      // same rate and channel count, so samples can be compared at all
    public bool Identical;       // same format, rate, channels, frames and every sample value bit for bit
    public int BestLag;          // lag with the smallest mean squared difference within the search window (B later than A is positive)
    public int ExpectLag;        // the lag the residual figures below are measured at
    public double MaxDiff;       // largest |A[n] - B[n + ExpectLag]| over the overlap, finite pairs only
    public double HeadDiff;      // the same within the first HeadSeconds of A
    public long NonFiniteA, NonFiniteB;
    public long NanA, NanB, InfA, InfB; // the non-finite samples, NaN and infinite counted apart
    public double PeakA, PeakB;  // largest |x| over finite samples
    public double[] RmsA, RmsB;  // RMS per channel over its finite samples; NaN for a channel without any
}

public static class HarnessWav {
    static Exception Bad(string why) { return new InvalidDataException("WAV: " + why); }

    public static HarnessWavData Read(string path) {
        byte[] b;
        try { b = File.ReadAllBytes(path); } catch (Exception e) { throw Bad("cannot read the file (" + e.GetType().Name + ")"); }
        if (b.Length < 12 || Encoding.ASCII.GetString(b, 0, 4) != "RIFF" || Encoding.ASCII.GetString(b, 8, 4) != "WAVE") throw Bad("not a RIFF/WAVE file");
        int pos = 12, fmtAt = -1, fmtLen = 0, dataAt = -1; long dataLen = 0;
        while (pos + 8 <= b.Length) {
            string id = Encoding.ASCII.GetString(b, pos, 4);
            long len = BitConverter.ToUInt32(b, pos + 4);
            int body = pos + 8;
            if (id == "fmt ") { fmtAt = body; fmtLen = (int)Math.Min(len, int.MaxValue); }
            else if (id == "data") {
                // 0xFFFFFFFF is the "length unknown" placeholder: the writer never came back to fill in the length, so the file
                // is not finished, however many whole frames it holds
                if (len == 0xFFFFFFFFL) throw Bad("the data length was never written (placeholder 0xFFFFFFFF), the file is not finished");
                // a render cut off (a crash, a full disk, a writer that never finished) is never read as a shorter file
                if (len > (long)b.Length - body) throw Bad("data chunk is truncated (" + len + " bytes declared, " + ((long)b.Length - body) + " in the file)");
                dataAt = body; dataLen = len; break;
            }
            long next = body + len + (len & 1);
            if (next > b.Length) break;
            pos = (int)next;
        }
        if (fmtAt < 0) throw Bad("no fmt chunk");
        if (fmtLen < 16 || fmtLen > b.Length - fmtAt) throw Bad("fmt chunk is too short or truncated");
        if (dataAt < 0) throw Bad("no data chunk");
        int tag = BitConverter.ToUInt16(b, fmtAt);
        int channels = BitConverter.ToUInt16(b, fmtAt + 2);
        int rate = (int)BitConverter.ToUInt32(b, fmtAt + 4);
        int align = BitConverter.ToUInt16(b, fmtAt + 12);
        int bits = BitConverter.ToUInt16(b, fmtAt + 14);
        bool ext = false;
        if (tag == 0xFFFE) {
            if (fmtLen < 40) throw Bad("WAVE_FORMAT_EXTENSIBLE fmt chunk is too short");
            ext = true;
            // SubFormat GUID: the first two bytes are the format tag, the rest is the fixed KSDATAFORMAT suffix
            byte[] tail = { 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 };
            for (int i = 0; i < 14; i++) if (b[fmtAt + 26 + i] != tail[i]) throw Bad("WAVE_FORMAT_EXTENSIBLE with an unknown sub-format");
            tag = BitConverter.ToUInt16(b, fmtAt + 24);
        }
        if (channels < 1 || channels > 64) throw Bad("channel count " + channels + " is out of range");
        if (rate < 1 || rate > 1536000) throw Bad("sample rate " + rate + " is out of range");
        string format;
        if (tag == 1 && (bits == 16 || bits == 24 || bits == 32)) format = "pcm" + bits;
        else if (tag == 3 && (bits == 32 || bits == 64)) format = "float" + bits;
        else throw Bad("unsupported encoding (format tag " + tag + ", " + bits + " bits)");
        int bytes = bits / 8;
        if (align != bytes * channels) throw Bad("block align " + align + " does not match " + channels + " channels of " + bits + " bits");
        if (dataLen % align != 0) throw Bad("data chunk does not hold whole frames (" + dataLen + " bytes, " + align + " per frame)");
        long frames = dataLen / align;
        var s = new double[frames * channels];
        int p = dataAt;
        for (long i = 0; i < s.LongLength; i++, p += bytes) {
            switch (format) {
                case "pcm16": s[i] = BitConverter.ToInt16(b, p) / 32768.0; break;
                case "pcm24": s[i] = ((b[p] | (b[p + 1] << 8) | ((sbyte)b[p + 2] << 16))) / 8388608.0; break;
                case "pcm32": s[i] = BitConverter.ToInt32(b, p) / 2147483648.0; break;
                case "float32": s[i] = BitConverter.ToSingle(b, p); break;
                default: s[i] = BitConverter.ToDouble(b, p); break;
            }
        }
        return new HarnessWavData { Rate = rate, Channels = channels, Frames = frames, Format = format, Extensible = ext, Samples = s };
    }

    public static void Write(string path, int rate, int channels, string format, bool extensible, double[] s) {
        int bits, tag;
        switch (format) {
            case "pcm16": bits = 16; tag = 1; break;
            case "pcm24": bits = 24; tag = 1; break;
            case "pcm32": bits = 32; tag = 1; break;
            case "float32": bits = 32; tag = 3; break;
            case "float64": bits = 64; tag = 3; break;
            default: throw new ArgumentException("unknown format " + format);
        }
        int bytes = bits / 8, align = bytes * channels;
        long dataLen = (s.LongLength / channels) * align;
        using (var w = new BinaryWriter(File.Create(path))) {
            int fmtLen = extensible ? 40 : 16;
            w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write((uint)(4 + 8 + fmtLen + 8 + dataLen)); w.Write(Encoding.ASCII.GetBytes("WAVE"));
            w.Write(Encoding.ASCII.GetBytes("fmt ")); w.Write((uint)fmtLen);
            w.Write((ushort)(extensible ? 0xFFFE : tag)); w.Write((ushort)channels); w.Write((uint)rate); w.Write((uint)(rate * align)); w.Write((ushort)align); w.Write((ushort)bits);
            if (extensible) {
                w.Write((ushort)22); w.Write((ushort)bits); w.Write((uint)0);
                w.Write((ushort)tag); w.Write(new byte[] { 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 });
            }
            w.Write(Encoding.ASCII.GetBytes("data")); w.Write((uint)dataLen);
            for (long i = 0; i < (dataLen / bytes); i++) {
                double v = s[i];
                switch (format) {
                    case "pcm16": w.Write((short)Math.Max(-32768, Math.Min(32767, Math.Round(v * 32768.0)))); break;
                    case "pcm24": { int q = (int)Math.Max(-8388608, Math.Min(8388607, Math.Round(v * 8388608.0))); w.Write((byte)(q & 0xFF)); w.Write((byte)((q >> 8) & 0xFF)); w.Write((byte)((q >> 16) & 0xFF)); break; }
                    case "pcm32": w.Write((int)Math.Max(-2147483648.0, Math.Min(2147483647.0, Math.Round(v * 2147483648.0)))); break;
                    case "float32": w.Write((float)v); break;
                    default: w.Write(v); break;
                }
            }
        }
    }

    // One impulse of 1.0 at 0.25 s (every channel), uniform noise at noiseDb from a seeded xorshift32 (one stream per
    // channel, so swapped channels are detectable), optional sine. OffsetSamples (>= 0) delays the whole signal by
    // that many frames (zeros in front, the same number dropped at the end), so the length stays the same.
    public static double[] Signal(int rate, int channels, double seconds, uint seed, double noiseDb, double sineHz, double sineDb, int offsetSamples) {
        if (offsetSamples < 0) throw new ArgumentException("offsetSamples must not be negative");
        long frames = (long)Math.Round(seconds * rate);
        var s = new double[frames * channels];
        double noiseAmp = Math.Pow(10.0, noiseDb / 20.0), sineAmp = sineHz > 0 ? Math.Pow(10.0, sineDb / 20.0) : 0.0;
        long impulse = (long)Math.Round(0.25 * rate);
        for (int c = 0; c < channels; c++) {
            uint x = unchecked(seed * 2654435761u + (uint)(c + 1) * 40503u); if (x == 0) x = 1;
            for (long n = 0; n < frames; n++) {
                x ^= x << 13; x ^= x >> 17; x ^= x << 5;
                double u = (x / 4294967296.0) * 2.0 - 1.0;
                s[n * channels + c] = (n == impulse) ? 1.0 : noiseAmp * u + sineAmp * Math.Sin(2.0 * Math.PI * sineHz * n / rate);
            }
        }
        if (offsetSamples > 0)
            for (long i = s.LongLength - 1; i >= 0; i--) s[i] = (i - (long)offsetSamples * channels >= 0) ? s[i - (long)offsetSamples * channels] : 0.0;
        return s;
    }

    static bool Finite(double v) { return !double.IsNaN(v) && !double.IsInfinity(v); }

    public static double[] Rms(HarnessWavData w) {
        var sum = new double[w.Channels]; var count = new long[w.Channels]; var r = new double[w.Channels];
        for (long i = 0; i < w.Samples.LongLength; i++) {
            double v = w.Samples[i]; int c = (int)(i % w.Channels);
            if (Finite(v)) { sum[c] += v * v; count[c]++; }
        }
        for (int c = 0; c < w.Channels; c++) r[c] = count[c] > 0 ? Math.Sqrt(sum[c] / count[c]) : double.NaN;
        return r;
    }

    public static HarnessCompareFacts Compare(HarnessWavData a, HarnessWavData b, int expectLag, int lagSearch, double headSeconds) {
        var f = new HarnessCompareFacts {
            RateA = a.Rate, RateB = b.Rate, ChannelsA = a.Channels, ChannelsB = b.Channels, FramesA = a.Frames, FramesB = b.Frames,
            FormatA = a.Format, FormatB = b.Format, ExpectLag = expectLag, BestLag = 0, MaxDiff = double.NaN, HeadDiff = double.NaN
        };
        foreach (var v in a.Samples) { if (double.IsNaN(v)) f.NanA++; else if (double.IsInfinity(v)) f.InfA++; else if (Math.Abs(v) > f.PeakA) f.PeakA = Math.Abs(v); }
        foreach (var v in b.Samples) { if (double.IsNaN(v)) f.NanB++; else if (double.IsInfinity(v)) f.InfB++; else if (Math.Abs(v) > f.PeakB) f.PeakB = Math.Abs(v); }
        f.NonFiniteA = f.NanA + f.InfA; f.NonFiniteB = f.NanB + f.InfB;
        f.RmsA = Rms(a); f.RmsB = Rms(b);
        f.Comparable = a.Rate == b.Rate && a.Channels == b.Channels;
        if (!f.Comparable) return f;
        int ch = a.Channels;
        bool same = a.Format == b.Format && a.Frames == b.Frames;
        if (same) for (long i = 0; i < a.Samples.LongLength; i++) if (BitConverter.DoubleToInt64Bits(a.Samples[i]) != BitConverter.DoubleToInt64Bits(b.Samples[i])) { same = false; break; }
        f.Identical = same;
        double best = double.PositiveInfinity;
        for (int lag = -lagSearch; lag <= lagSearch; lag++) {
            double sum = 0; long count = 0;
            long n0 = Math.Max(0, -lag), n1 = Math.Min(a.Frames, b.Frames - lag);
            for (long n = n0; n < n1; n++)
                for (int c = 0; c < ch; c++) {
                    double x = a.Samples[n * ch + c], y = b.Samples[(n + lag) * ch + c];
                    if (!Finite(x) || !Finite(y)) continue;
                    double d = x - y; sum += d * d; count++;
                }
            if (count == 0) continue;
            double mean = sum / count;
            // ties go to the lag closest to zero
            if (mean < best || (mean == best && Math.Abs(lag) < Math.Abs(f.BestLag))) { best = mean; f.BestLag = lag; }
        }
        long head = (long)Math.Round(headSeconds * a.Rate);
        double mx = 0, hx = 0; bool any = false;
        long m0 = Math.Max(0, -expectLag), m1 = Math.Min(a.Frames, b.Frames - expectLag);
        for (long n = m0; n < m1; n++)
            for (int c = 0; c < ch; c++) {
                double x = a.Samples[n * ch + c], y = b.Samples[(n + expectLag) * ch + c];
                if (!Finite(x) || !Finite(y)) continue;
                double d = Math.Abs(x - y); any = true;
                if (d > mx) mx = d;
                if (n < head && d > hx) hx = d;
            }
        if (any) { f.MaxDiff = mx; f.HeadDiff = hx; }
        return f;
    }
}
'@
}

$script:Inv = [Globalization.CultureInfo]::InvariantCulture

# Linear amplitude -> dBFS text with two decimals; 0 is -inf; NaN (nothing to measure) is n/a.
function Format-HarnessDb([double]$Linear) {
    if ([double]::IsNaN($Linear)) { return 'n/a' }
    if ($Linear -le 0) { return '-inf' }
    (20 * [Math]::Log10($Linear)).ToString('0.00', $script:Inv)
}

function Read-HarnessWav([Parameter(Mandatory)][string]$Path) {
    try { [HarnessWav]::Read($Path) } catch { throw ($_.Exception.InnerException ?? $_.Exception).Message }
}

function Write-HarnessWav {
    param([Parameter(Mandatory)][string]$Path, [int]$Rate = 48000, [int]$Channels = 2, [ValidateSet('pcm16', 'pcm24', 'pcm32', 'float32', 'float64')][string]$Format = 'float32',
          [switch]$Extensible, [Parameter(Mandatory)][double[]]$Samples)
    [HarnessWav]::Write($Path, $Rate, $Channels, $Format, [bool]$Extensible, $Samples)
}

# The test signal as a float32 file. Signal is the config's signal object (seconds, seed, noiseDb, sine); offsets are
# only used by the built-in negative case.
function New-HarnessSignalFile {
    param([Parameter(Mandatory)][string]$Path, [int]$Rate = 48000, [int]$Channels = 2, [double]$Seconds = 4, [uint32]$Seed = 1, [double]$NoiseDb = -20,
          [double]$SineHz = 0, [double]$SineDb = -20, [int]$OffsetSamples = 0)
    $s = [HarnessWav]::Signal($Rate, $Channels, $Seconds, $Seed, $NoiseDb, $SineHz, $SineDb, $OffsetSamples)
    [HarnessWav]::Write($Path, $Rate, $Channels, 'float32', $false, $s)
}

# An RMS as a level for the channel criteria: digital silence counts as -400 dB (the lowest value a criterion can
# name, so [-400, x] accepts it); NaN (a channel without finite samples) stays NaN.
function ConvertTo-HarnessLevelDb([double]$Linear) {
    if ([double]::IsNaN($Linear)) { return [double]::NaN }
    if ($Linear -le 0) { return -400.0 }
    [Math]::Max(-400.0, 20 * [Math]::Log10($Linear))
}

function Format-HarnessRmsList($Rms) { (@($Rms) | ForEach-Object { Format-HarnessDb $_ }) -join ',' }

# Pure function: the channel criteria against compare facts (B is the render judged, A the reference). Criteria are
# tables from the configuration: key -> @{ Key; Channels (1-based numbers); Min; Max }. Returns the problems.
#   RmsDb          RMS of a channel of B
#   EnergyRatioDb  RMS of one channel of B minus RMS of another; two silent channels have no ratio
#   RmsChangeDb    RMS of a channel of B minus the same channel of A
function Get-HarnessChannelProblems {
    param([Parameter(Mandatory)]$Facts, $RmsDb = $null, $EnergyRatioDb = $null, $RmsChangeDb = $null)
    $why = [Collections.Generic.List[string]]::new()
    $fmt = { param([double]$v) $v.ToString('0.00', $script:Inv) }
    $range = { param($c) "[$(& $fmt $c.Min), $(& $fmt $c.Max)]" }
    $rmsA = @($Facts.RmsA | Where-Object { $null -ne $_ }); $rmsB = @($Facts.RmsB | Where-Object { $null -ne $_ })
    $level = { param($list, [int]$n) ($n -le $list.Count) ? (ConvertTo-HarnessLevelDb $list[$n - 1]) : $null }
    foreach ($c in @(($null -ne $RmsDb) ? $RmsDb.get_Values() : @())) {
        $v = & $level $rmsB $c.Channels[0]
        if ($null -eq $v) { $why.Add("rms $($c.Key): the render has no channel $($c.Channels[0])"); continue }
        if ([double]::IsNaN($v)) { $why.Add("rms $($c.Key) is undefined (no finite samples)"); continue }
        if ($v -lt $c.Min -or $v -gt $c.Max) { $why.Add("rms $($c.Key) $(& $fmt $v) dB outside $(& $range $c)") }
    }
    foreach ($c in @(($null -ne $EnergyRatioDb) ? $EnergyRatioDb.get_Values() : @())) {
        $x = & $level $rmsB $c.Channels[0]; $y = & $level $rmsB $c.Channels[1]
        if ($null -eq $x -or $null -eq $y) { $why.Add("ratio $($c.Key): the render has no channel $(($null -eq $x) ? $c.Channels[0] : $c.Channels[1])"); continue }
        if ([double]::IsNaN($x) -or [double]::IsNaN($y)) { $why.Add("ratio $($c.Key) is undefined (no finite samples)"); continue }
        if ($x -le -400 -and $y -le -400) { $why.Add("ratio $($c.Key) is undefined (both channels are silent)"); continue }
        $r = $x - $y
        if ($r -lt $c.Min -or $r -gt $c.Max) { $why.Add("ratio $($c.Key) $(& $fmt $r) dB outside $(& $range $c)") }
    }
    foreach ($c in @(($null -ne $RmsChangeDb) ? $RmsChangeDb.get_Values() : @())) {
        $n = $c.Channels[0]
        $levelA = & $level $rmsA $n; $levelB = & $level $rmsB $n
        if ($null -eq $levelA -or $null -eq $levelB) { $why.Add("rms change $($c.Key): the $(($null -eq $levelA) ? 'reference' : 'render') has no channel $n"); continue }
        if ([double]::IsNaN($levelA) -or [double]::IsNaN($levelB)) { $why.Add("rms change $($c.Key) is undefined (no finite samples)"); continue }
        $d = $levelB - $levelA
        if ($d -lt $c.Min -or $d -gt $c.Max) { $why.Add("rms change $($c.Key) $(& $fmt $d) dB outside $(& $range $c)") }
    }
    , $why.ToArray()
}

# The facts appended after the fixed ones: RMS per channel when a channel criterion is given (A/B, or only B for a
# render judged on its own), NaN and Inf counted apart when there are any.
function Get-HarnessExtraFacts($Facts, [bool]$Channels, [switch]$Single) {
    $f = $Facts
    $x = ''
    if ($Channels) { $x += $Single ? " rms=$(Format-HarnessRmsList $f.RmsB)" : " rms=$(Format-HarnessRmsList $f.RmsA)/$(Format-HarnessRmsList $f.RmsB)" }
    if ($Single ? ($f.NonFiniteB -gt 0) : ($f.NonFiniteA -gt 0 -or $f.NonFiniteB -gt 0)) { $x += $Single ? " nan=$($f.NanB) inf=$($f.InfB)" : " nan=$($f.NanA)/$($f.NanB) inf=$($f.InfA)/$($f.InfB)" }
    $x
}

# Pure function: compare facts + criteria -> @{ Status; Detail }. Criteria (all optional):
#   MaxDiffDb  allowed residual in dBFS at the expected lag; absent means the renders must be bit-identical
#   Lag        expected lag (B later than A is positive), default 0; the best lag found must equal it
#   PeakMaxDb  B's peak must not exceed it; NotSilent  B's peak must be above -120 dBFS
#   RmsDb, EnergyRatioDb, RmsChangeDb  channel criteria (Get-HarnessChannelProblems)
# Always checked: both files comparable (same rate and channel count), no NaN / Inf in either. The line starts with
# the fixed facts (identical, lag, maxdiff, head, frames, channels, rate, format, nonfinite, peak), so negative
# cases can match it with a regex; RMS per channel (with channel criteria) and NaN / Inf counts (when there are
# any) follow; a failure appends "; failed: <reasons>".
# A render with no frames comes first and is INCOMPLETE ("; incomplete: <reason>"): no sample was compared, and two
# empty files would otherwise count as bit-identical.
function Get-HarnessCompareVerdict {
    param([Parameter(Mandatory)]$Facts, [Nullable[double]]$MaxDiffDb = $null, [int]$Lag = 0, [Nullable[double]]$PeakMaxDb = $null, [switch]$NotSilent,
          $RmsDb = $null, $EnergyRatioDb = $null, $RmsChangeDb = $null)
    $f = $Facts
    $line = 'identical={0} lag={1} maxdiff={2} head={3} frames={4}/{5} channels={6}/{7} rate={8}/{9} format={10}/{11} nonfinite={12}/{13} peak={14}/{15}' -f `
        ($f.Identical ? 'yes' : 'no'), ($f.Comparable ? [string]$f.BestLag : '?'), (Format-HarnessDb $f.MaxDiff), (Format-HarnessDb $f.HeadDiff), $f.FramesA, $f.FramesB,
        $f.ChannelsA, $f.ChannelsB, $f.RateA, $f.RateB, $f.FormatA, $f.FormatB, $f.NonFiniteA, $f.NonFiniteB, (Format-HarnessDb $f.PeakA), (Format-HarnessDb $f.PeakB)
    $line += Get-HarnessExtraFacts $f ($null -ne $RmsDb -or $null -ne $EnergyRatioDb -or $null -ne $RmsChangeDb)
    if ($f.FramesA -eq 0 -or $f.FramesB -eq 0) { return [pscustomobject]@{ Status = 'INCOMPLETE'; Detail = "$line; incomplete: a render has no frames, nothing was compared" } }
    $why = [Collections.Generic.List[string]]::new()
    if (-not $f.Comparable) { $why.Add('sample rate or channel count differ, the renders cannot be compared') }
    if ($f.NonFiniteA -gt 0 -or $f.NonFiniteB -gt 0) { $why.Add('NaN or Inf samples present') }
    if ($f.Comparable) {
        if ($f.BestLag -ne $Lag) { $why.Add("lag is $($f.BestLag), expected $Lag") }
        if ($null -eq $MaxDiffDb) {
            if (-not $f.Identical) { $why.Add('not bit-identical') }
        } else {
            if ($f.FramesA -ne $f.FramesB) { $why.Add('frame counts differ') }
            if ([double]::IsNaN($f.MaxDiff)) { $why.Add('no overlapping finite samples') }
            elseif ($f.MaxDiff -gt 0 -and 20 * [Math]::Log10($f.MaxDiff) -gt [double]$MaxDiffDb) { $why.Add("residual $(Format-HarnessDb $f.MaxDiff) dBFS above $(([double]$MaxDiffDb).ToString('0.00', $script:Inv))") }
        }
    }
    if ($null -ne $PeakMaxDb -and $f.PeakB -gt 0 -and 20 * [Math]::Log10($f.PeakB) -gt [double]$PeakMaxDb) { $why.Add("peak $(Format-HarnessDb $f.PeakB) dBFS above $(([double]$PeakMaxDb).ToString('0.00', $script:Inv))") }
    if ($NotSilent -and ($f.PeakB -le 0 -or 20 * [Math]::Log10($f.PeakB) -le -120)) { $why.Add('silent (peak not above -120 dBFS)') }
    foreach ($p in (Get-HarnessChannelProblems -Facts $f -RmsDb $RmsDb -EnergyRatioDb $EnergyRatioDb -RmsChangeDb $RmsChangeDb)) { $why.Add($p) }
    if ($why.Count) { return [pscustomobject]@{ Status = 'FAIL'; Detail = "$line; failed: $($why -join ', ')" } }
    [pscustomobject]@{ Status = 'PASS'; Detail = $line }
}

# Pure function: one render judged on its own (facts of the file compared with itself, B side). The line starts with
# frames= channels= rate= format= nonfinite= peak=; then the extra facts and, on a FAIL, "; failed: <reasons>".
# Always checked: no NaN / Inf. Optional: PeakMaxDb, NotSilent, RmsDb, EnergyRatioDb. A render with no frames is
# INCOMPLETE before any of that, as in Get-HarnessCompareVerdict.
function Get-HarnessRenderVerdict {
    param([Parameter(Mandatory)]$Facts, [Nullable[double]]$PeakMaxDb = $null, [switch]$NotSilent, $RmsDb = $null, $EnergyRatioDb = $null)
    $f = $Facts
    $line = 'frames={0} channels={1} rate={2} format={3} nonfinite={4} peak={5}' -f $f.FramesB, $f.ChannelsB, $f.RateB, $f.FormatB, $f.NonFiniteB, (Format-HarnessDb $f.PeakB)
    $line += Get-HarnessExtraFacts $f ($null -ne $RmsDb -or $null -ne $EnergyRatioDb) -Single
    if ($f.FramesB -eq 0) { return [pscustomobject]@{ Status = 'INCOMPLETE'; Detail = "$line; incomplete: the render has no frames, nothing was checked" } }
    $why = [Collections.Generic.List[string]]::new()
    if ($f.NonFiniteB -gt 0) { $why.Add('NaN or Inf samples present') }
    if ($null -ne $PeakMaxDb -and $f.PeakB -gt 0 -and 20 * [Math]::Log10($f.PeakB) -gt [double]$PeakMaxDb) { $why.Add("peak $(Format-HarnessDb $f.PeakB) dBFS above $(([double]$PeakMaxDb).ToString('0.00', $script:Inv))") }
    if ($NotSilent -and ($f.PeakB -le 0 -or 20 * [Math]::Log10($f.PeakB) -le -120)) { $why.Add('silent (peak not above -120 dBFS)') }
    foreach ($p in (Get-HarnessChannelProblems -Facts $f -RmsDb $RmsDb -EnergyRatioDb $EnergyRatioDb)) { $why.Add($p) }
    if ($why.Count) { return [pscustomobject]@{ Status = 'FAIL'; Detail = "$line; failed: $($why -join ', ')" } }
    [pscustomobject]@{ Status = 'PASS'; Detail = $line }
}

# Reads both files and compares them. A file that cannot be read gives INCOMPLETE (nothing was compared), never PASS.
function Compare-HarnessWavFiles {
    param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B, [Nullable[double]]$MaxDiffDb = $null, [int]$Lag = 0, [int]$LagSearch = 64,
          [Nullable[double]]$PeakMaxDb = $null, [switch]$NotSilent, [double]$HeadSeconds = 2, $RmsDb = $null, $EnergyRatioDb = $null, $RmsChangeDb = $null)
    foreach ($pair in @(@('A', $A), @('B', $B))) {
        if (-not (Test-Path -LiteralPath $pair[1] -PathType Leaf)) { return [pscustomobject]@{ Status = 'INCOMPLETE'; Detail = "render $($pair[0]) does not exist" } }
    }
    try { $wa = [HarnessWav]::Read($A) } catch { return [pscustomobject]@{ Status = 'INCOMPLETE'; Detail = "cannot read render A: $(($_.Exception.InnerException ?? $_.Exception).Message)" } }
    try { $wb = [HarnessWav]::Read($B) } catch { return [pscustomobject]@{ Status = 'INCOMPLETE'; Detail = "cannot read render B: $(($_.Exception.InnerException ?? $_.Exception).Message)" } }
    $Facts = [HarnessWav]::Compare($wa, $wb, $Lag, [Math]::Max([Math]::Abs($Lag), $LagSearch), $HeadSeconds)
    Get-HarnessCompareVerdict -Facts $Facts -MaxDiffDb $MaxDiffDb -Lag $Lag -PeakMaxDb $PeakMaxDb -NotSilent:$NotSilent -RmsDb $RmsDb -EnergyRatioDb $EnergyRatioDb -RmsChangeDb $RmsChangeDb
}

# Checks one render on its own (compare "none", and kinds that have nothing to compare against): readable, all
# finite, optional peak, silence and channel criteria (Get-HarnessRenderVerdict). Returns @{ Status; Detail }.
function Test-HarnessWavFile {
    param([Parameter(Mandatory)][string]$Path, [Nullable[double]]$PeakMaxDb = $null, [switch]$NotSilent, $RmsDb = $null, $EnergyRatioDb = $null)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Status = 'INCOMPLETE'; Detail = 'the render does not exist' } }
    try { $w = [HarnessWav]::Read($Path) } catch { return [pscustomobject]@{ Status = 'INCOMPLETE'; Detail = "cannot read the render: $(($_.Exception.InnerException ?? $_.Exception).Message)" } }
    $Facts = [HarnessWav]::Compare($w, $w, 0, 0, 0)
    Get-HarnessRenderVerdict -Facts $Facts -PeakMaxDb $PeakMaxDb -NotSilent:$NotSilent -RmsDb $RmsDb -EnergyRatioDb $EnergyRatioDb
}

Export-ModuleMember -Function Format-HarnessDb, Read-HarnessWav, Write-HarnessWav, New-HarnessSignalFile, Get-HarnessCompareVerdict, Get-HarnessRenderVerdict, Get-HarnessChannelProblems,
    ConvertTo-HarnessLevelDb, Compare-HarnessWavFiles, Test-HarnessWavFile
