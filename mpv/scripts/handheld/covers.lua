-- Album pictures at the pixel sizes this screen needs, made on the device
-- and kept in /storage/.cache/cmp. mpv's overlay-add cannot scale,
-- so every size is a file of its own: raw BGRA squares.
--
-- The picture comes from the album's first track, which also brings the
-- folder's cover.jpg / folder.jpg (mpv's cover-art-auto) or the picture inside
-- the file, and its tags, used when the folder is not named "Artist - Album".
-- One short helper mpv per album (grab.lua), one at a time, in the
-- background; the largest size is made there and smaller ones scaled down
-- here. Folders already holding cover-80.bgra / cover-400.bgra (made on a
-- computer by music-to-handheld) are used as they are.

local mp = require "mp"
local utils = require "mp.utils"
local ffi = require "ffi"
local bit = require "bit"

local C = {}

local CACHE = "/storage/.cache/cmp"
local BIG = 560  -- the biggest picture drawn (album page and player), in canvas units

local known = {}      -- dir .. "@" .. px -> path | false (no picture)
local info = {}       -- dir -> { album, artist, art } from the helper
local queue, busy = {}, false
local on_ready        -- called with the album when its pictures arrive
local helper_dir

-- script_dir: where grab.lua is; scale: screen pixels per canvas unit;
-- ready(album) is called when an album's pictures and tags arrive.
function C.setup(script_dir, scale, ready)
    helper_dir, C.scale, on_ready = script_dir, scale or 1, ready
    os.execute("mkdir -p " .. CACHE)
end

local function key_of(dir)  -- djb2, as hex
    local h = 5381
    for i = 1, #dir do h = (h * 33 + dir:byte(i)) % 4294967296 end
    return bit.tohex(bit.tobit(h))
end

C.key_of = key_of  -- (tags.lua names its files the same way)

local function cached(dir, px) return string.format("%s/%s-%d.bgra", CACHE, key_of(dir), px) end

-- Write a file whole or not at all: a short picture file crashes mpv.
local function put(path, data)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    local ok = f:write(data)
    ok = f:close() and ok
    if not ok then os.remove(tmp); return false end
    return os.rename(tmp, path) and true or false
end

-- Box-filter the middle square of a w x h BGRA picture to px x px.
local function shrink(src, w, h, px, dst_path)
    local s = ffi.cast("const uint8_t *", src)
    local out = ffi.new("uint8_t[?]", px * px * 4)
    local side = math.min(w, h)
    local ox, oy = math.floor((w - side) / 2), math.floor((h - side) / 2)
    local scale = side / px
    for y = 0, px - 1 do
        local y0 = oy + math.floor(y * scale)
        local y1 = math.max(y0 + 1, oy + math.floor((y + 1) * scale))
        for x = 0, px - 1 do
            local x0 = ox + math.floor(x * scale)
            local x1 = math.max(x0 + 1, ox + math.floor((x + 1) * scale))
            local b, g, r, n = 0, 0, 0, 0
            for yy = y0, y1 - 1 do
                local o = (yy * w + x0) * 4
                for _ = x0, x1 - 1 do
                    b, g, r, n = b + s[o], g + s[o + 1], r + s[o + 2], n + 1
                    o = o + 4
                end
            end
            local d = (y * px + x) * 4
            out[d], out[d + 1], out[d + 2], out[d + 3] = b / n, g / n, r / n, 255
        end
    end
    return put(dst_path, ffi.string(out, px * px * 4))
end

local function size_of(path)
    local i = path and utils.file_info(path)
    return i and i.size or -1
end

-- A picture file is used only when it is whole: mpv maps width * height * 4
-- bytes of it, and a short file (a full card, a helper cut off) crashes mpv.
local function whole(path, w, h) return size_of(path) >= w * (h or w) * 4 end

local function forget(dir)
    for k in pairs(known) do if k:sub(1, #dir + 1) == dir .. "@" then known[k] = nil end end
end

-- What the helper found for a folder, or false when it has not looked yet
-- or the folder changed since (a picture added or replaced).
local function load_info(dir)
    if info[dir] ~= nil then return info[dir] end
    local f = io.open(string.format("%s/%s.json", CACHE, key_of(dir)), "r")
    local data = f and utils.parse_json(f:read("*a") or "")
    if f then f:close() end
    if type(data) == "table" and data.mtime and data.mtime ~= (utils.file_info(dir) or {}).mtime then
        data = nil  -- changed: look again
    end
    info[dir] = type(data) == "table" and data or false
    return info[dir]
end

local function run_next()
    if busy or #queue == 0 then return end
    local job = table.remove(queue, 1)
    -- the biggest size this screen draws, even (pictures come out in yuv420)
    local a = job.album
    local big = math.max(job.px, math.floor(BIG * (C.scale or 1) / 2 + 0.5) * 2)
    if load_info(a.dir) then run_next(); return end  -- done meanwhile
    busy = true
    local prefix = string.format("%s/%s", CACHE, key_of(a.dir))
    -- a picture in the album folder wins (with disc folders, mpv would only
    -- look next to the first track); --cover-art-file takes one path as it is
    local art = {}
    for _, f in ipairs(utils.readdir(a.dir, "files") or {}) do
        local base, ext = f:lower():match("^(.+)%.(%a+)$")
        if (ext == "jpg" or ext == "jpeg" or ext == "png")
            and (base == "cover" or base == "folder" or base == "front" or base == "album" or base == "albumart") then
            art[#art + 1] = "--cover-art-file=" .. utils.join_path(a.dir, f)
            break
        end
    end
    os.remove(prefix .. "-" .. big .. ".json")
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = { "mpv", "--no-config", "--vo=null", "--ao=null", "--pause", "--really-quiet",
                 "--audio-display=embedded-first", "--cover-art-auto=exact",
                 -- setsar=1: square pixels, so the picture comes out square (a JPEG's
                 -- density can otherwise make it 561x560)
                 string.format("--vf=lavfi=[scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,setsar=1]",
                               big, big, big, big),
                 "--script=" .. helper_dir .. "/grab.lua", "--script-opts=grab-out=" .. prefix .. "-" .. big,
                 art[1] or "--cover-art-auto=exact", a.tracks[1] },
    }, function()
        busy = false
        -- the helper wrote PREFIX-BIG.bgra and then PREFIX-BIG.json
        local f = io.open(prefix .. "-" .. big .. ".json", "r")
        local data = f and utils.parse_json(f:read("*a") or "")
        if f then f:close() end
        os.remove(prefix .. "-" .. big .. ".json")
        if type(data) ~= "table" or data.timeout then
            -- cut off or too slow: no picture for now, and nothing written,
            -- so the next start tries again
            info[a.dir] = { art = false }
        else
            data.big = big  -- the size in the picture's file name; w and h are what came out
            data.mtime = (utils.file_info(a.dir) or {}).mtime
            if data.art and not whole(prefix .. "-" .. big .. ".bgra", data.w, data.h) then data.art = false end
            put(prefix .. ".json", utils.format_json(data))
            info[a.dir] = data
        end
        forget(a.dir)
        if on_ready then on_ready(a) end
        run_next()
    end)
end

-- Forget what was looked up, so a rescan notices changed folders.
function C.reset()
    known, info = {}, {}
end

-- Path of the album's picture px pixels wide, or nil while it is being made
-- (on_ready is called then) or when the album has none.
-- The radio's picture: a radio and its name on a dark tile, drawn here once
-- per size (with libass, like the rest of the screen).
function C.radio_picture(px)
    local path = string.format("%s/radio-%d.bgra", CACHE, px)
    if whole(path, px) then return path end
    local ui, B = require "ui", require "textbmp"
    local buf = ffi.new("int32_t[?]", px * px)
    local bg = bit.tobit(0xFF1C1C1E)  -- ui.PANEL
    for i = 0, px * px - 1 do buf[i] = bg end
    local lines = {}
    ui.icon_radio(lines, px / 2, px * 0.42, px * 0.46, ui.ACCENT)
    ui.text(lines, px / 2, px * 0.8, "Radio", math.floor(px * 0.12), ui.WHITE, 5, true)
    if not B.draw(buf, px, px, px, lines) then return nil end
    return put(path, ffi.string(buf, px * px * 4)) and path or nil
end

function C.get(a, px)
    if a.radio then return C.radio_picture(px) end
    local k = a.dir .. "@" .. px
    if known[k] ~= nil then return known[k] or nil end
    local path
    if px == 80 and whole(a.dir .. "/cover-80.bgra", 80) then path = a.dir .. "/cover-80.bgra"
    elseif px == 400 and whole(a.dir .. "/cover-400.bgra", 400) then path = a.dir .. "/cover-400.bgra"
    else
        local i = load_info(a.dir)
        if i == false then
            if not (a.tracks and a.tracks[1]) then return nil end
            -- never looked at (or changed): ask the helper
            local queued = false
            for _, j in ipairs(queue) do if j.album.dir == a.dir then queued = true end end
            if not queued then queue[#queue + 1] = { album = a, px = px } end
            run_next()
            return nil
        elseif i.art then
            local big = cached(a.dir, i.big or i.w)
            if not i.big and not whole(big, i.w, i.h) then big = cached(a.dir, i.h) end  -- older caches
            if whole(cached(a.dir, px), px) and px ~= (i.big or i.w) then path = cached(a.dir, px)
            elseif px == i.w and i.w == i.h and whole(big, px) then path = big
            elseif whole(big, i.w, i.h) then
                local f = io.open(big, "rb")
                local data = f and f:read("*a")
                if f then f:close() end
                local dst = cached(a.dir, px)
                if dst == big then dst = dst:gsub("%.bgra$", "s.bgra") end  -- never over the source
                if data and shrink(data, i.w, i.h, px, dst) then path = dst end
            end
        end
    end
    known[k] = path or false
    return path
end

-- Tags from the album's first track, once the helper has read them.
function C.tags(a)
    local i = load_info(a.dir)
    return i and i.album and { album = i.album, artist = i.artist } or nil
end

return C
