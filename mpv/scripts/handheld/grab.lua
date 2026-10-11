-- Helper for covers.lua, run in its own short-lived mpv:
--   mpv --no-config --vo=null --ao=null --pause --audio-display=embedded-first
--       --vf=lavfi=[scale=...,crop=...] --script=grab.lua
--       --script-opts=grab-out=PREFIX FILE
-- FILE is a picture or a track with a picture in it. Writes PREFIX.bgra (the
-- picture, w*4 bytes a row, what mpv's overlay-add reads) and PREFIX.json
-- (its size and the file's tags), then quits. ROCKNIX's ffmpeg has no raw
-- output, so the frame comes out through mpv's screenshot-raw.

local mp = require "mp"
local utils = require "mp.utils"

local out = mp.get_opt("grab-out")
local done = false

local function finish(info)
    if done then return end
    done = true
    local f = io.open(out .. ".json", "w")
    if f then f:write(utils.format_json(info)); f:close() end
    mp.command("quit")
end

local function grab()
    local meta = mp.get_property_native("metadata") or {}
    local function tag(k) return meta[k] or meta[k:upper()] or meta[k:sub(1, 1):upper() .. k:sub(2)] end
    local info = { album = tag("album"), artist = tag("album_artist") or tag("artist"), art = false }
    local r = mp.get_property_native("vid") and mp.command_native({ name = "screenshot-raw", flags = "video", format = "bgra" })
    if r and r.data and r.w > 0 then
        local f = io.open(out .. ".bgra", "wb")
        if f then
            if r.stride == r.w * 4 then f:write(r.data)
            else for y = 0, r.h - 1 do f:write(r.data:sub(y * r.stride + 1, y * r.stride + r.w * 4)) end end
            f:close()
            info.art, info.w, info.h = true, r.w, r.h
        end
    end
    finish(info)
end

mp.register_event("playback-restart", function() mp.add_timeout(0.05, grab) end)
mp.register_event("end-file", function() finish({ art = false }) end)
mp.add_timeout(8, function() finish({ timeout = true }) end)  -- too slow: covers.lua tries again later
