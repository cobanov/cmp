-- Helper for tags.lua, run in its own short-lived mpv:
--   mpv --no-config --vo=null --ao=null --vid=no --pause --idle=no
--       --script=tagread.lua --script-opts=tagread-out=FILE -- TRACK...
-- Opens each track just far enough to read its tags (paused, nothing is
-- played), then writes FILE: { [path] = { title, duration } } as JSON.

local mp = require "mp"
local utils = require "mp.utils"

local out = mp.get_opt("tagread-out")
local found = {}

mp.register_event("file-loaded", function()
    local meta = mp.get_property_native("metadata") or {}
    local title = meta.title or meta.TITLE or meta.Title
    found[mp.get_property("path")] = { title = title, duration = mp.get_property_number("duration") }
    mp.command("playlist-next force")  -- after the last one, mpv quits (--idle=no)
end)

mp.register_event("shutdown", function()
    local f = io.open(out .. ".tmp", "w")
    if not f then return end
    local ok = f:write(utils.format_json(found))
    if f:close() and ok then os.rename(out .. ".tmp", out) else os.remove(out .. ".tmp") end
end)

mp.add_timeout(60, function() mp.command("quit") end)  -- a stuck file must not keep it running
