local function row(key, label, kind, value, on, extra)
  local r = { key = key, label = label, kind = kind, value = value or "", on = on or false, off = false, danger = false, close = false }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end
local st = {
 kind = "music", title = "Closure", artist = "Opeth", album = "Damnation",
  cover = "/storage/roms/music/Opeth - Damnation/cover-400.bgra",
  pos = 26, dur = 316, paused = false, has_prev = true, has_next = true,
  shuffle = true, ["repeat"] = "One", keep_on = false,
  settings = {
    { title = "Settings", rows = { row("shuffle", "Shuffle", "toggle", "On", true), row("repeat", "Repeat", "choice", "One"),
      row("album-view", "Album view", "choice", "Cover Flow"), row("stay-on", "Keep touch screen on", "toggle", "Off"),
      row("move", "Play in background", "action", "", false, { close = true }),
      row("guide", "Button guide", "guide"), row("about", "About", "about") } },
  } }
-- the queue on the remote (the main screen shows what is playing), the pad's pick on the fifth song
st.queue = { "Windowpane", "In My Time of Need", "Death Whispered a Lullaby", "Closure",
             "Hope Leaves", "To Rid the Disease", "Ending Credits", "Weakness" }
st.queue_pos, st.queue_sel = 3, 4
return st
