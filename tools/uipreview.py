# uipreview.py PREFIX: render PREFIX.ass (with libass, like mpv) and PREFIX.images
# (raw premultiplied BGRA pictures) onto 1024x768 black and write PREFIX.png.
import ctypes, struct, sys, zlib
W, H = 1024, 768
prefix = sys.argv[1]
ass = ctypes.CDLL("libass.so.9")
class Img(ctypes.Structure):
    pass
Img._fields_ = [("w", ctypes.c_int), ("h", ctypes.c_int), ("stride", ctypes.c_int),
                ("bitmap", ctypes.POINTER(ctypes.c_ubyte)), ("color", ctypes.c_uint32),
                ("dst_x", ctypes.c_int), ("dst_y", ctypes.c_int), ("next", ctypes.POINTER(Img)), ("type", ctypes.c_int)]
ass.ass_library_init.restype = ctypes.c_void_p
ass.ass_renderer_init.restype = ctypes.c_void_p
ass.ass_renderer_init.argtypes = [ctypes.c_void_p]
ass.ass_set_frame_size.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
ass.ass_set_fonts.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
ass.ass_read_memory.restype = ctypes.c_void_p
ass.ass_read_memory.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
ass.ass_render_frame.restype = ctypes.POINTER(Img)
ass.ass_render_frame.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_longlong, ctypes.POINTER(ctypes.c_int)]
lib = ass.ass_library_init()
r = ass.ass_renderer_init(lib)
ass.ass_set_frame_size(r, W, H)
ass.ass_set_fonts(r, None, b"sans-serif", 1, None, 1)
data = open(prefix + ".ass", "rb").read()
track = ass.ass_read_memory(lib, data, len(data), None)
canvas = bytearray(W * H * 3)
img = ass.ass_render_frame(r, track, 1000, None)
while img:
    i = img.contents
    c = i.color
    cr, cg, cb, ca = c >> 24, (c >> 16) & 255, (c >> 8) & 255, 255 - (c & 255)
    for y in range(i.h):
        row = (i.dst_y + y) * W
        for x in range(i.w):
            a = i.bitmap[y * i.stride + x] * ca // 255
            if a:
                p = (row + i.dst_x + x) * 3
                canvas[p] = (cr * a + canvas[p] * (255 - a)) // 255
                canvas[p + 1] = (cg * a + canvas[p + 1] * (255 - a)) // 255
                canvas[p + 2] = (cb * a + canvas[p + 2] * (255 - a)) // 255
    img = i.next
for line in open(prefix + ".images"):
    x, y, w, h, path = line.split(" ", 4)
    x, y, w, h = int(x), int(y), int(w), int(h)
    raw = open(path.strip(), "rb").read()
    for yy in range(h):
        for xx in range(w):
            b, g, rr, a = raw[(yy * w + xx) * 4:(yy * w + xx) * 4 + 4]
            p = ((y + yy) * W + x + xx) * 3
            canvas[p] = rr + canvas[p] * (255 - a) // 255
            canvas[p + 1] = g + canvas[p + 1] * (255 - a) // 255
            canvas[p + 2] = b + canvas[p + 2] * (255 - a) // 255
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
raw = b"".join(b"\0" + bytes(canvas[y * W * 3:(y + 1) * W * 3]) for y in range(H))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
open(prefix + ".png", "wb").write(png)
