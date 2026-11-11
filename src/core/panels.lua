-- The data beside the HUD: cards for the battery, position and messages, and
-- a status bar. Built from the Lofted Aero design system, in the theme being
-- shown (core/palette.lua): surface cards with a hairline frame and the orange rule
-- under their titles, a charcoal bar, captions dim and values bright.

local use = ...
local palette = use("palette")
local units = use("units")
local vehicle = use("vehicle")

local M = {}

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local T, B = palette.T, palette.BAR
local DASH = "-"

-- MAVLink severities: 0-3 emergency to error, 4 warning, 5 notice,
-- 6 info, 7 debug. Debug never shows.
local function severityColor(sev)
  if sev <= 3 then
    return T.bad
  elseif sev == 4 then
    return T.warn
  end
  return T.ink2
end

--- Scale for a panel on a screen of this size, as the HUD scales.
function M.scale(w, h)
  return max(0.75, min(1.5, min(w, h) / 320))
end

--- A card: frame, title and the orange rule. Returns the top of its body.
function M.card(c, x, y, w, h, title, sc)
  c.fill(x, y, w, h, T.surface)
  c.line(x, y, x + w - 1, y, T.line, 1)
  c.line(x, y + h - 1, x + w - 1, y + h - 1, T.line, 1)
  c.line(x, y, x, y + h - 1, T.line, 1)
  c.line(x + w - 1, y, x + w - 1, y + h - 1, T.line, 1)
  local pad = 6 * sc
  local titleY = y + pad + 6 * sc
  c.text(x + pad, titleY, title, 11 * sc, T.ink, "left", true)
  local ruleY = titleY + 9 * sc
  c.fill(x + pad, ruleY, w - 2 * pad, max(1, floor(1.5 * sc + 0.5)), T.orange)
  return ruleY + 6 * sc
end

-- A label and its value on one line, the label dim on the left.
local function row(c, x, y, w, label, value, sc, color)
  local pad = 6 * sc
  c.text(x + pad, y, label, 10 * sc, T.ink3, "left")
  c.text(x + w - pad, y, value, 12 * sc, color or T.ink, "right")
end

local function rowH(sc)
  return 15 * sc
end

-- Distances past a kilometer (or a mile) read in the larger unit.
local function distance(m, unit)
  if unit == "ft" then
    local ft = units.toDistance(m, "ft")
    return ft >= 5280 and string.format("%.2f mi", ft / 5280) or string.format("%d ft", floor(ft + 0.5))
  end
  return m >= 1000 and string.format("%.2f km", m / 1000) or string.format("%d m", floor(m + 0.5))
end

--- The battery card: volts large with volts per cell, current, power, the
--- charge used against the pack's capacity with a level bar, the second
--- pack when there is one, and the transmitter's own battery if `opts.tx` is
--- set. `opts.cells` is the pilot's cell count, where set.
function M.battery(c, x, y, w, h, s, sc, opts)
  local by = M.card(c, x, y, w, h, "Battery", sc)
  local pad = 6 * sc
  local b = s.battery[1]
  local cells = opts.cells or vehicle.cells(b)
  local tx = opts.tx
  local ly = by + 12 * sc
  c.text(x + pad, ly, b.volts and string.format("%.1f V", b.volts) or DASH, 20 * sc,
    s.battFailsafe and T.bad or T.ink, "left", true)
  c.text(x + w - pad, ly, cells and b.volts and string.format("%.2f V/cell", b.volts / cells) or "",
    11 * sc, T.ink2, "right")
  ly = ly + 20 * sc
  -- Rows in order of what a pilot flies by; a short card drops from the end.
  local bottom = y + h - 6 * sc
  local used = b.used and (b.capacity and b.capacity > 0 and string.format("%d / %d mAh", b.used, b.capacity)
    or string.format("%d mAh", b.used)) or DASH
  row(c, x, ly, w, "Used", used, sc)
  ly = ly + rowH(sc) - 4 * sc
  -- The level: the aircraft's percentage, else what is left of the capacity.
  -- A level needs no threshold, so it takes no status color.
  local pct = M.batteryPct(b)
  local barW = w - 2 * pad - 36 * sc
  local barH = max(4, floor(6 * sc))
  c.fill(x + pad, ly, barW, barH, T.surface2)
  if pct then
    c.fill(x + pad, ly, barW * min(pct, 100) / 100, barH, s.battFailsafe and T.bad or T.ink2)
  end
  c.text(x + w - pad, ly + barH / 2, pct and (pct .. "%") or DASH, 11 * sc, T.ink, "right")
  ly = ly + barH + 12 * sc
  -- Current and power share a row: they are read together, and a row
  -- each did not fit beside four lines of messages.
  if ly < bottom then
    local load = DASH
    if b.amps and b.volts then
      load = string.format("%.1f A  %d W", b.amps, floor(b.amps * b.volts + 0.5))
    end
    row(c, x, ly, w, "Load", load, sc)
    ly = ly + rowH(sc)
  end
  local b2 = s.battery[2]
  if b2.volts and ly < bottom then
    row(c, x, ly, w, "Battery 2", string.format("%.1f V  %.1f A", b2.volts, b2.amps or 0), sc)
    ly = ly + rowH(sc)
  end
  if tx and ly < bottom then
    row(c, x, ly, w, "Transmitter", tx.volts and string.format("%.1f V", tx.volts) or DASH, sc)
  end
end

local FIX = { [0] = "No GPS", "No fix", "2D", "3D", "DGPS", "RTK float", "RTK fixed" }

--- The position card: home distance, the fix, coordinates in `opts.coords`'s
--- format, altitude above sea level in `opts.units`.
function M.position(c, x, y, w, h, s, sc, opts)
  local u = opts.units
  local by = M.card(c, x, y, w, h, "Position", sc)
  local ly = by + 8 * sc
  local step = rowH(sc)
  local fits = function()
    return ly < y + h - 6 * sc
  end
  row(c, x, ly, w, "Home", s.homeDist and distance(s.homeDist, u.distance) or DASH, sc)
  ly = ly + step
  local gps = DASH
  if s.fix then
    gps = FIX[min(s.fix, 6)] .. (s.sats and ("  " .. s.sats .. " sats") or "")
  elseif s.sats then
    gps = s.sats .. " sats"
  end
  row(c, x, ly, w, "GPS", gps, sc)
  ly = ly + step
  if fits() then
    row(c, x, ly, w, "Alt MSL", s.altMsl and (units.formatDistance(s.altMsl, u.distance) .. " " .. units.distanceLabel(u.distance)) or DASH, sc)
    ly = ly + step
  end
  -- Latitude and longitude share a row, so a short tile shows both or
  -- neither: one without the other finds nothing.
  if fits() then
    -- No label: the pair is plainly coordinates and needs the full width,
    -- in smaller type where it is still too wide (degrees, minutes and
    -- seconds on a 480-wide screen).
    local text = s.lat and s.lon and units.formatCoords(s.lat, s.lon, opts.coords) or DASH
    local size = 12 * sc
    if c.textWidth(text, size) > w - 12 * sc then
      size = 10 * sc
    end
    c.text(x + w - 6 * sc, ly, text, size, T.ink, "right")
  end
end

--- The message log: newest first, colored by severity, each shortened to
--- the log's width. A message the aircraft repeats shows once, with a count.
--- A framed panel without a title: it runs the width of the screen and its
--- contents say what it is.
---
--- `skip`, given for the full-screen list, starts that many messages back
--- and adds a scroll bar where they do not all fit. Returns how many
--- messages there are (counted only with `skip`), how many lines fit, and
--- the line's height.
function M.messages(c, x, y, w, h, s, sc, skip)
  c.fill(x, y, w, h, T.surface)
  c.line(x, y, x + w - 1, y, T.line, 1)
  c.line(x, y + h - 1, x + w - 1, y + h - 1, T.line, 1)
  c.line(x, y, x, y + h - 1, T.line, 1)
  c.line(x + w - 1, y, x + w - 1, y + h - 1, T.line, 1)
  local pad = 6 * sc
  local size = 10 * sc
  local step = 14 * sc
  local ly = y + pad + step / 2
  local room = w - 2 * pad
  local fit = floor((h - 2 * pad - step / 2) / step) + 1
  local list = s.messages
  local shown, total = 0, 0
  if skip then
    for i = 1, #list do
      if list[i].severity < 7 then
        total = total + 1
      end
    end
    if total > fit then
      -- The bar takes the right edge.
      room = room - 6 * sc
      local track = h - 2 * pad
      local bw = max(2, floor(3 * sc))
      c.fill(x + w - pad / 2 - bw, y + pad + track * skip / total, bw, track * fit / total, T.lineStrong)
    end
  end
  local back = skip or 0
  for i = #list, 1, -1 do
    if shown >= fit then
      break
    end
    local m = list[i]
    if m.severity < 7 and back > 0 then
      back = back - 1
    elseif m.severity < 7 then
      local text = m.text
      local count = m.count and m.count > 1 and ("  (" .. m.count .. ")") or ""
      if c.textWidth(text .. count, size) > room then
        while #text > 4 and c.textWidth(text .. "..." .. count, size) > room do
          text = string.sub(text, 1, -2)
        end
        text = text .. "..."
      end
      c.text(x + pad, ly, text .. count, size, severityColor(m.severity), "left")
      ly = ly + step
      shown = shown + 1
    end
  end
  if shown == 0 then
    c.text(x + pad, ly, DASH, size, T.ink3, "left")
  end
  return total, fit, step
end

-- The status bar, after Lofty GCS's app bar (src/ui/shell/AppStatus.tsx).
-- The aircraft's state on the left: the GCS's status pill, and the flight
-- mode beside it, which a pilot reads with it. The radio's side on the
-- right: the GCS's link item (signal bars and a value) and the
-- transmitter's battery, which the GCS has no counterpart for. Battery and
-- GPS are left to the tiles. The bar is dark in both themes, so its colors
-- are the dark theme's, mixed as the GCS's stylesheet mixes them.

local WHITE = { 255, 255, 255 }

-- `t` of color a over b.
local function mix(a, b, t)
  return {
    floor(a[1] * t + b[1] * (1 - t) + 0.5),
    floor(a[2] * t + b[2] * (1 - t) + 0.5),
    floor(a[3] * t + b[3] * (1 - t) + 0.5),
  }
end

-- The bar's colors over its background (each theme's charcoal), kept.
local barColors = setmetatable({}, { __mode = "k" })
local function colorsOver(bg)
  local k = barColors[bg]
  if not k then
    local icon = mix(WHITE, bg, 0.72)
    k = {
      icon = icon,
      unlit = mix(icon, bg, 0.26),
      pill = {
        ok = mix(B.ok, bg, 0.34), warn = mix(B.warn, bg, 0.34), bad = mix(B.bad, bg, 0.4), idle = mix(WHITE, bg, 0.1),
      },
      dot = { ok = mix(B.ok, WHITE, 0.55), warn = mix(B.warn, WHITE, 0.55), bad = mix(B.bad, WHITE, 0.55), idle = WHITE },
    }
    barColors[bg] = k
  end
  return k
end

--- The status pill's word and tone: link, then failsafe, then armed, as the
--- GCS fuses them. Without prearm health, which neither CRSF nor
--- passthrough carries, a disarmed aircraft is "Disarmed", not "Ready".
function M.status(s, now, failsafe)
  if not s.lastFrame then
    return "No telemetry", "idle"
  elseif now and now - s.lastFrame > vehicle.LOST_S then
    return "Link lost", "bad"
  elseif failsafe then
    return "Failsafe", "bad"
  elseif s.armed == true then
    return "Armed", "ok"
  elseif s.armed == false then
    return "Disarmed", "idle"
  end
  return "Connected", "idle"
end

--- The level to show: the aircraft's percentage, else what is left of the
--- capacity it sent.
function M.batteryPct(b)
  if b.pct then
    return b.pct
  elseif b.used and b.capacity and b.capacity > 0 then
    return max(0, floor(100 - b.used * 100 / b.capacity + 0.5))
  end
end

-- The GCS's signal icon on its 20-unit grid, at `d` pixels square: four
-- bars, unlit ones faint so the shape still reads.
local function signalIcon(c, x, y, d, bars, lit, unlit)
  local k = d / 20
  for i = 0, 3 do
    local bh = (3.4 + i * 4) * k
    c.fill(x + (1.2 + i * 4.9) * k, y + 17 * k - bh, 3.3 * k, bh, bars and i < bars and lit or unlit)
  end
end

-- The pill's width, as wide as the longest word it shows beside the mode, so
-- the mode does not move as the word changes. Per canvas and size.
local pillWidths = setmetatable({}, { __mode = "k" })
local function pillWidth(c, size, sc)
  local bySize = pillWidths[c]
  if not bySize then
    bySize = {}
    pillWidths[c] = bySize
  end
  local wd = bySize[size]
  if not wd then
    wd = 0
    for _, t in ipairs({ "Connected", "Disarmed", "Link lost", "Failsafe" }) do
      wd = max(wd, c.textWidth(t, size, true))
    end
    wd = floor(wd + 26 * sc)
    bySize[size] = wd
  end
  return wd
end

--- The status bar. `tx` is the transmitter's battery ({volts}); `failsafe`
--- the HUD's failsafe text or nil; `now` the clock, for a lost link.
function M.bar(c, x, y, w, h, s, sc, tx, failsafe, now)
  local bg = T.charcoal
  c.fill(x, y, w, h, bg)
  local k = colorsOver(bg)
  local size = 12 * sc
  local mid = y + h / 2
  local lx = x + 8 * sc

  -- The pill: a dot and the word, centered in a fixed width.
  local word, tone = M.status(s, now, failsafe)
  local tw = c.textWidth(word, size, true)
  local ph = floor(h - 6 * sc)
  local pw = max(pillWidth(c, size, sc), floor(tw + 26 * sc))
  c.fill(lx, mid - ph / 2, pw, ph, k.pill[tone])
  local dot = max(4, floor(6 * sc))
  local dx = lx + (pw - (dot + 5 * sc + tw)) / 2
  c.fill(dx, mid - dot / 2, dot, dot, k.dot[tone])
  c.text(dx + dot + 5 * sc, mid, word, size, B.ink, "left", true)
  lx = lx + pw + floor(10 * sc)

  -- The radio's side, from the right: the transmitter's battery, then the
  -- link. Both are the radio's own readings, so they show before any
  -- telemetry, which tells a silent aircraft from a dead link.
  local rx = x + w - 8 * sc
  local volts = tx and tx.volts and string.format("%.1fV", tx.volts) or DASH
  c.text(rx, mid, volts, size, B.ink, "right")
  rx = rx - c.textWidth(volts, size) - 4 * sc
  c.text(rx, mid, "TX", 9 * sc, B.ink3, "right")
  rx = rx - c.textWidth("TX", 9 * sc) - floor(14 * sc)
  local lq = (s.link or {}).lq
  local link = lq and ("LQ " .. lq .. "%") or DASH
  c.text(rx, mid, link, size, B.ink, "right")
  rx = rx - c.textWidth(link, size) - floor(4 * sc)
  local d = floor(14 * sc)
  local bars = lq and (lq <= 0 and 0 or min(4, math.ceil(lq / 25)))
  signalIcon(c, rx - d, floor(mid - d / 2), d, bars, k.icon, k.unlit)
  rx = rx - d - floor(10 * sc)

  -- The mode needs an aircraft; shortened only where it would reach the
  -- link.
  if s.lastFrame then
    local mode = vehicle.modeName(s) or DASH
    while #mode > 3 and c.textWidth(mode, size) > rx - lx do
      mode = string.sub(mode, 1, -3) .. "."
    end
    c.text(lx, mid, mode, size, B.ink, "left")
  end
end

-- Sliders, for the devices' settings: three tracks, each with its knob, all
-- rectangles, which both radios fill without the gaps they leave between
-- triangles. Whole pixels, so the tracks sit evenly.
local KNOBS = { { 0.18, 0.62 }, { 0.5, 0.22 }, { 0.82, 0.48 } }
local function sliders(c, x, y, d, color)
  local t = max(2, floor(d * 0.07 + 0.5))
  local kw, kh = max(4, floor(d * 0.16 + 0.5)), max(8, floor(d * 0.3 + 0.5))
  for i = 1, 3 do
    local k = KNOBS[i]
    local cy = y + floor(d * k[1] + 0.5)
    c.fill(x, cy - floor(t / 2), d, t, color)
    c.fill(x + floor((d - kw) * k[2] + 0.5), cy - floor(kh / 2), kw, kh, color)
  end
end

--- The square button that opens the devices on the link.
function M.settings(c, x, y, size, sc)
  c.fill(x, y, size, size, T.surface2)
  c.line(x, y, x + size - 1, y, T.lineStrong, 1)
  c.line(x, y + size - 1, x + size - 1, y + size - 1, T.lineStrong, 1)
  c.line(x, y, x, y + size - 1, T.lineStrong, 1)
  c.line(x + size - 1, y, x + size - 1, y + size - 1, T.lineStrong, 1)
  local d = floor(min(size * 0.6, 36 * sc))
  sliders(c, x + floor((size - d) / 2), y + floor((size - d) / 2), d, T.ink2)
end

return M
