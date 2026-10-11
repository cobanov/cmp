-- The music library on the touch screen, for the background player: with a
-- game on the main screen the pad belongs to the game, so albums and tracks
-- are picked here, by touch. Two pages: the albums, then one album's tracks.
-- Both scroll with a finger and keep sliding a little when flicked.
--
-- touch.lua draws a page with L.draw and forwards the finger: L.press when
-- it lands in the list, L.move while it moves, L.release when it lifts.
-- Taps go through touch.lua's hit areas (lib-* names), see L.tap.

local mp = require "mp"
local ffi = require "ffi"
local ui = require "ui"
local covers = require "covers"

local L = { page = nil }  -- nil | "albums" | "tracks"

local TOP = 96                    -- the list starts under the header
local LIST_H = ui.H - TOP
local ALBUM_ROW, TRACK_ROW = 120, 84  -- big enough to read and to hit with a thumb
local THUMB, THUMB_X = 80, 44     -- cover-80.bgra
local TRACKS_X = 456              -- the track list, right of the album cover

local albums, album_i = {}, nil
local names = function(a) return a.title, a.artist end  -- folder name or tags (music.names)
local track_name                -- (path, album) -> the title tag or the file name (music.track_name)
local scroll = { albums = 0, tracks = 0 }
local finger, glide             -- a finger scrolling; the slide after a flick

-- Rows ------------------------------------------------------------------------
-- Each row (thumbnail, words, divider) is drawn once into its own bitmap
-- (textbmp.lua puts the words in), and the visible rows are copied into one
-- list buffer shown as one overlay. Scrolling then only copies bitmaps: no
-- text is laid out again and the whole list moves in the same frame.

local B = require "textbmp"
local bit = require "bit"

local LIST_ID = 41
local COVER_ID = 42
local list = ffi.new("int32_t[?]", ui.W * LIST_H)
local list_key
local rows = {}                 -- key -> { buf, w, h }, the rows drawn so far
local row_count = 0
local thumb_data = {}           -- path -> the file's bytes
local BLACK = bit.tobit(0xFF000000)

local function argb(bgr)        -- ui colours are ASS BGR strings
    local v = tonumber(bgr, 16)
    return bit.bor(BLACK, bit.lshift(bit.band(v, 0xFF), 16), bit.band(v, 0xFF00), bit.rshift(v, 16))
end

local function fill(buf, stride, x, y, w, h, color)
    for yy = y, y + h - 1 do
        local o = yy * stride + x
        for xx = 0, w - 1 do buf[o + xx] = color end
    end
end

local function thumb(buf, stride, path, x, y)
    local data = thumb_data[path]
    if data == nil then
        local f = io.open(path, "rb")
        data = f and f:read("*a") or false
        if f then f:close() end
        if data and #data < THUMB * THUMB * 4 then data = false end
        thumb_data[path] = data
    end
    if not data then return false end
    local src = ffi.cast("const int32_t *", data)
    for r = 0, THUMB - 1 do ffi.copy(buf + (y + r) * stride + x, src + r * THUMB, THUMB * 4) end
    return true
end

-- A row bitmap, from the cache or drawn now. lines(c) adds the ASS for the
-- words; extra(buf, w) draws pictures first.
local function row(key, w, h, divider, lines, extra)
    local r = rows[key]
    if r then return r end
    if row_count > 60 then rows, row_count = {}, 0 end  -- a long list: start over
    local buf = ffi.new("int32_t[?]", w * h)
    fill(buf, w, 0, 0, w, h, BLACK)
    if divider then fill(buf, w, divider[1], 0, divider[2], 1, argb(ui.RAISED)) end
    if extra then extra(buf, w) end
    local c = {}
    lines(c)
    B.draw(buf, w, h, w, c)
    r = { buf = buf, w = w, h = h }
    rows[key], row_count = r, row_count + 1
    return r
end

-- Copy the visible rows (each { row, y in the list }) into the list buffer
-- and show it at x.
local function show_list(x, w, visible)
    local key = { x, w }
    for _, v in ipairs(visible) do key[#key + 1] = tostring(v[1]) .. "@" .. v[2] end
    key = table.concat(key, "|")
    if key == list_key then return end
    list_key = key
    ffi.fill(list, w * LIST_H * 4)
    for _, v in ipairs(visible) do
        local r, y = v[1], v[2]
        for line = math.max(0, -y), math.min(r.h, LIST_H - y) - 1 do
            ffi.copy(list + (y + line) * w, r.buf + line * r.w, r.w * 4)
        end
    end
    mp.commandv("overlay-add", LIST_ID, x, TOP, string.format("&%d", tonumber(ffi.cast("uintptr_t", list))),
                0, "bgra", w, LIST_H, w * 4)
end

local function hide_list()
    if list_key then mp.commandv("overlay-remove", LIST_ID) end
    list_key = nil
end

local cover_shown
local function show_cover(path)
    if path == cover_shown then return end
    if path then mp.commandv("overlay-add", COVER_ID, 30, 112, path, 0, "bgra", 400, 400, 1600)
    else mp.commandv("overlay-remove", COVER_ID) end
    cover_shown = path
end

-- Pages ---------------------------------------------------------------------

local function limit(page)
    local n, h = page == "albums" and #albums or #(albums[album_i] or { tracks = {} }).tracks,
                 page == "albums" and ALBUM_ROW or TRACK_ROW
    return math.max(0, n * h - LIST_H + 16)
end

local function clamp(page)
    scroll[page] = math.max(0, math.min(limit(page), scroll[page]))
end

local function title_of(path)
    local name = path:match("([^/]+)$") or path
    return (name:gsub("%.[^.]+$", ""):gsub("^%d+%s*[%.%-_]?%s*", ""))
end

local function header(c, cv, title, sub, buttons, back)
    local x = 44
    if back then
        ui.circle(c, 74, 48, 30, ui.RAISED)
        ui.text(c, 72, 46, "‹", 40, ui.WHITE, 5, true)
        ui.hit(cv, 0, 0, 560, TOP, back)
        x = 124
    end
    ui.text(c, x, 16, ui.trim(title, 26), 34, ui.WHITE, 7, true)
    if sub then ui.text(c, x, 60, ui.trim(sub, 36), 22, ui.GREY, 7) end
    x = 992
    for i = #buttons, 1, -1 do
        local b = buttons[i]
        local w = b[3] or 112
        x = x - w
        ui.rect(c, x, 22, w, 54, 18, b[4] and ui.ACCENT or ui.RAISED)
        ui.text(c, x + w / 2, 49, b[1], 24, ui.WHITE, 5, b[4])
        ui.hit(cv, x - 8, 8, w + 16, 82, b[2])
        x = x - 16
    end
end

local function draw_albums(c, cv, st)
    local playing_dir = st and (st.album_dir or st.path and st.path:match("^(.*)/[^/]*$"))
    local visible = {}
    local s = math.floor(scroll.albums + 0.5)
    for i, a in ipairs(albums) do
        local y = (i - 1) * ALBUM_ROW - s
        if y + ALBUM_ROW > 0 and y < LIST_H then
            local playing = a.dir == playing_dir
            local thumb_path = covers.get(a, THUMB)
            local r = row(string.format("a%d%s%s", i, playing and "p" or "", thumb_path and "t" or ""), ui.W, ALBUM_ROW,
                i > 1 and { 44, 936 },
                function(l)
                    if not thumb_path then
                        ui.rect(l, THUMB_X, 20, THUMB, THUMB, 12, ui.PANEL)
                        ui.text(l, THUMB_X + THUMB / 2, 60, "♪", 34, ui.DIM, 5)
                    end
                    local title, artist = names(a)
                    ui.text(l, 148, 24, ui.trim(title, 32), 31, playing and ui.ACCENT or ui.WHITE, 7, true)
                    ui.text(l, 148, 68, ui.trim(artist, 40), 25, ui.GREY, 7)
                    ui.text(l, 980, ALBUM_ROW / 2, playing and "♪ Playing" or (#a.tracks .. " tracks"), 22,
                        playing and ui.ACCENT or ui.DIM, 6)
                end,
                function(buf, w) if thumb_path then thumb(buf, w, thumb_path, THUMB_X, 20) end end)
            visible[#visible + 1] = { r, y }
            ui.hit(cv, 0, TOP + math.max(y, 0), ui.W, ALBUM_ROW, "lib-album", i)
        end
    end
    if #albums == 0 then
        ui.text(c, 512, 360, "No music yet", 30, ui.WHITE, 5, true)
        ui.text(c, 512, 404, "Put album folders in /storage/roms/music", 22, ui.GREY, 5)
    end
    show_cover(nil)
    show_list(0, ui.W, visible)
    header(c, cv, "Library", #albums .. " albums", { { "Shuffle all", "lib-shuffle-all", 160 }, { "Done", "lib-done", 112, true } })
end

local function draw_tracks(c, cv, st)
    local a = albums[album_i]
    local cover_path = covers.get(a, 400)
    show_cover(cover_path)
    if not cover_path then
        ui.rect(c, 30, 112, 400, 400, 22, ui.PANEL)
        ui.text(c, 230, 312, "♪", 90, ui.DIM, 5)
    end
    local x0, w = TRACKS_X - 20, ui.W - (TRACKS_X - 20)
    local visible = {}
    local s = math.floor(scroll.tracks + 0.5)
    for i, path in ipairs(a.tracks) do
        local y = (i - 1) * TRACK_ROW - s
        if y + TRACK_ROW > 0 and y < LIST_H then
            local playing = st and st.path == path
            local name = track_name and track_name(path, a) or title_of(path)
            -- (the name is in the key: a title arriving from the tags draws the row again)
            local r = row(string.format("t%d.%d%s|%s", album_i, i, playing and "p" or "", name), w, TRACK_ROW,
                i > 1 and { 20, 1000 - TRACKS_X },
                function(l)
                    ui.text(l, 34, TRACK_ROW / 2, playing and "♪" or tostring(i), 24, playing and ui.ACCENT or ui.DIM, 4)
                    ui.text(l, 80, TRACK_ROW / 2, ui.trim(name, 27), 29, playing and ui.ACCENT or ui.WHITE, 4)
                end)
            visible[#visible + 1] = { r, y }
            ui.hit(cv, x0, TOP + math.max(y, 0), w, TRACK_ROW, "lib-track", i)
        end
    end
    show_list(x0, w, visible)
    -- back to the albums: the arrow and the album's name
    local title, artist = names(a)
    header(c, cv, title, artist, { { "Shuffle", "lib-shuffle-album", 128 }, { "Done", "lib-done", 112, true } }, "lib-back")
end

-- What touch.lua calls ------------------------------------------------------

function L.open(list, names_of, track_name_of)
    albums = list or {}
    if names_of then names = names_of end
    if track_name_of then track_name = track_name_of end
    L.page = "albums"
    clamp("albums")
end

function L.close()
    L.page, finger = nil, nil
    if glide then glide:kill(); glide = nil end
    hide_list()
    show_cover(nil)
    rows, row_count = {}, 0  -- free the bitmaps; the playing marks will have moved anyway
end

function L.draw(cv, st)
    local c = cv.lines
    if L.page == "tracks" and albums[album_i] then draw_tracks(c, cv, st) else draw_albums(c, cv, st) end
end

-- A tap on one of the page's hit areas. Returns "play" after starting
-- music (touch.lua then shows the player), or true when the page changed.
function L.tap(hit, action)
    local n = hit.fn
    if n == "lib-album" then
        album_i, L.page, scroll.tracks = hit.data, "tracks", 0
        return true
    elseif n == "lib-back" then
        L.page = "albums"
        return true
    elseif n == "lib-track" then
        action("play-album", album_i, hit.data)
        return "play"
    elseif n == "lib-shuffle-album" then
        action("shuffle-album", album_i)
        return "play"
    elseif n == "lib-shuffle-all" then
        action("shuffle-all")
        return "play"
    end
end

-- Scrolling -----------------------------------------------------------------

function L.in_list(y) return L.page ~= nil and y > TOP end

-- A finger landed in the list.
function L.press(y)
    if glide then glide:kill(); glide = nil end
    finger = { y0 = y, s0 = scroll[L.page], moved = false, last = { { mp.get_time(), y } } }
end

-- Returns true when the list moved (a redraw is due).
function L.move(y)
    if not finger then return false end
    if not finger.moved and math.abs(y - finger.y0) < 14 then return false end
    finger.moved = true
    scroll[L.page] = finger.s0 - (y - finger.y0)
    clamp(L.page)
    local last = finger.last
    last[#last + 1] = { mp.get_time(), y }
    if #last > 4 then table.remove(last, 1) end
    return true
end

-- The finger lifted. Returns true when it was a scroll, false for a tap.
-- redraw is called for each step of the slide after a flick.
function L.release(redraw)
    local f = finger
    finger = nil
    if not f or not f.moved then return false end
    local a, b = f.last[1], f.last[#f.last]
    local v = (b[2] - a[2]) / math.max(0.016, b[1] - a[1])  -- px/s, finger direction
    if math.abs(v) < 300 then return true end
    local page, t = L.page, mp.get_time()
    glide = mp.add_periodic_timer(1 / 50, function()
        local now = mp.get_time()
        local dt = now - t
        t = now
        scroll[page] = scroll[page] - v * dt
        v = v * math.exp(-dt * 5)
        local before = scroll[page]
        clamp(page)
        if math.abs(v) < 60 or scroll[page] ~= before or L.page ~= page then
            glide:kill(); glide = nil
        end
        redraw()
    end)
    return true
end

return L
