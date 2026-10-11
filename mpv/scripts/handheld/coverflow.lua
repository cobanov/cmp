-- Cover Flow for the music browser: the chosen album faces you, its
-- neighbours stand turned on either side, every cover with a reflection.
--
-- mpv cannot scale or tilt pictures, so the whole strip is drawn here, in one
-- BGRA buffer, with LuaJIT FFI, and handed to mpv as one overlay (mpv copies
-- it). One overlay per frame means no half-updated frames, and the covers can
-- move smoothly between places.
--
-- Covers are the albums' cover-400.bgra squares. Each one is kept column by
-- column, with two horizontally halved, shaded copies for covers seen from
-- the side, and its reflection under every column, so drawing a cover that
-- stands still is one copy per pixel. Columns hidden behind nearer covers are
-- skipped.

local ffi = require "ffi"
local bit = require "bit"
local band, bor, rshift, tobit = bit.band, bit.bor, bit.rshift, bit.tobit
local floor, ceil, min, max, abs = math.floor, math.ceil, math.min, math.max, math.abs

local F = {}
F.COVER, F.TOP = 400, 44  -- the facing cover's size and the strip's top, in canvas units

-- The strip is laid out in canvas units (ui.lua) and drawn in screen pixels:
-- F.setup works the sizes out for the screen (on the RG DS Plus 1 unit is 1
-- pixel, on a 720x480 screen 0.625).
local SRC, RH, CH              -- a cover's pixels across; reflection rows; a stored column
local W, H, STRIDE             -- the strip in pixels; its row length in memory
local MID, CX, SIZE            -- the eye line; the middle; the facing cover's size
local SIDE_W, SIDE_OUT, SIDE_IN -- a turned cover: width, outer and inner edge
local FIRST, GAP               -- the first turned cover's centre from the middle, then the step
local REFL, REACH
local SIDE_SHADE = 0.6         -- turned covers sit in shade
local SLIDE = 0.22             -- seconds from one album to the next
local OVERLAY = 50
local CACHE = 13               -- covers kept (1.5 MB each at full size): the 9 on screen and the next ones

-- Pixels are int32, the type LuaJIT's bit operations return, so they go in
-- and out of the arrays as they are.
local PIXELS = "int32_t[?]"
local strip
local cache, used, clock, placeholder = {}, {}, 0, nil

-- Pixels --------------------------------------------------------------------
-- Premultiplied BGRA, 0xAARRGGBB in an int32. f and a are 0..256.

local function shade(p, f)
    return bor(band(rshift(band(p, 0xFF00FF) * f, 8), 0xFF00FF),
               band(rshift(band(p, 0xFF00) * f, 8), 0xFF00), 0xFF000000)
end

local function blend(s, d, a)
    local na = 256 - a
    local rb = band(rshift(band(s, 0xFF00FF) * a + band(d, 0xFF00FF) * na, 8), 0xFF00FF)
    local ag = band(band(rshift(s, 8), 0xFF00FF) * a + band(rshift(d, 8), 0xFF00FF) * na, 0xFF00FF00)
    return bor(rb, ag)
end

local function average(p, q)
    return tobit(rshift(band(p, 0xFEFEFEFE), 1) + rshift(band(q, 0xFEFEFEFE), 1))
end

-- Covers --------------------------------------------------------------------

-- levels[0..2]: SRC, SRC/2 and SRC/4 columns of CH pixels each; 1 and 2 are
-- for turned covers, so they come shaded
local function prepare(rows)  -- rows: SRC*SRC row-major pixels
    local pix = ffi.new(PIXELS, (SRC + SRC / 2 + SRC / 4) * CH)
    local l0, l1, l2 = pix, pix + SRC * CH, pix + (SRC + SRC / 2) * CH
    for c = 0, SRC - 1 do
        local col = l0 + c * CH
        for r = 0, SRC - 1 do col[r] = bor(rows[r * SRC + c], 0xFF000000) end
    end
    for _, lv in ipairs({ { l0, l1, SRC / 2 }, { l1, l2, SRC / 4 } }) do
        local from, to, n = lv[1], lv[2], lv[3]
        for c = 0, n - 1 do
            local a, b, o = from + 2 * c * CH, from + (2 * c + 1) * CH, to + c * CH
            for r = 0, SRC - 1 do o[r] = average(a[r], b[r]) end
        end
    end
    local f = floor(SIDE_SHADE * 256 + 0.5)
    for i = 0, (SRC / 2 + SRC / 4) * CH - 1 do l1[i] = shade(l1[i], f) end
    -- the reflection: the bottom of the cover mirrored, fading out
    local fade = {}
    for k = 0, RH - 1 do fade[k] = floor(256 * 0.3 * (1 - k / RH) ^ 2 + 0.5) end
    for _, lv in ipairs({ { l0, SRC }, { l1, SRC / 2 }, { l2, SRC / 4 } }) do
        for c = 0, lv[2] - 1 do
            local col = lv[1] + c * CH
            for k = 0, RH - 1 do col[SRC + k] = shade(col[SRC - 1 - k], fade[k]) end
        end
    end
    return { pix = pix, [0] = l0, l1, l2 }
end

local function load(path)
    local f = path and io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    if #data < SRC * SRC * 4 then return nil end
    local rows = ffi.new(PIXELS, SRC * SRC)
    ffi.copy(rows, data, SRC * SRC * 4)
    return prepare(rows)
end

-- Albums without a picture: a dark tile with two beamed notes.
local function blank()
    local rows = ffi.new(PIXELS, SRC * SRC)
    local k = SRC / 400  -- the shapes are drawn for 400 pixels
    local function inside(x, y)
        x, y = x / k, y / k
        local function head(cx, cy) local dx, dy = (x - cx) / 40, (y - cy) / 30; return dx * dx + dy * dy <= 1 end
        if head(165, 285) or head(275, 265) then return true end
        if x >= 193 and x <= 205 and y >= 120 and y <= 285 then return true end
        if x >= 303 and x <= 315 and y >= 100 and y <= 265 then return true end
        local by = 120 - (x - 193) * 20 / 122  -- the beam, from one stem to the other
        return x >= 193 and x <= 315 and y >= by and y <= by + 26
    end
    for y = 0, SRC - 1 do
        local g = floor(0x3A - (0x3A - 0x1E) * y / SRC)
        local bg, note = tobit(0xFF000000 + g * 0x10101), tobit(0xFF6E6A6A)
        for x = 0, SRC - 1 do rows[y * SRC + x] = inside(x, y) and note or bg end
    end
    return prepare(rows)
end


local function cover(album)
    local key = F.picture and F.picture(album, SRC) or album.cover
    if not key then
        placeholder = placeholder or blank()
        return placeholder
    end
    clock = clock + 1
    used[key] = clock
    if cache[key] == nil then
        local n = 0
        for _ in pairs(cache) do n = n + 1 end
        if n >= CACHE then
            local oldest
            for k in pairs(cache) do if not oldest or used[k] < used[oldest] then oldest = k end end
            cache[oldest], used[oldest] = nil, nil
            used[key] = clock
        end
        cache[key] = load(key) or false
    end
    if cache[key] then return cache[key] end
    placeholder = placeholder or blank()
    return placeholder
end

-- Drawing -------------------------------------------------------------------

-- A pixel only partly covered (a cover's top and bottom edge, its first and
-- last column): mix it with what is under it.
local function mix(o, p, f, a)
    if f < 256 then p = shade(p, f) end
    if a < 256 then p = blend(p, strip[o], a) end
    strip[o] = p
end

-- Copy rows ya..yb of one strip column from a picture column, starting at
-- picture row v0 and stepping `step` rows per strip row. The hot loop: fixed
-- point and a pointer per column (LuaJIT on the RK3566 manages about 12 ns a
-- pixel this way, against 50 with a float row counter).
local function run(x, src, n, ya, yb, v0, step, f7, f, a)
    if yb < ya then return end
    local v, dv = tobit(max(0, floor(v0 * 65536))), tobit(floor(step * 65536))
    while yb >= ya and rshift(v + (yb - ya) * dv, 16) >= n do yb = yb - 1 end
    local d = strip + x
    if a < 256 then
        for y = ya, yb do mix(y * STRIDE + x, src[rshift(v, 16)], f, a); v = v + dv end
    elseif f7 < 128 then
        for y = ya, yb do
            local p = src[rshift(v, 16)]
            d[y * STRIDE] = bor(band(rshift(band(p, 0xFF00FF) * f7, 7), 0xFF00FF),
                                band(rshift(band(p, 0xFF00) * f7, 7), 0xFF00), 0xFF000000)
            v = v + dv
        end
    else
        for y = ya, yb do d[y * STRIDE] = src[rshift(v, 16)]; v = v + dv end
    end
end

-- One column of a cover: its reflection under it, then the cover from y0 to
-- y1 (strip rows, fractional). f shades it (256: as it is), a is how much of
-- the column the cover covers (256: all of it).
local function column(x, col, y0, y1, f, a)
    local h = y1 - y0
    local f7 = rshift(f, 1)
    -- reflection, from the cover's bottom row down
    local rh = h * REFL
    local ya = max(0, floor(y1))
    run(x, col + SRC, RH, ya, min(H - 1, ceil(y1 + rh) - 1), (ya + 0.5 - y1) * RH / rh, RH / rh, f7, f, a)
    -- the cover: the rows it covers fully, then the partly covered top and bottom
    local top, bottom = ceil(y0), floor(y1)
    ya = max(0, top)
    run(x, col, SRC, ya, min(H - 1, bottom - 1), (ya + 0.5 - y0) * SRC / h, SRC / h, f7, f, a)
    if top > y0 and top >= 1 then mix((top - 1) * STRIDE + x, col[0], f, floor(a * (top - y0))) end
    if y1 > bottom and bottom < H then mix(bottom * STRIDE + x, col[SRC - 1], f, floor(a * (y1 - bottom))) end
end

-- Where a cover stands when it is p places from the middle (fractional while
-- moving): left and right edge x, their heights, how far it has turned.
local function place(p)
    local d = abs(p)
    local t = min(d, 1)
    local cx = CX + (p < 0 and -1 or 1) * (d <= 1 and FIRST * t or FIRST + (d - 1) * GAP)
    local w = SIZE + (SIDE_W - SIZE) * t
    local outer, inner = SIZE + (SIDE_OUT - SIZE) * t, SIZE + (SIDE_IN - SIZE) * t
    -- left of the middle the outer edge is the left one
    if p > 0 then return cx - w / 2, cx + w / 2, inner, outer, t end
    return cx - w / 2, cx + w / 2, outer, inner, t
end

local function height_at(q, x)  -- q: a placed cover; x: a column centre
    local t = (x - q.xa) / (q.xb - q.xa)
    return q.ha + (q.hb - q.ha) * t
end

-- Is column x of cover q wholly behind one of the covers drawn after it?
local function hidden(q, x, h, nearer)
    for _, n in ipairs(nearer) do
        if n.xa <= x and x + 1 <= n.xb and height_at(n, x + 0.5) >= h then return true end
    end
    return false
end

local function draw_cover(q, nearer)
    local xa, xb, ha, hb = q.xa, q.xb, q.ha, q.hb
    -- standing still: the plain or the turned (shaded, narrower) copy;
    -- turning: the full copy, shaded as it turns
    local level, f = 0, 256
    if q.t >= 1 then level = SRC / (xb - xa) < 3.2 and 1 or 2
    elseif q.t > 0 then f = floor((1 + (SIDE_SHADE - 1) * q.t) * 256 + 0.5) end
    local lw, cols = SRC / 2 ^ level, q.cover[level]
    for x = max(0, floor(xa)), min(W - 1, ceil(xb) - 1) do
        local t = (x + 0.5 - xa) / (xb - xa)
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local h = ha + (hb - ha) * t
        if not hidden(q, x, h, nearer) then
            -- perspective: across the cover, depth goes as 1/height
            local u = min(floor(t * hb / ((1 - t) * ha + t * hb) * lw), lw - 1)
            local a = floor((min(x + 1, xb) - max(x, xa)) * 256 + 0.5)
            column(x, cols + u * CH, MID - h / 2, MID + h / 2, f, a)
        end
    end
end

function F.render(albums, pos)
    ffi.fill(strip, STRIDE * H * 4)
    local placed = {}
    for i = max(1, floor(pos - REACH)), min(#albums, ceil(pos + REACH)) do
        local p = i - pos
        if abs(p) <= REACH then
            local xa, xb, ha, hb, t = place(p)
            placed[#placed + 1] = { cover = cover(albums[i]), d = abs(p), xa = xa, xb = xb, ha = ha, hb = hb, t = t }
        end
    end
    -- farthest first, so nearer covers lie on top
    table.sort(placed, function(a, b) return a.d > b.d end)
    for i, q in ipairs(placed) do
        local nearer = {}
        for j = i + 1, #placed do
            local n = placed[j]
            if n.xb > q.xa and n.xa < q.xb then nearer[#nearer + 1] = n end
        end
        draw_cover(q, nearer)
    end
    return strip
end

-- Showing and moving --------------------------------------------------------

local mp
local albums, pos, target = {}, 1, 1
local from, start, timer
F.shown = false

local function show()
    mp.commandv("overlay-add", OVERLAY, F.X, F.Y, string.format("&%d", tonumber(ffi.cast("uintptr_t", strip))),
                0, "bgra", W, H, STRIDE * 4)
end

-- After a move, read the covers that come into view next, one per tick, so
-- the next step does not stop to load them.
local function preload()
    for d = 5, 6 do
        for _, i in ipairs({ target + d, target - d }) do
            local a = albums[i]
            if a and a.cover and cache[a.cover] == nil then
                cover(a)
                if F.shown and not timer then mp.add_timeout(0.05, preload) end
                return
            end
        end
    end
end

local function frame()
    local t = (mp.get_time() - start) / SLIDE
    if t >= 1 then
        pos = target
        if timer then timer:kill(); timer = nil end
        mp.add_timeout(0.1, preload)
    else
        local e = 1 - (1 - t) ^ 3   -- ease out
        pos = from + (target - from) * e
    end
    F.render(albums, pos)
    show()
end

-- Work the sizes out for the screen (ui.W, ui.S); call again when it changes.
function F.setup()
    local ui = require "ui"
    local k = F.COVER / 400  -- the layout below is drawn for a 400-unit cover
    local function px(v) return ui.px(v * k) end
    SRC = math.max(64, math.floor(px(400) / 4) * 4)  -- halved twice for turned covers
    RH = math.floor(SRC * 0.3)
    CH = SRC + RH
    REFL = RH / SRC
    W, H = ui.px(ui.W), px(400) + RH + ui.px(8)
    -- Covers are drawn column by column. With rows exactly 4 KiB apart a
    -- column's pixels all land in the same few cache sets and every write
    -- stalls; a slightly longer row spreads them out (three times faster on
    -- the RK3566).
    STRIDE = W + 16
    MID, CX, SIZE = px(200), W / 2, SRC
    SIDE_W, SIDE_OUT, SIDE_IN = px(130), px(368), px(248)
    FIRST, GAP = px(255), px(70)
    REACH = (CX - FIRST) / GAP + 1.6  -- wider screens show more turned covers
    F.X, F.Y, F.W, F.H, F.STRIDE = 0, ui.px(F.TOP), W, H, STRIDE
    strip = ffi.new(PIXELS, STRIDE * H)
    cache, used, clock, placeholder = {}, {}, 0, nil
end

-- Draw again with the same albums (a picture arrived).
function F.refresh()
    if F.shown and mp then F.render(albums, pos); show() end
end

-- Show the strip with album `index` in the middle. Moves there smoothly when
-- it is already showing, starting from wherever it is now.
function F.go(list, index)
    mp = mp or require "mp"
    if not strip then F.setup() end
    local same = list == albums
    albums, target = list, index
    if not F.shown or not same or abs(index - pos) > 8 then
        pos, F.shown = index, true
        if timer then timer:kill(); timer = nil end
        F.render(albums, pos)
        show()
        mp.add_timeout(0.1, preload)
        return
    end
    if pos == index and not timer then return end
    from, start = pos, mp.get_time()
    if not timer then timer = mp.add_periodic_timer(1 / 60, frame) end
end

function F.hide()
    if not F.shown then return end
    F.shown = false
    if timer then timer:kill(); timer = nil end
    mp.commandv("overlay-remove", OVERLAY)
end

return F
