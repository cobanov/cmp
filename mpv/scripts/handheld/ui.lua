-- Drawing helpers: one look for every screen (pad menu, touch controls,
-- settings). Everything is laid out on a canvas 768 units tall and as wide as
-- the screen's shape (1024 on a 4:3 screen such as the RG DS Plus, 1152 on a
-- 3:2 one such as the RG34XX), so nothing is stretched; mpv scales it to the
-- screen. Pictures are placed in screen pixels: unit * ui.S.

local ui = {}

ui.W, ui.H = 1024, 768
ui.S = 1  -- screen pixels per unit

-- Fit the canvas to a window of w x h pixels. Returns true when it changed.
function ui.fit(w, h)
    if not w or not h or w <= 0 or h <= 0 then return false end
    local width, s = math.floor(ui.H * w / h + 0.5), h / ui.H
    if width == ui.W and s == ui.S then return false end
    ui.W, ui.S = width, s
    return true
end

-- A length in units as whole screen pixels.
function ui.px(v) return math.floor(v * ui.S + 0.5) end

-- ASS colours are BGR.
ui.WHITE  = "FFFFFF"
ui.GREY   = "A5A0A0"   -- secondary text
ui.DIM    = "6E6A6A"
ui.PANEL  = "1E1C1C"   -- #1C1C1E
ui.RAISED = "2E2C2C"   -- #2C2C2E
ui.TRACK  = "4A4848"   -- #48484A switch off, buttons on a highlighted row
ui.SELECT = "666363"   -- #636366 chosen tab
ui.ACCENT = "FF840A"   -- #0A84FF
ui.RED    = "3A45FF"   -- #FF453A

local K = 0.4477  -- 1 - 0.5523: bezier control offset for a quarter circle

local function rr_path(x, y, w, h, r)
    r = math.min(r, w / 2, h / 2)
    local k = r * K
    return string.format(
        "m %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d",
        x + r, y, x + w - r, y,
        x + w - k, y, x + w, y + k, x + w, y + r,
        x + w, y + h - r,
        x + w, y + h - k, x + w - k, y + h, x + w - r, y + h,
        x + r, y + h,
        x + k, y + h, x, y + h - k, x, y + h - r,
        x, y + r,
        x, y + k, x + k, y, x + r, y)
end

-- alpha: 0 opaque .. 255 invisible (ASS convention)
function ui.rect(c, x, y, w, h, r, color, alpha)
    c[#c + 1] = string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%02X&\\p1}%s{\\p0}",
        color, alpha or 0, rr_path(x, y, w, h, r or 0))
end

function ui.circle(c, cx, cy, r, color, alpha)
    ui.rect(c, cx - r, cy - r, 2 * r, 2 * r, r, color, alpha)
end

function ui.ring(c, cx, cy, r, thick, color, alpha)
    c[#c + 1] = string.format("{\\an7\\pos(0,0)\\bord%d\\shad0\\1a&HFF&\\3c&H%s&\\3a&H%02X&\\p1}%s{\\p0}",
        thick, color, alpha or 0, rr_path(cx - r, cy - r, 2 * r, 2 * r, r))
end

function ui.poly(c, color, alpha, ...)
    local pts = { ... }
    local d = { string.format("m %d %d", pts[1], pts[2]) }
    for i = 3, #pts, 2 do d[#d + 1] = string.format("l %d %d", pts[i], pts[i + 1]) end
    c[#c + 1] = string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%02X&\\p1}%s{\\p0}",
        color, alpha or 0, table.concat(d, " "))
end

-- libass has no escape for a backslash: like mpv, follow it with a word
-- joiner (U+2060) so "AC\DC" or "\N" in a name stay as written.
local function esc(s)
    return (tostring(s):gsub("\\", "\\\226\129\160"):gsub("{", "\\{"):gsub("}", "\\}"):gsub("\n", " "))
end
ui.esc = esc

-- an: ASS alignment (7 top-left, 8 top-centre, 9 top-right, 4/5/6 middle row)
function ui.text(c, x, y, s, size, color, an, bold)
    c[#c + 1] = string.format("{\\an%d\\pos(%d,%d)\\fs%d\\b%d\\bord0\\shad0\\1c&H%s&\\fnDejaVu Sans}%s",
        an or 7, x, y, size, bold and 1 or 0, color or ui.WHITE, esc(s))
end

-- How wide a string is at a font size, in canvas units: measured with libass
-- (textbmp.lua), or estimated when that cannot load (DejaVu Sans Condensed,
-- the face fontconfig picks here, averages about half the size a character).
local measure
function ui.width(s, size, bold)
    s = tostring(s)
    if measure == nil then
        local ok, B = pcall(require, "textbmp")
        measure = ok and B.measure or false
    end
    local w = measure and measure(s, math.floor(size), bold)
    if w then return w end
    local n = 0
    for _ in s:gmatch("[^\128-\191]") do n = n + 1 end
    return n * size * 0.5
end

-- The string cut (with an ellipsis) to fit `width` units at a font size.
function ui.fit_text(s, width, size, bold)
    s = tostring(s or "")
    if ui.width(s, size, bold) <= width then return s end
    local chars = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
    local lo, hi = 0, #chars  -- the longest prefix that fits, with the ellipsis
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if ui.width(table.concat(chars, "", 1, mid) .. "…", size, bold) <= width then lo = mid else hi = mid - 1 end
    end
    return table.concat(chars, "", 1, lo):gsub("%s+$", "") .. "…"
end

-- The key hints along the bottom: a small badge with the button, then what
-- it does, e.g. { {"A", "Open"}, {"B", "Back"} }.
-- Buttons always appear in this order, whatever the screen, so A and B do
-- not move about from one screen to the next.
local HINT_ORDER = { "A", "B", "X", "Y", "↑↓", "←→", "L1 R1", "L2 R2", "Select", "Start" }

function ui.hints(c, x, y, hints, size)
    size = size or 26
    local rank = {}
    for i, k in ipairs(HINT_ORDER) do rank[k] = i end
    local sorted = {}
    for i, h in ipairs(hints) do sorted[i] = { h = h, r = rank[h[1]] or 50, i = i } end
    table.sort(sorted, function(p, q) if p.r ~= q.r then return p.r < q.r end return p.i < q.i end)
    for _, item in ipairs(sorted) do
        local h = item.h
        local bw = math.max(size * 1.25, ui.width(h[1], size * 0.8) + size * 0.7)
        ui.rect(c, x, y - size * 0.62, bw, size * 1.24, size * 0.3, ui.RAISED)
        ui.text(c, x + bw / 2, y, h[1], size * 0.8, ui.WHITE, 5, true)
        x = x + bw + size * 0.35
        ui.text(c, x, y, h[2], size, ui.GREY, 4)
        x = x + ui.width(h[2], size) + size * 1.1
    end
    return x
end

-- Cut a UTF-8 string to n characters, adding an ellipsis.
function ui.trim(s, n)
    s = tostring(s or "")
    local count, cut = 0, nil
    for pos in s:gmatch("()[^\128-\191]") do
        count = count + 1
        if count == n then cut = pos end
    end
    if count <= n then return s end
    return s:sub(1, cut - 1) .. "…"
end

-- A straight stroke, as a thin polygon.
function ui.line(c, x1, y1, x2, y2, w, color, alpha)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len == 0 then return end
    local nx, ny = -dy / len * w / 2, dx / len * w / 2
    ui.poly(c, color, alpha or 0, x1 + nx, y1 + ny, x2 + nx, y2 + ny, x2 - nx, y2 - ny, x1 - nx, y1 - ny)
end

function ui.outline(c, x, y, w, h, r, thick, color, alpha)
    c[#c + 1] = string.format("{\\an7\\pos(0,0)\\bord%d\\shad0\\1a&HFF&\\3c&H%s&\\3a&H%02X&\\p1}%s{\\p0}",
        thick, color, alpha or 0, rr_path(x, y, w, h, r))
end

-- Icons, drawn as shapes so they do not depend on font coverage.

-- Two crossing arrows.
function ui.icon_shuffle(c, cx, cy, s, color)
    local w = math.max(3, s * 0.1)
    local x0, x1, x2 = cx - s * 0.55, cx - s * 0.22, cx + s * 0.3
    local top, bot = cy - s * 0.27, cy + s * 0.27
    ui.line(c, x0, top, x1, top, w, color)
    ui.line(c, x1, top, x2, bot, w, color)
    ui.line(c, x0, bot, x1, bot, w, color)
    ui.line(c, x1, bot, x2, top, w, color)
    local h = s * 0.19
    ui.poly(c, color, 0, x2 - 1, top - h * 0.8, x2 + h * 1.1, top, x2 - 1, top + h * 0.8)
    ui.poly(c, color, 0, x2 - 1, bot - h * 0.8, x2 + h * 1.1, bot, x2 - 1, bot + h * 0.8)
end

-- A loop with arrows; "one" adds a 1 inside for repeating a single track.
function ui.icon_repeat(c, cx, cy, s, color, one)
    local w, h = s * 0.95, s * 0.6
    ui.outline(c, cx - w / 2, cy - h / 2, w, h, h / 2, math.max(2, math.floor(s * 0.07)), color)
    local a = s * 0.17
    ui.poly(c, color, 0, cx + s * 0.04, cy - h / 2 - a, cx + s * 0.04 + a * 1.3, cy - h / 2, cx + s * 0.04, cy - h / 2 + a)
    ui.poly(c, color, 0, cx - s * 0.04, cy + h / 2 - a, cx - s * 0.04 - a * 1.3, cy + h / 2, cx - s * 0.04, cy + h / 2 + a)
    if one then  -- small badge at the top right, as in most players
        ui.circle(c, cx + w / 2, cy - h / 2 - 2, s * 0.2, color)
        ui.text(c, cx + w / 2, cy - h / 2 - 2, "1", math.floor(s * 0.3), "000000", 5, true)
    end
end
function ui.icon_play(c, cx, cy, s, color)
    ui.poly(c, color, 0, cx - s * 0.38, cy - s * 0.5, cx + s * 0.55, cy, cx - s * 0.38, cy + s * 0.5)
end

function ui.icon_pause(c, cx, cy, s, color)
    local w = s * 0.28
    ui.rect(c, cx - s * 0.42, cy - s * 0.5, w, s, 3, color)
    ui.rect(c, cx + s * 0.42 - w, cy - s * 0.5, w, s, 3, color)
end

function ui.icon_skip(c, cx, cy, s, color, forward)
    local d = forward and 1 or -1
    ui.poly(c, color, 0, cx - d * s * 0.45, cy - s * 0.45, cx + d * s * 0.3, cy, cx - d * s * 0.45, cy + s * 0.45)
    local bx = forward and cx + s * 0.3 or cx - s * 0.3 - s * 0.16
    ui.rect(c, bx, cy - s * 0.45, s * 0.16, s * 0.9, 2, color)
end

-- A battery w x h (the nub outside), filled to pct; green while charging,
-- red when low.
function ui.icon_battery(c, x, y, w, h, pct, charging)
    local color = charging and "58D130" or (pct <= 15 and ui.RED or ui.WHITE)  -- #30D158
    ui.outline(c, x, y, w, h, h * 0.25, 2, ui.GREY)
    ui.rect(c, x + w + 2, y + h * 0.3, 3, h * 0.4, 1, ui.GREY)
    local inner = (w - 8) * math.max(0, math.min(100, pct)) / 100
    if inner >= 1 then ui.rect(c, x + 4, y + 4, inner, h - 8, h * 0.12, color) end
end

-- A radio of width s: a body with a speaker and a dial, and an antenna.
function ui.icon_radio(c, cx, cy, s, color)
    local w, h = s, s * 0.62
    local x, y = cx - w / 2, cy - h / 2 + s * 0.08
    ui.line(c, x + w * 0.22, y, x + w * 0.62, y - s * 0.28, s * 0.04, color)
    ui.rect(c, x, y, w, h, s * 0.08, color)
    ui.circle(c, x + w * 0.32, y + h * 0.55, h * 0.3, ui.PANEL)
    ui.rect(c, x + w * 0.6, y + h * 0.22, w * 0.28, h * 0.12, 2, ui.PANEL)
    ui.rect(c, x + w * 0.6, y + h * 0.48, w * 0.28, h * 0.12, 2, ui.PANEL)
end

-- A crescent moon of radius r: a circle with a circle of the background cut out.
function ui.icon_moon(c, cx, cy, r, color, bg)
    ui.circle(c, cx, cy, r, color)
    ui.circle(c, cx + r * 0.45, cy - r * 0.35, r * 0.8, bg or "000000")
end

function ui.fmt_time(t)
    t = math.max(0, math.floor((t or 0) + 0.5))
    local h, m, s = math.floor(t / 3600), math.floor(t / 60) % 60, t % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

-- A canvas collects ASS lines and clickable regions for one frame.
function ui.canvas()
    return { lines = {}, hits = {} }
end

function ui.hit(cv, x, y, w, h, fn, data, data2)
    local h = { x = x, y = y, w = w, h = h, fn = fn, data = data, data2 = data2 }
    cv.hits[#cv.hits + 1] = h
    return h
end

function ui.find_hit(cv, x, y)
    for i = #cv.hits, 1, -1 do
        local r = cv.hits[i]
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then return r end
    end
end

function ui.show(overlay, cv)
    local data = table.concat(cv.lines, "\n")
    if data == overlay.data and overlay.res_x == ui.W and overlay.res_y == ui.H then return end  -- unchanged: spare mpv a redraw
    overlay.res_x, overlay.res_y = ui.W, ui.H
    overlay.data = data
    overlay:update()
end

return ui
