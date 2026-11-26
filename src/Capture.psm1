# SPDX-License-Identifier: MIT
#
# Shots of a held plugin window (windows.capture of a transport state). The driver asks for each shot with a request
# file in the work directory; a capture service of the harness, a thread of its own during that one launch, answers it
# with a PNG of the window's client area and an answer file. Nothing in an image is judged.
#   Get-HarnessCapturePlan -Scenario -Work   (pure) $null when no state has shots, else Dir (<work>\<id>.shots) and
#       Shots, one per shot in state order, then offset order: State, StateNo and K (1-based), At (ms of the hold), Name
#       (<state>-<ms>.png), Png, Req, Done, Err (full paths in Dir). The one builder: the scenario makes the directory,
#       the job and the launch from it, and collection reads it again
#   Initialize-HarnessCapture   compiles the service on first use, so a configuration without shots never loads it;
#       throws "the capture service could not be built: ..." (then nothing has started)
#   Read-HarnessShotAnswer -Path -Kind done|err   (pure on files) an answer of the service, read strictly: done gives
#       Width, Height, View (x, y, w, h in image coordinates, or $null) and Dpi; err the problem text of its reason
#       from a fixed table (the file's own text is never printed); $null when it cannot be read
#   Test-HarnessShotImage -Path -Answer   (pure on files) whether the PNG's header has the size of its answer
#   Get-HarnessShotFacts -Plan -Facts -StateNo [-Stopped]   (pure on files) the shots of one state as its facts list them
# The service (class HarnessCapture) is handed the PID of the REAPER the host started, its start time, the shot rule of
# Host.psm1 and the plan's file names. It answers each planned request at most once and ignores every other file. On
# a request it first looks at the shot directory (a link or junction gets no image), then at the top-level windows of
# that PID only: visible, of the dialog class, with a title of the shot rule; exactly one, or no shot. PrintWindow
# with PW_CLIENTONLY | PW_RENDERFULLCONTENT draws the client area into a bitmap of the harness, then the PNG (8-bit
# RGB) and the answer are written, each through <file>.part and a rename, never over a file that is there. Inside the
# window it reads only the class names and rectangles of that PID's own child windows, to find the plugin's view. Apart
# from PrintWindow's request to draw, it sends nothing to any window and moves, sizes, shows or focuses nothing.
# It leaves its loop when stopped, when that process has exited, or at its deadline, and nothing escapes its thread.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Guard.psm1') -ErrorAction Stop

# A shot's client area is at most this wide and high (the C# MaxSide is the same; a case compares them)
$script:ShotMaxSide = 4096

$script:ShotReasons = [ordered]@{
    nowindow    = 'no plugin window of this REAPER was visible'
    empty       = 'the window had no client area'
    toolarge    = "its client area is larger than $($script:ShotMaxSide) x $($script:ShotMaxSide)"
    printfailed = 'PrintWindow failed'
    exists      = 'its file was there already and is never overwritten'
    link        = 'the shot directory was a link or junction: no image was written'
}

$script:ServiceSource = @'
using System;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public sealed class HarnessCapture
{
    public const int MaxSide = 4096;
    // REAPER 7.82 hosts a plugin's editor in a child of this class, below its own row of controls (measured for a VST3;
    // a JSFX window has none, and its view is null)
    const string ViewClass = "reaperPluginHostWrapProc";
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [DllImport("user32")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32")] static extern bool EnumChildWindows(IntPtr h, EnumProc p, IntPtr l);
    [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32")] static extern bool ScreenToClient(IntPtr h, ref POINT p);
    [DllImport("user32")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("kernel32")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32")] static extern bool GetProcessTimes(IntPtr h, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr h);
    [DllImport("gdi32")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32")] static extern IntPtr CreateDIBSection(IntPtr dc, byte[] bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32")] static extern bool GdiFlush();
    [DllImport("gdi32")] static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32")] static extern bool DeleteDC(IntPtr dc);

    readonly uint pid;
    readonly long started;
    readonly Regex title;
    readonly string[] req, png, done, err;
    readonly bool[] answered;
    readonly int deadlineMs;
    volatile bool stopping;
    Thread thread;

    // pid and started (its creation time as a UTC file time): the REAPER the host started; title: Host's shot rule;
    // req, png, done, err: the plan's paths, index for index; deadlineMs: it leaves its loop then at the latest
    public HarnessCapture(uint pid, long started, string title, string[] req, string[] png, string[] done, string[] err, int deadlineMs)
    {
        if (png.Length != req.Length || done.Length != req.Length || err.Length != req.Length) throw new ArgumentException("the lists of the plan differ in length");
        this.pid = pid; this.started = started; this.title = new Regex(title, RegexOptions.CultureInvariant);
        this.req = req; this.png = png; this.done = done; this.err = err; this.deadlineMs = deadlineMs; answered = new bool[req.Length];
    }

    public void Start() { thread = new Thread(Run) { IsBackground = true, Name = "reaper-harness capture" }; thread.Start(); }

    // Sets the stop flag and waits for the thread; false when it did not end in time. Never throws.
    public bool Stop(int ms) { try { stopping = true; return thread == null || thread.Join(ms); } catch (Exception) { return false; } }

    void Run()
    {
        // Nothing escapes the thread: whatever goes wrong, the requests not answered yet stay unanswered
        try
        {
            try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (Exception) { } // per monitor v2: physical pixels
            IntPtr process = OpenProcess(0x00100000 | 0x1000, false, pid); // SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION
            if (process == IntPtr.Zero) return;
            try
            {
                long created, exited, kernel, user;
                // A process that did not start when the host's did is not the one the host started: nothing is answered
                if (!GetProcessTimes(process, out created, out exited, out kernel, out user) || Math.Abs(created - started) > 10000) return;
                long until = Environment.TickCount64 + deadlineMs;
                while (!stopping && Environment.TickCount64 < until && WaitForSingleObject(process, 0) == 258) // WAIT_TIMEOUT: it runs
                {
                    for (int i = 0; i < req.Length && !stopping; i++)
                    {
                        if (answered[i] || !File.Exists(req[i])) continue;
                        answered[i] = true;
                        Answer(i);
                    }
                    WaitForSingleObject(process, 20);
                }
            }
            finally { CloseHandle(process); }
        }
        catch (Exception) { }
    }

    void Answer(int i)
    {
        string reason;
        try { reason = Shoot(i); }
        catch (Exception e) { reason = "failed " + e.GetType().Name; }
        if (reason == null) return;
        // An err file that cannot be written is no answer: the driver says late
        try { Put(err[i], Encoding.ASCII.GetBytes("reason=" + reason + "\n")); } catch (Exception) { }
    }

    // Every file goes through <file>.part, renamed once complete; never over a file that is there
    static void Put(string path, byte[] data)
    {
        string part = path + ".part";
        using (var fs = new FileStream(part, FileMode.CreateNew, FileAccess.Write, FileShare.None)) fs.Write(data, 0, data.Length);
        File.Move(part, path, false);
    }

    // null: the PNG and then the done file were written; else the reason of the err file
    string Shoot(int i)
    {
        // The shot directory before anything else (the plan's files share it): a link or junction there gets no image and
        // no done file, and its err answer, of fixed text, is the one file written through it
        if ((File.GetAttributes(Path.GetDirectoryName(png[i])) & FileAttributes.ReparsePoint) != 0) return "link";
        IntPtr hwnd = IntPtr.Zero;
        int seen = 0;
        var text = new StringBuilder(512);
        EnumWindows((h, l) =>
        {
            uint owner;
            GetWindowThreadProcessId(h, out owner);
            if (owner != pid || !IsWindowVisible(h)) return true;
            text.Clear(); GetClassName(h, text, 256);
            if (text.ToString() != "#32770") return true;
            text.Clear(); GetWindowText(h, text, 512); // no message for a window of another process: a hung one cannot block it
            if (!title.IsMatch(text.ToString())) return true;
            hwnd = h; seen++;
            return true;
        }, IntPtr.Zero);
        if (seen == 0) return "nowindow";
        if (seen > 1) return "windows " + Math.Min(seen, 999).ToString(CultureInfo.InvariantCulture);
        RECT r;
        if (!GetClientRect(hwnd, out r)) return "nowindow";
        int w = r.R - r.L, h = r.B - r.T;
        if (w <= 0 || h <= 0) return "empty";
        if (w > MaxSide || h > MaxSide) return "toolarge";
        if (File.Exists(png[i])) return "exists";
        byte[] pixels = Print(hwnd, w, h);
        if (pixels == null) return "printfailed";
        Put(png[i], Png(pixels, w, h));
        string view = "none";
        IntPtr wrap = View(hwnd);
        RECT v;
        if (wrap != IntPtr.Zero && GetWindowRect(wrap, out v))
        {
            var o = new POINT { X = v.L, Y = v.T };
            if (ScreenToClient(hwnd, ref o)) view = string.Format(CultureInfo.InvariantCulture, "{0},{1},{2},{3}", o.X, o.Y, v.R - v.L, v.B - v.T);
        }
        Put(done[i], Encoding.ASCII.GetBytes(string.Format(CultureInfo.InvariantCulture, "width={0}\nheight={1}\nview={2}\ndpi={3}\n", w, h, view, GetDpiForWindow(hwnd))));
        return null;
    }

    // The first descendant of that PID with the view's class; only class names and rectangles are read
    IntPtr View(IntPtr top)
    {
        IntPtr hit = IntPtr.Zero;
        var text = new StringBuilder(256);
        EnumChildWindows(top, (h, l) =>
        {
            uint owner;
            GetWindowThreadProcessId(h, out owner);
            if (owner != pid) return true;
            text.Clear(); GetClassName(h, text, 256);
            if (text.ToString() != ViewClass) return true;
            hit = h;
            return false;
        }, IntPtr.Zero);
        return hit;
    }

    // The client area drawn into a top-down 32 bpp bitmap of the harness: its bytes (B, G, R, x), or null
    byte[] Print(IntPtr hwnd, int w, int h)
    {
        IntPtr dc = CreateCompatibleDC(IntPtr.Zero);
        if (dc == IntPtr.Zero) return null;
        try
        {
            var bmi = new byte[40];
            BitConverter.GetBytes(40).CopyTo(bmi, 0); BitConverter.GetBytes(w).CopyTo(bmi, 4); BitConverter.GetBytes(-h).CopyTo(bmi, 8);
            BitConverter.GetBytes((short)1).CopyTo(bmi, 12); BitConverter.GetBytes((short)32).CopyTo(bmi, 14);
            IntPtr bits;
            IntPtr bmp = CreateDIBSection(dc, bmi, 0, out bits, IntPtr.Zero, 0);
            if (bmp == IntPtr.Zero) return null;
            try
            {
                if (bits == IntPtr.Zero) return null;
                IntPtr old = SelectObject(dc, bmp);
                try
                {
                    // The window may have gone, and its handle gone to another, since it was found
                    uint owner;
                    GetWindowThreadProcessId(hwnd, out owner);
                    if (!IsWindow(hwnd) || owner != pid) return null;
                    if (!PrintWindow(hwnd, dc, 3)) return null; // PW_CLIENTONLY | PW_RENDERFULLCONTENT
                    GdiFlush();
                    var pixels = new byte[4 * w * h];
                    Marshal.Copy(bits, pixels, 0, pixels.Length);
                    return pixels;
                }
                finally { SelectObject(dc, old); }
            }
            finally { DeleteObject(bmp); }
        }
        finally { DeleteDC(dc); }
    }

    static readonly uint[] CrcTable = MakeCrcTable();
    static uint[] MakeCrcTable()
    {
        var t = new uint[256];
        for (uint n = 0; n < 256; n++) { uint c = n; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; t[n] = c; }
        return t;
    }
    static void BigEndian(byte[] b, int at, uint v) { b[at] = (byte)(v >> 24); b[at + 1] = (byte)(v >> 16); b[at + 2] = (byte)(v >> 8); b[at + 3] = (byte)v; }
    static void Chunk(Stream s, string type, byte[] data)
    {
        var head = new byte[8];
        BigEndian(head, 0, (uint)data.Length); Encoding.ASCII.GetBytes(type, 0, 4, head, 4);
        s.Write(head, 0, 8); s.Write(data, 0, data.Length);
        uint c = 0xFFFFFFFFu;
        for (int i = 4; i < 8; i++) c = CrcTable[(c ^ head[i]) & 0xFF] ^ (c >> 8);
        foreach (byte b in data) c = CrcTable[(c ^ b) & 0xFF] ^ (c >> 8);
        var tail = new byte[4];
        BigEndian(tail, 0, c ^ 0xFFFFFFFFu); s.Write(tail, 0, 4);
    }
    // 8-bit RGB (the bitmap's fourth byte dropped), filter 0 on every row
    static byte[] Png(byte[] bgrx, int w, int h)
    {
        var packed = new MemoryStream();
        using (var z = new ZLibStream(packed, CompressionLevel.Fastest, true))
        {
            var row = new byte[1 + 3 * w];
            for (int y = 0; y < h; y++)
            {
                for (int x = 0, s = 4 * w * y; x < w; x++, s += 4) { row[1 + 3 * x] = bgrx[s + 2]; row[2 + 3 * x] = bgrx[s + 1]; row[3 + 3 * x] = bgrx[s]; }
                z.Write(row, 0, row.Length);
            }
        }
        var ihdr = new byte[13];
        BigEndian(ihdr, 0, (uint)w); BigEndian(ihdr, 4, (uint)h); ihdr[8] = 8; ihdr[9] = 2;
        var file = new MemoryStream();
        file.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }, 0, 8);
        Chunk(file, "IHDR", ihdr); Chunk(file, "IDAT", packed.ToArray()); Chunk(file, "IEND", new byte[0]);
        return file.ToArray();
    }
}
'@

function Initialize-HarnessCapture {
    if ('HarnessCapture' -as [type]) { return }
    try { Add-Type -TypeDefinition $script:ServiceSource -ErrorAction Stop }
    catch { throw "the capture service could not be built: $($_.Exception.Message -replace '\s+', ' ')" }
}

# Scenario ids and state names have no dots, and an offset has no '-': <state>-<ms> names each shot once
function Get-HarnessCapturePlan {
    param([Parameter(Mandatory)]$Scenario, [Parameter(Mandatory)][string]$Work)
    $states = ($Scenario.PSObject.Properties['states'] -and $Scenario.states) ? @($Scenario.states) : @()
    $dir = [IO.Path]::GetFullPath((Join-Path $Work "$($Scenario.id).shots"))
    $list = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $states.Count; $i++) {
        $w = $states[$i].PSObject.Properties['Windows'] ? $states[$i].Windows : $null
        $offsets = @(($w -and $w.PSObject.Properties['Capture']) ? @($w.Capture) : @())
        for ($k = 0; $k -lt $offsets.Count; $k++) {
            $base = Join-Path $dir "$($states[$i].Name)-$([int]$offsets[$k])"
            $list.Add([pscustomobject]@{ State = $states[$i].Name; StateNo = $i + 1; K = $k + 1; At = [int]$offsets[$k]; Name = "$($states[$i].Name)-$([int]$offsets[$k]).png"; Png = "$base.png"; Req = "$base.req"; Done = "$base.done"; Err = "$base.err" })
        }
    }
    if (-not $list.Count) { return $null }
    [pscustomobject]@{ Dir = $dir; Shots = $list.ToArray() }
}

# At most 1024 bytes of ASCII, one key=value a line, every key once
function Read-HarnessShotAnswer {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][ValidateSet('done', 'err')][string]$Kind)
    try {
        if ([IO.FileInfo]::new($Path).Length -gt 1024) { return $null }
        $bytes = [IO.File]::ReadAllBytes($Path)
    } catch { return $null }
    if ($bytes.Length -gt 1024 -or @($bytes | Where-Object { $_ -gt 127 }).Count) { return $null }
    $map = [ordered]@{}
    foreach ($line in ([Text.Encoding]::ASCII.GetString($bytes) -split "`n")) {
        if ($line -ceq '') { continue }
        if ($line -cnotmatch '\A([a-z]+)=([ -~]*)\z' -or $map.Contains($Matches[1])) { return $null }
        $map[$Matches[1]] = $Matches[2]
    }
    if ($Kind -ceq 'err') {
        if ((@($map.get_Keys()) -join ',') -cne 'reason') { return $null }
        $r = $map['reason']
        if ($r -cmatch '\Awindows ([2-9]|[1-9][0-9]{1,2})\z') { return "$($Matches[1]) plugin windows of this REAPER were visible: which one is meant cannot be told" }
        if ($r -cmatch '\Afailed ([A-Za-z][A-Za-z0-9]{0,63})\z') { return "the capture failed ($($Matches[1]))" }
        foreach ($k in $script:ShotReasons.get_Keys()) { if ($k -ceq $r) { return $script:ShotReasons[$k] } }
        return $null
    }
    if ((@($map.get_Keys() | Sort-Object) -join ',') -cne 'dpi,height,view,width') { return $null }
    $num = { param([string]$Text, [int]$Least, [int]$Most) $v = 0; ($Text -cmatch '\A-?[0-9]{1,6}\z' -and [int]::TryParse($Text, [ref]$v) -and $v -ge $Least -and $v -le $Most) ? $v : $null }
    $width = & $num $map['width'] 1 $script:ShotMaxSide
    $height = & $num $map['height'] 1 $script:ShotMaxSide
    $dpi = & $num $map['dpi'] 1 2000
    if ($null -eq $width -or $null -eq $height -or $null -eq $dpi) { return $null }
    $view = $null
    if ($map['view'] -cne 'none') {
        $parts = @($map['view'] -split ',')
        if ($parts.Count -ne 4) { return $null }
        $v = @((& $num $parts[0] -65536 65536), (& $num $parts[1] -65536 65536), (& $num $parts[2] 0 65536), (& $num $parts[3] 0 65536))
        if (@($v | Where-Object { $null -eq $_ }).Count) { return $null }
        $view = [ordered]@{ x = $v[0]; y = $v[1]; w = $v[2]; h = $v[3] }
    }
    [pscustomobject]@{ Width = $width; Height = $height; View = $view; Dpi = $dpi }
}

# The PNG signature, then the IHDR chunk with the answer's width and height (big-endian); nothing else is looked at
function Test-HarnessShotImage([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Answer) {
    try {
        $head = [byte[]]::new(24); $got = 0
        $fs = [IO.File]::OpenRead($Path)
        try { while ($got -lt 24) { $n = $fs.Read($head, $got, 24 - $got); if ($n -le 0) { break }; $got += $n } } finally { $fs.Dispose() }
    } catch { return $false }
    $be = { param([int]$At) ([long]$head[$At] -shl 24) -bor ([long]$head[$At + 1] -shl 16) -bor ([long]$head[$At + 2] -shl 8) -bor [long]$head[$At + 3] }
    $got -eq 24 -and ([Convert]::ToHexString($head, 0, 16)) -ceq '89504E470D0A1A0A0000000D49484452' -and (& $be 16) -eq $Answer.Width -and (& $be 20) -eq $Answer.Height
}

function ConvertTo-ShotNumber([AllowNull()][string]$Text) {
    $v = 0.0
    if (-not $Text -or -not [double]::TryParse($Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -or [double]::IsNaN($v) -or [double]::IsInfinity($v)) { return $null }
    [long][Math]::Round($v)
}

# One entry of a state's facts; path, bytes and sha256 stay null here (collection fills them in after the move)
function New-HarnessShotFact($Shot) {
    [ordered]@{ at = $Shot.At; held = $null; wallMs = $null; name = $Shot.Name; taken = $false; problem = $null; path = $null; bytes = $null; sha256 = $null; width = $null; height = $null; view = $null; dpi = $null }
}

# Facts: the driver's key=value result; Stopped: CaptureStopped of the launch ($false: the service may still write, so
# nothing is read). By the driver's st<n>_shot<k>: done (the answer and the image are checked), err (its reason), late,
# gone, none; anything else is reported without the driver's text.
function Get-HarnessShotFacts {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][hashtable]$Facts, [Parameter(Mandatory)][int]$StateNo, $Stopped = $null)
    , @(foreach ($x in @($Plan.Shots | Where-Object { $_.StateNo -eq $StateNo })) {
            $key = "st${StateNo}_shot$($x.K)"
            $one = New-HarnessShotFact $x
            $one.held = ConvertTo-ShotNumber $Facts["${key}_held"]
            $one.wallMs = ConvertTo-ShotNumber $Facts["${key}_wall"]
            if ($false -eq $Stopped) { $one.problem = 'the capture service did not stop in time'; $one; continue }
            $said = $Facts.ContainsKey($key) ? [string]$Facts[$key] : $null
            $one.problem = switch -CaseSensitive ($said) {
                'done' {
                    $a = (Test-Path -LiteralPath $x.Done -PathType Leaf) ? (Read-HarnessShotAnswer -Path $x.Done -Kind done) : $null
                    if (-not (Test-Path -LiteralPath $x.Done -PathType Leaf)) { 'the driver saw an answer, but there is no answer file' }
                    elseif (-not $a) { 'the answer file cannot be read' }
                    elseif (-not (Test-HarnessShotImage -Path $x.Png -Answer $a)) { 'the image does not match its answer' }
                    else { $one.taken = $true; $one.width = $a.Width; $one.height = $a.Height; $one.view = $a.View; $one.dpi = $a.Dpi; $null }
                }
                'err' { (Read-HarnessShotAnswer -Path $x.Err -Kind err) ?? 'the answer file cannot be read' }
                'late' { 'no answer within 10 s' }
                'gone' { 'the window was gone before the shot was taken' }
                'none' { 'it was never asked for: the window did not open, or the request could not be written' }
                default { ($null -eq $said) ? 'the driver reported nothing about it' : 'the driver reported an unknown state for it' }
            }
            $one
        })
}

Export-ModuleMember -Function Initialize-HarnessCapture, Get-HarnessCapturePlan, Read-HarnessShotAnswer, Test-HarnessShotImage, Get-HarnessShotFacts, New-HarnessShotFact
