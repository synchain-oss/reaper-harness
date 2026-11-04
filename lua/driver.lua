-- SPDX-License-Identifier: MIT
--
-- The Lua driver of reaper-harness. The runner writes a job file (return { ... }) and passes its path in the
-- environment variable REAPER_HARNESS_JOB. The driver runs one step, writes "key=value" lines to job.result (last
-- line done=1) and quits REAPER. Errors are written as error=... before quitting; only the hang step never quits
-- (for the watchdog negative cases). Every wait yields to REAPER's message loop through a coroutine.
--   learn       open the learn project; add each plugin by name on its own track (or take the one a state block
--               already put there), set parameters by name and read them back, save the project (the runner takes
--               the plugin blocks from that file)
--   device      open a project, read back the audio device block size and sample rate, the workrender setting and
--               every FX's reported latency; save a copy when asked (it shows the state each plugin holds)
--   savereopen  open a project, read its FX, then cycles times: save it as a new file, open that and read the FX again
--   instances   add and remove plugin instances many times; touch a mark file after the warm-up and at the end so
--               the runner can sample handle and memory counts there
--   transport   open a project, read it back like device, then take the tested track through a list of transport, arm
--               and monitoring states and count, per state, the blocks its FX chain is run with and what they carry
--   hang        never finishes (watchdog negative cases)
-- Extension steps: job.extensions lists Lua files; each returns a table of step name -> function(h), where h gives
-- the job and the helpers below. A step name that is already taken is an error (the runner checks the names in the
-- "-- harness-steps:" header of each file before REAPER starts; this is the second line of defence).

local job = dofile(os.getenv("REAPER_HARNESS_JOB"))
local lines = {}

local function clean(v)
    return (tostring(v):gsub("[%c]", " "))
end

local function put(key, value) lines[#lines + 1] = key .. "=" .. clean(value) end

local function flushResult()
    local part = job.result .. ".part"
    local f = assert(io.open(part, "w"))
    f:write(table.concat(lines, "\n"), "\ndone=1\n")
    f:close()
    os.remove(job.result)
    assert(os.rename(part, job.result))
end

local function touch(path)
    local f = assert(io.open(path, "w"))
    f:write("1")
    f:close()
end

local function wait(seconds)
    local untilTime = reaper.time_precise() + seconds
    while reaper.time_precise() < untilTime do coroutine.yield() end
end

local function device(attr)
    for _ = 1, 50 do
        local ok, value = reaper.GetAudioDeviceInfo(attr, "")
        if ok then return value end
        wait(0.1)
    end
    return "unavailable"
end

local function openAndWait(path)
    reaper.Main_openProject("noprompt:" .. path)
    wait(1.0) -- let the plugins instantiate before anything is read
end

local function named(track, fx, key)
    local ok, v = reaper.TrackFX_GetNamedConfigParm(track, fx, key)
    return ok and v or ""
end

local function config(name)
    local ok, v = reaper.get_config_var_string(name)
    return ok and v or "unavailable"
end

local function findParam(track, fx, name)
    for p = 0, reaper.TrackFX_GetNumParams(track, fx) - 1 do
        local _, pn = reaper.TrackFX_GetParamName(track, fx, p, "")
        if pn == name then return p end
    end
    return nil
end

local function paramText(track, fx, p)
    local _, txt = reaper.TrackFX_GetFormattedParamValue(track, fx, p, "")
    return txt
end

-- Every track and FX of the open project. reads: list of { t = track index, f = fx index, name = parameter name }
-- whose values are reported as <prefix>t<i>_fx<j>_param<k>=<normalized> and ..._display<k>=<text>.
local function putTracks(prefix, reads)
    local n = reaper.CountTracks(0)
    put(prefix .. "tracks", n)
    for t = 0, n - 1 do
        local track = reaper.GetTrack(0, t)
        local _, tname = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
        local count = reaper.TrackFX_GetCount(track)
        put(prefix .. "t" .. t .. "_name", tname)
        put(prefix .. "t" .. t .. "_fx_count", count)
        for i = 0, count - 1 do
            local _, name = reaper.TrackFX_GetFXName(track, i, "")
            local p = prefix .. "t" .. t .. "_fx" .. i .. "_"
            put(p .. "name", name)
            put(p .. "pdc", named(track, i, "pdc"))
            put(p .. "chain_pdc_actual", named(track, i, "chain_pdc_actual"))
            put(p .. "bypassed", not reaper.TrackFX_GetEnabled(track, i))
            put(p .. "offline", reaper.TrackFX_GetOffline(track, i))
        end
    end
    for k, r in ipairs(reads or {}) do
        local track = reaper.GetTrack(0, r.t)
        local p = prefix .. "t" .. r.t .. "_fx" .. r.f .. "_"
        local idx = track and findParam(track, r.f, r.name) or nil
        if idx then
            put(p .. "param" .. k, string.format("%.9f", reaper.TrackFX_GetParamNormalized(track, r.f, idx)))
            put(p .. "display" .. k, paramText(track, r.f, idx))
        else
            put(p .. "param" .. k, "missing")
        end
    end
end

local steps = {}

-- job.project: one track per entry, in order (named learn-<n>, or after the template track of its state), empty or
-- holding a state block; entry n is on track n whatever its name; job.fx: list of { name = the name to add
-- it by, preloaded = true when the track already holds it, params = { { name, value, display? } ... } }; job.saveAs.
-- Reported per entry n (1-based): fx<n>_idx (-1 = REAPER could not add it, or the state block did not load),
-- fx<n>_name, fx<n>_ident, fx<n>_pdc, fx<n>_offline, fx<n>_nparams, and per parameter k:
-- fx<n>_p<k>=<normalized read back> or missing, fx<n>_p<k>_display=<text read back>.
function steps.learn()
    if job.project then
        openAndWait(job.project)
    else
        reaper.Main_OnCommand(40023, 0) -- File: New project
        wait(0.5)
    end
    for n, e in ipairs(job.fx) do
        local track = reaper.GetTrack(0, n - 1)
        if not track then
            reaper.InsertTrackAtIndex(reaper.CountTracks(0), false)
            track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
            reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "learn-" .. n, true)
        end
        local idx
        if e.preloaded then
            idx = (reaper.TrackFX_GetCount(track) == 1) and 0 or -1
        else
            idx = reaper.TrackFX_AddByName(track, e.name, false, -1)
        end
        local key = "fx" .. n .. "_"
        put(key .. "idx", idx)
        if idx >= 0 then
            local _, name = reaper.TrackFX_GetFXName(track, idx, "")
            put(key .. "name", name)
            put(key .. "ident", named(track, idx, "fx_ident"))
            put(key .. "pdc", named(track, idx, "pdc"))
            put(key .. "offline", reaper.TrackFX_GetOffline(track, idx))
            put(key .. "nparams", reaper.TrackFX_GetNumParams(track, idx))
            for k, prm in ipairs(e.params or {}) do
                local p = findParam(track, idx, prm.name)
                if p then
                    reaper.TrackFX_SetParamNormalized(track, idx, p, prm.value)
                    put(key .. "p" .. k, string.format("%.9f", reaper.TrackFX_GetParamNormalized(track, idx, p)))
                    put(key .. "p" .. k .. "_display", paramText(track, idx, p))
                else
                    put(key .. "p" .. k, "missing")
                end
            end
        end
    end
    wait(1.0)
    reaper.Main_SaveProjectEx(0, job.saveAs, 0)
    wait(0.5)
    put("saved", reaper.file_exists(job.saveAs))
end

function steps.device()
    openAndWait(job.project)
    put("dev_bsize", device("BSIZE"))
    put("dev_srate", device("SRATE"))
    put("dev_mode", device("MODE"))
    put("project_srate", reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false))
    put("cfg_workrender", config("workrender"))
    put("cfg_runallonstop", config("runallonstop"))
    putTracks("", job.reads)
    if job.saveAs then
        reaper.Main_SaveProjectEx(0, job.saveAs, 0)
        wait(0.5)
        put("saved", reaper.file_exists(job.saveAs))
    end
end

-- job.cycles (default 1): reports before_... once, then after<i>_... for each save and reopen.
function steps.savereopen()
    openAndWait(job.project)
    putTracks("before_", job.reads)
    for i = 1, (job.cycles or 1) do
        reaper.Main_SaveProjectEx(0, job.saveAs, 0)
        wait(0.5)
        openAndWait(job.saveAs)
        putTracks("after" .. i .. "_", job.reads)
    end
    put("saved", reaper.file_exists(job.saveAs))
end

-- job.names: plugin names to add on each cycle's track, in order; job.cycles, job.warmup, job.play, job.warmMark,
-- job.loopMark.
function steps.instances()
    openAndWait(job.project)
    local made = 0
    if job.warmup == 0 then -- no warm-up cycles: the first sample is taken before the first cycle
        touch(job.warmMark)
        wait(0.8)
    end
    for i = 1, job.cycles do
        reaper.InsertTrackAtIndex(reaper.CountTracks(0), false)
        local track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
        for k, name in ipairs(job.names) do
            local idx = reaper.TrackFX_AddByName(track, name, false, -1)
            if idx ~= k - 1 then error("cycle " .. i .. ": adding " .. name .. " returned " .. tostring(idx) .. ", expected " .. (k - 1)) end
        end
        if job.play then
            reaper.OnPlayButton()
            wait(0.25)
            reaper.OnStopButton()
        else
            wait(0.1)
        end
        reaper.DeleteTrack(track)
        made = made + 1
        if i == job.warmup then
            touch(job.warmMark)
            wait(0.8)
        end
    end
    put("cycles_done", made)
    put("tracks_left", reaper.CountTracks(0))
    touch(job.loopMark)
    wait(0.8)
end

-- job.track: index of the tested track; job.probe, job.feed: the names to add the block probe and the feed JSFX by
-- (no feed without job.feed); job.feedMode: the feed's Channels parameter; job.settle: device samples to let pass after
-- each change of state (default: REAPER's "run FX after stopping" time plus half a second); job.sr; job.recordDir;
-- job.states: list of { name, transport = "stop" | "play" | "pause", arm = 0 | 1, monitor = 0 | 1 | 2, samples }.
-- After the readback a clock track goes at the end (armed, recording disabled, no input, monitoring off, no master
-- send) with a block probe in gmem slot 0; a block probe goes first in the chain of the tested track (slot 1) and the
-- feed into its input chain (slot 2). Settling and windows are counted in clock samples, not in wall-clock time.
-- They write their counts one at a time on the audio thread, with value 10 of the slot, a generation, odd meanwhile: a
-- reading counts only if that was even and the same before and after it, so no half-written block is taken as evidence.
-- This step never records: no record action is called anywhere in this file, every wait checks the transport for the
-- record bit, both tracks have recording disabled and the record path is the work directory.
-- Reported per state n: st<n>_settled, st<n>_clock and _clock_samples (device blocks and samples of the window),
-- _blocks, _samples, _silent, _signal, _left, _right, _equal (the tested chain), _fed and _fed_samples (blocks and
-- frames the feed played), _playstate, _arm, _monitor and _monitoring (read back at the end of the window). A state
-- without a clean reading has no _clock up to _fed_samples, which makes it a state that was not observed.
function steps.transport()
    openAndWait(job.project)
    put("dev_bsize", device("BSIZE"))
    put("dev_srate", device("SRATE"))
    put("dev_mode", device("MODE"))
    put("cfg_workrender", config("workrender"))
    put("cfg_runallonstop", config("runallonstop"))
    local after = config("runafterstop")
    put("cfg_runafterstop", after)
    putTracks("", job.reads)
    local setOk = reaper.GetSetProjectInfo_String(0, "RECORD_PATH", job.recordDir, true)
    local _, path = reaper.GetSetProjectInfo_String(0, "RECORD_PATH", "", false)
    local pathOk = setOk and path == job.recordDir
    put("record_path", pathOk and "ok" or "failed")
    -- Fail closed: without the record path in the work directory nothing is armed and the transport is never touched
    if not pathOk then error("the record path of the project could not be set to the work directory; nothing was armed") end
    local tested = reaper.GetTrack(0, job.track)
    if not tested then error("the project has no track " .. tostring(job.track)) end
    reaper.InsertTrackAtIndex(reaper.CountTracks(0), false)
    local clock = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
    reaper.GetSetMediaTrackInfo_String(clock, "P_NAME", "harness-clock", true)
    for _, kv in ipairs({ { "I_RECINPUT", -1 }, { "I_RECMODE", 2 }, { "I_RECMON", 0 }, { "B_MAINSEND", 0 }, { "I_RECARM", 1 } }) do
        reaper.SetMediaTrackInfo_Value(clock, kv[1], kv[2])
    end
    reaper.SetMediaTrackInfo_Value(tested, "I_RECINPUT", -1)
    reaper.SetMediaTrackInfo_Value(tested, "I_RECMODE", 2)
    local cfx = reaper.TrackFX_AddByName(clock, job.probe, false, -1000)
    local pfx = reaper.TrackFX_AddByName(tested, job.probe, false, -1000)
    put("clock_ident", cfx >= 0 and named(clock, cfx, "fx_ident") or "")
    put("probe_idx", pfx)
    put("probe_ident", pfx >= 0 and named(tested, pfx, "fx_ident") or "")
    put("probe_fx_count", reaper.TrackFX_GetCount(tested))
    local ffx = 0
    if job.feed then
        ffx = reaper.TrackFX_AddByName(tested, job.feed, true, -1)
        if ffx >= 0 and ffx < 0x1000000 then ffx = ffx + 0x1000000 end -- the input chain is addressed from 0x1000000
        put("feed_ident", ffx >= 0 and named(tested, ffx, "fx_ident") or "")
    end
    if cfx < 0 or pfx < 0 or ffx < 0 then error("the block probes or the feed could not be added") end
    reaper.TrackFX_SetParam(clock, cfx, 0, 0)
    reaper.TrackFX_SetParam(tested, pfx, 0, 1)
    if job.feed then
        reaper.TrackFX_SetParam(tested, ffx, 0, 2)
        reaper.TrackFX_SetParam(tested, ffx, 1, job.feedMode)
    end
    reaper.gmem_attach("ReaperHarness")
    local CLOCK, TESTED, FEED = 0, 16, 32
    for i = 0, 47 do reaper.gmem_write(i, 0) end
    reaper.gmem_write(FEED + 11, -2) -- the feed writes its file_open result here when it first runs
    local function int(x) return math.floor(x + 0.5) end
    local function noRecord()
        if reaper.GetPlayState() & 4 ~= 0 then
            reaper.OnStopButton()
            error("the transport showed the record state; stopped")
        end
    end
    local function waitSamples(n)
        local start = reaper.gmem_read(CLOCK + 1)
        local deadline = reaper.time_precise() + 3 * n / job.sr + 10
        while reaper.gmem_read(CLOCK + 1) - start < n do
            noRecord()
            if reaper.time_precise() > deadline then
                error("the device clock stopped: " .. int(reaper.gmem_read(CLOCK + 1) - start) .. " of " .. n .. " samples")
            end
            coroutine.yield()
        end
        noRecord()
        return reaper.gmem_read(CLOCK + 1) - start
    end
    local SNAP_TRIES = 1000 -- bounded: this spins on the main thread
    local function snap(base)
        for _ = 1, SNAP_TRIES do
            local g = reaper.gmem_read(base + 10)
            if g % 2 == 0 then
                local v = {}
                for i = 0, 15 do v[i] = reaper.gmem_read(base + i) end
                if reaper.gmem_read(base + 10) == g then return v end
            end
        end
    end
    local function transport(want)
        local ps = reaper.GetPlayState()
        if want == "stop" then
            if ps ~= 0 then reaper.OnStopButton() end
        elseif want == "play" then
            if ps & 1 == 0 or ps & 2 ~= 0 then reaper.OnPlayButton() end
        elseif want == "pause" then
            if ps & 2 == 0 then reaper.OnPauseButton() end
        end
    end
    local settle = job.settle or int(((tonumber(after) or 4000) + 500) * job.sr / 1000)
    put("settle", settle)
    local done = 0
    for n, st in ipairs(job.states) do
        reaper.SetMediaTrackInfo_Value(tested, "I_RECARM", st.arm)
        reaper.SetMediaTrackInfo_Value(tested, "I_RECMON", st.monitor)
        transport(st.transport)
        local p = "st" .. n .. "_"
        put(p .. "settled", int(waitSamples(settle)))
        local c0, t0, f0 = snap(CLOCK), snap(TESTED), snap(FEED)
        waitSamples(st.samples)
        local c1, t1, f1 = snap(CLOCK), snap(TESTED), snap(FEED)
        if c0 and t0 and f0 and c1 and t1 and f1 then
            put(p .. "clock", int(c1[0] - c0[0]))
            put(p .. "clock_samples", int(c1[1] - c0[1]))
            for i, key in ipairs({ "blocks", "samples", "silent", "signal", "left", "right", "equal" }) do put(p .. key, int(t1[i - 1] - t0[i - 1])) end
            put(p .. "fed", int(f1[0] - f0[0]))
            put(p .. "fed_samples", int(f1[1] - f0[1]))
        end
        put(p .. "playstate", reaper.GetPlayState())
        put(p .. "arm", int(reaper.GetMediaTrackInfo_Value(tested, "I_RECARM")))
        put(p .. "monitor", int(reaper.GetMediaTrackInfo_Value(tested, "I_RECMON")))
        put(p .. "monitoring", int(reaper.GetMediaTrackInfo_Value(tested, "B_RECMON_IN_EFFECT")))
        done = n
    end
    reaper.OnStopButton()
    reaper.SetMediaTrackInfo_Value(tested, "I_RECARM", 0)
    reaper.SetMediaTrackInfo_Value(clock, "I_RECARM", 0)
    put("states_done", done)
    put("feed_handle", int(reaper.gmem_read(FEED + 11)))
    put("feed_channels", int(reaper.gmem_read(FEED + 12)))
    put("feed_rate", int(reaper.gmem_read(FEED + 13)))
end

function steps.hang()
    while true do wait(0.5) end
end

local builtin = {}
for name in pairs(steps) do builtin[name] = true end

local function loadExtensions()
    local helpers = { job = job, put = put, wait = wait, touch = touch, device = device, openAndWait = openAndWait, putTracks = putTracks, findParam = findParam, paramText = paramText }
    for _, path in ipairs(job.extensions or {}) do
        local chunk = assert(loadfile(path))
        local added = chunk()
        if type(added) ~= "table" then error("extension " .. path .. " did not return a table of steps") end
        for name, fn in pairs(added) do
            if builtin[name] or steps[name] then error("extension step '" .. tostring(name) .. "' is already defined") end
            if type(fn) ~= "function" then error("extension step '" .. tostring(name) .. "' is not a function") end
            steps[name] = function() return fn(helpers) end
        end
    end
end

local function run()
    loadExtensions()
    local step = steps[job.step]
    if not step then error("no such step: " .. tostring(job.step)) end
    step()
end

local co = coroutine.create(function()
    local ok, err = pcall(run)
    if not ok then put("error", tostring(err)) end
    flushResult()
    reaper.Main_OnCommand(40004, 0) -- File: Quit REAPER (a modified project brings up the save prompt; the runner answers No)
end)

local function pump()
    local ok, err = coroutine.resume(co)
    if not ok then
        put("error", "driver: " .. tostring(err))
        pcall(flushResult)
        reaper.Main_OnCommand(40004, 0)
    elseif coroutine.status(co) ~= "dead" then
        reaper.defer(pump)
    end
end

pump()
