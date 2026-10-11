-- Music player. Albums are folders under /storage/roms/music ("Artist - Album"),
-- tracks are the audio files inside, in name order. Optional cover-80.bgra and
-- cover-400.bgra (raw BGRA squares, made by music-to-handheld) show the cover.
--
-- Two modes, one look:
--   in the music app the main screen browses (albums, tracks) with the pad and
--   the second screen is the player (the touch remote);
--   with "Play in background" the second screen keeps playing on its own, all
--   in one piece, while a game runs on the main screen.
-- M.app() is the browser; M.state()/M.action() are the transport the touch
-- player uses in both modes.

local mp = require "mp"
local utils = require "mp.utils"
local ui = require "ui"
local S = require "settings"
local covers = require "covers"
local tags = require "tags"

local M = {}

local ROOT = "/storage/roms/music"
local SESSION = "/storage/.config/mpv/handheld-music.json"
local PLAYLIST = "/storage/.config/mpv/handheld-music.m3u"
local HUB = mp.get_opt("handheld-hub") or "/storage/.config/mpv/media-hub.py"  -- set by the launcher
local AUDIO = { mp3 = true, flac = true, opus = true, ogg = true, m4a = true, aac = true, wav = true }
local REPEAT = { "Off", "All", "One" }
local SETTINGS_FILE = "/storage/.config/mpv/handheld-music-settings.json"

-- view: the album browser as a "list" or "flow" (Cover Flow)
-- stay_on: keep the player on the second screen lit, or let it turn off when idle
M.settings = { view = "flow", stay_on = true }

local function load_settings()
    local f = io.open(SETTINGS_FILE, "r")
    if not f then return end
    local data = utils.parse_json(f:read("*a") or "")
    f:close()
    if type(data) ~= "table" then return end
    if data.view == "flow" or data.view == "list" then M.settings.view = data.view end
    if type(data.stay_on) == "boolean" then M.settings.stay_on = data.stay_on end
end

local function save_settings()
    local f = io.open(SETTINGS_FILE, "w")
    if f then f:write(utils.format_json(M.settings)); f:close() end
end

-- the state files live in mpv's config folder, which a music-only install
-- may not have
if not utils.file_info("/storage/.config/mpv") then os.execute("mkdir -p /storage/.config/mpv") end

load_settings()

M.shuffle, M.repeat_mode = false, 1

local function track_title(path)
    local _, name = utils.split_path(path)
    return (name:gsub("%.[^.]+$", ""):gsub("^%d+%s*[%.%-_]?%s*", ""))
end

-- Library -------------------------------------------------------------------

-- Any folder holding audio files is an album, however deep: "Artist - Album",
-- "Artist/Album", "Artist/Album/CD1" (disc folders join their album), or a
-- bare "Album" (named from its tags later). Tracks lying in the music folder
-- itself make one album, "Singles".

-- "2 x" before "10 x", "CD2" before "CD10", whatever the case. Each name's
-- key is made once: making it in every comparison was most of a scan's time.
local function pad_number(d) return string.format("%012d", tonumber(d)) end
local function sort_natural(list)
    local keys = {}
    for _, name in ipairs(list) do keys[name] = name:lower():gsub("%d+", pad_number) end
    table.sort(list, function(a, b) return keys[a] < keys[b] end)
end

local function is_disc(name)
    local n = name:lower()
    return (n:match("^cd%s*%d+$") or n:match("^dis[ck]%s*%d+$") or n:match("^dis[ck]%s*%d+%s*%-")) ~= nil
end

-- Where an album lives and what to call it, from the folder of one track.
local function describe(dir)
    dir = dir:gsub("/$", "")
    local parent, name = utils.split_path(dir)
    parent = parent:gsub("/$", "")
    if dir == ROOT then return { dir = dir, artist = "", title = "Singles", named = true } end
    if is_disc(name) and parent ~= ROOT then return describe(parent) end
    local artist, title = name:match("^(.-) %- (.+)$")
    if not artist and parent ~= ROOT then
        local _, up = utils.split_path(parent)
        artist, title = up, name
    end
    if artist == "VA" then artist = "Various artists" end
    return { dir = dir, artist = artist or "", title = title or name, named = artist ~= nil }
end

function M.scan()
    local by_dir, albums = {}, {}
    local function walk(dir, depth)
        local tracks = {}
        for _, f in ipairs(utils.readdir(dir, "files") or {}) do
            local ext = f:match("%.([^.]+)$")
            if ext and AUDIO[ext:lower()] and f:sub(1, 1) ~= "." then tracks[#tracks + 1] = dir .. "/" .. f end
        end
        if #tracks > 0 then
            local d = describe(dir)
            local a = by_dir[d.dir]
            if not a then
                a = d
                a.tracks = {}
                by_dir[d.dir] = a
                albums[#albums + 1] = a
            end
            for _, t in ipairs(tracks) do a.tracks[#a.tracks + 1] = t end
        end
        if depth < 6 then
            for _, sub in ipairs(utils.readdir(dir, "dirs") or {}) do
                if sub:sub(1, 1) ~= "." then walk(dir .. "/" .. sub, depth + 1) end
            end
        end
    end
    walk(ROOT, 0)
    for _, a in ipairs(albums) do
        sort_natural(a.tracks)  -- disc folders in their order, then the track numbers
        -- pictures come from covers.lua, at the sizes each screen needs
    end
    M.save_library(albums)
    return M.sorted(albums)
end

function M.sorted(albums)
    for _, a in ipairs(albums) do a.name = ((a.artist ~= "" and a.artist .. " - " or "") .. a.title):lower() end
    table.sort(albums, function(a, b) return a.name < b.name end)
    return albums
end

-- The library is kept between starts: reading every folder of a big
-- library on an SD card takes seconds. The list from last time shows at
-- once; M.check_library then asks find, in the background, whether any
-- folder changed since it was written (adding, removing or renaming a file
-- or folder changes its folder), and only then is everything read again.
local LIBRARY = "/storage/.cache/cmp/library.json"
local LIBRARY_VERSION = 1

function M.save_library(albums)
    local out = {}
    for i, a in ipairs(albums) do
        out[i] = { dir = a.dir, artist = a.artist, title = a.title, named = a.named, tracks = a.tracks }
    end
    os.execute("mkdir -p /storage/.cache/cmp")
    local tmp = LIBRARY .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    local ok = f:write(utils.format_json({ version = LIBRARY_VERSION, root = ROOT, albums = out }))
    if f:close() and ok then os.rename(tmp, LIBRARY) else os.remove(tmp) end
end

-- The albums from last time, or a fresh scan when there are none.
function M.load_library()
    local f = io.open(LIBRARY, "r")
    local data = f and utils.parse_json(f:read("*a") or "")
    if f then f:close() end
    if type(data) == "table" and data.version == LIBRARY_VERSION and data.root == ROOT and type(data.albums) == "table" then
        local albums = {}
        for _, a in ipairs(data.albums) do
            if type(a) == "table" and type(a.dir) == "string" and type(a.tracks) == "table" then albums[#albums + 1] = a end
        end
        return M.sorted(albums), true
    end
    return M.scan(), false
end

-- changed() is called, from the event loop, if any folder changed since
-- the list was kept.
function M.check_library(changed)
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = { "find", ROOT, "-maxdepth", "7", "-type", "d", "-newer", LIBRARY },
    }, function(ok, r)
        if ok and r and r.status == 0 and (r.stdout or "") ~= "" then changed() end
    end)
end

local function album_of(path)
    if not path then return nil end
    local a = describe((utils.split_path(path)))
    a.tracks = { path }
    return a
end

-- What to call a track: its title tag, else its file name. With the album
-- given, its tags are read (in the background) if they are not known yet.
function M.track_name(path, album)
    if album then tags.want(album) end
    return tags.title(path) or track_title(path)
end

-- What to call an album: its folder name ("Artist - Album"), else its tags.
function M.names(a)
    if not a.named then
        local t = covers.tags(a)
        if t then return t.album or a.title, t.artist or a.artist end
    end
    return a.title, a.artist
end

-- Transport -----------------------------------------------------------------

local function apply_repeat()
    mp.set_property("loop-playlist", M.repeat_mode == 2 and "inf" or "no")
    mp.set_property("loop-file", M.repeat_mode == 3 and "inf" or "no")
end

-- Start a track of a new queue. Not playlist-play-index: right after "stop"
-- in an idle mpv it is ignored and the first track plays (mpv 0.41).
local function start_at(index)
    mp.set_property_number("playlist-pos", (index or 1) - 1)
end

-- The queue in its own order (an album's track order), kept so Shuffle Off
-- can put it back even after a restart, which mpv's own unshuffle cannot.
M.order = {}
local pending  -- { path, pos }: where to resume, applied when that track loads

local function load_queue(paths)
    mp.command("stop")
    pending = nil
    M.order = {}
    for i, p in ipairs(paths) do M.order[i] = p; mp.commandv("loadfile", p, "append") end
end

function M.play_list(paths, index)
    load_queue(paths)
    mp.set_property_native("pause", false)
    start_at(index)
end

function M.shuffle_play(tracks)
    if #tracks == 0 then return end
    M.shuffle = true
    load_queue(tracks)
    mp.command("playlist-shuffle")  -- mpv's own random order, different every time
    mp.set_property_native("pause", false)
    start_at(1)
end

-- The albums, read once per player: the touch library of the background
-- player browses them (the app on the main screen keeps its own list).
local library
function M.library()
    library = library or (M.load_library())
    return library
end

-- Move the queue's entries, without stopping the track playing, into `want`.
local function reorder(want)
    local now = {}
    for i, e in ipairs(mp.get_property_native("playlist") or {}) do now[i] = e.filename end
    for i, path in ipairs(want) do
        if now[i] ~= path then
            for j = i + 1, #now do
                if now[j] == path then
                    mp.commandv("playlist-move", j - 1, i - 1)
                    table.insert(now, i, table.remove(now, j))
                    break
                end
            end
        end
    end
end

function M.set_shuffle(on)
    M.shuffle = on
    if on then
        mp.command("playlist-shuffle")
        -- the track playing goes first, so nothing ends up behind it unplayed
        local cur = mp.get_property_number("playlist-pos", -1)
        if cur > 0 then mp.commandv("playlist-move", cur, 0) end
    elseif #M.order > 0 then reorder(M.order)
    else mp.command("playlist-unshuffle") end
end

function M.cycle_repeat(dir)
    M.repeat_mode = (M.repeat_mode - 1 + (dir or 1)) % 3 + 1
    apply_repeat()
end

-- Settings: the same three-tab screen as the video player (settings.lua).
-- Sleep timer: the music fades out and stops after a while, or at the end of
-- the track playing. M.sleep.at is the clock time it stops (os.time), so it
-- can move along with the queue to the background player.
local SLEEP = { 0, 15, 30, 45, 60, 90, "track" }
M.sleep = { choice = 1, at = nil }
local sleep_timer, fading

function M.sleep_left()
    return M.sleep.at and math.max(0, M.sleep.at - os.time()) or nil
end

local function fade_out()
    if fading then return end
    local volume, step = mp.get_property_number("volume", 100), 0
    local STEPS = 20  -- over 10 s
    fading = mp.add_periodic_timer(0.5, function()
        step = step + 1
        -- paused by hand meanwhile, or faded out: stop, and put the volume back
        if step >= STEPS or mp.get_property_native("pause") then
            fading:kill()
            fading = nil
            mp.set_property_native("pause", true)
            mp.set_property_number("volume", volume)
            if M.draw then M.draw() end
            return
        end
        mp.set_property_number("volume", volume * (1 - step / STEPS))
    end)
end

local function set_sleep(choice, at)
    if sleep_timer then sleep_timer:kill(); sleep_timer = nil end
    local minutes = SLEEP[choice]
    M.sleep.choice = choice
    M.sleep.at = type(minutes) == "number" and minutes > 0 and (at or os.time() + minutes * 60) or nil
    if M.sleep.at then
        sleep_timer = mp.add_timeout(math.max(1, M.sleep.at - os.time()), function()
            sleep_timer = nil
            M.sleep.choice, M.sleep.at = 1, nil
            fade_out()
        end)
    end
end

-- "End of track": the next track loads paused (pause carries over to it)
mp.register_event("end-file", function(e)
    if SLEEP[M.sleep.choice] == "track" and e.reason == "eof" then
        set_sleep(1)
        mp.set_property_native("pause", true)
    end
end)

local function sleep_label()
    local v = SLEEP[M.sleep.choice]
    if v == "track" then return "End of track" end
    local left = M.sleep_left()
    return left and string.format("%d min", math.ceil(left / 60)) or "Off"
end

-- a hand-over (to or from the background player) keeps a running timer
local function restore_sleep(data)
    if not data.play then return end
    local choice = tonumber(data.sleep_choice) or 1
    if SLEEP[choice] == "track" then set_sleep(choice)
    elseif tonumber(data.sleep_at) and data.sleep_at > os.time() then set_sleep(choice, data.sleep_at) end
end

local in_background = mp.get_opt("handheld-role") == "bottom"
-- ROCKNIX lists a dual-screen device's outputs, main first, in this variable
local two_screens = (os.getenv("SDL_VIDEO_DISPLAY_PRIORITY") or ""):find(",") ~= nil
M.two_screens = two_screens

-- One list, no tabs: the music player has only a handful of settings.
M.TABS = {
    { title = "Settings", rows = {
        { key = "shuffle", label = "Shuffle", kind = "toggle",
          on = function() return M.shuffle end, value = function() return M.shuffle and "On" or "Off" end,
          change = function() M.set_shuffle(not M.shuffle) end },
        { key = "repeat", label = "Repeat", kind = "choice",
          value = function() return REPEAT[M.repeat_mode] end, change = M.cycle_repeat },
        { key = "sleep", label = "Sleep timer", kind = "choice", value = sleep_label,
          change = function(dir) set_sleep((M.sleep.choice - 1 + (dir or 1)) % #SLEEP + 1) end },
        { key = "album-view", label = "Album view", kind = "choice",
          value = function() return M.settings.view == "flow" and "Cover Flow" or "List" end,
          change = function()
              M.settings.view = M.settings.view == "flow" and "list" or "flow"
              save_settings()
              if M.draw then M.draw() end
          end },
        { key = "stay-on", label = "Keep touch screen on", kind = "toggle",
          hidden = function() return not two_screens end,
          on = function() return M.settings.stay_on end, value = function() return M.settings.stay_on and "On" or "Off" end,
          change = function() M.settings.stay_on = not M.settings.stay_on; save_settings() end },
        { key = "move", label = in_background and "Open player" or "Play in background", kind = "action", close = true,
          hidden = function() return not two_screens end,  -- the background player lives on the second screen
          run = function() if in_background then M.to_top() else M.to_bottom() end; return "close" end },
        -- only the browser on the main screen has a library to read again
        { key = "rescan", label = "Rescan library", kind = "action",
          hidden = function() return M.rescan == nil end,
          value = function() return M.album_count and (M.album_count .. " albums") or "" end,
          run = function() M.rescan() end },
        { key = "guide", label = "Button guide", kind = "guide" },
        { key = "about", label = "About", kind = "about" },
    } },
}

function M.state()
    local path = mp.get_property("path")
    local album = album_of(path)
    local meta = mp.get_property_native("metadata") or {}
    local function tag(k) return meta[k] or meta[k:upper()] or meta[k:sub(1, 1):upper() .. k:sub(2)] end
    local pos, count = mp.get_property_number("playlist-pos", -1), mp.get_property_number("playlist-count", 0)
    return {
        kind = "music",
        path = path,
        album_dir = album and album.dir,  -- the album folder (above any disc folder)
        title = path and (tag("title") or track_title(path)) or "Nothing playing",
        artist = path and (tag("artist") or (album and album.artist) or "") or "",
        album = path and (tag("album") or (album and album.title) or "") or "",
        cover = album and covers.get(album, 400) or nil,  -- for the 1024x768 touch screen
        pos = mp.get_property_number("time-pos", 0),
        dur = mp.get_property_number("duration", 0),
        paused = mp.get_property_native("pause") or not path,
        has_prev = pos > 0 or M.repeat_mode == 2,
        has_next = (pos >= 0 and pos < count - 1) or M.repeat_mode == 2,
        shuffle = M.shuffle,
        ["repeat"] = REPEAT[M.repeat_mode],
        keep_on = M.settings.stay_on,
        settings = S.snapshot(M.TABS),
    }
end

-- Session: the queue survives quitting, and moves with the background player.

-- Last known place, kept up to date because time-pos and playlist-pos are
-- already gone by the time the shutdown event runs.
local last_index, last_pos = 1, 0
mp.observe_property("playlist-pos", "number", function(_, v)
    if v and v >= 0 and v + 1 ~= last_index then last_index, last_pos = v + 1, 0 end
end)
mp.add_periodic_timer(1, function()
    local t = mp.get_property_number("time-pos")
    if t then last_pos = t end
end)

function M.save_session(play)
    local paths = {}
    for _, e in ipairs(mp.get_property_native("playlist") or {}) do paths[#paths + 1] = e.filename end
    if #paths == 0 then return end
    local data = {
        paths = paths, index = last_index, pos = mp.get_property_number("time-pos") or last_pos,
        shuffle = M.shuffle, ["repeat"] = M.repeat_mode, play = play or false, order = M.order,
        sleep_choice = M.sleep.choice, sleep_at = M.sleep.at,
    }
    if mp.get_property_native("idle-active") then data.index, data.pos = 1, 0 end  -- played to its end
    local f = io.open(SESSION, "w")
    if f then f:write(utils.format_json(data)); f:close() end
end

function M.restore_session()
    local f = io.open(SESSION, "r")
    if not f then return false end
    local data = utils.parse_json(f:read("*a") or "")
    f:close()
    if type(data) ~= "table" or type(data.paths) ~= "table" or #data.paths == 0 then return false end
    M.shuffle, M.repeat_mode = data.shuffle or false, data["repeat"] or 1
    apply_repeat()
    -- Load the queue once mpv is idle: a queue that exists while the player
    -- is still starting gets played from its first track.
    local function load(_, idle)
        if not idle then return end
        mp.unobserve_property(load)
        load_queue(data.paths)
        if type(data.order) == "table" and #data.order > 0 then M.order = data.order end
        restore_sleep(data)
        pending = { path = data.paths[data.index or 1], pos = data.pos }
        mp.set_property_native("pause", not data.play)
        start_at(data.index)
    end
    mp.observe_property("idle-active", "bool", load)
    return data.paths[data.index or 1]
end

-- The saved position belongs to one track: if that one is gone (and another
-- loads instead), it is not applied anywhere else.
mp.register_event("file-loaded", function()
    if pending and pending.pos and pending.pos > 1 and mp.get_property("path") == pending.path then
        mp.commandv("seek", pending.pos, "absolute")
    end
    pending = nil
end)

-- Hand the queue to a player on the second screen and quit, so EmulationStation
-- comes back and a game can be played with the music on.
function M.to_bottom()
    if mp.get_property_number("playlist-count", 0) == 0 then return end
    M.save_session(true)
    local f = io.open(PLAYLIST, "w")
    if not f then return end
    for _, e in ipairs(mp.get_property_native("playlist") or {}) do f:write(e.filename, "\n") end
    f:close()
    mp.commandv("run", "sh", "-c",
        "systemctl stop handheld-bottom 2>/dev/null; systemctl reset-failed handheld-bottom 2>/dev/null; " ..
        "exec systemd-run --quiet --collect --unit=handheld-bottom " .. HUB .. " bottom-music")
    M.handed_off = true
    mp.add_timeout(0.4, function() mp.command("quit") end)
end

-- In the background player: start where the main player stopped.
function M.background()
    local f = io.open(SESSION, "r")
    local data = f and utils.parse_json(f:read("*a") or "")
    if f then f:close() end
    if type(data) == "table" then
        M.shuffle, M.repeat_mode = data.shuffle or false, data["repeat"] or 1
        apply_repeat()
        if type(data.order) == "table" then M.order = data.order end
        restore_sleep(data)
        if type(data.paths) == "table" then pending = { path = data.paths[data.index or 1], pos = data.pos } end
    end
    mp.register_event("shutdown", function() if not M.handed_off then M.save_session(false) end end)
end

function M.to_top()
    M.save_session(true)
    local r = mp.command_native({ name = "subprocess", capture_stdout = true, playback_only = false,
                                  args = { "curl", "-s", "-m", "2", "http://127.0.0.1:1234/runningGame" } })
    if not (r.stdout or ""):find("NO GAME RUNNING", 1, true) then
        mp.osd_message("Close the game first", 2)
        return
    end
    M.handed_off = true
    mp.commandv("run", "curl", "-s", "-m", "3", "-X", "POST", "--data-binary",
        "/storage/.config/gmu/playlists/Music.sh", "http://127.0.0.1:1234/launch")
    mp.add_timeout(0.3, function() mp.command("quit") end)
end

function M.action(name, a, b)
    if name == "pause" then
        if not mp.get_property("path") and mp.get_property_number("playlist-count", 0) > 0 then
            -- the queue played to its end: play it again from the top
            mp.set_property_number("playlist-pos", 0)
            mp.set_property_native("pause", false)
        else mp.commandv("cycle", "pause") end
    elseif name == "seek" then mp.commandv("seek", tonumber(a) or 0, "relative+exact")
    elseif name == "seek-to" then mp.commandv("seek", tonumber(a) or 0, "absolute+exact")
    elseif name == "prev" then
        if mp.get_property_number("time-pos", 0) > 4 then mp.commandv("seek", 0, "absolute") else mp.command("playlist-prev") end
    elseif name == "next" then mp.command("playlist-next")
    elseif name == "setting" then
        local _, result = S.apply(M.TABS, a, tonumber(b) or 1)
        return result
    elseif name == "play-album" or name == "shuffle-album" then
        local album = M.library()[tonumber(a) or 0]
        if album and name == "play-album" then M.shuffle = false; M.play_list(album.tracks, tonumber(b) or 1)
        elseif album then M.shuffle_play(album.tracks) end
    elseif name == "shuffle-all" then
        local all = {}
        for _, album in ipairs(M.library()) do for _, t in ipairs(album.tracks) do all[#all + 1] = t end end
        M.shuffle_play(all)
    elseif name == "shuffle" then M.set_shuffle(not M.shuffle)
    elseif name == "repeat" then M.cycle_repeat()
    elseif name == "to-bottom" then M.to_bottom()
    elseif name == "to-top" then M.to_top()
    elseif name == "quit" then mp.command("quit")
    end
end

-- The app on the main screen -----------------------------------------------

function M.app()
    local overlay = mp.create_osd_overlay("ass-events")
    local albums, from_cache = M.load_library()
    local view = "library"   -- library (list or Cover Flow) | album | playing

    local lib_sel, lib_top = 1, 1
    local album, tr_sel, tr_top = nil, 1, 1
    local menu = require "padmenu"
    local flow = require "coverflow"
    local draw
    local settled = false  -- the window has its real size (see osd-dimensions below)

    -- the canvas follows the screen's shape; pictures follow its pixels
    local d = mp.get_property_native("osd-dimensions") or {}
    ui.fit(d.w, d.h)
    covers.setup(mp.get_script_directory(), ui.S, function()
        if draw then draw(); flow.refresh() end
    end)
    tags.setup(nil, function() if draw and (view == "album" or view == "playing") then draw() end end)
    -- the whole album a track belongs to (album_of only knows the folder)
    local function full_album(path)
        local a = album_of(path)
        if not a then return nil end
        for _, b in ipairs(albums) do if b.dir == a.dir then return b end end
        return nil
    end

    -- Covers are mpv overlays. Re-adding one on every redraw makes it blink,
    -- so only touch the ones that changed. Positions and sizes in units.
    local shown, wanted = {}, {}

    local hide_images = false  -- pictures draw above text, so they step aside for the menu

    local function image(id, path, x, y, size)
        if hide_images or not path then return end
        local px = ui.px(size)
        local ix, iy = ui.px(x), ui.px(y)
        wanted[id] = true
        local key = string.format("%s@%d,%d", path, ix, iy)
        if shown[id] ~= key then
            mp.commandv("overlay-add", id, ix, iy, path, 0, "bgra", px, px, px * 4)
            shown[id] = key
        end
    end

    local function finish_images()
        for id in pairs(shown) do
            if not wanted[id] then
                mp.commandv("overlay-remove", id)
                shown[id] = nil
            end
        end
        wanted = {}
    end

    -- a picture, or a dark tile with a note while there is none (yet)
    local function picture(c, id, a, x, y, size, radius)
        local path = a and covers.get(a, ui.px(size))
        if path then image(id, path, x, y, size)
        else
            ui.rect(c, x, y, size, size, radius, ui.PANEL)
            ui.text(c, x + size / 2, y + size / 2, "♪", size * 0.42, ui.DIM, 5)
        end
    end

    -- Type sizes (canvas units): a 768-unit tall screen is about 5-6 cm on
    -- these handhelds, so 38 units of body text is about 2.5-3 mm.
    local T_TITLE, T_ASIDE, T_ROW, T_SUB, T_HINT = 44, 28, 38, 30, 26

    -- The battery, read at most every 30 s: { pct, charging } or nil.
    local battery_dir, battery, battery_read = nil, nil, -100
    local function read_battery()
        if mp.get_time() - battery_read < 30 then return battery end
        battery_read = mp.get_time()
        if not battery_dir then
            for _, d in ipairs(utils.readdir("/sys/class/power_supply", "dirs") or {}) do
                local f = io.open("/sys/class/power_supply/" .. d .. "/type", "r")
                local kind = f and f:read("*l")
                if f then f:close() end
                if kind == "Battery" then battery_dir = "/sys/class/power_supply/" .. d; break end
            end
            if not battery_dir then battery_dir = false end
        end
        if not battery_dir then return nil end
        local function get(name)
            local f = io.open(battery_dir .. "/" .. name, "r")
            local v = f and f:read("*l")
            if f then f:close() end
            return v
        end
        -- ROCKNIX's batteryplus (on by default) estimates the level from the
        -- voltage, which is what EmulationStation shows; the fuel gauge's own
        -- figure is used only without it
        local f = io.open("/tmp/battery.percent", "r")
        local pct = f and tonumber(f:read("*l"))
        if f then f:close() end
        pct = pct or tonumber(get("capacity"))
        local state = get("status")
        battery = pct and { pct = pct, charging = state == "Charging" or state == "Full" } or nil
        return battery
    end

    -- Top right on every page: the sleep timer while it runs, the clock and
    -- the battery. Returns where it begins, for the title to stop before.
    local function status(c)
        local y, x = 50, ui.W - 44
        local b = read_battery()
        if b then
            x = x - 44
            ui.icon_battery(c, x, y - 11, 40, 22, b.pct, b.charging)
            local pct = b.pct .. "%"
            x = x - 12
            ui.text(c, x, y, pct, T_HINT, ui.GREY, 6)
            x = x - ui.width(pct, T_HINT) - 22
        end
        local clock = os.date("%H:%M")
        ui.text(c, x, y, clock, T_ASIDE, ui.WHITE, 6)
        x = x - ui.width(clock, T_ASIDE)
        local left = M.sleep_left()
        if left or M.sleep.choice == #SLEEP then
            local mins = left and (math.ceil(left / 60) .. "m") or "♪"
            x = x - 22
            ui.text(c, x, y, mins, T_HINT, ui.ACCENT, 6)
            x = x - ui.width(mins, T_HINT) - 22
            ui.icon_moon(c, x, y, 11, ui.ACCENT)
            x = x - 11
        end
        return x
    end

    -- The page's title at the left, then a grey aside (artist, count), and
    -- the status at the right.
    local function header(c, title, sub)
        local room = status(c) - 44 - 40
        local aside = sub and ui.fit_text(sub, room * 0.4, T_ASIDE) or ""
        local aside_w = sub and ui.width(aside, T_ASIDE) + 24 or 0
        local shown = ui.fit_text(title, room - aside_w, T_TITLE, true)
        ui.text(c, 44, 22, shown, T_TITLE, ui.WHITE, 7, true)
        if sub then ui.text(c, 44 + ui.width(shown, T_TITLE, true) + 24, 36, aside, T_ASIDE, ui.GREY, 7) end
    end

    -- Y turns the screen off while music plays (the hub does it, see lock())
    local function footer(c, hints)
        if mp.get_property("path") and not mp.get_property_native("pause") then
            hints[#hints + 1] = { "Y", "Screen off" }
        end
        ui.hints(c, 44, 726, hints, T_HINT)
    end

    local function playing_dir()
        local a = album_of(mp.get_property("path"))
        return a and a.dir
    end

    -- Jumping by letter in a long library: the first letter of what the
    -- albums are sorted by ("artist - album"), shown big for a moment.
    local UPPER = { ["ç"] = "Ç", ["ğ"] = "Ğ", ["ı"] = "I", ["ö"] = "Ö", ["ş"] = "Ş", ["ü"] = "Ü" }
    local function letter(a)
        local c = (a and a.name or ""):match("^[%z\1-\127\194-\244][\128-\191]*") or ""
        if c:match("^%a$") then return c:upper() end
        if #c > 1 then return UPPER[c] or c end
        return "#"
    end
    local shown_letter, letter_until = nil, 0
    local function jump_letter(dir)
        if #albums == 0 then return end
        local here, i = letter(albums[lib_sel]), lib_sel
        if dir > 0 then
            while i < #albums and letter(albums[i]) == here do i = i + 1 end
            if letter(albums[i]) == here then i = lib_sel end  -- the last letter already
        elseif i > 1 and letter(albums[i - 1]) == here then
            while i > 1 and letter(albums[i - 1]) == here do i = i - 1 end  -- to this letter's first
        elseif i > 1 then
            i = i - 1
            local before = letter(albums[i])
            while i > 1 and letter(albums[i - 1]) == before do i = i - 1 end  -- to the one before
        end
        lib_sel = i
        shown_letter, letter_until = letter(albums[i]), mp.get_time() + 0.9
        mp.add_timeout(0.95, function() if mp.get_time() >= letter_until then draw() end end)
    end
    local function letter_showing() return shown_letter and mp.get_time() < letter_until end
    local function library_hints(along)
        return { { "A", "Open" }, { "X", "Now playing" }, { along, "Letter" }, { "Select", "Settings" } }
    end

    local ROWS, ROW_H, ROW_Y, THUMB = 4, 128, 100, 100
    local function draw_library(cv)
        local c = cv.lines
        header(c, "Music", #albums .. " albums")
        if #albums == 0 then
            ui.text(c, ui.W / 2, 340, "No music yet", T_TITLE, ui.WHITE, 5, true)
            ui.text(c, ui.W / 2, 400, "Put album folders in /storage/roms/music", T_SUB, ui.GREY, 5)
            return
        end
        if lib_sel < lib_top then lib_top = lib_sel end
        if lib_sel >= lib_top + ROWS then lib_top = lib_sel - ROWS + 1 end
        local now = playing_dir()
        for i = lib_top, math.min(#albums, lib_top + ROWS - 1) do
            local a = albums[i]
            local title, artist = M.names(a)
            local y = ROW_Y + (i - lib_top) * ROW_H
            local playing = a.dir == now
            local tx = 44 + THUMB + 28
            -- the highlight stays beside the picture: with the screen scaled,
            -- mpv's software OSD (vo=wlshm) garbles a picture over a shape
            if i == lib_sel then ui.rect(c, tx - 16, y, ui.W - tx - 8, THUMB + 8, 20, ui.RAISED) end
            picture(c, i - lib_top + 1, a, 44, y + 4, THUMB, 14)
            local room = ui.W - tx - 110  -- the track count sits at the right
            ui.text(c, tx, y + 14, ui.fit_text(title, room, T_ROW, true), T_ROW, playing and ui.ACCENT or ui.WHITE, 7, true)
            ui.text(c, tx, y + 60, ui.fit_text(artist, room, T_SUB), T_SUB, ui.GREY, 7)
            ui.text(c, ui.W - 44, y + 4 + THUMB / 2, playing and "♪" or tostring(#a.tracks), T_ASIDE,
                playing and ui.ACCENT or ui.DIM, 6)
        end
        if letter_showing() then  -- (beside the pictures, which would draw over it)
            ui.rect(c, ui.W / 2 - 80, 304, 160, 160, 32, ui.RAISED, 0x18)
            ui.text(c, ui.W / 2, 384, shown_letter, 100, ui.WHITE, 5, true)
        end
        footer(c, library_hints("←→"))
    end

    local TROWS, TROW_H = 7, 80
    -- The album page and the player show the cover at the same place and
    -- size, so going from one to the other does not jump: as big as the
    -- screen's width allows next to a 480-unit column for the controls
    -- (544 on a 3:2 screen, 416 on a 4:3 one, 260 on a square one).
    local COVER_X, COVER_Y = 44, 100
    local function cover_size() return math.max(260, math.min(560, ui.W - 608)) end
    -- Cover Flow (coverflow.lua draws the covers; the words are ours)
    local flow_now = false  -- drawn in this frame
    flow.picture = function(a, px) return covers.get(a, px) end

    local function draw_flow(cv)
        local c = cv.lines
        if #albums == 0 then return draw_library(cv) end
        flow.go(albums, lib_sel)
        flow_now = true
        local a = albums[lib_sel]
        local title, artist = M.names(a)
        local playing = a.dir == playing_dir()
        -- under the strip (44 + 400 + reflection): the title, then artist and track count on one line
        ui.text(c, ui.W / 2, 582, ui.fit_text(title, ui.W - 120, T_TITLE, true), T_TITLE, playing and ui.ACCENT or ui.WHITE, 8, true)
        local more = playing and "♪ Playing" or (#a.tracks .. " tracks")
        ui.text(c, ui.W / 2, 640, ui.fit_text(artist, ui.W - 360, T_SUB) .. "  ·  " .. more, T_SUB,
            playing and ui.ACCENT or ui.GREY, 8)
        -- top left, above the covers: the letter after a jump, then where we are
        local x = 44
        if letter_showing() then
            ui.text(c, x, 22, shown_letter, T_TITLE, ui.ACCENT, 7, true)
            x = x + ui.width(shown_letter, T_TITLE, true) + 18
        end
        ui.text(c, x, 36, lib_sel .. " / " .. #albums, T_ASIDE, ui.DIM, 7)
        status(c)
        footer(c, library_hints("↑↓"))
    end

    local function draw_album(cv)
        local c = cv.lines
        local title, artist = M.names(album)
        local COVER = cover_size()
        picture(c, 20, album, COVER_X, COVER_Y, COVER, 22)
        header(c, title, artist)
        local playing = mp.get_property("path")
        if tr_sel < tr_top then tr_top = tr_sel end
        if tr_sel >= tr_top + TROWS then tr_top = tr_sel - TROWS + 1 end
        local x, right = COVER_X + COVER + 40, ui.W - 24
        for i = tr_top, math.min(#album.tracks, tr_top + TROWS - 1) do
            local y = 100 + (i - tr_top) * TROW_H
            if i == tr_sel then ui.rect(c, x - 16, y, right - x + 16, TROW_H - 8, 18, ui.RAISED) end
            local is_playing = album.tracks[i] == playing
            local mid = y + (TROW_H - 8) / 2
            local T_TRACK = 36  -- the track names, a little bigger than other second lines
            ui.text(c, x + 8, mid, is_playing and "♪" or string.format("%d", i), 28,
                is_playing and ui.ACCENT or ui.DIM, 4)
            ui.text(c, x + 60, mid, ui.fit_text(M.track_name(album.tracks[i], album), right - x - 76, T_TRACK), T_TRACK,
                is_playing and ui.ACCENT or ui.WHITE, 4)
        end
        footer(c, { { "A", "Play" }, { "B", "Back" }, { "X", "Now playing" }, { "Select", "Settings" } })
    end

    -- What is playing, on the main screen: the only player a single-screen
    -- device has (dual-screen ones also have it on the touch screen). Under
    -- it the queue around the current track; up/down pick, A plays.
    -- Three places to be in the player, top to bottom: the controls
    -- (previous, play, next, shuffle, repeat), the progress bar, the queue.
    -- Up/down go from one to the next (and along the queue); left/right walk
    -- the controls or, on the bar, seek (held, they keep seeking); A acts on
    -- the focused one; B in the queue goes back to the controls.
    local queue_sel           -- playlist index (0-based) under the cursor
    local QROWS, QROW_H = 4, 58
    local CONTROLS = { "prev", "pause", "next", "shuffle", "repeat" }
    local control, zone = 2, "controls"  -- focus starts on play/pause

    -- While a new queue loads there is no track for a moment; keep showing
    -- the last one rather than flashing the empty picture in between.
    local last_st

    local function draw_playing(cv)
        local c = cv.lines
        local st = M.state()
        -- (and once the queue has played to its end: the last track, stopped)
        if st.path then last_st = st
        elseif last_st then  -- the track from before; shuffle, repeat and the rest as they are now
            for _, k in ipairs({ "path", "title", "album", "artist", "dur", "album_dir" }) do st[k] = last_st[k] end
            st.paused, st.pos = true, 0
        end
        local here = album_of(st.path)
        local count = mp.get_property_number("playlist-count", 0)
        header(c, "Now playing", count > 0 and string.format("%d / %d", mp.get_property_number("playlist-pos", 0) + 1, count))
        local COVER = cover_size()
        picture(c, 20, here, COVER_X, COVER_Y, COVER, 22)  -- the album page's overlay: the same picture stays put
        local x = COVER_X + COVER + 40
        local width = ui.W - x - 44
        ui.text(c, x, 100, ui.fit_text(st.album, width, T_ASIDE), T_ASIDE, ui.GREY, 7)
        ui.text(c, x, 136, ui.fit_text(st.title, width, 48, true), 48, ui.WHITE, 7, true)
        ui.text(c, x, 198, ui.fit_text(st.artist, width, T_SUB + 4), T_SUB + 4, ui.GREY, 7)
        -- the controls: previous, play/pause, next, shuffle, repeat
        -- (kept small enough to leave the artist's line clear above them)
        local cy = 306
        local cx = { x + 26, x + 110, x + 194, x + 276, x + 346 }
        if zone == "controls" then  -- the focus: a ring around the control
            ui.ring(c, cx[control], cy, control == 2 and 48 or 30, 4, ui.ACCENT)
        end
        ui.icon_skip(c, cx[1], cy, 30, st.has_prev and ui.WHITE or ui.DIM, false)
        ui.circle(c, cx[2], cy, 40, ui.WHITE)
        if st.paused then ui.icon_play(c, cx[2] + 4, cy, 32, ui.PANEL) else ui.icon_pause(c, cx[2], cy, 30, ui.PANEL) end
        ui.icon_skip(c, cx[3], cy, 30, st.has_next and ui.WHITE or ui.DIM, true)
        local rep = st["repeat"] or "Off"
        ui.icon_shuffle(c, cx[4], cy, 30, st.shuffle and ui.ACCENT or ui.GREY)
        ui.icon_repeat(c, cx[5], cy, 30, rep ~= "Off" and ui.ACCENT or ui.GREY, rep == "One")
        -- progress
        local by = 384
        local frac = (st.dur or 0) > 0 and math.min(1, (st.pos or 0) / st.dur) or 0
        local on_bar = zone == "progress"
        ui.rect(c, x, by - 4, width, 8, 4, ui.WHITE, 0xB0)
        ui.rect(c, x, by - 4, math.max(8, width * frac), 8, 4, ui.ACCENT)
        if on_bar then ui.ring(c, x + width * frac, by, 22, 4, ui.ACCENT) end
        ui.circle(c, x + width * frac, by, on_bar and 16 or 12, ui.WHITE)
        ui.text(c, x, by + 24, ui.fmt_time(st.pos), T_HINT, on_bar and ui.WHITE or ui.GREY, 7)
        ui.text(c, x + width, by + 24, ui.fmt_time(st.dur), T_HINT, on_bar and ui.WHITE or ui.GREY, 9)
        -- the queue: the track before, this one, and the next ones
        local list = mp.get_property_native("playlist") or {}
        local cur = mp.get_property_number("playlist-pos", 0)
        if not queue_sel or not list[queue_sel + 1] then queue_sel = cur end
        local first = math.max(0, math.min(queue_sel - 1, #list - QROWS))
        local qy = 450
        for i = first, math.min(#list - 1, first + QROWS - 1) do
            local y = qy + (i - first) * QROW_H
            local mid = y + (QROW_H - 8) / 2
            if zone == "queue" and i == queue_sel then ui.rect(c, x - 16, y, width + 32, QROW_H - 8, 16, ui.RAISED) end
            local now = i == cur
            ui.text(c, x + 6, mid, now and "♪" or tostring(i + 1), T_HINT, now and ui.ACCENT or ui.DIM, 4)
            local path = list[i + 1].filename
            ui.text(c, x + 54, mid, ui.fit_text(M.track_name(path, full_album(path)), width - 70, T_SUB), T_SUB,
                now and ui.ACCENT or ui.WHITE, 4)
        end
        local hints = { { "↑↓", "Move" } }
        if zone == "controls" then hints[#hints + 1] = { "←→", "Controls" }
        elseif zone == "progress" then hints[#hints + 1] = { "←→", "−10 s / +10 s" } end
        hints[#hints + 1] = { "A", zone == "progress" and "Pause" or "Select" }
        hints[#hints + 1] = { "B", "Back" }
        footer(c, hints)
    end
    -- the settings screen covers the whole main screen, so the browser
    -- (and its pictures, which would draw above it) steps aside meanwhile
    local screen_off = false  -- the hub turned the screen off: nothing to draw for
    function draw()
        if not settled or screen_off then return end
        local cv = ui.canvas()
        hide_images = menu.open
        flow_now = false
        if not menu.open then
            if view == "album" then draw_album(cv)
            elseif view == "playing" then draw_playing(cv)
            elseif M.settings.view == "flow" then draw_flow(cv)
            else draw_library(cv) end
        end
        if not flow_now then flow.hide() end
        finish_images()
        ui.show(overlay, cv)
    end
    M.draw = draw

    M.album_count = #albums
    -- Read the library again, staying on the same album (and page) when it
    -- is still there.
    local function reload()
        local keep, open = albums[lib_sel] and albums[lib_sel].dir, album and album.dir
        albums = M.scan()
        M.album_count = #albums
        lib_sel = math.max(1, math.min(lib_sel, #albums))
        local still_open = false
        for i, a in ipairs(albums) do
            if a.dir == keep then lib_sel = i end
            if a.dir == open then album, still_open = a, true end
        end
        if view == "album" and not still_open then view = "library" end
        if album then tr_sel = math.min(tr_sel, #album.tracks) end
        draw()
    end
    function M.rescan()
        covers.reset()  -- pictures and titles added or changed since are read again
        tags.reset()
        reload()
    end
    -- the list from last time is up already; read it again if a folder changed
    if from_cache then M.check_library(reload) end
    menu.setup({ model = function() return S.snapshot(M.TABS) end, guide = "music", on_toggle = draw,
                 apply = function(key, dir) return M.action("setting", key, dir) end })

    local shuffle_play = M.shuffle_play

    local function pause() M.action("pause") end

    -- Starting music opens the player; B there goes back to where it came from.
    local came_from = "library"
    local function open_playing(from)
        if view ~= "playing" then came_from = from or view end
        queue_sel, control, zone = nil, 2, "controls"
        view = "playing"
    end
    local function play(list, index, shuffle)
        if shuffle then shuffle_play(list) else M.shuffle = false; M.play_list(list, index) end
        -- what the player shows until the track has loaded
        last_st = { path = list[index or 1], album = "", title = M.track_name(list[index or 1]), artist = "",
                    paused = false, pos = 0, dur = 0, has_prev = false, has_next = false }
        if album and not shuffle then
            local t, a = M.names(album)
            last_st.album, last_st.artist = t, a
        end
        open_playing()
    end

    -- One meaning per button everywhere: A chooses, B goes back, X jumps to
    -- the player; Y is kept free for later.
    local function to_player() if mp.get_property("path") then open_playing() end end

    -- Screen off and the buttons locked: the hub reads the pad, the lid and
    -- the power button, so it does this; the player only asks.
    local function lock()
        if not mp.get_property("path") or mp.get_property_native("pause") then return end
        mp.set_property("user-data/handheld/req", utils.format_json({ lock = true, t = mp.get_time() }))
    end
    mp.register_script_message("handheld-screen", function(on)
        screen_off = on == "off"
        if not screen_off then draw() end
    end)

    local step = 1  -- how far a held direction moves (set by the key handler)
    local keys = {
        -- along the list one album (faster when held), across it by letter
        library = {
            up = function()
                if M.settings.view == "flow" then jump_letter(-1) else lib_sel = math.max(1, lib_sel - step) end
            end,
            down = function()
                if M.settings.view == "flow" then jump_letter(1) else lib_sel = math.min(#albums, lib_sel + step) end
            end,
            left = function()
                if M.settings.view == "flow" then lib_sel = math.max(1, lib_sel - step) else jump_letter(-1) end
            end,
            right = function()
                if M.settings.view == "flow" then lib_sel = math.min(#albums, lib_sel + step) else jump_letter(1) end
            end,
            a = function()
                if albums[lib_sel] then album, tr_sel, tr_top, view = albums[lib_sel], 1, 1, "album" end
            end,
            x = to_player,
        },
        album = {
            up = function() tr_sel = math.max(1, tr_sel - 1) end,
            down = function() tr_sel = math.min(#album.tracks, tr_sel + 1) end,
            left = function() tr_sel = math.max(1, tr_sel - TROWS) end,
            right = function() tr_sel = math.min(#album.tracks, tr_sel + TROWS) end,
            a = function()
                -- the track already playing: go on from where it is, do not start it over
                if album.tracks[tr_sel] == mp.get_property("path") then
                    mp.set_property_native("pause", false)
                    open_playing()
                else play(album.tracks, tr_sel) end
            end,
            x = to_player,
            b = function() view = "library" end,
        },
        playing = {
            left = function()
                if zone == "controls" then control = math.max(1, control - 1)
                elseif zone == "progress" then M.action("seek", -10) end
            end,
            right = function()
                if zone == "controls" then control = math.min(#CONTROLS, control + 1)
                elseif zone == "progress" then M.action("seek", 10) end
            end,
            up = function()
                if zone == "queue" then
                    if queue_sel and queue_sel > 0 then queue_sel = queue_sel - 1 else zone = "progress" end
                elseif zone == "progress" then zone = "controls" end
            end,
            down = function()
                local n = mp.get_property_number("playlist-count", 0)
                if zone == "controls" then zone = "progress"
                elseif zone == "progress" then
                    zone, queue_sel = "queue", mp.get_property_number("playlist-pos", 0)
                elseif queue_sel then queue_sel = math.min(n - 1, queue_sel + 1) end
            end,
            a = function()
                if zone == "controls" then
                    M.action(CONTROLS[control])
                    return
                elseif zone == "progress" then
                    pause()
                    return
                end
                local cur = mp.get_property_number("playlist-pos", 0)
                if queue_sel and queue_sel ~= cur then
                    mp.set_property_number("playlist-pos", queue_sel)
                    mp.set_property_native("pause", false)
                    queue_sel = nil
                else pause() end
            end,
            b = function()
                if zone == "queue" then zone = "controls"; return end
                view = (came_from == "playing") and "library" or came_from
            end,
        },
    }
    local NO_REPEAT = { a = true, x = true, y = true, b = true }
    -- a direction held down: 1 album a step, then 3, then 8
    local held, repeats = nil, 0

    mp.register_script_message("handheld", function(key, kind)
        if key == "start" then mp.command("quit"); return end
        key = ({ lstick_up = "up", lstick_down = "down", lstick_left = "left", lstick_right = "right" })[key] or key
        if menu.key(key) then return end
        if key == "select" then menu.toggle(); return end
        if key == "l1+r1" then  -- both shoulders: carry on in the background, on the second screen
            if M.two_screens and mp.get_property("path") then M.to_bottom() end
            return
        end
        if key == "l1" then M.action("prev"); return end
        if key == "r1" then M.action("next"); return end
        if key == "l2" then M.action("seek", -10); return end
        if key == "r2" then M.action("seek", 10); return end
        if key == "y" then lock(); return end
        if kind == "repeat" and NO_REPEAT[key] then return end
        if kind == "repeat" and key == held then repeats = repeats + 1 else held, repeats = key, 0 end
        step = repeats < 6 and 1 or repeats < 16 and 3 or 8
        local fn = keys[view][key]
        if fn then fn(); draw() end
    end)

    -- state for the touch player on the second screen
    local last
    local function publish()
        local json = utils.format_json(M.state())
        if json ~= last then last = json; mp.set_property("user-data/handheld/state", json) end
    end
    mp.add_periodic_timer(1, publish)
    mp.add_timeout(0.05, publish)  -- the remote is waiting for its first state

    mp.register_script_message("handheld-action", function(name, a, b)
        M.action(name, a ~= "" and a or nil, b ~= "" and b or nil)
        mp.add_timeout(0.05, publish)  -- answer a tap at once, not on the next tick
    end)

    -- the "playing" marks follow the current track
    mp.observe_property("path", "string", function() queue_sel = nil; draw() end)
    mp.observe_property("pause", "bool", function() draw() end)  -- (paused from outside too: headphones out)
    -- the player's progress, and the clock everywhere (on the minute)
    local minute = os.date("%M")
    mp.add_periodic_timer(1, function()
        if menu.open then return end
        if view == "playing" or os.date("%M") ~= minute then minute = os.date("%M"); draw() end
    end)
    -- The window opens at mpv's default size and sway makes it fullscreen a
    -- moment later; draw (and ask for pictures) once its size has settled.
    local settle
    mp.observe_property("osd-dimensions", "native", function(_, dims)
        if not dims or (dims.w or 0) <= 0 or (dims.h or 0) <= 0 then return end  -- no window yet
        if not ui.fit(dims.w, dims.h) and settled then return end
        covers.scale = ui.S
        if settle then settle:kill() end
        settle = mp.add_timeout(0.2, function()
            settled = true
            flow.setup()
            for id in pairs(shown) do mp.commandv("overlay-remove", id) end
            shown = {}
            draw()
        end)
    end)


    mp.register_event("shutdown", function() if not M.handed_off then M.save_session(false) end end)

    -- start on the album that was playing (the first draw waits for the window)
    local resumed = album_of(M.restore_session() or nil)
    for i, a in ipairs(albums) do
        if resumed and a.dir == resumed.dir then lib_sel = i end
    end
end

return M
