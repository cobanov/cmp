-- The video browser: the folders and videos of ROCKNIX's Media Player folder,
-- to switch to another video without going back to EmulationStation. B opens
-- it, on the touch screen of a dual-screen device (where a finger or the pad
-- picks) or over the video on a one-screen one (the pad).
--
-- The player keeps how far each video was watched in handheld-progress.json;
-- the browser marks finished videos and shows a bar for the ones left halfway.
--
-- F.open_at(path) opens it at the folder of the playing file, F.key(key) moves
-- in it (returns { "play", path }, "close", or true to redraw), F.draw(cv, st)
-- draws it with hit areas (files-item, files-up, files-close) for touch.

local mp = require "mp"
local utils = require "mp.utils"
local ui = require "ui"

local F = { is_open = false }

local ROOT = "/storage/roms/mplayer"
local PROGRESS = "/storage/.config/mpv/handheld-progress.json"
F.VIDEO_EXT = { mkv = true, mp4 = true, m4v = true, avi = true, webm = true, mov = true, ts = true }
-- EmulationStation's scraped pictures and manuals live beside the videos
local SKIP = { images = true, manuals = true, downloaded_images = true, media = true }
local FINISHED = 0.95  -- watched this far: done

-- Progress ------------------------------------------------------------------

local progress, progress_mtime = {}, nil

function F.progress()
    local info = utils.file_info(PROGRESS)
    if not info then progress, progress_mtime = {}, nil; return progress end
    if info.mtime ~= progress_mtime then
        progress_mtime = info.mtime
        local f = io.open(PROGRESS, "r")
        local data = f and utils.parse_json(f:read("*a") or "")
        if f then f:close() end
        progress = type(data) == "table" and data or {}
    end
    return progress
end

-- The player: how far path was watched (0..1).
function F.save_progress(path, frac)
    if not path or not frac then return end
    local p = F.progress()
    if frac >= FINISHED then p[path] = 1
    elseif frac > 0.02 then p[path] = math.floor(frac * 1000) / 1000
    else p[path] = nil end
    if next(p) == nil then p = { _ = 0 } end  -- (an empty table would be written as [])
    local f = io.open(PROGRESS, "w")
    if f then f:write(utils.format_json(p)); f:close() end
    progress_mtime = nil
end

-- Listing -------------------------------------------------------------------

-- "Episode 2" before "Episode 10"
local function sort_key(s)
    return (s:lower():gsub("%d+", function(d) return string.format("%09d", tonumber(d)) end))
end

local function is_video(name)
    local ext = name:match("%.([^.]+)$")
    return ext ~= nil and F.VIDEO_EXT[ext:lower()] == true and name:sub(1, 1) ~= "."
end

local function videos_in(dir)
    local n = 0
    for _, f in ipairs(utils.readdir(dir, "files") or {}) do
        if is_video(f) then n = n + 1 end
    end
    return n
end

local function subdirs(dir)
    local out = {}
    for _, d in ipairs(utils.readdir(dir, "dirs") or {}) do
        if d:sub(1, 1) ~= "." and not SKIP[d:lower()] then out[#out + 1] = d end
    end
    return out
end

-- Folders first (with how many videos they hold), then the videos.
function F.list(dir)
    local folders, videos = {}, {}
    for _, d in ipairs(subdirs(dir)) do
        local path = utils.join_path(dir, d)
        local n = videos_in(path)
        if n > 0 or #subdirs(path) > 0 then
            folders[#folders + 1] = { kind = "dir", name = d, path = path, count = n, key = sort_key(d) }
        end
    end
    for _, f in ipairs(utils.readdir(dir, "files") or {}) do
        if is_video(f) then
            videos[#videos + 1] = { kind = "file", name = f:gsub("%.[^.]+$", ""), path = utils.join_path(dir, f),
                                    key = sort_key(f) }
        end
    end
    table.sort(folders, function(a, b) return a.key < b.key end)
    table.sort(videos, function(a, b) return a.key < b.key end)
    for _, v in ipairs(videos) do folders[#folders + 1] = v end
    return folders
end

-- Browsing ------------------------------------------------------------------

local TOP, ROW = 108, 84
local ROWS = 7
local dir, items, sel, first = ROOT, {}, 1, 0

local function parent_of(d) return d:match("^(.*)/[^/]+$") end

local function at_root() return dir == ROOT or not parent_of(dir) or parent_of(dir) == "" end

-- Keep the pick on the page, a row from its edges when it can be.
local function follow()
    sel = math.max(1, math.min(sel, #items))
    if sel - 1 < first + 1 then first = sel - 2 end
    if sel > first + ROWS - 1 then first = sel - ROWS + 1 end
    first = math.max(0, math.min(first, #items - ROWS))
end

function F.cd(d, pick)
    dir, items, sel, first = d, F.list(d), 1, 0
    for i, it in ipairs(items) do if it.path == pick then sel = i end end
    first = sel - math.floor(ROWS / 2)
    follow()
end

function F.open_at(path)
    local d = path and parent_of(path)
    if not d or not utils.file_info(d) then d = ROOT end
    F.cd(d, path)
    F.is_open = true
end

function F.close() F.is_open = false end

function F.up()
    if at_root() then return false end
    F.cd(parent_of(dir), dir)
    return true
end

-- Open item i: a folder shows its videos, a video is handed back to play.
function F.activate(i)
    local it = items[i]
    if not it then return false end
    if it.kind == "dir" then F.cd(it.path); return true end
    return { "play", it.path }
end

function F.key(key)
    if key == "up" then sel = sel - 1; follow(); return true
    elseif key == "down" then sel = sel + 1; follow(); return true
    elseif key == "l1" then sel = sel - ROWS; follow(); return true
    elseif key == "r1" then sel = sel + ROWS; follow(); return true
    elseif key == "left" then return F.up()
    elseif key == "right" or key == "a" then return F.activate(sel)
    elseif key == "b" then return "close"
    end
    return false
end

-- A finger moving the list: rows from where it landed.
function F.scroll_to(f) first = math.max(0, math.min(f, #items - ROWS)) end
function F.first() return first end
F.ROW = ROW

-- Drawing -------------------------------------------------------------------

local function folder_icon(c, cx, cy, color)
    ui.rect(c, cx - 22, cy - 15, 18, 8, 3, color)
    ui.rect(c, cx - 22, cy - 10, 44, 28, 5, color)
end

-- The video's name in its folder: "Naruto - 060 - Name" in "Naruto" shows as "060 - Name".
local function short_name(it)
    local folder = dir:match("([^/]+)$") or ""
    local name = it.name
    if folder ~= "" and name:sub(1, #folder + 3) == folder .. " - " then name = name:sub(#folder + 4) end
    return name
end

-- st: the player's state (path, pos, dur) to mark the video playing.
-- o.pad: show the pad's pick; o.backdrop: dim what is under it (over a video).
function F.draw(cv, st, o)
    o = o or {}
    local c = cv.lines
    local W = ui.W
    if o.backdrop then ui.rect(c, 0, 0, W, ui.H, 0, "000000", o.backdrop) end
    local x = 44
    if not at_root() then
        ui.circle(c, 74, 52, 30, ui.RAISED)
        ui.text(c, 72, 50, "‹", 40, ui.WHITE, 5, true)
        ui.hit(cv, 0, 0, 420, TOP - 8, "files-up")
        x = 124
    end
    local nfold, nvid = 0, 0
    for _, it in ipairs(items) do if it.kind == "dir" then nfold = nfold + 1 else nvid = nvid + 1 end end
    local title = at_root() and "Videos" or (dir:match("([^/]+)$") or dir)
    ui.text(c, x, 22, ui.fit_text(title, W - x - 140, 34, true), 34, ui.WHITE, 7, true)
    local sub = {}
    if nfold > 0 then sub[#sub + 1] = nfold .. (nfold == 1 and " folder" or " folders") end
    if nvid > 0 then sub[#sub + 1] = nvid .. (nvid == 1 and " video" or " videos") end
    ui.text(c, x, 66, #sub > 0 and table.concat(sub, ", ") or "Nothing to play here", 22, ui.GREY, 7)
    ui.circle(c, W - 58, 52, 30, ui.RAISED)
    ui.text(c, W - 58, 52, "✕", 28, ui.WHITE, 5)
    ui.hit(cv, W - 98, 12, 80, 80, "files-close")

    local seen = F.progress()
    local playing = st and st.path
    local left, width = 44, W - 88
    for i = first + 1, math.min(#items, first + ROWS) do
        local it = items[i]
        local y = TOP + (i - first - 1) * ROW
        local mid = y + (ROW - 8) / 2
        if o.pad and i == sel then ui.rect(c, left - 16, y, width + 32, ROW - 8, 16, ui.RAISED) end
        if it.kind == "dir" then
            folder_icon(c, left + 24, mid, ui.GREY)
            local count = it.count > 0 and tostring(it.count) or ""
            ui.text(c, left + width - 28, mid, count, 24, ui.GREY, 6)
            ui.text(c, left + width - 4, mid - 2, "›", 34, ui.GREY, 6, true)
            ui.text(c, left + 70, mid, ui.fit_text(it.name, width - 170, 28, true), 28, ui.WHITE, 4, true)
        else
            local now = it.path == playing
            local frac = seen[it.path]
            if now and st.dur and st.dur > 0 then frac = (st.pos or 0) / st.dur end
            if now then ui.icon_play(c, left + 26, mid, 26, ui.ACCENT)
            elseif frac and frac >= FINISHED then ui.text(c, left + 24, mid, "✓", 28, ui.ACCENT, 5, true) end
            local name_y = (frac and frac > 0.02 and frac < FINISHED) and mid - 10 or mid
            ui.text(c, left + 70, name_y, ui.fit_text(short_name(it), width - 90, 28), 28, now and ui.ACCENT or ui.WHITE, 4)
            if frac and frac > 0.02 and frac < FINISHED then
                local bw = math.min(360, width - 90)
                ui.rect(c, left + 70, mid + 18, bw, 6, 3, ui.RAISED)
                ui.rect(c, left + 70, mid + 18, math.max(6, bw * frac), 6, 3, now and ui.ACCENT or ui.GREY)
            end
        end
        ui.hit(cv, left - 16, y, width + 32, ROW - 8, "files-item", i)
    end
    if #items > ROWS then  -- where in the list
        local track = ROWS * ROW - 8
        local h = math.max(40, track * ROWS / #items)
        local ty = TOP + (track - h) * first / math.max(1, #items - ROWS)
        ui.rect(c, W - 14, TOP, 4, track, 2, ui.RAISED)
        ui.rect(c, W - 14, ty, 4, h, 2, ui.GREY)
    end
    if o.pad then
        ui.hints(c, 44, ui.H - 34, { { "A", "Open" }, { "←", "Up" }, { "L1 R1", "Page" }, { "B", "Close" } }, 22)
    end
end

return F
