-- Touch controls for the second (touch) screen: a player screen and a
-- settings screen. The same code runs in two places:
--
--   remote  an otherwise empty window on the second screen while the video
--           plays on the main screen; state comes from, and actions go to,
--           the player through media-hub.py. Sleeps (screen off) when idle.
--   bottom  over the video itself when the video plays on the second screen.
--
-- `backend` supplies state() and action(name, a, b); remote also has
-- wake()/sleep(), the background music player library() (touchlib.lua).

local mp = require "mp"
local ui = require "ui"
local S = require "settings"
local L = require "touchlib"
local lyrics = require "lyrics"
local battery = require "battery"
local F = require "files"

local T = {}

local overlay = mp.create_osd_overlay("ass-events")
local backend, remote
local view = "hidden"            -- hidden | controls | settings | guide | about | library | lyrics | files
local tab = 1                    -- settings tab
local cv = ui.canvas()
local idle_timer, tick_timer
local down, drag, last_tap = nil, nil, nil
local scrolling = false          -- a finger in the library list; a tap there is told apart when it lifts
local flash = nil                -- { text, side, until }
local intro = false              -- first showing: say how to bring it back
local level_kind = nil           -- the remote's open volume/brightness panel: "volume" | "brightness"
local level_drag = nil           -- { value } while a finger moves its slider
local level_timer, level_sent = nil, 0
local wake_tap = nil             -- the first tap of the double tap that wakes the dark remote
local close_tap = nil            -- the first tap of the double tap that turns it off
local files_pad = false          -- the video browser was opened with the pad: show its pick
local pad_locked = false         -- the handheld's buttons locked from the remote (the hub drops them)
local locked_flash = -10         -- when a locked button was pressed: say so for a moment
local files_drag = nil           -- { y, first, moved } while a finger moves the browser's list

local HIDE_AFTER = 4              -- seconds, controls over the video
local SLEEP_AFTER = 5             -- seconds, remote panel (the players' setting overrides it)
local INTRO_FOR = 10              -- seconds the remote stays up when a video opens
local SETTINGS_SLEEP_AFTER = 20
local LEVEL_CLOSE_AFTER = 5       -- seconds the volume/brightness panel stays without a touch
local WAKE_TAPS_WITHIN = 0.5      -- seconds between the two taps that wake the remote

-- Layout --------------------------------------------------------------------

local BAR_X, BAR_W, BAR_Y = 72, 880, 520

local COVER_ID = 40
local cover_shown

local function show_cover(path)
    if path == cover_shown then return end
    if path then mp.commandv("overlay-add", COVER_ID, 52, 64, path, 0, "bgra", 400, 400, 1600)
    else mp.commandv("overlay-remove", COVER_ID) end
    cover_shown = path
end

-- The ✕ asks before it closes the player: a first tap turns it red and says
-- so, a second one within a few seconds closes.
local QUIT_CONFIRM = 3
local quit_ask = nil
local function close_button(c, cy, alpha)
    local asking = quit_ask ~= nil and mp.get_time() - quit_ask < QUIT_CONFIRM
    ui.circle(c, 966, cy, 30, asking and ui.RED or ui.RAISED, not asking and alpha or nil)
    ui.text(c, 966, cy, "✕", 28, ui.WHITE, 5)
    if asking then ui.text(c, 996, cy + 52, "Tap again to close", 22, ui.RED, 6, true) end
    ui.hit(cv, 926, cy - 40, 80, 80, "quit")
end

local function pill_row(c, pills)
    local gap, py, ph = 16, 628, 76
    local pw = (BAR_W - gap * (#pills - 1)) / #pills
    for i, p in ipairs(pills) do
        local px = BAR_X + (i - 1) * (pw + gap)
        ui.rect(c, px, py, pw, ph, 18, ui.RAISED, remote and 0 or 0x30)
        if p[1] then
            ui.text(c, px + pw / 2, py + 14, p[1], 18, ui.GREY, 8)
            ui.text(c, px + pw / 2, py + 38, ui.trim(p[2], 15), 23, ui.WHITE, 8)
        else
            ui.text(c, px + pw / 2, py + ph / 2, p[2], 23, ui.WHITE, 5)
        end
        ui.hit(cv, px, py, pw, ph, p[3], p[4], p[4] and 1 or nil)
    end
end

local function progress(c, st, y)
    if st.live then  -- a station: the bar full and faint, "● LIVE", how long it has played
        ui.rect(c, BAR_X, y - 4, BAR_W, 8, 4, ui.ACCENT, 0x90)
        ui.circle(c, BAR_X + 7, y + 40, 6, ui.RED)
        ui.text(c, BAR_X + 20, y + 26, "LIVE", 22, ui.WHITE, 7, true)
        ui.text(c, BAR_X + BAR_W, y + 26, ui.fmt_time(st.pos), 22, ui.GREY, 9)
        return
    end
    local dur = st.dur or 0
    local frac = dur > 0 and math.min(1, (st.pos or 0) / dur) or 0
    if drag then frac = drag.frac end
    ui.rect(c, BAR_X, y - 4, BAR_W, 8, 4, ui.WHITE, 0xB0)
    ui.rect(c, BAR_X, y - 4, math.max(8, BAR_W * frac), 8, 4, ui.ACCENT)
    ui.circle(c, BAR_X + BAR_W * frac, y, drag and 20 or 14, ui.WHITE)
    ui.text(c, BAR_X, y + 26, ui.fmt_time(drag and frac * dur or st.pos), 22, ui.GREY, 7)
    ui.text(c, BAR_X + BAR_W, y + 26, ui.fmt_time(dur), 22, ui.GREY, 9)
    if drag then
        local bx = math.max(BAR_X + 60, math.min(BAR_X + BAR_W - 60, BAR_X + BAR_W * frac))
        ui.rect(c, bx - 60, y - 78, 120, 48, 14, ui.PANEL, 0x10)
        ui.text(c, bx, y - 54, ui.fmt_time(frac * dur), 26, ui.WHITE, 5, true)
    end
    ui.hit(cv, BAR_X - 30, y - 44, BAR_W + 60, 88, "bar")
end

local function draw_music(st)
    local c = cv.lines
    show_cover(st.cover)
    if not st.cover then
        ui.rect(c, 52, 64, 400, 400, 24, ui.PANEL)
        ui.text(c, 252, 264, "♪", 110, ui.DIM, 5)
    end
    close_button(c, 56)
    -- right of the cover, one centred column: what is playing, the transport,
    -- then shuffle and repeat under the gaps between the buttons
    local mid = 746
    ui.text(c, mid, 98, ui.trim(st.album, 30), 21, ui.GREY, 8)
    ui.text(c, mid, 128, ui.trim(st.title, 24), 34, ui.WHITE, 8, true)
    ui.text(c, mid, 178, ui.trim(st.artist, 30), 25, ui.GREY, 8)
    local cy, prev_x, play_x, next_x = 304, mid - 122, mid, mid + 122
    ui.icon_skip(c, prev_x, cy, 36, st.has_prev and ui.WHITE or ui.DIM, false)
    ui.hit(cv, prev_x - 50, cy - 60, 100, 120, "prev")
    ui.circle(c, play_x, cy, 68, ui.WHITE)
    if st.paused then ui.icon_play(c, play_x + 6, cy, 52, ui.PANEL) else ui.icon_pause(c, play_x, cy, 48, ui.PANEL) end
    ui.hit(cv, play_x - 72, cy - 72, 144, 144, "pause")
    ui.icon_skip(c, next_x, cy, 36, st.has_next and ui.WHITE or ui.DIM, true)
    ui.hit(cv, next_x - 50, cy - 60, 100, 120, "next")
    local rep = st["repeat"] or "Off"
    local row = 416
    local function toggle(x, on, draw_icon, name)
        draw_icon(x, on and ui.ACCENT or ui.GREY)
        if on then ui.circle(c, x, row + 30, 4, ui.ACCENT) end  -- the "on" dot, as in most players
        ui.hit(cv, x - 50, row - 36, 100, 80, name)
    end
    toggle(prev_x, st.shuffle, function(x, col) ui.icon_shuffle(c, x, row, 40, col) end, "shuffle")
    toggle(play_x, rep ~= "Off", function(x, col) ui.icon_repeat(c, x, row, 40, col, rep == "One") end, "repeat")
    -- the lyrics, on this screen (dim when the song has none)
    local has = st.path and lyrics.get(st.path)
    ui.icon_mic(c, next_x, row, 34, has and ui.GREY or ui.DIM)
    if has then ui.hit(cv, next_x - 50, row - 36, 100, 80, "lyrics") end
    progress(c, st, BAR_Y)
    local pills = {
        { nil, remote and "Play in background" or "Open player", remote and "to-bottom" or "to-top" },
        { "Stay on", st.keep_on and "On" or "Off", "setting", "stay-on" },
        { nil, "Settings", "settings" },
    }
    -- in the background (a game has the pad) albums and tracks are picked here
    if backend.library then table.insert(pills, 1, { nil, "Library", "library" }) end
    pill_row(c, pills)
end

-- The remote of the music player on the main screen. That screen shows what
-- is playing, so this one holds the controls and the queue: tap a song to
-- play it, drag the list to scroll. The pad's pick in the queue shows here.
local Q_TOP, Q_ROW, Q_ROWS = 320, 72, 4
local queue_first   -- the first row after a finger scrolled the list; nil: it follows
local queue_follow  -- what it follows: the pad's pick, else the song playing
local queue_drag    -- { x, y, first, moved } while a finger is on the list

-- (the state carries a stretch of the queue: queue_start is its first row,
-- queue_count the whole queue; rows are 0-based like mpv's playlist)
local function queue_top(st)
    local n = st.queue_count or 0
    local at = st.queue_sel or st.queue_pos or 0
    if at ~= queue_follow then queue_follow, queue_first = at, nil end
    return math.max(0, math.min(queue_first or at - 1, n - Q_ROWS)), n
end

-- The volume or brightness sliders, in place of the queue (or the transport).
local slider_range = {}   -- target -> { x1, x2 } as last drawn

local function level_at(x, target)
    local r = slider_range[target] or { BAR_X + 128, BAR_X + BAR_W - 128 }
    return math.floor(math.max(0, math.min(1, (x - r[1]) / (r[2] - r[1]))) * 100 + 0.5)
end

local LEVEL_FIELD = { volume = "volume", top = "brightness_top", bottom = "brightness_bottom" }
local function level_value(st, target)
    if level_drag and (level_drag.target == target or (st and st.brightness_sync
            and target ~= "volume" and level_drag.target ~= "volume")) then
        return level_drag.value  -- (synced screens move together)
    end
    return (st and st[LEVEL_FIELD[target]]) or 50
end

local function slider(c, st, target, y, x1, x2)
    slider_range[target] = { x1, x2 }
    local dragging = level_drag and level_drag.target == target
    local frac = level_value(st, target) / 100
    ui.rect(c, x1, y - 7, x2 - x1, 14, 7, ui.TRACK)
    ui.rect(c, x1, y - 7, math.max(14, (x2 - x1) * frac), 14, 7, ui.ACCENT)
    ui.circle(c, x1 + (x2 - x1) * frac, y, dragging and 26 or 20, ui.WHITE)
    ui.hit(cv, x1 - 30, y - 40, x2 - x1 + 60, 80, "level-bar", target)
end

-- top, h: the card's place (the queue's on the music remote, the transport's over a video)
local function draw_level(c, st, top, h)
    local x, y, w = BAR_X, top, BAR_W
    ui.rect(c, x, y, w, h, 24, ui.RAISED)
    ui.hit(cv, x, y, w, h, "level-keep")  -- (a tap on the card keeps it open)
    local volume = level_kind == "volume"
    if volume then ui.icon_speaker(c, BAR_X + 52, y + 56, 40, ui.WHITE)
    else ui.icon_sun(c, BAR_X + 52, y + 56, 40, ui.WHITE) end
    ui.text(c, BAR_X + 92, y + 56, volume and "Volume" or "Brightness", 30, ui.WHITE, 4, true)
    if volume or not (st and st.brightness_bottom) then
        -- one slider, with steps of 5 at its ends
        local target = volume and "volume" or "top"
        ui.text(c, BAR_X + BAR_W - 32, y + 56, level_value(st, target) .. "%", 30, ui.ACCENT, 6, true)
        local sy = top + 160
        slider(c, st, target, sy, BAR_X + 128, BAR_X + BAR_W - 128)
        for _, b in ipairs({ { BAR_X + 62, "−", -5 }, { BAR_X + BAR_W - 62, "+", 5 } }) do
            ui.circle(c, b[1], sy, 34, ui.PANEL)
            ui.text(c, b[1], sy - 2, b[2], 38, ui.WHITE, 5, true)
            ui.hit(cv, b[1] - 44, sy - 44, 88, 88, "level-step", b[3], target)
        end
        return
    end
    -- two screens, each its own, or linked by Sync
    for i, row in ipairs({ { "top", "Top screen" }, { "bottom", "Bottom screen" } }) do
        local sy = top + 60 + i * 80
        ui.text(c, BAR_X + 32, sy, row[2], 24, ui.GREY, 4)
        slider(c, st, row[1], sy, BAR_X + 230, BAR_X + BAR_W - 300)
        ui.text(c, BAR_X + BAR_W - 206, sy, level_value(st, row[1]) .. "%", 26, ui.ACCENT, 6, true)
    end
    local sync = st.brightness_sync
    local bx, by, bw, bh = BAR_X + BAR_W - 172, top + 104, 140, 152
    ui.rect(c, bx, by, bw, bh, 20, sync and ui.ACCENT or ui.PANEL)
    ui.icon_link(c, bx + bw / 2, by + 60, 44, sync and ui.WHITE or ui.GREY)
    ui.text(c, bx + bw / 2, by + 114, "Sync", 22, sync and ui.WHITE or ui.GREY, 5, true)
    ui.hit(cv, bx, by, bw, bh, "level-sync")
end

-- The clock and the battery in a remote's top row, ending at x (centred on
-- y). Returns where they begin.
local function clock_battery(c, x, y)
    local b = battery.read()
    if b then
        x = x - 44
        ui.icon_battery(c, x, y - 11, 40, 22, b.pct, b.charging)
        local pct = b.pct .. "%"
        x = x - 12
        ui.text(c, x, y, pct, 22, ui.GREY, 6)
        x = x - ui.width(pct, 22) - 20
    end
    local clock = os.date("%H:%M")
    ui.text(c, x, y, clock, 26, ui.WHITE, 6)
    return x - ui.width(clock, 26)
end

-- The lock for the handheld's buttons, so a hand holding it does not press
-- them by accident; a tap here locks and unlocks them.
local function lock_button(c, cx, cy)
    local col = pad_locked and ui.ACCENT or ui.GREY
    ui.icon_lock(c, cx, cy, 40, col, not pad_locked)
    if pad_locked and mp.get_time() - locked_flash < 2 then
        ui.text(c, cx, cy + 44, "Buttons locked", 20, ui.ACCENT, 8, true)
    end
    ui.hit(cv, cx - 42, cy - 40, 84, 80, "padlock")
end

-- The brightness and volume buttons of a remote's top row, ending at x.
local function level_buttons(c, x)
    ui.icon_sun(c, x - 90, 48, 40, level_kind == "brightness" and ui.ACCENT or ui.GREY)
    ui.hit(cv, x - 135, 8, 90, 80, "level-open", "brightness")
    ui.icon_speaker(c, x, 48, 40, level_kind == "volume" and ui.ACCENT or ui.GREY)
    ui.hit(cv, x - 45, 8, 90, 80, "level-open", "volume")
end

local function draw_remote_music(st)
    local c = cv.lines
    show_cover(nil)
    local first, n = queue_top(st)
    ui.text(c, 44, 48, "Queue", 28, ui.WHITE, 4, true)
    if n > 0 then
        ui.text(c, 62 + ui.width("Queue", 28, true), 50, string.format("%d / %d", (st.queue_pos or 0) + 1, n), 22, ui.GREY, 4)
    end
    -- lyrics or the cover on the main screen (lit while the lyrics show,
    -- dim when the song has none), and quit
    local has = st.has_lyrics
    lock_button(c, clock_battery(c, 610, 48) - 48, 48)
    -- brightness and volume: each opens a slider over the queue
    level_buttons(c, 780)
    ui.icon_mic(c, 870, 48, 30, not has and ui.DIM or (st.lyrics_on and ui.ACCENT or ui.GREY))
    if has then ui.hit(cv, 820, 8, 100, 80, "toggle-lyrics") end
    close_button(c, 48)
    -- the transport, with shuffle and repeat at its sides
    local cy = 158
    local rep = st["repeat"] or "Off"
    local function toggle(x, on, draw_icon, name)
        draw_icon(x, on and ui.ACCENT or ui.GREY)
        if on then ui.circle(c, x, cy + 34, 4, ui.ACCENT) end  -- the "on" dot
        ui.hit(cv, x - 60, cy - 50, 120, 100, name)
    end
    toggle(132, st.shuffle, function(x, col) ui.icon_shuffle(c, x, cy, 40, col) end, "shuffle")
    toggle(892, rep ~= "Off", function(x, col) ui.icon_repeat(c, x, cy, 40, col, rep == "One") end, "repeat")
    ui.icon_skip(c, 322, cy, 38, st.has_prev and ui.WHITE or ui.DIM, false)
    ui.hit(cv, 262, cy - 60, 120, 120, "prev")
    ui.circle(c, 512, cy, 66, ui.WHITE)
    if st.paused then ui.icon_play(c, 518, cy, 50, ui.PANEL) else ui.icon_pause(c, 512, cy, 46, ui.PANEL) end
    ui.hit(cv, 436, cy - 76, 152, 152, "pause")
    ui.icon_skip(c, 702, cy, 38, st.has_next and ui.WHITE or ui.DIM, true)
    ui.hit(cv, 642, cy - 60, 120, 120, "next")
    progress(c, st, 266)
    if level_kind then
        draw_level(c, st, Q_TOP, Q_ROWS * Q_ROW - 8)
    else
    -- the queue
    local start = st.queue_start or 0
    for i = first, math.min(n - 1, first + Q_ROWS - 1) do
        local y = Q_TOP + (i - first) * Q_ROW
        local mid = y + (Q_ROW - 8) / 2
        local now = i == st.queue_pos
        local name, id = (st.queue or {})[i - start + 1], (st.queue_ids or {})[i - start + 1]
        if i == st.queue_sel then ui.rect(c, BAR_X - 24, y, BAR_W + 48, Q_ROW - 8, 16, ui.RAISED) end
        ui.text(c, BAR_X, mid, now and "♪" or tostring(i + 1), 24, now and ui.ACCENT or ui.DIM, 4)
        -- (scrolled past the stretch the state carries: the name comes with the next state)
        ui.text(c, BAR_X + 60, mid, ui.fit_text(name or "…", BAR_W - 70, 28), 28, now and ui.ACCENT or ui.WHITE, 4)
        if id then ui.hit(cv, BAR_X - 24, y, BAR_W + 48, Q_ROW - 8, "queue-play", id) end
    end
    if n == 0 then ui.text(c, ui.W / 2, Q_TOP + Q_ROWS * Q_ROW / 2, "The queue is empty", 26, ui.DIM, 5) end
    end
    pill_row(c, {
        { nil, "Play in background", "to-bottom" },
        { "Stay on", st.keep_on and "On" or "Off", "setting", "stay-on" },
        { nil, "Settings", "settings" },
    })
end

local function draw_controls(st)
    local c = cv.lines
    if st and st.kind == "music" then
        if remote then draw_remote_music(st) else draw_music(st) end
        return
    end
    show_cover(nil)
    if not remote then ui.rect(c, 0, 0, ui.W, ui.H, 0, "000000", 0x58) end
    if not st then return end  -- the player is still starting; it says what to show

    if not remote then ui.text(c, 44, 40, ui.trim(st.title, 46), 28, ui.WHITE, 7, true) end
    if remote then
        -- the top row: the clock and the battery, then the buttons; the title gets its own lines below
        local b, clock = battery.read(), os.date("%H:%M")
        local w = ui.width(clock, 26) + (b and 20 + ui.width(b.pct .. "%", 22) + 12 + 44 or 0)
        clock_battery(c, 44 + w, 52)
        lock_button(c, 505, 52)
        -- "Show - 060 - Episode name" (the way the library names episodes): the show and the
        -- number small, the episode's name big; anything else is the title as it is
        local show, num, name = (st.title or ""):match("^(.-)%s+%-%s+(%d+)%s+%-%s+(.+)$")
        if show then
            ui.text(c, 44, 128, ui.fit_text(show .. "  ·  Episode " .. tonumber(num), ui.W - 88, 24), 24, ui.GREY, 4)
            ui.text(c, 44, 170, ui.fit_text(name, ui.W - 88, 36, true), 36, ui.WHITE, 4, true)
        else
            ui.text(c, 44, 150, ui.fit_text(st.title or "", ui.W - 88, 36, true), 36, ui.WHITE, 4, true)
        end
        level_buttons(c, 690)
        -- "Stay on": keep this screen lit instead of turning it off after a few seconds
        local sx, sy = 836, 38
        ui.text(c, sx - 14, sy + 17, "Stay on", 21, ui.GREY, 6)
        ui.rect(c, sx, sy, 68, 36, 18, st.keep_on and ui.ACCENT or ui.RAISED)
        ui.circle(c, st.keep_on and sx + 50 or sx + 18, sy + 18, 14, ui.WHITE)
        ui.hit(cv, sx - 110, sy - 16, 196, 68, "setting", "remote-on", 1)
        if intro and not st.keep_on then
            ui.text(c, 44, 206, "This screen turns off after a few seconds. " .. (st.wake_taps == 1 and "Tap" or "Double-tap") .. " it to bring the controls back,", 19, ui.GREY, 7)
            ui.text(c, 44, 230, "or switch on Stay on.", 19, ui.GREY, 7)
        end
    end
    close_button(c, 56, 0x20)

    if remote and level_kind then
        draw_level(c, st, 214, 272)  -- in place of the transport while it is open
    else
    -- transport
    local cy = 330
    local function skip(x, forward, enabled, name)
        ui.icon_skip(c, x, cy, 40, enabled and ui.WHITE or ui.DIM, forward)
        if enabled then ui.hit(cv, x - 50, cy - 50, 100, 100, name) end
    end
    skip(196, false, st.has_prev, "prev")
    skip(828, true, st.has_next, "next")
    for _, b in ipairs({ { 340, "−10", -10 }, { 684, "+10", 10 } }) do
        ui.ring(c, b[1], cy, 54, 4, ui.WHITE, 0x10)
        ui.text(c, b[1], cy, b[2], 30, ui.WHITE, 5, true)
        ui.hit(cv, b[1] - 64, cy - 64, 128, 128, "seek", b[3])
    end
    ui.circle(c, 512, cy, 82, ui.WHITE)
    if st.paused then ui.icon_play(c, 518, cy, 64, ui.PANEL) else ui.icon_pause(c, 512, cy, 60, ui.PANEL) end
    ui.hit(cv, 420, cy - 92, 184, 184, "pause")
    end

    progress(c, st, BAR_Y)

    pill_row(c, remote and {
        { nil, "Videos", "files" },
        { "Subtitles", st.sub, "sub-next" },
        { "Audio", st.audio, "audio-next" },
        { nil, "Settings", "settings" },
    } or {
        { "Subtitles", st.sub, "sub-next" },
        { "Audio", st.audio, "audio-next" },
        { nil, "Settings", "settings" },
        { nil, "Move to top", "to-top" },
    })
end

-- The lyrics, the whole screen: the line being sung in the middle, white;
-- a redraw when the next one starts. The remote hears the position once a
-- second and runs on from there.
local lyrics_timer
local function draw_lyrics(st)
    local c = cv.lines
    show_cover(nil)
    if lyrics_timer then lyrics_timer:kill(); lyrics_timer = nil end
    ui.text(c, 44, 40, ui.trim(st and st.title or "", 34), 28, ui.WHITE, 7, true)
    ui.text(c, 44, 80, ui.trim(st and st.artist or "", 40), 22, ui.GREY, 7)
    ui.rect(c, ui.W - 164, 30, 130, 60, 20, ui.ACCENT)
    ui.text(c, ui.W - 99, 60, "Done", 28, ui.WHITE, 5, true)
    ui.hit(cv, ui.W - 184, 18, 170, 88, "done")
    local lyr = st and st.path and lyrics.get(st.path)
    if not lyr then
        ui.text(c, ui.W / 2, ui.H / 2, "No lyrics for this song", 30, ui.DIM, 5)
        return
    end
    local pos = st.pos or 0
    if not st.paused and st.at then pos = pos + (mp.get_time() - st.at) end
    local LINE, top, bottom = 70, 130, ui.H - 24
    local rows = math.floor((bottom - top) / LINE)
    top = top + ((bottom - top) - rows * LINE) / 2  -- the lines in the middle of what is left
    local lines, cur, first = lyr.lines, 0, 1
    if lyr.timed then
        cur = lyrics.at(lyr, pos)
        first = math.max(1, math.min(cur - math.floor(rows / 2), #lines - rows + 1))
    else
        local frac = (st.dur or 0) > 0 and math.min(1, pos / st.dur) or 0
        first = 1 + math.floor(frac * math.max(0, #lines - rows) + 0.5)
    end
    for i = first, math.min(#lines, first + rows - 1) do
        local now = i == cur
        local text = lines[i].text ~= "" and lines[i].text or "♪"
        local size = now and 38 or 32
        ui.text(c, ui.W / 2, top + (i - first) * LINE + LINE / 2, ui.fit_text(text, ui.W - 80, size, now), size,
            now and ui.WHITE or (lyr.timed and i < cur and ui.DIM or ui.GREY), 5, now)
    end
    local nxt = lyr.timed and not st.paused and lyrics.next_time(lyr, pos)
    if nxt then
        lyrics_timer = mp.add_timeout(math.max(0.05, nxt - pos + 0.02), function()
            lyrics_timer = nil
            if view == "lyrics" then T.draw() end
        end)
    end
end

local function draw_settings(st)
    show_cover(nil)
    local tabs = st and st.settings or {}
    tab = math.max(1, math.min(tab, #tabs))
    local o = { tab = tab, backdrop = remote and 0 or 0x28 }
    if view == "about" then S.draw_about(cv, o)
    elseif view == "guide" then S.draw_guide(cv, st and st.kind == "music" and "music" or "video", o)
    else S.draw(cv, tabs, o) end
end

local last_draw, draw_later = 0, nil

local function draw()
    last_draw = mp.get_time()
    cv = ui.canvas()
    if view == "hidden" then
        show_cover(nil)
        if flash and mp.get_time() < flash.till then
            local x = flash.side < 0 and 200 or ui.W - 200
            ui.circle(cv.lines, x, ui.H / 2, 90, "000000", 0x60)
            ui.text(cv.lines, x, ui.H / 2, flash.text, 34, ui.WHITE, 5, true)
            ui.show(overlay, cv)
        else
            flash = nil
            overlay:remove(); overlay.data = nil  -- so ui.show draws it again
        end
        return
    end
    local st = backend.state()
    if view == "controls" then draw_controls(st)
    elseif view == "lyrics" then draw_lyrics(st)
    elseif view == "library" then show_cover(nil); L.draw(cv, st)
    elseif view == "files" then show_cover(nil); F.draw(cv, st, { pad = files_pad })
    else draw_settings(st) end
    ui.show(overlay, cv)
end
T.draw = draw

-- While a finger scrolls, touch events come faster than a frame can be
-- drawn; draw at most 40 times a second, always the latest position.
local function draw_soon()
    if draw_later then return end
    local wait = last_draw + 1 / 40 - mp.get_time()
    if wait <= 0 then draw(); return end
    draw_later = mp.add_timeout(wait, function() draw_later = nil; draw() end)
end

-- Visibility ----------------------------------------------------------------


local function in_settings() return view == "settings" or view == "guide" or view == "about" or view == "library" or view == "files" end
local function stays() return view == "lyrics" end  -- read while the song plays: no turning off

-- A player setting the remote follows (sent with the state).
local function setting(name, default)
    local st = backend and backend.state()
    return (st and st[name]) or default
end

-- Stay lit? The remote and the music player follow the viewer's "Stay on";
-- controls over a video always hide.
local function keep_on()
    if T.always_on then return true end
    local st = backend and backend.state()
    return st ~= nil and st.keep_on == true and (remote or st.kind == "music")
end

-- The volume/brightness panel closes by itself a few seconds after the last touch.
local function arm_level()
    if level_timer then level_timer:kill() end
    level_timer = mp.add_timeout(LEVEL_CLOSE_AFTER, function()
        level_timer = nil
        if level_drag then arm_level(); return end
        level_kind = nil
        draw()
    end)
end

local function close_level()
    if level_timer then level_timer:kill(); level_timer = nil end
    level_kind, level_drag = nil, nil
end

-- While the slider moves, the setting follows it a few times a second.
local function send_level(force)
    local now = mp.get_time()
    if level_drag and (force or now - level_sent >= 0.12) then
        level_sent = now
        backend.action("level", level_drag.target, level_drag.value)
    end
end

local function arm_idle(seconds)
    if idle_timer then idle_timer:kill() end
    local after = seconds or (remote and (in_settings() and SETTINGS_SLEEP_AFTER or setting("remote_sleep", SLEEP_AFTER)) or HIDE_AFTER)
    idle_timer = mp.add_timeout(after, function()
        if not remote and view == "controls" then
            local st = backend.state()
            if st and st.paused then return end  -- keep controls up while paused
        end
        if not remote and in_settings() then return end
        if keep_on() or stays() then return end
        T.hide()
    end)
end

local function set_view(v)
    if view == "library" and v ~= "library" then L.close() end
    view = v
    if v == "hidden" then
        if tick_timer then tick_timer:kill(); tick_timer = nil end
    elseif not tick_timer and not remote then
        tick_timer = mp.add_periodic_timer(1, draw)
    end
    draw()
end

-- Wake the controls if hidden, else keep the page and restart the timer.
function T.poke()
    if view == "hidden" then T.show("controls") else arm_idle() end
end

function T.show(v)
    if view == "hidden" and backend.wake then backend.wake() end
    set_view(v or "controls")
    arm_idle()
end

-- The remote shows itself for a while when a video opens, so people find it,
-- then turns the screen off like after any other use.
function T.intro()
    intro = true
    T.show("controls")
    arm_idle(INTRO_FOR)
end

function T.hide()
    intro = false
    if view == "files" then F.close(); backend.action("browse-closed") end
    files_drag = nil
    close_level()
    scrolling = false
    queue_drag, queue_first = nil, nil
    down = nil
    if idle_timer then idle_timer:kill(); idle_timer = nil end
    drag = nil
    set_view("hidden")
    if backend.sleep then backend.sleep() end
end

-- The video browser ----------------------------------------------------------

local function open_files(pad)
    local st = backend.state()
    F.open_at(st and st.path)
    files_pad = pad
    T.show("files")
end

local function close_files(tell)
    F.close()
    files_drag = nil
    set_view("controls")
    arm_idle()
    if tell then backend.action("browse-closed") end  -- the player stops handing over the pad
end

local function files_result(r)
    if r == "close" then close_files(true)
    elseif type(r) == "table" then  -- a video: the player opens it
        backend.action("open-file", r[2])
        close_files(true)
    elseif r then draw() end
end

-- The hub dropped a button while they are locked: show why.
local LOCKED_SHOW = 2  -- seconds a dark screen lights up to show the lock after a stray press
function T.locked()
    pad_locked = true
    locked_flash = mp.get_time()
    if view == "hidden" then
        T.show("controls")
        arm_idle(LOCKED_SHOW)  -- only a glimpse: the press was most likely by accident
    else
        draw()
    end
    mp.add_timeout(LOCKED_SHOW + 0.05, function() if view ~= "hidden" then draw() end end)
end

-- The player's X and its pad keys while the browser is open (from the hub).
function T.browse(key)
    if key == "open" then
        if view == "files" then files_pad = true; arm_idle(); draw() else open_files(true) end
        return
    end
    if key == "close" then if view == "files" then close_files(false) end; return end
    if view ~= "files" then open_files(true) end  -- (it had turned off meanwhile)
    files_pad = true
    arm_idle()
    files_result(F.key(key))
end

-- Input -------------------------------------------------------------------

-- Where the finger is: touch-pos while a finger is down, else mouse-pos.
-- Remember the last place for when the finger lifts.
local last_pos = { x = 0, y = 0 }

-- A finger can still be down after mpv said "up": when the hub hands the
-- keyboard focus back to the main screen, mpv releases every held key, the
-- touch included, although the finger stays on the glass and keeps moving.
-- So a drag ends when touch-pos is empty, not on "up".
local function finger_down()
    local t = mp.get_property_native("touch-pos")
    return type(t) == "table" and #t > 0
end

local function canvas_pos()
    local t = mp.get_property_native("touch-pos")
    local p = (type(t) == "table" and t[1]) or mp.get_property_native("mouse-pos") or last_pos
    local d = mp.get_property_native("osd-dimensions") or {}
    local w, h = d.w or ui.W, d.h or ui.H
    if w <= 0 or h <= 0 then w, h = ui.W, ui.H end
    last_pos = { x = p.x, y = p.y }
    return p.x * ui.W / w, p.y * ui.H / h
end

local function frac_at(x)
    return math.max(0, math.min(1, (x - BAR_X) / BAR_W))
end


local function run(hit)
    local name = hit.fn
    if name == "settings" then set_view("settings")
    elseif name == "lyrics" then set_view("lyrics")
    elseif name == "done" then set_view("controls")
    elseif name == "tab" then tab = hit.data; draw()
    elseif name == "guide" then set_view("guide")
    elseif name == "guide-done" or name == "about-done" then set_view("settings")
    elseif name == "about" then set_view("about")
    elseif name == "setting" then
        backend.action("setting", hit.data, hit.data2)
        if hit.close then set_view("controls") end
    elseif name == "library" then L.open(backend.library(), backend.names, backend.track_name); set_view("library")
    elseif name == "padlock" then
        pad_locked = not pad_locked
        if backend.padlock then backend.padlock(pad_locked) end
        draw()
    elseif name == "files" then open_files(false); return
    elseif name == "files-close" then close_files(true); return
    elseif name == "files-up" then F.up(); draw(); return
    elseif name == "files-item" then files_result(F.activate(hit.data)); return
    elseif name == "lib-done" then set_view("controls")
    elseif name:sub(1, 4) == "lib-" then
        if L.tap(hit, backend.action) == "play" then set_view("controls") else draw() end
    elseif name == "level-open" then
        if level_kind == hit.data then close_level() else level_kind, level_drag = hit.data, nil; arm_level() end
        draw()
    elseif name == "level-step" then
        local v = math.max(0, math.min(100, level_value(backend.state(), hit.data2) + hit.data))
        backend.action("level", hit.data2, v)
        arm_level()
    elseif name == "level-sync" then
        local st = backend.state() or {}
        backend.action("level-sync", st.brightness_sync and "off" or "on")
        arm_level()
    elseif name == "level-keep" or name == "level-bar" then arm_level()
    elseif name == "quit" then
        if quit_ask and mp.get_time() - quit_ask < QUIT_CONFIRM then
            quit_ask = nil
            backend.action("quit")
            T.hide()
        else
            quit_ask = mp.get_time()
            mp.add_timeout(QUIT_CONFIRM + 0.05, function() if view ~= "hidden" then draw() end end)
            draw()
        end
    elseif name == "to-bottom" or name == "to-top" then backend.action(name)
    else backend.action(name, hit.data) end
    mp.add_timeout(0.08, draw)
end

local function end_scroll()
    scrolling = false
    local moved = L.release(draw_soon)
    local d = down
    down = nil
    arm_idle()
    if not moved and d then
        local hit = ui.find_hit(cv, d.x, d.y)
        if hit then run(hit) end
    end
end

-- The remote's queue: a finger that moves scrolls it a row at a time, one
-- that lifts where it landed taps the song.
local function in_queue(y)
    local st = remote and view == "controls" and not level_kind and backend.state()
    return st and st.kind == "music" and y >= Q_TOP and y < Q_TOP + Q_ROWS * Q_ROW
end

local function queue_move(y)
    local d = queue_drag.y - y
    if math.abs(d) < 24 and not queue_drag.moved then return end
    queue_drag.moved = true
    local n = (backend.state() or {}).queue_count or 0
    local first = math.max(0, math.min(queue_drag.first + math.floor(d / Q_ROW + 0.5), n - Q_ROWS))
    if first ~= queue_first then queue_first = first; draw_soon() end
end

-- A tap on an empty spot of the remote turns it off: the same way it is woken
-- (one tap, or a double tap); a single tap alone does nothing in double-tap mode.
local function empty_tap()
    if setting("wake_taps", 1) == 1 then
        if not keep_on() then T.hide() end
        return
    end
    local now = mp.get_time()
    if close_tap and now - close_tap <= WAKE_TAPS_WITHIN then
        close_tap = nil
        T.hide()
    else
        close_tap = now
    end
end

local function queue_release()
    local qd = queue_drag
    queue_drag, down = nil, nil
    arm_idle()
    if qd.moved then
        if queue_first then backend.action("queue-view", queue_first) end  -- the names around where the list was left
    else
        local hit = ui.find_hit(cv, qd.x, qd.y)
        if hit then run(hit)
        else empty_tap() end  -- (an empty spot, as anywhere else)
    end
end

local function files_move(y)
    local d = files_drag.y - y
    if math.abs(d) < 24 and not files_drag.moved then return end
    files_drag.moved = true
    local first = files_drag.first + math.floor(d / F.ROW + 0.5)
    if first ~= F.first() then F.scroll_to(first); draw_soon() end
end

local function files_release()
    local fd = files_drag
    files_drag, down = nil, nil
    arm_idle()
    if not fd.moved then
        local hit = ui.find_hit(cv, fd.x, fd.y)
        if hit then run(hit) end
    end
end

local function on_down(x, y)
    down = { x = x, y = y, t = mp.get_time() }
    if idle_timer then idle_timer:kill(); idle_timer = nil end  -- not while a finger is down
    if view == "files" and y > 100 then
        files_drag = { x = x, y = y, first = F.first(), moved = false }
        return
    end
    if in_queue(y) then
        queue_drag = { x = x, y = y, first = (queue_top(backend.state())), moved = false }
    elseif view == "library" and L.in_list(y) then
        scrolling = true
        L.press(y)
    elseif view == "controls" then
        local hit = ui.find_hit(cv, x, y)
        if hit and hit.fn == "level-bar" then
            level_drag = { target = hit.data, value = level_at(x, hit.data) }
            send_level(true)
            draw()
        elseif hit and hit.fn == "bar" then
            drag = { frac = frac_at(x) }
            draw()
        end
    end
end

local function on_move(x)
    if level_drag then
        level_drag.value = level_at(x, level_drag.target)
        send_level(false)
        draw()
    elseif drag then
        drag.frac = frac_at(x)
        draw()
    end
end

-- Seek to where the moves left the knob (at release touch-pos is already
-- empty and mouse-pos may be stale).
local function end_drag()
    if level_drag then
        send_level(true)
        level_drag, down = nil, nil
        arm_level()
        arm_idle()
        mp.add_timeout(0.15, draw)
        return
    end
    local st = backend.state()
    if st and st.dur and st.dur > 0 then backend.action("seek-to", drag.frac * st.dur) end
    drag, down = nil, nil
    arm_idle()
    mp.add_timeout(0.15, draw)
end

local function on_up(x, y)
    arm_idle()
    if files_drag then
        if not finger_down() then files_release() end
        return
    end
    if queue_drag then
        if not finger_down() then queue_release() end
        return
    end
    if drag or level_drag then
        if not finger_down() then end_drag() end
        return
    end
    if scrolling then
        if not finger_down() then end_scroll() end
        return
    end
    if not down or math.abs(x - down.x) > 40 or math.abs(y - down.y) > 40 then return end
    down = nil

    if view == "hidden" then
        if remote then
            -- a double tap wakes it, so a hand resting on the dark screen does not
            local now = mp.get_time()
            if setting("wake_taps", 1) == 1 or (wake_tap and now - wake_tap <= WAKE_TAPS_WITHIN) then
                wake_tap = nil
                T.show("controls")
            else
                wake_tap = now
            end
            return
        end
        -- over the video: one tap shows the controls, a quick second tap on
        -- the left or right third seeks 10 s
        local now = mp.get_time()
        local side = x < ui.W / 3 and -1 or x > ui.W * 2 / 3 and 1 or 0
        if last_tap and now - last_tap.t < 0.35 and side ~= 0 and side == last_tap.side then
            if last_tap.timer then last_tap.timer:kill() end
            backend.action("seek", 10 * side)
            local n = (flash and flash.side == side and flash.n or 0) + 1
            flash = { text = (side < 0 and "−" or "+") .. (10 * n), side = side, n = n, till = now + 0.7 }
            last_tap = { t = now, side = side }
            draw()
            mp.add_timeout(0.75, draw)
            return
        end
        local timer = mp.add_timeout(0.3, function() last_tap = nil; T.show("controls") end)
        last_tap = { t = now, side = side, timer = timer }
        return
    end

    local hit = ui.find_hit(cv, x, y)
    if level_kind and not (hit and hit.fn:sub(1, 6) == "level-") then
        close_level()
        arm_idle()
        draw()
        return
    end
    if hit then
        run(hit)
    elseif view == "controls" and remote then
        empty_tap()
    elseif view == "controls" and not keep_on() then
        T.hide()
    end
end

function T.init(b, is_remote, always_on)
    backend, remote, T.always_on = b, is_remote, always_on
    if remote then
        -- the remote redraws when the state comes; the clock in its top row moves on the minute too
        local minute = os.date("%M")
        mp.add_periodic_timer(5, function()
            if os.date("%M") == minute then return end
            minute = os.date("%M")
            if view ~= "hidden" then draw() end
        end)
    end
    mp.add_forced_key_binding("MBTN_LEFT", "handheld-touch", function(e)
        local x, y = canvas_pos()
        if e.event == "down" then on_down(x, y)
        elseif e.event == "up" then on_up(x, y) end
    end, { complex = true })
    mp.add_forced_key_binding("MBTN_LEFT_DBL", "handheld-touch-dbl", function() end)
    mp.observe_property("touch-pos", "native", function(_, t)
        local held = type(t) == "table" and #t > 0
        if files_drag then
            if held then files_move(select(2, canvas_pos())) else files_release() end
            return
        end
        if queue_drag then
            if held then queue_move(select(2, canvas_pos())) else queue_release() end
            return
        end
        if scrolling then
            if not held then end_scroll()
            elseif L.move(select(2, canvas_pos())) then draw_soon() end
            return
        end
        if not drag and not level_drag then return end
        if held then on_move((canvas_pos())) else end_drag() end
    end)
    mp.observe_property("mouse-pos", "native", function()
        if finger_down() then return end  -- touch-pos has it
        if files_drag then files_move(select(2, canvas_pos()))
        elseif queue_drag then queue_move(select(2, canvas_pos()))
        elseif scrolling then
            if L.move(select(2, canvas_pos())) then draw_soon() end
        elseif drag or level_drag then on_move((canvas_pos())) end
    end)
    if always_on then mp.add_timeout(0.2, function() T.show("controls") end) end
end

return T
