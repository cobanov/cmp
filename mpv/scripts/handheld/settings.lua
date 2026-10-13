-- One settings screen for both players and both ways of using them. The
-- player builds its tabs (player.lua for video, music.lua for music); the pad
-- menu draws them on the main screen and the touch controls on the second
-- screen, from the same plain snapshot (the remote gets it as JSON).
--
-- A tab is { title, rows }. A row, as the player defines it:
--   key, label         label may be a function
--   kind               "track" | "choice" | "number"  ‹ › or − + steppers
--                      "toggle"  a switch
--                      "action"  runs on A / tap, run() returns "close" to
--                                leave the settings afterwards
--                      "guide"   opens the button guide where it is drawn
--                      "about"   opens the About page (S.ABOUT)
--                      "page"    opens a page of the player's own (padmenu's
--                                cfg.pages[key]); pad only
--   pad_only           left out on the touch screen
--   value(), on()      what it shows
--   change(dir)        steppers and toggles; run() for actions
--   off()              shown dimmed and does nothing
--   hidden()           left out
--   danger, close      red label; leave the settings after it ran

local ui = require "ui"

local S = {}

local function call(v) if type(v) == "function" then return v() end return v end

function S.snapshot(tabs)
    local out = {}
    for _, t in ipairs(tabs) do
        local rows = {}
        for _, r in ipairs(t.rows) do
            if not (r.hidden and r.hidden()) then
                rows[#rows + 1] = {
                    key = r.key, label = call(r.label), kind = r.kind,
                    value = r.value and r.value() or "", on = r.on and r.on() or false,
                    off = r.off and r.off() or false, danger = r.danger or false, close = r.close or false,
                    pad_only = r.pad_only or false,
                }
            end
        end
        out[#out + 1] = { title = t.title, rows = rows }
    end
    return out
end

function S.find(tabs, key)
    for _, t in ipairs(tabs) do
        for _, r in ipairs(t.rows) do
            if r.key == key then return r end
        end
    end
end

-- Change or run one row. Returns the row and what run() said.
function S.apply(tabs, key, dir)
    local r = S.find(tabs, key)
    if not r or (r.off and r.off()) then return end
    if r.run then return r, r.run() end
    if r.change then r.change(dir or 1) end
    return r
end

-- About ---------------------------------------------------------------------
-- Who made it and where it lives, one step away from Settings rather than on
-- every screen.

S.ABOUT = {
    name = "CMP",
    version = "0.4.0",
    tagline = "Console Music Player, for retro handhelds",
    lines = {
        { "Made by", "Mert Cobanov" },
        { "Email", "mertcobanov@gmail.com" },
        { "Source code", "github.com/cobanov/cmp" },
        { "Report a problem", "github.com/cobanov/cmp/issues" },
        { "License", "GPL-2.0-or-later, free software" },
        { "Built with", "mpv, libass, LuaJIT" },
    },
    -- QR code of https://github.com/cobanov/cmp (version 3, level M), one
    -- string per row, 1 = dark. Made with: python -c "import segno;
    -- print(segno.make('https://github.com/cobanov/cmp', error='m').matrix)"
    qr = {
        "11111110010101010010001111111",
        "10000010011111100001001000001",
        "10111010101000111101101011101",
        "10111010011100010011101011101",
        "10111010101101010010001011101",
        "10000010100110101111001000001",
        "11111110101010101010101111111",
        "00000000000001001110000000000",
        "01001010101101000100110110100",
        "00001001000110000110101110011",
        "01001111111101001100010111001",
        "10011101100111010101110100011",
        "01101011010111101101100101001",
        "01001100101000101100001010101",
        "11000010010001000110111010001",
        "11101101010110100111101101000",
        "00000011110110010101010000011",
        "11000000110011101000001110001",
        "00001110110011001110100011101",
        "00111101111110100111100011010",
        "11100011111100010100111111011",
        "00000000110000111011100010101",
        "11111110011111011101101010001",
        "10000010000010100101100011000",
        "10111010101101010011111110000",
        "10111010001101100010000101110",
        "10111010010001011001110001111",
        "10000010110001011100100101011",
        "11111110000010100110101011010",
    },
}

-- Button guides -------------------------------------------------------------

S.GUIDE = {
    video = {
        { "A", "Play / pause" },
        { "B", "Time and progress" },
        { "X", "Switch subtitles" },
        { "Y", "Switch audio language" },
        { "← →", "Back / forward 10 s, hold to scrub" },
        { "↑ ↓", "Forward / back 85 s (skip the opening)" },
        { "L1 R1", "Previous / next episode (press twice)" },
        { "Left stick", "Same as the d-pad" },
        { "Select", "Settings" },
        { "Start", "Quit, the position is saved" },
        { "Touch", "Bottom screen: controls" },
    },
    music = {
        { "A", "Choose: open the album, play a track" },
        { "B", "Back" },
        { "X", "Now playing; there, lyrics or the cover" },
        { "↑ ↓", "Move; in Cover Flow, jump by letter" },
        { "← →", "Browse; in the album list, jump by letter" },
        { "L1 R1", "Previous / next track" },
        { "Y", "Options: search, queue, screen off" },
        { "L1 + R1", "Together: play in the background (two screens)" },
        { "L2 R2", "Back / forward 10 s" },
        { "Select", "Settings" },
        { "Start", "Play / pause" },
        { "Select + Start", "Quit, the queue is saved" },
    },
}

-- Drawing -------------------------------------------------------------------
-- Same layout on both screens, as wide as the canvas (ui.W). o.pad: drawn
-- for the pad (row highlight, L1/R1 marks, key hints); otherwise for touch
-- (Done, hit areas).

local TAB_Y, TAB_H = 92, 64
local ROW_Y, ROW_H = 180, 76
S.ROW_Y, S.ROW_H, S.TAB_Y, S.TAB_H = ROW_Y, ROW_H, TAB_Y, TAB_H

local function header(cv, title, o, done)
    local c = cv.lines
    if o.backdrop then ui.rect(c, 0, 0, ui.W, ui.H, 0, "000000", o.backdrop) end
    ui.text(c, 44, 20, title, 42, ui.WHITE, 7, true)
    if not o.pad then
        local x = ui.W - 164
        ui.rect(c, x, 16, 130, 60, 20, ui.ACCENT)
        ui.text(c, x + 65, 46, "Done", 28, ui.WHITE, 5, true)
        ui.hit(cv, x - 20, 4, 180, 88, done)
    end
end

local function tabs_bar(cv, tabs, sel, o)
    local c = cv.lines
    local x, w = 44, ui.W - 88
    if o.pad then
        x, w = 120, ui.W - 240
        for _, b in ipairs({ { 44, "L1" }, { ui.W - 100, "R1" } }) do
            ui.rect(c, b[1], TAB_Y + 12, 56, 40, 12, ui.RAISED)
            ui.text(c, b[1] + 28, TAB_Y + TAB_H / 2, b[2], 22, ui.GREY, 5, true)
        end
    end
    ui.rect(c, x, TAB_Y, w, TAB_H, TAB_H / 2, ui.RAISED)
    local sw = (w - 8) / #tabs
    for i, t in ipairs(tabs) do
        local sx = x + 4 + (i - 1) * sw
        if i == sel then ui.rect(c, sx, TAB_Y + 4, sw, TAB_H - 8, (TAB_H - 8) / 2, ui.SELECT) end
        ui.text(c, sx + sw / 2, TAB_Y + TAB_H / 2, t.title, 30, i == sel and ui.WHITE or ui.GREY, 5, i == sel)
        if not o.pad then ui.hit(cv, sx, TAB_Y - 10, sw, TAB_H + 20, "tab", i) end
    end
end

local function row(cv, r, y, selected, o, h)
    local c = cv.lines
    local ROW_H = h or ROW_H
    local mid = y + ROW_H / 2
    local dim = r.off
    ui.text(c, 48, mid, r.label, 34, dim and ui.DIM or r.danger and ui.RED or ui.WHITE, 4)
    local right = ui.W - 44
    if r.kind == "toggle" then
        local sx, sw, sh = right - 96, 96, 50
        ui.rect(c, sx, mid - sh / 2, sw, sh, sh / 2, r.on and ui.ACCENT or ui.TRACK)
        ui.circle(c, r.on and sx + sw - sh / 2 or sx + sh / 2, mid, sh / 2 - 4, ui.WHITE)
        if r.value ~= "On" and r.value ~= "Off" then ui.text(c, sx - 20, mid, r.value, 28, ui.GREY, 6) end
        if not o.pad then ui.hit(cv, 0, y, ui.W, ROW_H, "setting", r.key, 1) end
    elseif r.kind == "action" or r.kind == "guide" or r.kind == "about" or r.kind == "page" then
        if r.value ~= "" then ui.text(c, right, mid, r.value, 28, r.danger and ui.RED or ui.ACCENT, 6)
        else ui.text(c, right - 8, mid, "›", 42, dim and ui.DIM or ui.GREY, 6) end
        if not o.pad and not dim then
            local h = (r.kind == "guide" or r.kind == "about") and ui.hit(cv, 0, y, ui.W, ROW_H, r.kind)
                or ui.hit(cv, 0, y, ui.W, ROW_H, "setting", r.key, 1)
            h.close = r.close
        end
    else
        local arrows = r.kind ~= "number"
        local fill = selected and ui.TRACK or ui.RAISED
        local PLUS_X, MINUS_X = right - 28, right - 310
        local VALUE_X = (PLUS_X + MINUS_X) / 2
        ui.circle(c, MINUS_X, mid, 28, fill)
        ui.text(c, MINUS_X, mid, arrows and "‹" or "−", 34, ui.WHITE, 5, true)
        ui.circle(c, PLUS_X, mid, 28, fill)
        ui.text(c, PLUS_X, mid, arrows and "›" or "+", 34, ui.WHITE, 5, true)
        ui.text(c, VALUE_X, mid, ui.trim(r.value, 12), 30, ui.ACCENT, 5)
        if not o.pad then
            ui.hit(cv, MINUS_X - 60, y, 120, ROW_H, "setting", r.key, -1)
            ui.hit(cv, PLUS_X - 60, y, 128, ROW_H, "setting", r.key, 1)
        end
    end
end

-- o: { tab, sel (pad only), pad, backdrop }
function S.draw(cv, tabs, o)
    local c = cv.lines
    header(cv, "Settings", o, "done")
    if #tabs == 0 then return end
    local tab = tabs[o.tab] or tabs[1]
    if not o.pad then  -- rows for the pad only stay off the touch screen
        local rows = {}
        for _, r in ipairs(tab.rows) do if not r.pad_only then rows[#rows + 1] = r end end
        tab = { title = tab.title, rows = rows }
    end
    local top = 96  -- a single list starts right under the title
    if #tabs > 1 then tabs_bar(cv, tabs, o.tab, o); top = ROW_Y end
    -- a long list (a dual-screen device has a couple more rows) gets
    -- slimmer rows rather than running off the screen
    -- slimmer rows rather than running off the screen; one longer still
    -- scrolls with the cursor
    local bottom = o.pad and 708 or 760
    local h = math.max(60, math.min(ROW_H, math.floor((bottom - top) / math.max(1, #tab.rows))))
    local fits = math.floor((bottom - top) / h)
    local first = 1
    if o.pad and #tab.rows > fits then
        first = math.max(1, math.min((o.sel or 1) - math.floor(fits / 2), #tab.rows - fits + 1))
    end
    for i, r in ipairs(tab.rows) do
        if i < first or i >= first + fits then goto next end
        local y = top + (i - first) * h
        local selected = o.pad and i == o.sel
        if selected then ui.rect(c, 28, y + 4, ui.W - 56, h - 8, 16, ui.RAISED)
        elseif i > 1 and not (o.pad and i - 1 == o.sel) then ui.rect(c, 44, y, ui.W - 88, 1, 0, ui.RAISED) end
        row(cv, r, y, selected, o, h)
        ::next::
    end
    if o.pad then
        local hints = { { "↑↓", "Select" }, { "←→", "Change" }, { "A", "Apply" }, { "B", "Close" } }
        if #tabs > 1 then hints[#hints + 1] = { "L1 R1", "Tab" } end
        ui.hints(c, 44, 738, hints, 24)
    end
end

-- The QR code as one ASS drawing: a white square, then every dark module.
local function draw_qr(c, rows, x, y, module)
    local n = #rows
    local quiet = 2 * module
    local size = n * module + 2 * quiet
    ui.rect(c, x, y, size, size, module, ui.WHITE)
    local path = {}
    for r = 1, n do
        local line = rows[r]
        local my = y + quiet + (r - 1) * module
        for col = 1, #line do
            if line:sub(col, col) == "1" then
                local mx = x + quiet + (col - 1) * module
                path[#path + 1] = string.format("m %d %d l %d %d l %d %d l %d %d",
                    mx, my, mx + module, my, mx + module, my + module, mx, my + module)
            end
        end
    end
    c[#c + 1] = "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H000000&\\p1}" .. table.concat(path, " ") .. "{\\p0}"
    return size
end

function S.draw_about(cv, o)
    local c = cv.lines
    local a = S.ABOUT
    header(cv, "About", o, "about-done")
    -- top right: the repository as a QR code, for a phone camera
    if a.qr then draw_qr(c, a.qr, ui.W - 44 - (#a.qr + 4) * 7, 24, 7) end
    ui.text(c, 44, 112, a.name, 44, ui.WHITE, 7, true)
    ui.text(c, 44 + ui.width(a.name, 44, true) + 20, 128, "v" .. a.version, 28, ui.GREY, 7)
    ui.text(c, 44, 172, a.tagline, 30, ui.GREY, 7)
    for i, line in ipairs(a.lines) do
        local y = 286 + (i - 1) * 64
        if i > 1 then ui.rect(c, 44, y, ui.W - 88, 1, 0, ui.RAISED) end
        ui.text(c, 48, y + 32, line[1], 26, ui.GREY, 4)
        ui.text(c, 300, y + 32, ui.fit_text(line[2], ui.W - 344, 30), 30, ui.WHITE, 4)
    end
    if o.pad then ui.hints(c, 44, 738, { { "B", "Back" } }, 24) end
end

function S.draw_guide(cv, kind, o)
    local c = cv.lines
    header(cv, "Button guide", o, "guide-done")
    local lines = S.GUIDE[kind] or S.GUIDE.video
    local step = math.min(56, math.floor((720 - 88) / #lines))  -- (a long guide gets closer rows)
    for i, line in ipairs(lines) do
        local y = 88 + (i - 1) * step
        if i > 1 then ui.rect(c, 44, y, ui.W - 88, 1, 0, ui.RAISED) end
        ui.text(c, 48, y + step / 2, line[1], 28, ui.ACCENT, 4, true)
        ui.text(c, 290, y + step / 2, line[2], 28, ui.WHITE, 4)
    end
    if o.pad then ui.hints(c, 44, 738, { { "A", "Back" }, { "Select", "Close" } }, 24) end
end

return S
