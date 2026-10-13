-- The handheld's volume and screen brightness, for the touch remote's
-- sliders (music and video). ROCKNIX keeps them in system.cfg, and its own
-- volume and brightness commands, the hardware keys and ES all write there,
-- so the sliders read the same values and set them through those commands.
local mp = require "mp"
local utils = require "mp.utils"

local L = {}
local SYSTEM_CFG = "/storage/.config/system/configs/system.cfg"
local BACKLIGHTS = "/sys/class/backlight"
local SECOND_NOTE = "/run/handheld-second-backlight"  -- the second screen's backlight, found by media-hub.py
local SYNC_FILE = "/storage/.config/mpv/handheld-brightness-sync"  -- both screens move together
local cache, mtime = { volume = 50, screens = {} }, nil

-- The brightness command numbers the screens by their backlights in order
-- (screen 1 is display.brightness, screen N display.brightnessN).
local function screen_numbers()
    local names = {}
    for _, n in ipairs(utils.readdir(BACKLIGHTS) or {}) do names[#names + 1] = n end
    table.sort(names)
    local f = io.open(SECOND_NOTE)
    local second = f and f:read("*l")
    if f then f:close() end
    local top, bottom
    for i, n in ipairs(names) do
        if n == second then bottom = i elseif not top then top = i end
    end
    return top or 1, bottom
end

-- { volume, top, bottom, sync } in percent; bottom is nil with one screen (or before
-- the hub has told which backlight is the second screen's)
function L.get()
    local info = utils.file_info(SYSTEM_CFG)
    if info and info.mtime ~= mtime then
        mtime = info.mtime
        local f = io.open(SYSTEM_CFG)
        if f then
            for line in f:lines() do
                local v = line:match("^audio%.volume=(%d+)")
                if v then cache.volume = tonumber(v) end
                local n, b = line:match("^display%.brightness(%d*)=(%d+)")
                if b then cache.screens[tonumber(n ~= "" and n or 1)] = tonumber(b) end
            end
            f:close()
        end
    end
    local top, bottom = screen_numbers()
    return { volume = cache.volume, top = cache.screens[top] or 50,
             bottom = bottom and (cache.screens[bottom] or 50) or nil,
             sync = utils.file_info(SYNC_FILE) ~= nil }
end

-- One command at a time: ROCKNIX's set_setting rewrites system.cfg, and two at
-- once leave a key there twice. A value that comes while one runs waits, and
-- only the newest one of each kind is applied.
local running, pending = false, {}

local function run_next()
    local kind, value = next(pending)
    if not kind then running = false; return end
    pending[kind] = nil
    running = true
    local args
    if kind == "volume" then args = { "volume", tostring(value) }
    elseif kind == "all" then args = { "brightness", "set", "all", tostring(value) }
    else
        local top, bottom = screen_numbers()
        local n = kind == "bottom" and bottom or top
        args = { "brightness", "set", tostring(n), tostring(value) }
    end
    mp.command_native_async({ name = "subprocess", args = args, playback_only = false }, run_next)
end

-- kind: "volume" | "top" | "bottom" (a screen's brightness); value: percent
function L.set(kind, value)
    if kind ~= "volume" and kind ~= "top" and kind ~= "bottom" then return end
    value = math.max(kind == "volume" and 0 or 5, math.min(100, math.floor((tonumber(value) or 0) + 0.5)))
    if kind == "volume" then cache.volume = value
    elseif utils.file_info(SYNC_FILE) then  -- synced: every screen follows
        for n in pairs(cache.screens) do cache.screens[n] = value end
        pending.top, pending.bottom = nil, nil
        kind = "all"
    else
        local top, bottom = screen_numbers()
        local n = kind == "bottom" and bottom or top
        if not n then return end
        cache.screens[n] = value  -- shown at once; the command writes system.cfg as well
    end
    pending[kind] = value
    if not running then run_next() end
end

-- Link the screens' brightness (both take the top screen's) or let them go apart.
function L.set_sync(on)
    if on then
        local f = io.open(SYNC_FILE, "w")
        if f then f:close() end
        L.set("top", L.get().top)
    else
        os.remove(SYNC_FILE)
    end
end

return L
