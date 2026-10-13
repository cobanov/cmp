-- The battery, for the clock and battery at the top of the pages (the music
-- player's screens and the touch remote): { pct, charging } or nil, read at
-- most every 30 s.
local mp = require "mp"
local utils = require "mp.utils"

local B = {}
local dir, last, read_at = nil, nil, -100

local function get(name)
    local f = io.open(dir .. "/" .. name, "r")
    local v = f and f:read("*l")
    if f then f:close() end
    return v
end

function B.read()
    if mp.get_time() - read_at < 30 then return last end
    read_at = mp.get_time()
    if dir == nil then
        dir = false
        for _, d in ipairs(utils.readdir("/sys/class/power_supply", "dirs") or {}) do
            local f = io.open("/sys/class/power_supply/" .. d .. "/type", "r")
            local kind = f and f:read("*l")
            if f then f:close() end
            if kind == "Battery" then dir = "/sys/class/power_supply/" .. d; break end
        end
    end
    if not dir then return nil end
    -- ROCKNIX's batteryplus (on by default) estimates the level from the
    -- voltage, which is what EmulationStation shows; the fuel gauge's own
    -- figure is used only without it
    local f = io.open("/tmp/battery.percent", "r")
    local pct = f and tonumber(f:read("*l"))
    if f then f:close() end
    pct = pct or tonumber(get("capacity"))
    local state = get("status")
    last = pct and { pct = pct, charging = state == "Charging" or state == "Full" } or nil
    return last
end

return B
