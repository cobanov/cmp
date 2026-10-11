-- The options panel: Y on any page of the music player opens a short list of
-- what can be done there (search, queue, screen off), at the right of the
-- screen, clear of the album covers at the left. Up/down pick, A runs, B or
-- Y closes.
--
-- O.show(title, items) with items { label, run = function() end, danger }
-- (run may return a note to show, such as "Added to the queue").

local ui = require "ui"

local O = { open = false }

local title, items, sel = "", {}, 1

function O.show(t, list)
    title, items, sel, O.open = t or "", list or {}, 1, #(list or {}) > 0
end

function O.close() O.open = false end

local WIDTH, ROW_H, TOP = 520, 72, 96

-- The panel over the right of the page, with its own key hints.
function O.draw(c)
    local x = ui.W - WIDTH
    ui.rect(c, 0, 0, ui.W, ui.H, 0, "000000", 0x70)  -- the page behind, dimmed
    ui.rect(c, x, 0, WIDTH, ui.H, 0, ui.PANEL)
    ui.text(c, x + 36, 28, ui.fit_text(title, WIDTH - 72, 30, true), 30, ui.GREY, 7, true)
    for i, item in ipairs(items) do
        local y = TOP + (i - 1) * ROW_H
        if i == sel then ui.rect(c, x + 16, y, WIDTH - 32, ROW_H - 8, 16, ui.RAISED) end
        ui.text(c, x + 36, y + (ROW_H - 8) / 2, ui.fit_text(item.label, WIDTH - 72, 34), 34,
            item.danger and ui.RED or ui.WHITE, 4)
    end
    ui.hints(c, x + 36, 726, { { "A", "Choose" }, { "B", "Close" }, { "↑↓", "Move" } }, 26)
end

-- Returns true when the key was the panel's, and the note an item gave.
function O.key(key)
    if not O.open then return false end
    if key == "up" then sel = (sel - 2) % #items + 1
    elseif key == "down" then sel = sel % #items + 1
    elseif key == "a" then
        local item = items[sel]
        O.open = false
        return true, item and item.run and item.run()
    elseif key == "b" or key == "y" then O.open = false
    end
    return true
end

return O
