-- Track titles from the tags. The album page and the queue would otherwise
-- show file names. One short helper mpv per album (tagread.lua) reads them,
-- one album at a time, in the background, when the album is first shown;
-- they are kept in /storage/.cache/cmp next to the covers and read again
-- when the album's folder changes.

local mp = require "mp"
local utils = require "mp.utils"
local covers = require "covers"

local T = {}

local CACHE = "/storage/.cache/cmp"

local titles = {}   -- track path -> title from its tags
local seen = {}     -- album dir -> true once its tags are known or asked for
local queue, busy = {}, false
local helper_dir, on_ready = mp.get_script_directory(), nil

-- script_dir: where tagread.lua is; ready(album) is called when an album's
-- titles arrive.
function T.setup(script_dir, ready)
    helper_dir, on_ready = script_dir or helper_dir, ready
end

local function file_of(dir) return string.format("%s/%s-tags.json", CACHE, covers.key_of(dir)) end

local function take(found)
    for path, t in pairs(found) do
        if type(t) == "table" and type(t.title) == "string" and t.title ~= "" then titles[path] = t.title end
    end
end

local function run_next()
    if busy or #queue == 0 then return end
    local a = table.remove(queue, 1)
    busy = true
    local out = file_of(a.dir) .. ".new"
    os.remove(out)
    local args = { "mpv", "--no-config", "--vo=null", "--ao=null", "--vid=no", "--sid=no", "--pause", "--idle=no",
                   "--really-quiet", "--script=" .. helper_dir .. "/tagread.lua", "--script-opts=tagread-out=" .. out, "--" }
    for _, t in ipairs(a.tracks) do args[#args + 1] = t end
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
                              capture_stderr = true, args = args }, function()
        busy = false
        local f = io.open(out, "r")
        local found = f and utils.parse_json(f:read("*a") or "")
        if f then f:close() end
        os.remove(out)
        if type(found) == "table" then
            take(found)
            local keep = io.open(file_of(a.dir) .. ".tmp", "w")
            if keep then
                local ok = keep:write(utils.format_json({ mtime = (utils.file_info(a.dir) or {}).mtime, tracks = found }))
                if keep:close() and ok then os.rename(file_of(a.dir) .. ".tmp", file_of(a.dir)) end
            end
            if on_ready then on_ready(a) end
        end
        run_next()
    end)
end

-- Make sure the album's titles are known or on their way.
function T.want(a)
    if not a or not a.dir or not a.tracks or seen[a.dir] then return end
    seen[a.dir] = true
    local f = io.open(file_of(a.dir), "r")
    local data = f and utils.parse_json(f:read("*a") or "")
    if f then f:close() end
    if type(data) == "table" and type(data.tracks) == "table"
        and data.mtime == (utils.file_info(a.dir) or {}).mtime then
        take(data.tracks)
        return
    end
    queue[#queue + 1] = a
    run_next()
end

-- The title from the track's tags, or nil while unknown.
function T.title(path) return titles[path] end

-- Forget what was read, so changed folders are read again.
function T.reset() titles, seen = {}, {} end

return T
