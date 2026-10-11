-- flowbench.lua SCRIPTS_DIR OUT_PREFIX [POS ...]: time coverflow.lua's
-- drawing under luajit on the device and dump frames for uipreview.py.
package.path = arg[1] .. "/?.lua;" .. package.path
local out = arg[2]
local F = require "coverflow"
local ui = require "ui"
F.setup()
local ffi = require "ffi"
local albums = {}
local ls = io.popen("ls /storage/roms/music")
for name in ls:lines() do
    local dir = "/storage/roms/music/" .. name
    local f = io.open(dir .. "/cover-400.bgra", "rb")
    if f then f:close() end
    local artist, title = name:match("^(.-) %- (.+)$")
    albums[#albums + 1] = { title = title or name, artist = artist or "", cover = f and dir .. "/cover-400.bgra" or nil }
end
ls:close()
albums[#albums + 1] = { title = "No Cover Album", artist = "Someone" }
local t0 = os.clock()
F.render(albums, 3)
print(string.format("first frame (loads covers): %.1f ms", (os.clock() - t0) * 1000))
local n = 60
t0 = os.clock()
for i = 1, n do F.render(albums, 3 + i / n) end
print(string.format("moving frame: %.2f ms", (os.clock() - t0) * 1000 / n))
t0 = os.clock()
for _ = 1, n do F.render(albums, 4) end
print(string.format("still frame: %.2f ms", (os.clock() - t0) * 1000 / n))
for k = 3, #arg do
    local pos = tonumber(arg[k])
    local strip = F.render(albums, pos)
    local name = string.format("%s-%s", out, arg[k])
    local f = io.open(name .. ".bgra", "wb")
    for y = 0, F.H - 1 do f:write(ffi.string(strip + y * F.STRIDE, F.W * 4)) end
    f:close()
    f = io.open(name .. ".images", "w")
    f:write(string.format("%d %d %d %d %s.bgra\n", F.X, F.Y, F.W, F.H, name))
    f:close()
    local a = albums[math.floor(pos + 0.5)]
    local cv = ui.canvas()
    local c = cv.lines
    ui.text(c, 512, 596, ui.trim(a.title, 40), 30, ui.WHITE, 8, true)
    ui.text(c, 512, 638, ui.trim(a.artist, 50), 22, ui.GREY, 8)
    ui.text(c, 512, 674, "9 tracks", 19, ui.DIM, 8)
    ui.text(c, 980, 28, math.floor(pos + 0.5) .. " / " .. #albums, 20, ui.DIM, 9)
    ui.text(c, 44, 726, "← → browse    A open    X shuffle all    Y play/pause    L1 R1 track    Select settings", 19, ui.DIM, 7)
    f = io.open(name .. ".ass", "w")
    f:write("[Script Info]\nScriptType: v4.00+\nPlayResX: 1024\nPlayResY: 768\nWrapStyle: 2\n\n",
            "[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n",
            "Style: Default,sans-serif,40,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n\n",
            "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n")
    for _, line in ipairs(c) do f:write("Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,", line, "\n") end
    f:close()
end
