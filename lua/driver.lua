-- SPDX-License-Identifier: MIT
--
-- The Lua driver of reaper-harness. The runner writes a job file (return { ... }) and passes its path in the
-- environment variable REAPER_HARNESS_JOB. The driver runs one step, writes "key=value" lines to job.result (last
-- line done=1) and quits REAPER. Errors are written as error=... before quitting; only the hang step never quits
-- (for the watchdog negative cases). Every wait yields to REAPER's message loop through a coroutine.
--   learn       add each plugin by name on its own track, set parameters by name and read them back, save the project
--               (the runner takes the plugin blocks from that file)
--   device      open a project, read back the audio device block size and sample rate and every FX's reported latency
--   savereopen  open a project, read its FX, save it as a new file, open that and read the FX again
--   instances   add and remove plugin instances many times; touch a mark file after the warm-up and at the end so
--               the runner can sample handle and memory counts there
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

-- job.fx: list of { name = "VST3: Name (Vendor)", params = { { name, value, display? } ... } }; job.saveAs.
-- Reported per entry n (1-based): fx<n>_idx (-1 = REAPER could not add it), fx<n>_name, fx<n>_ident, fx<n>_pdc,
-- fx<n>_offline, fx<n>_nparams, and per parameter k: fx<n>_p<k>=<normalized read back> or missing,
-- fx<n>_p<k>_display=<text read back>.
function steps.learn()
    reaper.Main_OnCommand(40023, 0) -- File: New project
    wait(0.5)
    for n, e in ipairs(job.fx) do
        reaper.InsertTrackAtIndex(reaper.CountTracks(0), false)
        local track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
        reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "learn-" .. n, true)
        local idx = reaper.TrackFX_AddByName(track, e.name, false, -1)
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
    putTracks("", job.reads)
end

function steps.savereopen()
    openAndWait(job.project)
    putTracks("before_", job.reads)
    reaper.Main_SaveProjectEx(0, job.saveAs, 0)
    wait(0.5)
    openAndWait(job.saveAs)
    putTracks("after_", job.reads)
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
