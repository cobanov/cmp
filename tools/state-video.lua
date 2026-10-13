local function row(key, label, kind, value, on, extra)
  local r = { key = key, label = label, kind = kind, value = value or "", on = on or false, off = false, danger = false, close = false }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end
return { volume = 40, brightness_top = 65, brightness_bottom = 35, title = "Naruto - 060 - Byakugan vs. Shadow Clone Technique!", pos = 118, dur = 1418, paused = false,
  sub = "English", audio = "Japanese", has_prev = false, has_next = true, keep_on = false,
  settings = {
    { title = "Subtitles", rows = {
      row("sub", "Track", "track", "English"), row("sub-scale", "Size", "number", "110%"),
      row("sub-border-style", "Background", "toggle", "Dark box", true), row("sub-outline-size", "Outline", "number", "2.0"),
      row("sub-shadow-offset", "Shadow", "choice", "Off"), row("sub-pos", "Position", "number", "100"),
      row("sub-delay", "Delay", "number", "+0.0 s") } },
    { title = "Playback", rows = {
      row("audio", "Audio", "track", "Japanese"), row("speed", "Speed", "number", "1.00x"),
      row("autoplay", "Autoplay next episode", "toggle", "On", true), row("remote-on", "Keep touch screen on", "toggle", "Off") } },
    { title = "More", rows = {
      row("prev", "Previous episode", "action", "", false, { off = true, close = true }),
      row("next", "Next episode", "action", "", false, { close = true }),
      row("move", "Play on bottom screen", "action", "", false, { close = true }),
      row("delete", "Delete this episode", "action", "Press again", false, { danger = true }),
      row("guide", "Button guide", "guide") } },
  } }
