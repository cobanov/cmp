-- uipreview.lua STATE.lua VIEW OUT_PREFIX: run touch.lua outside mpv and dump
-- what it would draw (ASS events + picture overlays) for uipreview.py.
package.path = "/tmp/hh-test/handheld/?.lua;" .. package.path
local state_json, view, out = arg[1], arg[2] or "controls", arg[3] or "/tmp/uipv"
local now, key_fn, mouse = 0, nil, { x = 0, y = 0 }
local overlay = { data = "", update = function() end, remove = function(self) self.data = "" end }
local images = {}
local function timer() return { kill = function() end } end
local mp = {
    create_osd_overlay = function() return overlay end,
    add_timeout = timer, add_periodic_timer = timer,
    get_time = function() now = now + 0.01; return now end,
    commandv = function(name, id, x, y, path, _, _, w, h, stride)
        if name == "overlay-add" then
            if path:sub(1, 1) == "&" then  -- from memory: keep a copy as a file
                local ffi = require "ffi"
                local file = string.format("%s-ov%d.bgra", out, id)
                local f = io.open(file, "wb")
                f:write(ffi.string(ffi.cast("const char *", tonumber(path:sub(2))), tonumber(stride) * tonumber(h)))
                f:close()
                path = file
            end
            images[id] = { x = x, y = y, path = path, w = w, h = h }
        elseif name == "overlay-remove" then images[id] = nil end
    end,
    get_property_native = function(p)
        if p == "mouse-pos" then return mouse end
        if p == "osd-dimensions" then return { w = 1024, h = 768 } end
    end,
    add_forced_key_binding = function(_, _, fn) key_fn = key_fn or fn end,
    observe_property = function() end,
    osd_message = function() end,
}
package.preload["mp"] = function() return mp end
-- what the touch code's helpers (covers, lyrics, tags) need from mp.utils
package.preload["mp.utils"] = function()
    return {
        split_path = function(p) return p:match("^(.*/)") or "", p:match("([^/]*)$") end,
        join_path = function(a, b) return a:sub(-1) == "/" and a .. b or a .. "/" .. b end,
        file_info = function(p) local f = io.open(p, "rb"); if f then f:close(); return { is_file = true } end end,
        readdir = function(p, filter)
            -- (a folder ends in /; links to folders, as in /sys, count as folders)
            local t, h = {}, io.popen('for f in "' .. p .. '"/*; do [ -e "$f" ] || continue; ' ..
                                      'if [ -d "$f" ]; then echo "${f##*/}/"; else echo "${f##*/}"; fi; done')
            for l in h:lines() do
                local dir = l:sub(-1) == "/"
                if filter == "dirs" and dir then t[#t + 1] = l:sub(1, -2)
                elseif filter == "files" and not dir then t[#t + 1] = l
                elseif filter ~= "dirs" and filter ~= "files" then t[#t + 1] = dir and l:sub(1, -2) or l end
            end
            h:close()
            return t
        end,
        parse_json = function() return nil end,
        format_json = function() return "{}" end,
    }
end
local st = dofile(state_json)  -- a Lua file returning the state table
assert(st, "bad state json")
-- VIEW: controls | intro | settings[:TAB] | guide | level[:1 volume|:2 brightness] (touch screen)
--       bgcontrols | library | albumpage[:N] (the background music player)
--       pad[:TAB[:ROW]] | padguide (the pad's settings on the main screen)
local name, n1, n2 = view:match("^(%a+):?(%d*):?(%d*)$")
n1, n2 = tonumber(n1) or 1, tonumber(n2) or 1
if name == "pad" or name == "padguide" or name == "padabout" then
    local menu = require "padmenu"
    menu.setup({ model = function() return st.settings end, apply = function() end,
                 guide = st.kind == "music" and "music" or "video" })
    menu.toggle()
    for _ = 2, n1 do menu.key("r1") end
    for _ = 2, n2 do menu.key("down") end
    if name == "padguide" then  -- the guide is the last row of the last tab
        menu.key("l1"); menu.key("up"); menu.key("a")
    end
    if name == "padabout" then menu.key("up"); menu.key("a") end  -- About: the music list's last row
else
    local touch = require "touch"
    local backend = { state = function() return st end, action = function() end,
                      wake = function() end, sleep = function() end }
    local is_remote = true
    if name == "library" or name == "albumpage" or name == "bgcontrols" then  -- the background player
        is_remote = false
        backend.wake, backend.sleep = nil, nil
        backend.library = function()
            local albums = {}
            for d in io.popen("ls /storage/roms/music"):lines() do
                local dir = "/storage/roms/music/" .. d
                local tracks = {}
                for t in io.popen('ls "' .. dir .. '"'):lines() do
                    if t:match("%.opus$") or t:match("%.mp3$") or t:match("%.flac$") then tracks[#tracks + 1] = dir .. "/" .. t end
                end
                local artist, title = d:match("^(.-) %- (.+)$")
                local function has(p) local f = io.open(p, "rb"); if f then f:close() end; return f and p or nil end
                if #tracks > 0 then
                    albums[#albums + 1] = { dir = dir, title = title or d, artist = artist or "", tracks = tracks,
                        thumb = has(dir .. "/cover-80.bgra"), cover = has(dir .. "/cover-400.bgra") }
                end
            end
            return albums
        end
        st.path = "/storage/roms/music/Opeth - Damnation/04. Closure.opus"
    end
    touch.init(backend, is_remote)
    local function tap(x, y)
        mouse = { x = x, y = y }
        key_fn({ event = "down" }); key_fn({ event = "up" })
    end
    if name == "intro" then touch.intro() else touch.show("controls") end
    if name == "level" then tap(n1 == 2 and 690 or 780, 48) end  -- level:1 volume, level:2 brightness
    if name == "vlevel" then tap(n1 == 2 and 600 or 690, 48) end  -- the same over a video
    if name == "quit" then tap(966, 52) end  -- the ✕ once: it asks
    if name == "files" then  -- the video browser: files:0 at the playing file's folder, files:1 one up
        tap(176, 666)                       -- the Videos pill
        if n1 == 1 then tap(74, 52) end     -- ‹ up
    end
    if name == "library" or name == "albumpage" then
        tap(176, 666)                       -- the Library pill
        if name == "albumpage" then tap(500, 96 + (n1 - 0.5) * 120) end  -- album n1
    end
    if name == "settings" or name == "guide" then
        touch.show("settings")
        local sw = (936 - 8) / #st.settings
        tap(48 + sw * (n1 - 0.5), 130)  -- the tab
        if name == "guide" then touch.show("guide") end
    end
end
local f = io.open(out .. ".ass", "w")
f:write("[Script Info]\nScriptType: v4.00+\nPlayResX: 1024\nPlayResY: 768\nWrapStyle: 2\n\n",
        "[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n",
        "Style: Default,sans-serif,40,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n\n",
        "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n")
for line in overlay.data:gmatch("[^\n]+") do
    f:write("Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,", line, "\n")
end
f:close()
f = io.open(out .. ".images", "w")
for id, im in pairs(images) do f:write(string.format("%d %d %d %d %s\n", im.x, im.y, im.w, im.h, im.path)) end
f:close()
