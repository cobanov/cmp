-- The settings screen for the pad, drawn on the main screen: the same tabs and
-- rows the touch screen shows (settings.lua). Select opens it; L1/R1 switch
-- tabs, up/down pick a row, left/right change it, A runs it, B closes.
--
-- M.setup{ model = function() return snapshot end, apply = function(key, dir) end,
--          guide = "video" | "music", on_toggle = function(open) end }

local mp = require "mp"
local ui = require "ui"
local S = require "settings"

local M = { open = false }

local overlay = mp.create_osd_overlay("ass-events")
local cfg = {}
local tab, sel, guide = 1, 1, false  -- guide: false, or the page shown over the list ("guide" / "about")

function M.setup(c) cfg = c end

local function current()
    local tabs = cfg.model()
    tab = math.max(1, math.min(tab, #tabs))
    local rows = tabs[tab] and tabs[tab].rows or {}
    sel = math.max(1, math.min(sel, #rows))
    return tabs, rows
end

function M.draw()
    if not M.open then overlay:remove(); overlay.data = nil; return end
    local cv = ui.canvas()
    if guide == "about" then S.draw_about(cv, { pad = true, backdrop = 0x28 })
    elseif guide then S.draw_guide(cv, cfg.guide, { pad = true, backdrop = 0x28 })
    else S.draw(cv, (current()), { tab = tab, sel = sel, pad = true, backdrop = 0x28 }) end
    ui.show(overlay, cv)
end

local function set_open(open)
    M.open, guide = open, false
    if cfg.on_toggle then cfg.on_toggle(open) end
    M.draw()
end

function M.close() set_open(false) end
function M.toggle() set_open(not M.open) end

local function later() mp.add_timeout(0.05, M.draw) end

local function press(r, dir)
    if r.off then return end
    if r.kind == "guide" or r.kind == "about" then guide = r.kind; M.draw(); return end
    if r.kind == "action" and dir < 0 then return end
    local result = cfg.apply(r.key, dir)
    if result == "close" then M.close(); return end
    later()
    -- a row asking "Press again" goes back to normal on its own
    if r.kind == "action" then mp.add_timeout(3.1, function() if M.open then M.draw() end end) end
end

-- Returns true when the key was used by the menu.
function M.key(key)
    if not M.open then return false end
    if guide then
        if key == "a" or key == "b" then guide = false; M.draw()
        elseif key == "select" then M.close() end
        return true
    end
    local tabs, rows = current()
    local r = rows[sel]
    if (key == "l1" or key == "r1") and #tabs > 1 then
        tab = (tab - 1 + (key == "r1" and 1 or -1)) % #tabs + 1
        sel = 1
        M.draw()
    elseif key == "up" and #rows > 0 then sel = (sel - 2) % #rows + 1; M.draw()
    elseif key == "down" and #rows > 0 then sel = sel % #rows + 1; M.draw()
    elseif (key == "left" or key == "right") and r and r.kind ~= "action" and r.kind ~= "guide" and r.kind ~= "about" then
        press(r, key == "left" and -1 or 1)
    elseif key == "a" and r then press(r, 1)
    elseif key == "b" or key == "select" then M.close()
    end
    return true
end

mp.observe_property("osd-dimensions", "native", function() if M.open then M.draw() end end)

return M
