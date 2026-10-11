-- A long title in the player scrolls once when the track starts, then rests
-- with its "…" (lists keep their "…" from the start). Only once, and only
-- there: every step redraws the whole screen in software, about 40% of an
-- H700 core while it moves, which the battery should not pay for long.
--
-- In a page's draw: K.begin(), then K.line(...) for each line that may
-- scroll (it draws the ones that fit into the page's canvas), then
-- K.finish(). K.clear() hides them (a menu over the page, the screen off).

local mp = require "mp"
local ui = require "ui"

local K = {}

local overlay = mp.create_osd_overlay("ass-events")
overlay.z = 10  -- over the page

local SPEED, PAUSE, GAP, FPS = 80, 1.5, 96, 12  -- units/s; s still at the start; units before it comes round again
local PASSES = 1

local lines, key, start, timer, last = {}, nil, 0, nil, nil

function K.begin() lines = {} end

-- One line at x,y, at most w wide, an 7 (top-left) or 4 (middle-left).
function K.line(c, x, y, w, text, size, color, an, bold)
    text = tostring(text or "")
    local tw = ui.width(text, size, bold)
    if tw <= w then
        ui.text(c, x, y, text, size, color, an, bold)
        return
    end
    lines[#lines + 1] = { x = x, y = y, w = w, text = text, tw = tw, size = size, color = color, an = an or 7, bold = bold }
end

local function render()
    local t = mp.get_time() - start
    local out, moving = {}, false
    for _, l in ipairs(lines) do
        -- rest at the start, then once round; each line on its own clock
        local loop = l.tw + GAP
        local period = PAUSE + loop / SPEED
        local top = l.an == 4 and l.y - l.size or l.y - l.size * 0.2
        local clip = string.format("\\clip(%d,%d,%d,%d)", l.x, top, l.x + l.w, top + l.size * 2)
        local copies, text = { 0, loop }, l.text
        if t >= PASSES * period - PAUSE then  -- done: at rest, cut short
            l.short = l.short or ui.fit_text(l.text, l.w, l.size, l.bold)
            copies, text = { 0 }, l.short
        else
            moving = true
            local off = math.max(0, t % period - PAUSE) * SPEED
            copies = { -off, loop - off }
        end
        for _, dx in ipairs(copies) do
            out[#out + 1] = string.format("{\\an%d\\pos(%d,%d)%s\\fs%d\\b%d\\bord0\\shad0\\1c&H%s&\\fnDejaVu Sans}%s",
                l.an, l.x + dx, l.y, clip, l.size, l.bold and 1 or 0, l.color or ui.WHITE, ui.esc(text))
        end
    end
    if not moving and timer then timer:kill(); timer = nil end
    local data = table.concat(out, "\n")
    if data == last and overlay.res_x == ui.W then return end
    last = data
    overlay.res_x, overlay.res_y, overlay.data = ui.W, ui.H, data
    overlay:update()
end

function K.clear()
    lines = {}
    if timer then timer:kill(); timer = nil end
    key, last = nil, nil
    overlay:remove()
end

function K.finish()
    if #lines == 0 then K.clear(); return end
    -- the same lines as before keep scrolling where they were; new ones start over
    local k = {}
    for _, l in ipairs(lines) do k[#k + 1] = string.format("%d,%d|%s", l.x, l.y, l.text) end
    k = table.concat(k, "\n")
    if k ~= key then
        key, start = k, mp.get_time()
        if not timer then timer = mp.add_periodic_timer(1 / FPS, render) end
    end
    render()
end

return K
