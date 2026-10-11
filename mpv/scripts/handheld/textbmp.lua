-- Text drawn into our own pixel buffers, with libass called from LuaJIT (the
-- same library mpv draws its OSD with, so it looks the same). Lists that
-- scroll draw each row once into a bitmap and then only move bitmaps around;
-- redrawing every line through mpv's OSD on each finger move is too slow on
-- the RK3566.

local ffi = require "ffi"
local bit = require "bit"
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift

ffi.cdef [[
typedef struct ass_library ASS_Library;
typedef struct ass_renderer ASS_Renderer;
typedef struct ass_track ASS_Track;
typedef struct ass_image {
    int w, h, stride;
    unsigned char *bitmap;
    uint32_t color;
    int dst_x, dst_y;
    struct ass_image *next;
    int type;
} ASS_Image;
ASS_Library *ass_library_init(void);
ASS_Renderer *ass_renderer_init(ASS_Library *);
void ass_set_frame_size(ASS_Renderer *, int, int);
void ass_set_storage_size(ASS_Renderer *, int, int);
void ass_set_fonts(ASS_Renderer *, const char *, const char *, int, const char *, int);
ASS_Track *ass_read_memory(ASS_Library *, char *, size_t, const char *);
void ass_free_track(ASS_Track *);
ASS_Image *ass_render_frame(ASS_Renderer *, ASS_Track *, long long, int *);
]]

local B = {}

local lib, ass, renderer
local function init()
    if renderer then return true end
    local ok, l = pcall(ffi.load, "libass.so.9")
    if not ok then return false end
    lib = l
    ass = lib.ass_library_init()
    renderer = lib.ass_renderer_init(ass)
    lib.ass_set_fonts(renderer, nil, "sans-serif", 1, nil, 1)  -- 1: fontconfig, as mpv
    return true
end

local HEAD = "[Script Info]\nScriptType: v4.00+\nPlayResX: %d\nPlayResY: %d\nWrapStyle: 2\n\n" ..
    "[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, " ..
    "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, " ..
    "MarginL, MarginR, MarginV, Encoding\n" ..
    "Style: Default,sans-serif,40,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n\n" ..
    "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"

-- Draw ASS event texts (as ui.text and ui.rect make them, with positions
-- inside the buffer) onto `buf`: w x h int32 BGRA pixels, rows `stride`
-- pixels apart, opaque. Returns false when libass cannot be loaded.
function B.draw(buf, w, h, stride, lines)
    if not init() then return false end
    local text = { string.format(HEAD, w, h) }
    for _, l in ipairs(lines) do text[#text + 1] = "Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,," .. l .. "\n" end
    text = table.concat(text)
    local mem = ffi.new("char[?]", #text + 1, text)
    local track = lib.ass_read_memory(ass, mem, #text, nil)
    if track == nil then return false end
    lib.ass_set_frame_size(renderer, w, h)
    lib.ass_set_storage_size(renderer, w, h)
    local img = lib.ass_render_frame(renderer, track, 1000, nil)
    while img ~= nil do
        local c = img.color
        local r, g, b = rshift(c, 24), band(rshift(c, 16), 255), band(rshift(c, 8), 255)
        local opacity = 255 - band(c, 255)
        local solid = bor(0xFF000000, lshift(r, 16), lshift(g, 8), b)
        local bm, bs = img.bitmap, img.stride
        for y = 0, img.h - 1 do
            local dy = img.dst_y + y
            if dy >= 0 and dy < h then
                local o, s = dy * stride + img.dst_x, y * bs
                for x = 0, img.w - 1 do
                    local m = bm[s + x]
                    if m ~= 0 then
                        local a = m * opacity
                        if a >= 65025 then buf[o + x] = solid
                        else
                            local d = buf[o + x]
                            local dr, dg, db = band(rshift(d, 16), 255), band(rshift(d, 8), 255), band(d, 255)
                            dr = dr + math.floor((r - dr) * a / 65025)
                            dg = dg + math.floor((g - dg) * a / 65025)
                            db = db + math.floor((b - db) * a / 65025)
                            buf[o + x] = bor(0xFF000000, lshift(dr, 16), lshift(dg, 8), db)
                        end
                    end
                end
            end
        end
        img = img.next
    end
    lib.ass_free_track(track)
    return true
end

-- How wide a line of text is, in the units it is drawn at (a canvas unit
-- when the canvas is drawn 1:1). Remembered, since lists ask again and again.
local widths = {}
function B.measure(text, size, bold)
    local key = string.format("%d|%s|%s", size, bold and 1 or 0, text)
    local w = widths[key]
    if w then return w end
    if not init() then return nil end
    local script = string.format(HEAD, 4096, 256) ..
        string.format("Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,{\\an7\\pos(0,0)\\fs%d\\b%d\\bord0\\shad0\\fnDejaVu Sans}%s\n",
                      size, bold and 1 or 0, (text:gsub("\\", "\\\226\129\160"):gsub("{", "\\{"):gsub("}", "\\}")))
    local mem = ffi.new("char[?]", #script + 1, script)
    local track = lib.ass_read_memory(ass, mem, #script, nil)
    if track == nil then return nil end
    lib.ass_set_frame_size(renderer, 4096, 256)
    lib.ass_set_storage_size(renderer, 4096, 256)
    local img = lib.ass_render_frame(renderer, track, 1000, nil)
    w = 0
    while img ~= nil do
        w = math.max(w, img.dst_x + img.w)
        img = img.next
    end
    lib.ass_free_track(track)
    widths[key] = w
    return w
end

return B
