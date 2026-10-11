-- Lyrics for the player: an .lrc file next to the track (same name), or the
-- lyrics in its tags. Timed lyrics ([mm:ss.xx] lines) follow the song;
-- plain ones scroll along with it.
--
-- L.get(path) -> { lines = { { t, text } }, timed = bool } or nil
-- L.at(lyr, pos) -> the index of the line being sung (timed lyrics)

local mp = require "mp"
local utils = require "mp.utils"

local L = {}

local cache = {}   -- path -> lyrics | false
local dirs = {}    -- folder -> { lowercase name -> file name }

local function parse(text)
    local lines, offset, timed = {}, 0, false
    for raw in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local off = raw:match("^%[offset:%s*([%+%-]?%d+)%]")
        if off then offset = tonumber(off) / 1000 end
        local stamps, rest = {}, raw
        while true do
            local m, s, frac, after = rest:match("^%[(%d+):(%d+)([%.:]?%d*)%](.*)$")
            if not m then break end
            stamps[#stamps + 1] = tonumber(m) * 60 + tonumber(s) + (tonumber("0." .. frac:sub(2)) or 0)
            rest = after
        end
        if #stamps > 0 then
            timed = true
            rest = rest:gsub("<%d+:%d+[%.:]%d+>", ""):match("^%s*(.-)%s*$")  -- (word timings, enhanced LRC)
            for _, t in ipairs(stamps) do lines[#lines + 1] = { t = t, text = rest } end
        elseif not raw:match("^%[%a+:.*%]$") and not timed then
            lines[#lines + 1] = { t = 0, text = raw:match("^%s*(.-)%s*$") }  -- plain text
        end
    end
    if timed then
        local kept = {}
        for _, l in ipairs(lines) do if l.t > 0 or l.text ~= "" or #kept > 0 then kept[#kept + 1] = l end end
        lines = kept
        for _, l in ipairs(lines) do l.t = math.max(0, l.t - offset) end  -- (+offset: the words come sooner)
        table.sort(lines, function(a, b) return a.t < b.t end)
    else  -- no leading and trailing blank lines
        while lines[1] and lines[1].text == "" do table.remove(lines, 1) end
        while lines[#lines] and lines[#lines].text == "" do table.remove(lines) end
    end
    return #lines > 0 and { lines = lines, timed = timed } or nil
end

local function lrc_file(path)
    local dir, name = utils.split_path(path)
    if not dirs[dir] then
        dirs[dir] = {}
        for _, f in ipairs(utils.readdir(dir, "files") or {}) do dirs[dir][f:lower()] = f end
    end
    local base = name:gsub("%.[^.]+$", "")
    local f = dirs[dir][(base .. ".lrc"):lower()]
    return f and utils.join_path(dir, f)
end

-- The track playing also offers the lyrics in its tags.
local function tag_lyrics(path)
    if mp.get_property("path") ~= path then return nil end
    local meta = mp.get_property_native("metadata") or {}
    for k, v in pairs(meta) do
        local key = k:lower()
        if (key == "lyrics" or key:match("^lyrics%-") or key == "unsyncedlyrics" or key:match("^uslt")) and type(v) == "string" then
            return v
        end
    end
    return nil
end

function L.get(path)
    if not path or path:match("^%a+://") then return nil end
    if cache[path] ~= nil then return cache[path] or nil end
    local text
    local file = lrc_file(path)
    if file then
        local f = io.open(file, "r")
        text = f and f:read("*a")
        if f then f:close() end
        if text then text = text:gsub("^\239\187\191", "") end  -- (a UTF-8 byte order mark)
    end
    text = text or tag_lyrics(path)
    if not text and mp.get_property("path") ~= path then return nil end  -- (tags: ask again once it plays)
    cache[path] = text and parse(text) or false
    return cache[path] or nil
end

function L.at(lyr, pos)
    local lo, hi = 1, #lyr.lines
    if pos < lyr.lines[1].t then return 0 end
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if lyr.lines[mid].t <= pos then lo = mid else hi = mid - 1 end
    end
    return lo
end

-- When the next line starts, for a redraw then (nil: no more lines).
function L.next_time(lyr, pos)
    local i = L.at(lyr, pos) + 1
    return lyr.lines[i] and lyr.lines[i].t or nil
end

function L.forget(dir) if dir then dirs[dir] = nil else dirs, cache = {}, {} end end

return L
