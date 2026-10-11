-- Crossfade: the last seconds of a track and the first of the next one play
-- together, one fading out as the other fades in.
--
-- mpv plays one file at a time, so the next track's opening is mixed into
-- the current one with a filter graph (lavfi-complex) made as each track
-- loads: its own audio fades out over the last D seconds while ffmpeg's
-- "amovie" reads the next file and fades it in. When the track ends, the
-- next one starts D seconds in, where the mix left it: nothing is heard
-- twice and there is no gap. Every track comes out as 48 kHz float stereo
-- and the next file is opened ahead (prefetch), so the audio output stays
-- open from one track to the next. Recorded through a silent sink with
-- test tones on an RG SP, the hand-over is off by a few samples at most.
--
-- The graph works on timestamps, so seeking within a track keeps the fade
-- where it belongs; seeking into the fade itself plays this track out and
-- the next from its start. Skipping by hand does the same. A queue edit
-- that changes the next track makes the graph again (the audio pauses for
-- a moment as mpv takes it).

local mp = require "mp"

local X = {}

local D = 0           -- seconds of overlap; 0: off
local starts = {}     -- playlist entry id -> where it starts (heard in the mix already)
local mixing          -- { id = entry mixed in, at = when the fade starts }
local loaded = false  -- the track playing is past loading (queue edits may remake its graph)
X.allow = function() return true end  -- music.lua: false with Repeat one or "End of track"

local FMT = "aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo"

-- A path inside a filter graph: escaped for the filter's options, then for the graph.
local function graph_path(p)
    local opt = p:gsub("[\\':]", "\\%0")
    return (opt:gsub("[\\'%[%],;]", "\\%0"))
end

local function entry(i)
    return mp.get_property_number("playlist/" .. i .. "/id"), mp.get_property("playlist/" .. i .. "/filename")
end

-- the entry after the one playing, by the queue's order and Repeat
local function next_entry()
    local pos, count = mp.get_property_number("playlist-pos", -1), mp.get_property_number("playlist-count", 0)
    if pos < 0 then return nil end
    local i = pos + 1
    if i >= count then
        if mp.get_property("loop-playlist") == "no" then return nil end
        i = 0
    end
    return entry(i)
end

-- Take the mix away while the track plays: a graph that only passes the
-- track through (emptying lavfi-complex mid-track makes mpv 0.41 quit).
local function unmix()
    mp.set_property("file-local-options/lavfi-complex", "[aid1]" .. FMT .. "[ao]")
end

local function graph(S, path)
    return string.format("[aid1]%s,asplit[x][y];[x]afade=t=out:st=%.3f:d=%.3f[a];"
        .. "[y]volume=0,atrim=end=%.3f[s];amovie=filename=%s,%s[m];"
        .. "[s][m]concat=n=2:v=0:a=1,afade=t=in:st=%.3f:d=%.3f[b];"
        .. "[a][b]amix=inputs=2:duration=first:normalize=0[ao]",
        FMT, S, D, S, graph_path(path), FMT, S, D)
end

-- The graph for the track playing, or none. At load time (on_preloaded) it
-- costs nothing; later (a queue edit) mpv reloads the audio to take it.
local function make(now)
    local want, id, path = nil, nil, nil
    local dur = mp.get_property_number("duration")
    if D > 0 and X.allow() and dur and dur > 2 * D + 1 and mp.get_property("loop-file") == "no" then
        id, path = next_entry()
        if id and path and id ~= mp.get_property_number("playlist/" .. mp.get_property_number("playlist-pos", 0) .. "/id") then
            want = graph(dur - D, path)
        end
    end
    local key = want and id or nil
    if now and key == (mixing and mixing.id) then return end  -- nothing changed
    mixing = want and { id = id, at = dur - D } or nil
    if want then mp.set_property("file-local-options/lavfi-complex", want)
    elseif now then unmix() end
end

mp.add_hook("on_load", 50, function()
    local id = mp.get_property_number("playlist/" .. mp.get_property_number("playlist-pos", 0) .. "/id")
    local start = starts[id]
    starts, mixing, loaded = {}, nil, false
    if start then mp.set_property("file-local-options/start", string.format("%.3f", start)) end
end)

mp.add_hook("on_preloaded", 50, function() make(false) end)
mp.register_event("file-loaded", function() loaded = true end)

-- A track that played to its end hands its mix over to the next one;
-- skipping by hand starts the next one from its beginning.
mp.register_event("end-file", function(e)
    loaded = false
    if e.reason == "eof" and mixing then
        starts[mixing.id] = D
    else
        starts = {}
    end
end)

-- Seeking into the fade: no mix this time (the graph would start the next
-- track there silent), the next track plays from its start.
mp.register_event("playback-restart", function()
    local pos = mp.get_property_number("time-pos")
    if mixing and pos and pos > mixing.at then
        mixing = nil
        unmix()
    end
end)

-- a queue edit (play next, remove, shuffle) may change which track follows
mp.observe_property("playlist", "native", function()
    if D == 0 or not loaded then return end
    if next_entry() ~= (mixing and mixing.id) then make(true) end
end)

-- seconds: 0 turns it off. The steady 48 kHz float output keeps the audio
-- device open between tracks; off, every track plays as it is again.
function X.set(seconds)
    D = seconds or 0
    if D > 0 then
        mp.set_property("gapless-audio", "yes")
        mp.set_property("prefetch-playlist", "yes")
        mp.set_property("audio-samplerate", "48000")
        mp.set_property("audio-channels", "stereo")
        mp.set_property("audio-format", "floatp")
    else
        mp.set_property("gapless-audio", "weak")
        mp.set_property("prefetch-playlist", "no")
        mp.set_property("audio-samplerate", "0")
        mp.set_property("audio-channels", "auto-safe")
        mp.set_property("audio-format", "no")
        starts = {}
        if mixing then mixing = nil; unmix() end
    end
end

function X.seconds() return D end

-- Something that decides whether it applies changed (Repeat, the sleep timer).
function X.refresh() if loaded then make(true) end end

return X
