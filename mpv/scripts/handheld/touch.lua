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

local T = {}

local overlay = mp.create_osd_overlay("ass-events")
local backend, remote
local view = "hidden"            -- hidden | controls | settings | guide | about | library
local tab = 1                    -- settings tab
local cv = ui.canvas()
local idle_timer, tick_timer
local down, drag, last_tap = nil, nil, nil
local scrolling = false          -- a finger in the library list; a tap there is told apart when it lifts
local flash = nil                -- { text, side, until }
local intro = false              -- first showing: say how to bring it back

local HIDE_AFTER = 4              -- seconds, controls over the video
local SLEEP_AFTER = 8             -- seconds, remote panel
local INTRO_FOR = 10              -- seconds the remote stays up when a video opens
local SETTINGS_SLEEP_AFTER = 20

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
    ui.circle(c, 966, 56, 30, ui.RAISED)
    ui.text(c, 966, 56, "✕", 28, ui.WHITE, 5)
    ui.hit(cv, 926, 16, 80, 80, "quit")
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
    toggle((prev_x + play_x) / 2, st.shuffle, function(x, col) ui.icon_shuffle(c, x, row, 40, col) end, "shuffle")
    toggle((play_x + next_x) / 2, rep ~= "Off", function(x, col) ui.icon_repeat(c, x, row, 40, col, rep == "One") end, "repeat")
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

local function draw_controls(st)
    local c = cv.lines
    if st and st.kind == "music" then draw_music(st); return end
    show_cover(nil)
    if not remote then ui.rect(c, 0, 0, ui.W, ui.H, 0, "000000", 0x58) end
    if not st then return end  -- the player is still starting; it says what to show

    ui.text(c, 44, 40, ui.trim(st.title, remote and 36 or 46), 28, ui.WHITE, 7, true)
    if remote then
        -- "Stay on": keep this screen lit instead of turning it off after a few seconds
        local sx, sy = 836, 38
        ui.text(c, sx - 14, sy + 17, "Stay on", 21, ui.GREY, 6)
        ui.rect(c, sx, sy, 68, 36, 18, st.keep_on and ui.ACCENT or ui.RAISED)
        ui.circle(c, st.keep_on and sx + 50 or sx + 18, sy + 18, 14, ui.WHITE)
        ui.hit(cv, sx - 110, sy - 16, 196, 68, "setting", "remote-on", 1)
        if intro and not st.keep_on then
            ui.text(c, 44, 90, "This screen turns off after a few seconds. Tap it to bring the controls back,", 19, ui.GREY, 7)
            ui.text(c, 44, 116, "or switch on Stay on.", 19, ui.GREY, 7)
        end
    end
    ui.circle(c, 966, 56, 30, ui.RAISED, 0x20)
    ui.text(c, 966, 56, "✕", 28, ui.WHITE, 5)
    ui.hit(cv, 926, 16, 80, 80, "quit")

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

    progress(c, st, BAR_Y)

    pill_row(c, {
        { "Subtitles", st.sub, "sub-next" },
        { "Audio", st.audio, "audio-next" },
        { nil, "Settings", "settings" },
        { nil, remote and "Move to bottom" or "Move to top", remote and "to-bottom" or "to-top" },
    })
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
    elseif view == "library" then show_cover(nil); L.draw(cv, st)
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


local function in_settings() return view == "settings" or view == "guide" or view == "about" or view == "library" end

-- Stay lit? The remote and the music player follow the viewer's "Stay on";
-- controls over a video always hide.
local function keep_on()
    if T.always_on then return true end
    local st = backend and backend.state()
    return st ~= nil and st.keep_on == true and (remote or st.kind == "music")
end

local function arm_idle(seconds)
    if idle_timer then idle_timer:kill() end
    local after = seconds or (remote and (in_settings() and SETTINGS_SLEEP_AFTER or SLEEP_AFTER) or HIDE_AFTER)
    idle_timer = mp.add_timeout(after, function()
        if not remote and view == "controls" then
            local st = backend.state()
            if st and st.paused then return end  -- keep controls up while paused
        end
        if not remote and in_settings() then return end
        if keep_on() then return end
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
    scrolling = false
    down = nil
    if idle_timer then idle_timer:kill(); idle_timer = nil end
    drag = nil
    set_view("hidden")
    if backend.sleep then backend.sleep() end
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
    elseif name == "done" then set_view("controls")
    elseif name == "tab" then tab = hit.data; draw()
    elseif name == "guide" then set_view("guide")
    elseif name == "guide-done" or name == "about-done" then set_view("settings")
    elseif name == "about" then set_view("about")
    elseif name == "setting" then
        backend.action("setting", hit.data, hit.data2)
        if hit.close then set_view("controls") end
    elseif name == "library" then L.open(backend.library(), backend.names); set_view("library")
    elseif name == "lib-done" then set_view("controls")
    elseif name:sub(1, 4) == "lib-" then
        if L.tap(hit, backend.action) == "play" then set_view("controls") else draw() end
    elseif name == "quit" then backend.action("quit"); T.hide()
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

local function on_down(x, y)
    down = { x = x, y = y, t = mp.get_time() }
    if idle_timer then idle_timer:kill(); idle_timer = nil end  -- not while a finger is down
    if view == "library" and L.in_list(y) then
        scrolling = true
        L.press(y)
    elseif view == "controls" then
        local hit = ui.find_hit(cv, x, y)
        if hit and hit.fn == "bar" then
            drag = { frac = frac_at(x) }
            draw()
        end
    end
end

local function on_move(x)
    if drag then
        drag.frac = frac_at(x)
        draw()
    end
end

-- Seek to where the moves left the knob (at release touch-pos is already
-- empty and mouse-pos may be stale).
local function end_drag()
    local st = backend.state()
    if st and st.dur and st.dur > 0 then backend.action("seek-to", drag.frac * st.dur) end
    drag, down = nil, nil
    arm_idle()
    mp.add_timeout(0.15, draw)
end

local function on_up(x, y)
    arm_idle()
    if drag then
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
        if remote then T.show("controls"); return end
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
    if hit then
        run(hit)
    elseif view == "controls" and not keep_on() then
        T.hide()
    end
end

function T.init(b, is_remote, always_on)
    backend, remote, T.always_on = b, is_remote, always_on
    mp.add_forced_key_binding("MBTN_LEFT", "handheld-touch", function(e)
        local x, y = canvas_pos()
        if e.event == "down" then on_down(x, y)
        elseif e.event == "up" then on_up(x, y) end
    end, { complex = true })
    mp.add_forced_key_binding("MBTN_LEFT_DBL", "handheld-touch-dbl", function() end)
    mp.observe_property("touch-pos", "native", function(_, t)
        local held = type(t) == "table" and #t > 0
        if scrolling then
            if not held then end_scroll()
            elseif L.move(select(2, canvas_pos())) then draw_soon() end
            return
        end
        if not drag then return end
        if held then on_move((canvas_pos())) else end_drag() end
    end)
    mp.observe_property("mouse-pos", "native", function()
        if finger_down() then return end  -- touch-pos has it
        if scrolling then
            if L.move(select(2, canvas_pos())) then draw_soon() end
        elseif drag then on_move((canvas_pos())) end
    end)
    if always_on then mp.add_timeout(0.2, function() T.show("controls") end) end
end

return T
