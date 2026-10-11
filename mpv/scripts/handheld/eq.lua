-- A 10-band equalizer: presets and a curve of your own, with ffmpeg's
-- "firequalizer" in mpv's audio chain (one FIR filter: about half the CPU
-- of ten "equalizer" biquads on an H700, ~2% of a core). Changes are sent
-- to the running filter (af-command), so the music never skips while you
-- adjust; only turning it on or off rebuilds the chain. A preamp keeps
-- boosts from clipping.
--
-- E.load(saved) / E.save() -> { preset, custom }, E.apply(), and the page:
-- E.draw(c) and E.key(key) (returns "close" to leave it).

local mp = require "mp"
local ui = require "ui"

local E = {}

E.BANDS = { 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 }
local LABELS = { "31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k" }
local MAX = 12  -- dB either way

E.PRESETS = {
    { name = "Off",          g = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
    { name = "Bass boost",   g = { 6, 5, 4, 2, 0, 0, 0, 0, 0, 0 } },
    { name = "Treble boost", g = { 0, 0, 0, 0, 0, 1, 2, 4, 5, 6 } },
    { name = "Vocal",        g = { -2, -3, -3, 1, 4, 4, 3, 1, 0, -2 } },
    { name = "Rock",         g = { 5, 3, -2, -4, -1, 2, 4, 5, 5, 5 } },
    { name = "Pop",          g = { -1, 2, 4, 5, 3, 0, -1, -1, -1, -1 } },
    { name = "Jazz",         g = { 3, 2, 1, 2, -1, -1, 0, 1, 2, 3 } },
    { name = "Classical",    g = { 0, 0, 0, 0, 0, 0, -3, -3, -3, -5 } },
    { name = "Dance",        g = { 6, 4, 2, 0, 0, -2, -3, -3, 0, 0 } },
    { name = "Custom" },
}
local CUSTOM = #E.PRESETS

local preset = 1
local custom = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local band = 1     -- the band under the cursor on the page
local active = false

local function gains() return preset == CUSTOM and custom or E.PRESETS[preset].g end

function E.name() return E.PRESETS[preset].name end

local function preamp()
    local top = 0
    for _, g in ipairs(gains()) do top = math.max(top, g) end
    return string.format("%.1fdB", -top)
end

-- the curve as firequalizer's gain entries: "entry(31,6);entry(62,5);..."
local function entries()
    local g, out = gains(), {}
    for i, f in ipairs(E.BANDS) do out[i] = string.format("entry(%d,%d)", f, g[i]) end
    return table.concat(out, ";")
end

-- (scale=loglog: the curve between the bands follows octaves, as the sliders do)
local function chain()
    return string.format("@eq:lavfi=[volume@pre=volume=%s,firequalizer@fir=scale=loglog:gain_entry='%s']",
        preamp(), entries())
end

-- Send the current curve to the running filter.
local function send()
    mp.commandv("af-command", "eq", "gain_entry", entries(), "firequalizer@fir")
    mp.commandv("af-command", "eq", "volume", preamp(), "volume@pre")
end

function E.apply()
    local flat = true
    for _, g in ipairs(gains()) do if g ~= 0 then flat = false end end
    if flat then
        if active then mp.commandv("af", "remove", "@eq"); active = false end
        return
    end
    if not active then
        mp.commandv("af", "add", chain())
        active = true
    else
        send()
    end
end

-- The chain is built again when the audio format changes (a 44.1 kHz track
-- after a 48 kHz one), from the gains it was added with: send today's.
mp.register_event("audio-reconfig", function() if active then send() end end)

function E.load(saved)
    if type(saved) ~= "table" then return end
    for i, p in ipairs(E.PRESETS) do if p.name == saved.preset then preset = i end end
    if type(saved.custom) == "table" then
        for i = 1, #E.BANDS do custom[i] = math.max(-MAX, math.min(MAX, tonumber(saved.custom[i]) or 0)) end
    end
end

function E.save() return { preset = E.PRESETS[preset].name, custom = custom } end

-- The settings row: step through the presets.
function E.step(dir)
    preset = (preset - 1 + (dir or 1)) % #E.PRESETS + 1
    E.apply()
end

-- The page --------------------------------------------------------------------

local TOP, BOTTOM = 170, 590  -- the sliders' +12 and -12 dB

local function y_of(db) return (TOP + BOTTOM) / 2 - db * (BOTTOM - TOP) / (2 * MAX) end

function E.draw(c)
    ui.rect(c, 0, 0, ui.W, ui.H, 0, "000000")
    ui.text(c, 44, 20, "Equalizer", 42, ui.WHITE, 7, true)
    ui.text(c, ui.W - 44, 36, E.name(), 30, ui.ACCENT, 9, true)
    local g = gains()
    local left, span = 60, ui.W - 120
    local function x_of(i) return left + (i - 0.5) * span / #E.BANDS end
    -- 0 dB, and the curve through the bands
    ui.rect(c, left, y_of(0), span, 2, 0, ui.RAISED)
    ui.text(c, left - 8, y_of(MAX), "+12", 20, ui.DIM, 6)
    ui.text(c, left - 8, y_of(0), "0", 20, ui.DIM, 6)
    ui.text(c, left - 8, y_of(-MAX), "−12", 20, ui.DIM, 6)
    for i = 1, #E.BANDS - 1 do
        ui.line(c, x_of(i), y_of(g[i]), x_of(i + 1), y_of(g[i + 1]), 4, ui.ACCENT, 0x60)
    end
    for i = 1, #E.BANDS do
        local x, on = x_of(i), i == band
        ui.rect(c, x - 4, TOP, 8, BOTTOM - TOP, 4, on and ui.TRACK or ui.RAISED)
        if on then ui.ring(c, x, y_of(g[i]), 24, 4, ui.ACCENT) end
        ui.circle(c, x, y_of(g[i]), on and 16 or 12, on and ui.WHITE or ui.GREY)
        ui.text(c, x, BOTTOM + 40, LABELS[i], 24, on and ui.WHITE or ui.GREY, 5, on)
        if on then ui.text(c, x, TOP - 34, string.format("%+d dB", g[i]), 26, ui.WHITE, 5, true) end
    end
    ui.hints(c, 44, 726, { { "A", "Flat" }, { "B", "Back" }, { "↑↓", "Gain" }, { "←→", "Band" }, { "L1 R1", "Preset" } }, 24)
end

function E.key(key)
    if key == "left" then band = math.max(1, band - 1)
    elseif key == "right" then band = math.min(#E.BANDS, band + 1)
    elseif key == "up" or key == "down" or key == "a" then
        -- editing a preset turns it into your own curve
        if preset ~= CUSTOM then
            for i, v in ipairs(E.PRESETS[preset].g) do custom[i] = v end
            preset = CUSTOM
        end
        if key == "a" then for i = 1, #custom do custom[i] = 0 end
        else custom[band] = math.max(-MAX, math.min(MAX, custom[band] + (key == "up" and 1 or -1))) end
        E.apply()
    elseif key == "l1" or key == "r1" then E.step(key == "r1" and 1 or -1)
    elseif key == "b" or key == "select" then return "close"
    end
    return nil
end

return E
