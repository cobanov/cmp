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

local function exists(p)
    local f = p and io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

local function key_of(dir)  -- djb2, as hex
    local h = 5381
    for i = 1, #dir do h = (h * 33 + dir:byte(i)) % 4294967296 end
    return bit.tohex(bit.tobit(h))
end

local function cached(dir, px) return string.format("%s/%s-%d.bgra", CACHE, key_of(dir), px) end

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
    local f = io.open(dst_path, "wb")
    if f then f:write(ffi.string(out, px * px * 4)); f:close() end
end

local function load_info(dir)
    if info[dir] ~= nil then return info[dir] end
    local f = io.open(string.format("%s/%s.json", CACHE, key_of(dir)), "r")
    local data = f and utils.parse_json(f:read("*a") or "")
    if f then f:close() end
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
    -- look next to the first track)
    local art = {}
    for _, f in ipairs(utils.readdir(a.dir, "files") or {}) do
        local base, ext = f:lower():match("^(.+)%.(%a+)$")
        if (ext == "jpg" or ext == "jpeg" or ext == "png")
            and (base == "cover" or base == "folder" or base == "front" or base == "album" or base == "albumart") then
            art[#art + 1] = "--cover-art-files=" .. utils.join_path(a.dir, f)
            break
        end
    end
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = { "mpv", "--no-config", "--vo=null", "--ao=null", "--pause", "--really-quiet",
                 "--audio-display=embedded-first", "--cover-art-auto=exact",
                 string.format("--vf=lavfi=[scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d]", big, big, big, big),
                 "--script=" .. helper_dir .. "/grab.lua", "--script-opts=grab-out=" .. prefix .. "-" .. big,
                 art[1] or "--cover-art-auto=exact", a.tracks[1] },
    }, function()
        busy = false
        -- the helper wrote PREFIX-BIG.bgra and PREFIX-BIG.json
        local f = io.open(prefix .. "-" .. big .. ".json", "r")
        local data = f and utils.parse_json(f:read("*a") or "")
        if f then f:close() end
        if type(data) ~= "table" then data = { art = false } end
        data.big = big  -- the size in the picture's file name; w and h are what came out
        local out = io.open(prefix .. ".json", "w")
        if out then out:write(utils.format_json(data)); out:close() end
        os.remove(prefix .. "-" .. big .. ".json")
        info[a.dir] = data
        for k in pairs(known) do if k:sub(1, #a.dir + 1) == a.dir .. "@" then known[k] = nil end end
        if on_ready then on_ready(a) end
        run_next()
    end)
end

-- Path of the album's picture px pixels wide, or nil while it is being made
-- (on_ready is called then) or when the album has none.
function C.get(a, px)
    local k = a.dir .. "@" .. px
    if known[k] ~= nil then return known[k] or nil end
    local path
    if px == 80 and exists(a.dir .. "/cover-80.bgra") then path = a.dir .. "/cover-80.bgra"
    elseif px == 400 and exists(a.dir .. "/cover-400.bgra") then path = a.dir .. "/cover-400.bgra"
    elseif exists(cached(a.dir, px)) then path = cached(a.dir, px)
    else
        local i = load_info(a.dir)
        if i and i.art then
            -- the file is named after the size asked for (older caches: after w or h)
            local f = io.open(cached(a.dir, i.big or i.w), "rb") or (not i.big and io.open(cached(a.dir, i.h), "rb"))
            if f and not i.big then
                i.big = exists(cached(a.dir, i.w)) and i.w or i.h
            end
            if f then
                local data = f:read("*a")
                f:close()
                if px == i.w and i.w == i.h then path = cached(a.dir, i.big)
                elseif #data >= i.w * i.h * 4 then shrink(data, i.w, i.h, px, cached(a.dir, px)); path = cached(a.dir, px) end
            end
        elseif i == false and a.tracks and a.tracks[1] then
            -- never looked at: ask the helper
            local queued = false
            for _, j in ipairs(queue) do if j.album.dir == a.dir then queued = true end end
            if not queued then queue[#queue + 1] = { album = a, px = px } end
            run_next()
            return nil
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
