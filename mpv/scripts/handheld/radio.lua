-- Internet radio: the stations in radio.m3u in the music folder, played like
-- an album whose tracks are the stations (L1/R1 change station). The file
-- is made with a few long-lived stations the first time and can be edited
-- over the network share (#EXTINF:-1,Name then the address, per station).

local utils = require "mp.utils"

local R = {}

local DEFAULTS = {
    { "Radio Paradise", "https://stream.radioparadise.com/mp3-192" },
    { "Radio Paradise Mellow", "https://stream.radioparadise.com/mellow-192" },
    { "SomaFM Groove Salad", "https://ice2.somafm.com/groovesalad-128-mp3" },
    { "SomaFM Drone Zone", "https://ice2.somafm.com/dronezone-128-mp3" },
    { "KEXP Seattle", "https://kexp-mp3-128.streamguys1.com/kexp128.mp3" },
    { "FIP Paris", "https://icecast.radiofrance.fr/fip-midfi.mp3" },
}

local file
local names = {}  -- address -> station name

function R.setup(music_root) file = music_root .. "/radio.m3u" end

function R.is_stream(path) return type(path) == "string" and path:match("^%a[%w+.-]*://") ~= nil end

local function write_defaults()
    local f = io.open(file, "w")
    if not f then return end
    f:write("#EXTM3U\n")
    for _, s in ipairs(DEFAULTS) do f:write(string.format("#EXTINF:-1,%s\n%s\n", s[1], s[2])) end
    f:close()
end

-- The stations: { { name, url } }, read again each time (the file may have changed).
function R.stations()
    if not utils.file_info(file) then write_defaults() end
    local list, name = {}, nil
    local f = io.open(file, "r")
    if not f then return list end
    for line in f:lines() do
        line = line:gsub("^\239\187\191", ""):match("^%s*(.-)%s*$")
        local title = line:match("^#EXTINF:[^,]*,(.*)$")
        if title then name = title
        elseif line ~= "" and not line:match("^#") and R.is_stream(line) then
            list[#list + 1] = { name = name or line:match("^%a+://([^/:]+)") or line, url = line }
            names[line] = list[#list].name
            name = nil
        end
    end
    f:close()
    return list
end

function R.name(url)
    if not names[url] then R.stations() end
    return names[url] or url:match("^%a+://([^/:]+)") or url
end

-- The stations as an album, for the album page and the player.
function R.album()
    local tracks = {}
    for i, s in ipairs(R.stations()) do tracks[i] = s.url end
    return { dir = "radio:", title = "Radio", artist = "Internet radio", named = true, radio = true, tracks = tracks }
end

return R
