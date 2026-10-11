-- Handheld controls for mpv on ROCKNIX dual-screen devices.
--
-- One script directory, several roles, picked with --script-opts=handheld-role=...
--   player  (default) the video launched from EmulationStation on the main
--           screen. Driven by the pad through media-hub.py; publishes its state
--           for the touch remote on the second screen.
--   music   the music player on the main screen, same pad and remote.
--   remote  the touch remote on the second screen (no file, started by the hub).
--   bottom  a video (or, with handheld-kind=music, the music queue) playing on
--           the second screen, touch only, so a game can run on the main
--           screen at the same time.

local mp = require "mp"
local utils = require "mp.utils"

local role = mp.get_opt("handheld-role") or "player"

local function osd(text) mp.osd_message(text, 1.5) end

if role == "remote" then
    local touch = require "touch"
    local state, seq, last_keep = nil, 0, false
    local function request(t)
        seq = seq + 1
        t.seq = seq
        mp.set_property("user-data/handheld/req", utils.format_json(t))
    end
    mp.register_script_message("handheld-state", function(json)
        state = utils.parse_json(json)
        -- "Stay on" switched: show the screen (or, already showing, start its
        -- turn-off timer again) without leaving the page that is open
        local keep = state and state.keep_on or false
        if keep ~= last_keep then
            last_keep = keep
            touch.poke()
        end
        touch.draw()
    end)
    -- the hub saw a finger on the (powered off) screen
    mp.register_script_message("handheld-wake", function(why)
        if why == "intro" then touch.intro() else touch.show("controls") end
    end)
    touch.init({
        state = function() return state end,
        action = function(name, a, b)
            request({ cmd = { "script-message", "handheld-action", name, a ~= nil and tostring(a) or "",
                              b ~= nil and tostring(b) or "" } })
        end,
        wake = function() request({ wake = true }) end,
        sleep = function() request({ sleep = true }) end,
    }, true)
    return
end

if role == "music" then
    require("music").app()
    return
end

if role == "bottom" and mp.get_opt("handheld-kind") == "music" then
    local music = require "music"
    local touch = require "touch"
    local seq = 0
    local function request(t)  -- read by media-hub.py, which switches the screen's light
        seq = seq + 1
        t.seq = seq
        mp.set_property("user-data/handheld/req", utils.format_json(t))
    end
    music.background()
    -- album pictures for the touch library, made on the device when missing
    require("covers").setup(mp.get_script_directory(), 1, function() touch.draw() end)
    require("tags").setup(nil, function() touch.draw() end)  -- track titles, read when an album is shown
    touch.init({ state = music.state, action = music.action, library = music.library, names = music.names,
                 track_name = music.track_name,
                 wake = function() request({ wake = true }) end,
                 sleep = function() request({ sleep = true }) end }, false)
    mp.add_timeout(0.2, function() touch.show("controls") end)
    return
end

local P = require "player"
P.init()

if role == "bottom" then
    local touch = require "touch"
    touch.init({ state = P.state, action = P.action }, false)
    return
end

-- player ------------------------------------------------------------------

local menu = require "padmenu"
local S = require "settings"
menu.setup({ model = function() return S.snapshot(P.TABS) end, apply = P.change_setting, guide = "video" })

-- State for the touch remote; the hub forwards it while the remote is awake.
local last_state
local function publish()
    local json = utils.format_json(P.state())
    if json ~= last_state then
        last_state = json
        mp.set_property("user-data/handheld/state", json)
    end
end
mp.add_periodic_timer(1, publish)  -- once a second: each redraw of the remote costs CPU the video needs
mp.register_event("file-loaded", function() mp.add_timeout(0.05, publish) end)  -- the remote is waiting

mp.register_script_message("handheld-action", function(name, a, b)
    P.action(name, a ~= "" and a or nil, b ~= "" and b or nil)
    mp.add_timeout(0.1, publish)  -- answer a tap at once, not on the next tick
end)

local function seek(sec) mp.commandv("osd-msg-bar", "seek", sec, "relative+exact") end

-- L1/R1 ask first and change episode on a second press, so a stray shoulder
-- press does not throw away the episode being watched.
local pending_step, pending_until = 0, 0
local function episode_key(step)
    local target = P.neighbour(step)
    if not target then osd(step > 0 and "This is the last episode" or "This is the first episode"); return end
    if pending_step == step and mp.get_time() < pending_until then
        pending_step = 0
        P.open_neighbour(step)
        return
    end
    pending_step, pending_until = step, mp.get_time() + 2.5
    local _, name = utils.split_path(target)
    mp.osd_message(string.format("%s episode: %s\nPress %s again to switch",
        step > 0 and "Next" or "Previous", name:gsub("%.[^.]+$", ""), step > 0 and "R1" or "L1"), 2.5)
end

-- One job per control. Volume stays on the device's own volume keys.
local playing = {
    a = function() mp.commandv("cycle", "pause"); osd(mp.get_property_native("pause") and "Paused" or "Playing") end,
    b = function() mp.command("show-progress") end,
    x = function() P.step_track("sub", 1); osd("Subtitles: " .. P.track_name(P.current_track("sub"))) end,
    y = function() P.step_track("audio", 1); osd("Audio: " .. P.track_name(P.current_track("audio"))) end,
    left = function() seek(-10) end, right = function() seek(10) end,
    up = function() seek(85) end, down = function() seek(-85) end,
    l1 = function() episode_key(-1) end, r1 = function() episode_key(1) end,
    -- both shoulders together: carry on watching on the second screen
    ["l1+r1"] = function()
        if (os.getenv("SDL_VIDEO_DISPLAY_PRIORITY") or ""):find(",") then P.to_bottom() end
    end,
    select = function() menu.toggle() end,
}
local NO_REPEAT = { up = true, down = true }
local STICK = { lstick_up = "up", lstick_down = "down", lstick_left = "left", lstick_right = "right" }

mp.register_script_message("handheld", function(key, kind)
    if key == "start" then mp.command("quit"); return end
    key = STICK[key] or key  -- the left stick mirrors the d-pad; the right stick does nothing
    if menu.key(key) then return end
    if kind == "repeat" and NO_REPEAT[key] then return end
    local action = playing[key]
    if action then action() end
end)
