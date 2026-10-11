-- Player logic shared by every instance that plays a file: settings and their
-- persistence, episodes in the same folder, deleting, moving between screens,
-- and the state snapshot the touch controls draw from.

local mp = require "mp"
local utils = require "mp.utils"
local S = require "settings"

local P = {}

local SAVE_FILE = "/storage/.config/mpv/handheld-menu.json"
local PERSISTED = { "sub-scale", "sub-outline-size", "sub-shadow-offset", "sub-border-style", "sub-pos" }
local HUB = mp.get_opt("handheld-hub") or "/storage/.config/mpv/media-hub.py"  -- set by the launcher
local ES_API = "http://127.0.0.1:1234"

P.opts = { autoplay = true, remote_on = false }
P.deleted_any = false

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

function P.save()
    local data = {}
    for _, p in ipairs(PERSISTED) do data[p] = mp.get_property_native(p) end
    data.autoplay = P.opts.autoplay
    data.remote_on = P.opts.remote_on
    local f = io.open(SAVE_FILE, "w")
    if f then f:write(utils.format_json(data)); f:close() end
end

function P.load()
    local f = io.open(SAVE_FILE, "r")
    if not f then return end
    local data = utils.parse_json(f:read("*a") or "")
    f:close()
    if type(data) ~= "table" then return end
    for _, p in ipairs(PERSISTED) do
        if data[p] ~= nil then mp.set_property_native(p, data[p]) end
    end
    if data.autoplay ~= nil then P.opts.autoplay = data.autoplay end
    if data.remote_on ~= nil then P.opts.remote_on = data.remote_on end
end

-- Tracks ------------------------------------------------------------------

local function tracks(kind)
    local list = {}
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == kind then list[#list + 1] = t end
    end
    return list
end

local LANGS = { jpn = "Japanese", ja = "Japanese", eng = "English", en = "English", tur = "Turkish", tr = "Turkish",
                ger = "German", deu = "German", fre = "French", fra = "French", spa = "Spanish", ita = "Italian",
                por = "Portuguese", rus = "Russian", ara = "Arabic", chi = "Chinese", zho = "Chinese", kor = "Korean" }

function P.track_name(t)
    if not t then return "Off" end
    if t.title and t.title ~= "" then return t.title end
    if t.lang then return LANGS[t.lang:lower()] or t.lang end
    return "Track " .. t.id
end

function P.current_track(kind)
    local id = mp.get_property_native(kind == "sub" and "sid" or "aid")
    for _, t in ipairs(tracks(kind)) do
        if t.id == id then return t end
    end
end

function P.step_track(kind, dir)
    local prop = kind == "sub" and "sid" or "aid"
    local list = tracks(kind)
    if #list == 0 then return end
    local ids = {}
    if kind == "sub" then ids[1] = "no" end
    for _, t in ipairs(list) do ids[#ids + 1] = t.id end
    local cur = mp.get_property_native(prop)
    local idx = 1
    for i, id in ipairs(ids) do if id == cur or (cur == false and id == "no") then idx = i end end
    idx = (idx - 1 + dir) % #ids + 1
    mp.set_property(prop, tostring(ids[idx]))
end

-- Settings ----------------------------------------------------------------
-- Three tabs, the same on the pad menu and the touch screen (settings.lua).

local function numeric(prop, step, lo, hi)
    return function(dir)
        local v = mp.get_property_number(prop, 0)
        mp.set_property_number(prop, clamp(math.floor((v + dir * step) / step + 0.5) * step, lo, hi))
    end
end

local SHADOWS = { [0] = "Off", "Light", "Medium", "Strong", "Very strong" }
local on_bottom = mp.get_opt("handheld-role") == "bottom"
local confirm_delete_until = 0

P.TABS = {
    { title = "Subtitles", rows = {
        { key = "sub", label = "Track", kind = "track",
          value = function() return P.track_name(P.current_track("sub")) end,
          change = function(dir) P.step_track("sub", dir) end },
        { key = "sub-scale", label = "Size", kind = "number", persist = true,
          value = function() return string.format("%d%%", mp.get_property_number("sub-scale", 1) * 100 + 0.5) end,
          change = numeric("sub-scale", 0.1, 0.5, 2.5) },
        { key = "sub-border-style", label = "Background", kind = "toggle", persist = true,
          on = function() return mp.get_property("sub-border-style") == "background-box" end,
          value = function() return mp.get_property("sub-border-style") == "background-box" and "Dark box" or "None" end,
          change = function()
              local box = mp.get_property("sub-border-style") == "background-box"
              mp.set_property("sub-border-style", box and "outline-and-shadow" or "background-box")
          end },
        { key = "sub-outline-size", label = "Outline", kind = "number", persist = true,
          value = function() return string.format("%.1f", mp.get_property_number("sub-outline-size", 0)) end,
          change = numeric("sub-outline-size", 0.5, 0, 6) },
        { key = "sub-shadow-offset", label = "Shadow", kind = "choice", persist = true,
          value = function() return SHADOWS[mp.get_property_number("sub-shadow-offset", 0)] or "?" end,
          change = numeric("sub-shadow-offset", 1, 0, 4) },
        { key = "sub-pos", label = "Position", kind = "number", persist = true,
          value = function() return string.format("%d", mp.get_property_number("sub-pos", 100)) end,
          change = numeric("sub-pos", 2, 50, 100) },
        { key = "sub-delay", label = "Delay", kind = "number",
          value = function() return string.format("%+.1f s", mp.get_property_number("sub-delay", 0)) end,
          change = numeric("sub-delay", 0.1, -30, 30) },
    } },
    { title = "Playback", rows = {
        { key = "audio", label = "Audio", kind = "track",
          value = function() return P.track_name(P.current_track("audio")) end,
          change = function(dir) P.step_track("audio", dir) end },
        { key = "speed", label = "Speed", kind = "number",
          value = function() return string.format("%.2fx", mp.get_property_number("speed", 1)) end,
          change = numeric("speed", 0.25, 0.5, 2) },
        { key = "autoplay", label = "Autoplay next episode", kind = "toggle", persist = true,
          on = function() return P.opts.autoplay end,
          value = function() return P.opts.autoplay and "On" or "Off" end,
          change = function() P.opts.autoplay = not P.opts.autoplay; P.queue_rest() end },
        -- the touch screen's own "Stay on"; over a video on that screen the controls always hide
        { key = "remote-on", label = "Keep touch screen on", kind = "toggle", persist = true,
          hidden = function() return on_bottom end,
          on = function() return P.opts.remote_on end,
          value = function() return P.opts.remote_on and "On" or "Off" end,
          change = function() P.opts.remote_on = not P.opts.remote_on end },
    } },
    { title = "More", rows = {
        { key = "prev", label = "Previous episode", kind = "action", close = true,
          off = function() return P.neighbour(-1) == nil end,
          run = function() P.open_neighbour(-1); return "close" end },
        { key = "next", label = "Next episode", kind = "action", close = true,
          off = function() return P.neighbour(1) == nil end,
          run = function() P.open_neighbour(1); return "close" end },
        { key = "move", label = on_bottom and "Play on top screen" or "Play on bottom screen", kind = "action", close = true,
          hidden = function() return not (os.getenv("SDL_VIDEO_DISPLAY_PRIORITY") or ""):find(",") end,
          run = function() if on_bottom then P.to_top() else P.to_bottom() end; return "close" end },
        -- asks once, deletes on a second press within 3 s
        { key = "delete", label = "Delete this episode", kind = "action", danger = true,
          value = function() return mp.get_time() < confirm_delete_until and "Press again" or "" end,
          run = function()
              if mp.get_time() < confirm_delete_until then
                  confirm_delete_until = 0
                  P.delete_current()
                  return "close"
              end
              confirm_delete_until = mp.get_time() + 3
          end },
        { key = "guide", label = "Button guide", kind = "guide" },
        { key = "about", label = "About", kind = "about" },
    } },
}

-- Returns "close" when the settings should be left.
function P.change_setting(key, dir)
    local r, result = S.apply(P.TABS, key, dir)
    if r and r.persist then mp.add_timeout(0.05, P.save) end
    return result
end

-- Episodes ----------------------------------------------------------------

local VIDEO_EXT = { mkv = true, mp4 = true, m4v = true, avi = true, webm = true, mov = true, ts = true }

local sib_cache = {}

function P.siblings()
    local path = mp.get_property("path")
    if not path then return {}, 0 end
    if sib_cache.path == path then return sib_cache.list, sib_cache.index end
    local dir, name = utils.split_path(path)
    local list = {}
    for _, f in ipairs(utils.readdir(dir, "files") or {}) do
        local ext = f:match("%.([^.]+)$")
        if ext and VIDEO_EXT[ext:lower()] then list[#list + 1] = f end
    end
    table.sort(list)
    local index = 0
    for i, f in ipairs(list) do
        list[i] = utils.join_path(dir, f)
        if f == name then index = i end
    end
    sib_cache = { path = path, list = list, index = index }
    return list, index
end

function P.neighbour(step)
    local list, index = P.siblings()
    return list[index + step]
end

function P.queue_rest()
    mp.command("playlist-clear")
    if not P.opts.autoplay then return end
    local list, index = P.siblings()
    for i = index + 1, #list do mp.commandv("loadfile", list[i], "append") end
end

function P.open_neighbour(step)
    local target = P.neighbour(step)
    if not target then
        mp.osd_message(step > 0 and "This is the last episode" or "This is the first episode", 1.5)
        return false
    end
    mp.command("write-watch-later-config")  -- mpv only saves the position on quit
    mp.commandv("loadfile", target, "replace")
    return true
end

function P.delete_current()
    local path = mp.get_property("path")
    if not path then return end
    local nxt = P.neighbour(1)
    mp.commandv("delete-watch-later-config", path)
    local ok, err = os.remove(path)
    if not ok then mp.osd_message("Could not delete: " .. tostring(err), 3); return end
    P.deleted_any = true
    sib_cache = {}
    local _, name = utils.split_path(path)
    mp.osd_message("Deleted: " .. name, 2)
    if nxt then mp.commandv("loadfile", nxt, "replace") else mp.command("quit") end
end

-- Screens -----------------------------------------------------------------

-- Hand the file to a player on the second screen and quit, so EmulationStation
-- comes back and a game can be started on the main screen.
function P.to_bottom()
    local path = mp.get_property("path")
    if not path then return end
    mp.command("write-watch-later-config")
    mp.commandv("run", "sh", "-c",
        "systemctl stop handheld-bottom 2>/dev/null; systemctl reset-failed handheld-bottom 2>/dev/null; " ..
        "exec systemd-run --quiet --collect --unit=handheld-bottom " .. HUB .. " bottom \"$0\"", path)
    mp.add_timeout(0.4, function() mp.command("quit") end)
end

-- Ask EmulationStation to open the file in the normal player again. Only
-- possible while no game is running, since ES launches one thing at a time.
function P.to_top()
    local path = mp.get_property("path")
    if not path then return end
    local r = mp.command_native({ name = "subprocess", capture_stdout = true, playback_only = false,
                                  args = { "curl", "-s", "-m", "2", ES_API .. "/runningGame" } })
    if not (r.stdout or ""):find("NO GAME RUNNING", 1, true) then
        mp.osd_message("Close the game first", 2)
        return false
    end
    mp.command("write-watch-later-config")
    mp.commandv("run", "curl", "-s", "-m", "3", "-X", "POST", "--data-binary", path, ES_API .. "/launch")
    mp.add_timeout(0.3, function() mp.command("quit") end)
    return true
end

-- Snapshot for the touch controls ----------------------------------------

function P.state()
    return {
        title = mp.get_property("media-title") or "",
        pos = mp.get_property_number("time-pos", 0),
        dur = mp.get_property_number("duration", 0),
        paused = mp.get_property_native("pause") or false,
        sub = P.track_name(P.current_track("sub")),
        audio = P.track_name(P.current_track("audio")),
        has_prev = P.neighbour(-1) ~= nil,
        has_next = P.neighbour(1) ~= nil,
        keep_on = P.opts.remote_on,
        settings = S.snapshot(P.TABS),
    }
end

-- Actions sent by the touch controls (directly, or relayed from the second
-- screen by media-hub.py as `script-message handheld-action ...`).
function P.action(name, a, b)
    if name == "pause" then mp.commandv("cycle", "pause")
    elseif name == "seek" then mp.commandv("seek", tonumber(a) or 0, "relative+exact")
    elseif name == "seek-to" then mp.commandv("seek", tonumber(a) or 0, "absolute+exact")
    elseif name == "sub-next" then P.step_track("sub", 1)
    elseif name == "audio-next" then P.step_track("audio", 1)
    elseif name == "setting" then P.change_setting(a, tonumber(b) or 1)
    elseif name == "prev" then P.open_neighbour(-1)
    elseif name == "next" then P.open_neighbour(1)
    elseif name == "to-bottom" then P.to_bottom()
    elseif name == "to-top" then P.to_top()
    elseif name == "quit" then mp.command("quit")
    end
end

function P.init()
    P.load()
    mp.register_event("file-loaded", P.queue_rest)
    mp.register_event("shutdown", function()
        -- EmulationStation still lists a deleted episode until it rescans
        if P.deleted_any then
            mp.commandv("run", "sh", "-c", "(sleep 3; curl -s " .. ES_API .. "/reloadgames) >/dev/null 2>&1 &")
        end
    end)
end

return P
