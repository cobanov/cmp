local function row(key, label, kind, value, on, extra)
  local r = { key = key, label = label, kind = kind, value = value or "", on = on or false, off = false, danger = false, close = false }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end
local st = {
 kind = "music", volume = 40, brightness_top = 65, brightness_bottom = 35, brightness_sync = false, title = "Closure", artist = "Opeth", album = "Damnation",
  cover = "/storage/roms/music/Opeth - Damnation/cover-400.bgra",
  pos = 26, dur = 316, paused = false, has_prev = true, has_next = true,
  shuffle = true, ["repeat"] = "One", keep_on = false,
  settings = {
    { title = "Settings", rows = { row("shuffle", "Shuffle", "toggle", "On", true), row("repeat", "Repeat", "choice", "One"),
      row("album-view", "Album view", "choice", "Cover Flow"), row("stay-on", "Keep touch screen on", "toggle", "Off"),
      row("move", "Play in background", "action", "", false, { close = true }),
      row("guide", "Button guide", "guide"), row("about", "About", "about") } },
  } }
-- the queue on the remote (the main screen shows what is playing), the fourth song playing
st.queue = { "Windowpane", "In My Time of Need", "Death Whispered a Lullaby", "Closure",
             "Hope Leaves", "To Rid the Disease", "Ending Credits", "Weakness" }
st.queue_pos, st.queue_sel, st.queue_start, st.queue_count = 3, nil, 0, 8
st.queue_ids = { 1, 2, 3, 4, 5, 6, 7, 8 }
return st
