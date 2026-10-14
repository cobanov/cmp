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
        if state then state.at = mp.get_time() end  -- (the lyrics run on from here between updates)
        -- "Stay on" switched: show the screen (or, already showing, start its
        -- turn-off timer again) without leaving the page that is open
        local keep = state and state.keep_on or false
        if keep ~= last_keep then
            last_keep = keep
            touch.poke()
        end
        touch.draw()
    end)
    -- the player's X and the pad keys while its video browser shows here
    mp.register_script_message("handheld-browse", function(key) touch.browse(key) end)
    -- the hub saw a finger on the (powered off) screen
    mp.register_script_message("handheld-wake", function(why)
        if why == "intro" then touch.intro()
        elseif why == "poke" then touch.poke()  -- already showing: the page stays, its timer starts again
        else touch.show("controls") end
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

-- The video browser (B): on the touch screen of a dual-screen device, where
-- the hub hands it the pad keys while it is open; over the video otherwise.
local files = require "files"
local ui = require "ui"
local dual = (os.getenv("SDL_VIDEO_DISPLAY_PRIORITY") or ""):find(",") ~= nil
local browsing_below = false
local files_overlay = mp.create_osd_overlay("ass-events")
local req_seq = 0
local function request(t)  -- read by media-hub.py
    req_seq = req_seq + 1
    t.seq = req_seq
    mp.set_property("user-data/handheld/req", utils.format_json(t))
end
local function draw_files()
    if not files.is_open then files_overlay:remove(); files_overlay.data = nil; return end
    local cv = ui.canvas()
    files.draw(cv, P.state(), { pad = true, backdrop = 0x28 })
    ui.show(files_overlay, cv)
end
local function open_files()
    if dual then
        browsing_below = true
        request({ browse = "open" })
    else
        files.open_at(mp.get_property("path"))
        draw_files()
    end
end
local function files_key(key)
    if browsing_below then request({ browse = key }); return end
    local r = files.key(key)
    if r == "close" then files.close()
    elseif type(r) == "table" then files.close(); P.action("open-file", r[2]) end
    draw_files()
end

mp.register_script_message("handheld-action", function(name, a, b)
    if name == "browse-closed" then browsing_below = false; return end  -- the touch screen closed it
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

-- L2/R2: the episode's chapters (opening, parts, ending); a file without any
-- (most films) moves a minute instead.
local function chapter_key(step)
    local n = mp.get_property_number("chapters", 0)
    if n <= 0 then seek(60 * step); return end
    mp.commandv("add", "chapter", step)
    mp.add_timeout(0.15, function()
        local ch = mp.get_property_number("chapter", 0)
        local title = mp.get_property("chapter-metadata/title")
        osd(string.format("Chapter %d / %d", ch + 1, n) .. (title and title ~= "" and (": " .. title) or ""))
    end)
end

local SPEEDS = { 1, 1.25, 1.5 }
local function speed_key()
    local now, i = mp.get_property_number("speed", 1), 1
    for k, v in ipairs(SPEEDS) do if math.abs(v - now) < 0.01 then i = k end end
    mp.set_property_number("speed", SPEEDS[i % #SPEEDS + 1])
    osd(string.format("Speed %gx", SPEEDS[i % #SPEEDS + 1]))
end

-- One job per control. Volume stays on the device's own volume keys.
local playing = {
    a = function() mp.commandv("cycle", "pause"); osd(mp.get_property_native("pause") and "Paused" or "Playing") end,
    b = open_files,
    x = function() P.step_track("sub", 1); osd("Subtitles: " .. P.track_name(P.current_track("sub"))) end,
    y = function() P.step_track("audio", 1); osd("Audio: " .. P.track_name(P.current_track("audio"))) end,
    -- the d-pad: short steps, and the opening's length up and down
    left = function() seek(-10) end, right = function() seek(10) end,
    up = function() seek(85) end, down = function() seek(-85) end,
    -- the left stick: longer steps, and five minutes up and down
    lstick_left = function() seek(-30) end, lstick_right = function() seek(30) end,
    lstick_up = function() seek(300) end, lstick_down = function() seek(-300) end,
    -- (no right stick: InputPlumber reports the RG DS Plus's one stick as both sticks)
    l1 = function() episode_key(-1) end, r1 = function() episode_key(1) end,
    l2 = function() chapter_key(-1) end, r2 = function() chapter_key(1) end,
    l3 = speed_key,
    r3 = function()
        mp.commandv("cycle", "sub-visibility")
        osd(mp.get_property_native("sub-visibility") and "Subtitles shown" or "Subtitles hidden")
    end,
    -- both shoulders together: carry on watching on the second screen
    ["l1+r1"] = function()
        if (os.getenv("SDL_VIDEO_DISPLAY_PRIORITY") or ""):find(",") then P.to_bottom() end
    end,
    select = function() menu.toggle() end,
}
local NO_REPEAT = { up = true, down = true, lstick_up = true, lstick_down = true }
-- in the settings menu the left stick moves like the d-pad
local STICK = { lstick_up = "up", lstick_down = "down", lstick_left = "left", lstick_right = "right" }

mp.register_script_message("handheld", function(key, kind)
    if key == "start" or key == "select+start" then mp.command("quit"); return end
    if browsing_below or files.is_open then
        if key == "select" then  -- the settings instead
            if browsing_below then request({ browse = "close" }); browsing_below = false end
            files.close(); draw_files()
            menu.toggle()
            return
        end
        files_key(STICK[key] or key)
        return
    end
    if menu.key(STICK[key] or key) then return end
    if kind == "repeat" and NO_REPEAT[key] then return end
    local action = playing[key]
    if action then action() end
end)
