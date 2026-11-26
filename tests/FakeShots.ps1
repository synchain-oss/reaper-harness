# SPDX-License-Identifier: MIT
#
# The stand-in for REAPER's floating plugin window in the self-test's capture cases: the capture service
# (src/Capture.psm1) looks at its windows as it would at REAPER's. It makes top-level windows on a thread of its own,
# with a child of the class REAPER hosts a plugin's view in, and never touches a window of any other process.
#   -Show -Until <file> [-Two] [-NoWrap] [-Hidden] [-Title <text>] [-OtherClass] [-Wide] [-Flat] [-Chain]
#       shows the window (two with -Two; no view child with -NoWrap; not visible with -Hidden; another title, or a
#       class of its own instead of the dialog class; a client area of 4100 x 4 with -Wide or of 640 x 0 with -Flat,
#       both without a frame, which no screen size holds back; next to it an FX chain window titled "FX: Track 1" with
#       -Chain) until <file> exists, at most 60 s, then closes it
#   without -Show: the driver's part of the handshake, from the compact JSON in FAKE_SHOTS:
#       { result, window, two, chain, status, shots: [ { n, k, at, req, done, err, name } ] }
#       shows the window(s) when asked (chain: the FX chain window too), then for each shot in order writes its
#       request and waits up to 3 s for the done or the err file, appending st<n>_shot<k>=done|err|late,
#       st<n>_shot<k>_held=<at + 2> and _wall=<at + 5> to the result file; status overrides by name: late (the request,
#       no wait), gone and none (no request), noreq (done without a request), missing (no lines). Then it closes the
#       windows and appends done=1.
# The window: client area 640 x 427, the view child at (0, 27, 640, 400), as REAPER lays out a plugin's window; the view
# is painted in one colour (red 32, green 128, blue 224), so an image shows which rows and which channels are which.
param([switch]$Show, [string]$Until = '', [switch]$Two, [switch]$NoWrap, [switch]$Hidden, [string]$Title = 'VST3: Fake Capture (Test) - Track 1 [1/1]', [switch]$OtherClass, [switch]$Wide,
    [switch]$Flat, [switch]$Chain)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class FakeShotWindow
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASS { public uint style; public IntPtr proc; public int clsExtra, wndExtra; public IntPtr inst, icon, cursor, brush; public string menu, name; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint m; public IntPtr w, l; public uint t; public int x, y; }
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern ushort RegisterClass(ref WNDCLASS c);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
    [DllImport("user32")] static extern bool AdjustWindowRectEx(ref RECT r, uint style, bool menu, uint ex);
    [DllImport("user32")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    [DllImport("user32")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32")] static extern bool PeekMessage(out MSG m, IntPtr h, uint a, uint b, uint remove);
    [DllImport("user32")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32")] static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("user32")] static extern bool SetProcessDpiAwarenessContext(IntPtr c);
    [DllImport("gdi32")] static extern IntPtr CreateSolidBrush(uint color);
    [DllImport("kernel32", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    [DllImport("kernel32", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr module, string name);
    static volatile bool closing;
    static Thread thread;
    public static volatile int Made = -1;

    // w x h: the client area; any other than 640 x 427 is a window without a frame. chain: an FX chain window next to it
    public static void Open(int count, string title, bool noWrap, bool hidden, bool other, int w, int h, bool chain)
    {
        // Physical pixels at any display scale, so the sizes the cases expect hold
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch (Exception) { }
        thread = new Thread(() => Loop(count, title, noWrap, hidden, other, w, h, chain)) { IsBackground = true };
        thread.Start();
    }
    public static void Close() { closing = true; if (thread != null) thread.Join(5000); }

    static IntPtr Make(IntPtr inst, string cls, string title, uint style, int at, int w, int h, bool wrapped)
    {
        uint ex = 0x08000000u; // WS_EX_NOACTIVATE: the user's window keeps the focus
        var r = new RECT { R = w, B = h };
        AdjustWindowRectEx(ref r, style, false, ex);
        IntPtr made = CreateWindowEx(ex, cls, title, style, 120 + 40 * at, 120 + 40 * at, r.R - r.L, r.B - r.T, IntPtr.Zero, IntPtr.Zero, inst, IntPtr.Zero);
        RECT c;
        if (made != IntPtr.Zero && GetClientRect(made, out c) && (c.R != w || c.B != h))
            SetWindowPos(made, IntPtr.Zero, 0, 0, r.R - r.L + w - c.R, r.B - r.T + h - c.B, 0x0002u | 0x0004u | 0x0010u); // NOMOVE | NOZORDER | NOACTIVATE
        if (made != IntPtr.Zero && wrapped) CreateWindowEx(0, "reaperPluginHostWrapProc", "", 0x40000000u | 0x10000000u, 0, 27, 640, 400, made, IntPtr.Zero, inst, IntPtr.Zero);
        return made;
    }

    static void Loop(int count, string title, bool noWrap, bool hidden, bool other, int w, int h, bool chain)
    {
        IntPtr inst = GetModuleHandle(null);
        IntPtr plain = GetProcAddress(GetModuleHandle("user32.dll"), "DefWindowProcW");
        var wrap = new WNDCLASS { proc = plain, inst = inst, name = "reaperPluginHostWrapProc", brush = CreateSolidBrush(0x00E08020u) }; // 0x00BBGGRR
        RegisterClass(ref wrap);
        var own = new WNDCLASS { proc = plain, inst = inst, name = "FakeCaptureOther" };
        RegisterClass(ref own);
        uint shown = hidden ? 0u : 0x10000000u; // WS_VISIBLE
        uint framed = 0x00C00000u | 0x00080000u; // WS_CAPTION | WS_SYSMENU
        uint style = (w == 640 && h == 427 ? framed : 0x80000000u) | shown; // or WS_POPUP
        var made = new System.Collections.Generic.List<IntPtr>();
        for (int i = 0; i < count; i++) made.Add(Make(inst, other ? "FakeCaptureOther" : "#32770", title, style, i, w, h, !noWrap));
        if (chain) made.Add(Make(inst, "#32770", "FX: Track 1", framed | 0x10000000u, count, 640, 427, false));
        int ok = 0;
        foreach (IntPtr x in made) if (x != IntPtr.Zero) ok++;
        Made = ok;
        MSG m;
        while (!closing)
        {
            while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessage(ref m); }
            Thread.Sleep(10);
        }
        foreach (IntPtr x in made) if (x != IntPtr.Zero) DestroyWindow(x);
    }
}
'@

function Open-FakeShotWindow([int]$Count, [switch]$Plain, [bool]$WithChain) {
    $client = ($Plain -or -not ($Wide -or $Flat)) ? @(640, 427) : ($Wide ? @(4100, 4) : @(640, 0))
    [FakeShotWindow]::Open($Count, $Title, (-not $Plain -and $NoWrap), (-not $Plain -and $Hidden), (-not $Plain -and $OtherClass), $client[0], $client[1], $WithChain)
    $limit = [DateTime]::UtcNow.AddSeconds(10)
    while ([FakeShotWindow]::Made -lt 0 -and [DateTime]::UtcNow -lt $limit) { Start-Sleep -Milliseconds 20 }
}

if ($Show) {
    Open-FakeShotWindow ($Two ? 2 : 1) -WithChain $Chain.IsPresent
    $limit = [DateTime]::UtcNow.AddSeconds(60)
    while (-not ($Until -and (Test-Path -LiteralPath $Until)) -and [DateTime]::UtcNow -lt $limit) { Start-Sleep -Milliseconds 50 }
    [FakeShotWindow]::Close()
    exit 0
}

$spec = ConvertFrom-Json -InputObject ([string]$env:FAKE_SHOTS) -AsHashtable
if ($spec['window']) { Open-FakeShotWindow ($spec['two'] ? 2 : 1) -Plain -WithChain ([bool]$spec['chain']) }
$lines = [Collections.Generic.List[string]]::new()
foreach ($s in @($spec['shots'])) {
    $key = "st$($s['n'])_shot$($s['k'])"
    $how = ($spec['status'] -and $spec['status'].Contains($s['name'])) ? [string]$spec['status'][$s['name']] : ''
    if ($how -ceq 'missing') { continue }
    if ($how -cin 'gone', 'none') { $lines.Add("$key=$how"); continue }
    $answer = 'done'
    if ($how -cne 'noreq') {
        [IO.File]::WriteAllText($s['req'], '1')
        $answer = 'late'
        $limit = [DateTime]::UtcNow.AddSeconds(3)
        while ($how -cne 'late' -and [DateTime]::UtcNow -lt $limit) {
            if (Test-Path -LiteralPath $s['done']) { $answer = 'done'; break }
            if (Test-Path -LiteralPath $s['err']) { $answer = 'err'; break }
            Start-Sleep -Milliseconds 20
        }
    }
    $lines.Add("$key=$answer"); $lines.Add("${key}_held=$([int]$s['at'] + 2)"); $lines.Add("${key}_wall=$([int]$s['at'] + 5)")
}
if ($spec['window']) { [FakeShotWindow]::Close() }
$lines.Add('done=1')
[IO.File]::AppendAllText([string]$spec['result'], ($lines -join "`n") + "`n")
exit 0
