-- Search the library from the pad: a keyboard at the left, what matches at
-- the right, updated with every letter. Albums (by title or artist) come
-- first, then songs. Typing is forgiving: case, accents and Turkish letters
-- do not matter ("kotu" finds "Kötü"), and every word typed must appear.
--
-- Q.setup{ albums = fn() -> list, names = fn(a) -> title, artist,
--          track_name = fn(path) -> name }
-- Q.draw(c, header, footer) draws the page; Q.key(key) returns what to do:
--   { album = a }               open the album
--   { album = a, track = i }    play the album from track i
--   "close"                     leave the search

local ui = require "ui"

local Q = { query = "" }

local KEYS = {
    { "A", "B", "C", "D", "E", "F" }, { "G", "H", "I", "J", "K", "L" }, { "M", "N", "O", "P", "Q", "R" },
    { "S", "T", "U", "V", "W", "X" }, { "Y", "Z", "1", "2", "3", "4" }, { "5", "6", "7", "8", "9", "0" },
    { "Space", "Delete", "Clear" },  -- each two keys wide
}
local COLS = 6
local KEY, GAP = 64, 8
local KEYS_X, KEYS_Y = 44, 196
local ROW_H, RESULTS_Y, LIMIT = 84, 196, 60

local FOLD = {
    ["ı"] = "i", ["İ"] = "i", ["ş"] = "s", ["Ş"] = "s", ["ğ"] = "g", ["Ğ"] = "g", ["ü"] = "u", ["Ü"] = "u",
    ["ö"] = "o", ["Ö"] = "o", ["ç"] = "c", ["Ç"] = "c", ["â"] = "a", ["Â"] = "a", ["î"] = "i", ["Î"] = "i",
    ["û"] = "u", ["é"] = "e", ["É"] = "e", ["è"] = "e", ["ê"] = "e", ["ë"] = "e", ["á"] = "a", ["Á"] = "a",
    ["à"] = "a", ["ä"] = "a", ["Ä"] = "a", ["ñ"] = "n", ["Ñ"] = "n", ["ó"] = "o", ["Ó"] = "o", ["ò"] = "o",
    ["ú"] = "u", ["Ú"] = "u", ["í"] = "i", ["Í"] = "i", ["ß"] = "ss", ["ø"] = "o", ["å"] = "a",
}
local function fold(s) return (tostring(s or ""):gsub("[\192-\223][\128-\191]", FOLD):lower()) end

local src = {}
local index, index_of    -- every album and song, with its folded text; the album list it was made from
local results = {}
local focus, row, col, pick, top = "keys", 1, 1, 1, 1

function Q.setup(s) src = s end

local function build()
    local albums = src.albums()
    if index and index_of == albums then return end
    index, index_of = {}, albums
    for _, a in ipairs(albums) do
        local title, artist = src.names(a)
        index[#index + 1] = { album = a, title = title, sub = artist, text = fold(title .. " " .. artist) }
    end
    for _, a in ipairs(albums) do
        local title = src.names(a)
        for i, path in ipairs(a.tracks) do
            local name = src.track_name(path)
            index[#index + 1] = { album = a, track = i, title = name, sub = title, text = fold(name) }
        end
    end
end

local function find()
    results, pick, top = {}, 1, 1
    local words = {}
    for w in fold(Q.query):gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then return end
    local starts, rest = {}, {}  -- names starting with the first word come first, albums before songs
    for _, e in ipairs(index) do
        local ok = true
        for _, w in ipairs(words) do
            if not e.text:find(w, 1, true) then ok = false; break end
        end
        if ok then
            if e.text:sub(1, #words[1]) == words[1] then starts[#starts + 1] = e else rest[#rest + 1] = e end
        end
    end
    for _, list in ipairs({ starts, rest }) do
        for _, e in ipairs(list) do
            if not e.track and #results < LIMIT then results[#results + 1] = e end
        end
    end
    for _, list in ipairs({ starts, rest }) do
        for _, e in ipairs(list) do
            if e.track and #results < LIMIT then results[#results + 1] = e end
        end
    end
end

-- Open the page: the last search is still there, its titles refreshed.
function Q.open()
    index = nil
    build()
    find()
    focus = #results > 0 and "results" or "keys"
end

-- The result under the cursor, for the options panel.
function Q.selected() return focus == "results" and results[pick] or nil end

local function type_key(k)
    if k == "Space" then
        if Q.query ~= "" and Q.query:sub(-1) ~= " " then Q.query = Q.query .. " " end
    elseif k == "Delete" then Q.query = Q.query:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
    elseif k == "Clear" then Q.query = ""
    else Q.query = Q.query .. k:lower() end
    find()
end

local function key_at(r, c)
    local keys = KEYS[r]
    if #keys == COLS then return keys[c] end
    return keys[math.min(#keys, math.floor((c - 1) / 2) + 1)]
end

function Q.key(key)
    if focus == "keys" then
        local last_row = #KEYS
        if key == "up" then row = (row - 2) % last_row + 1
        elseif key == "down" then row = row % last_row + 1
        elseif key == "left" then col = math.max(1, col - (row == last_row and 2 or 1))
        elseif key == "right" then
            local step = row == last_row and 2 or 1
            if col + step <= COLS then col = col + step
            elseif #results > 0 then focus = "results" end
        elseif key == "a" then type_key(key_at(row, col))
        elseif key == "b" then
            if Q.query == "" then return "close" end
            type_key("Delete")
        end
        if row == last_row then col = math.floor((col - 1) / 2) * 2 + 1 end  -- the wide keys start on odd columns
        return nil
    end
    -- the results
    if key == "up" then pick = math.max(1, pick - 1)
    elseif key == "down" then pick = math.min(#results, pick + 1)
    elseif key == "left" or key == "b" then focus = "keys"
    elseif key == "a" then
        local e = results[pick]
        if e then return { album = e.album, track = e.track } end
    end
    return nil
end

function Q.draw(c, header, footer)
    build()
    header(c, "Search")
    -- what was typed
    local fx, fw = 44, ui.W - 88
    ui.rect(c, fx, 100, fw, 72, 18, ui.RAISED)
    if Q.query == "" then
        ui.text(c, fx + 24, 136, "Albums, artists, songs", 32, ui.DIM, 4)
    else
        local shown = Q.query
        while ui.width(shown .. "|", 34) > fw - 48 and #shown > 0 do shown = shown:sub(2) end
        ui.text(c, fx + 24, 136, shown .. (focus == "keys" and "|" or ""), 34, ui.WHITE, 4)
    end
    -- the keyboard
    for r, keys in ipairs(KEYS) do
        for c2 = 1, COLS do
            local k = key_at(r, c2)
            local wide = #keys < COLS
            if not wide or c2 % 2 == 1 then
                local w = wide and (KEY * 2 + GAP) or KEY
                local x, y = KEYS_X + (c2 - 1) * (KEY + GAP), KEYS_Y + (r - 1) * (KEY + GAP)
                local on = focus == "keys" and r == row and c2 == col
                ui.rect(c, x, y, w, KEY, 14, on and ui.ACCENT or ui.RAISED)
                ui.text(c, x + w / 2, y + KEY / 2, k, wide and 24 or 30, ui.WHITE, 5, not wide)
            end
        end
    end
    -- what matches
    local rx = KEYS_X + COLS * (KEY + GAP) + 32
    local rw = ui.W - rx - 44
    local rows = math.floor((700 - RESULTS_Y) / ROW_H)
    if Q.query == "" then
        ui.text(c, rx + rw / 2, 400, "Type to search your music", 30, ui.DIM, 5)
    elseif #results == 0 then
        ui.text(c, rx + rw / 2, 400, "Nothing found", 30, ui.DIM, 5)
    end
    if pick < top then top = pick end
    if pick >= top + rows then top = pick - rows + 1 end
    for i = top, math.min(#results, top + rows - 1) do
        local e = results[i]
        local y = RESULTS_Y + (i - top) * ROW_H
        if focus == "results" and i == pick then ui.rect(c, rx - 16, y, rw + 32, ROW_H - 8, 16, ui.RAISED) end
        ui.text(c, rx + 8, y + (ROW_H - 8) / 2, e.track and "♪" or "◼", 26, e.track and ui.DIM or ui.ACCENT, 4)
        ui.text(c, rx + 52, y + 8, ui.fit_text(e.title, rw - 60, 32, not e.track), 32, ui.WHITE, 7, not e.track)
        ui.text(c, rx + 52, y + 46, ui.fit_text(e.sub, rw - 60, 24), 24, ui.GREY, 7)
    end
    if focus == "keys" then
        footer(c, { { "A", "Type" }, { "B", Q.query == "" and "Back" or "Delete" }, { "X", "Now playing" } })
    else
        footer(c, { { "A", "Open" }, { "B", "Keyboard" }, { "X", "Now playing" } })
    end
end

return Q
