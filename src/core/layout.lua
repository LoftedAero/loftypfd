-- The widget's screen: a status bar across the top, the HUD or the map on the
-- left with two tiles in a column beside it, and the message log across the
-- bottom. Either the HUD, the map or the message log can fill everything
-- below the bar.
--
-- The status bar is after Lofty GCS's app bar; the column, its actions column
-- beside what it relates to. The HUD shrinks to make room: everything a pilot
-- needs without swiping is on this screen.

local use = ...
local hud = use("hud")
local maps = use("maps")
local panels = use("panels")
local subcanvas = use("subcanvas")
local palette = use("palette")
local tiles = use("tiles")
local units = use("units")

local M = {}

local floor, max = math.floor, math.max
local T = palette.T

-- The bar carries mode, armed state and link, and the tiles battery and GPS,
-- so the HUD draws none of its corner readings; filling the screen, it draws
-- the tiles' two.
local NO_CORNERS = {}
local FULL_CORNERS = { battery = true, gps = true }

-- Lines in the message log.
local MESSAGE_LINES = 4

-- The button that swaps the HUD and the map (Eric's choice, after double
-- tap proved impossible on the X20: Ethos reads the touchscreen only between
-- frames, 300 ms apart there, and never saw the finger lift between two
-- taps; a tap now fills the screen instead). It shows a small picture of the
-- view it opens, in that view's own colors (Eric's pick of three each): on
-- the HUD a map tile with a road, the trail and the aircraft's arrow, on the
-- map a level horizon with the aircraft symbol. Rectangles and two triangles,
-- on the status bar's charcoal, which is dark in both themes, as the HUD is.
local MAP_GROUND, MAP_ROAD = { 122, 118, 92 }, { 95, 95, 95 }

local function swapButton(c, x, y, b, view)
  c.fill(x, y, b, b, palette.BAR.charcoal, 0.8)
  local m = floor(b * 0.17)
  local s = b - 2 * m
  local x0, y0 = x + m, y + m
  if view == "hud" then
    local mc = maps.COLORS
    c.fill(x0, y0, s, s, MAP_GROUND)
    c.fill(x0 + floor(s * 0.68), y0, max(2, floor(s * 0.1)), s, MAP_ROAD)
    local t = max(1, floor(b * 0.05))
    c.fill(x0 + floor(s * 0.12), y0 + floor(s * 0.62), floor(s * 0.3), t, mc.trail)
    c.fill(x0 + floor(s * 0.12), y0 + floor(s * 0.62), t, floor(s * 0.25), mc.trail)
    -- The map's arrow, its "M0 -13 L9 11 L0 6 L-9 11" at this size.
    local cx, cy, k = x0 + floor(s * 0.42), y0 + floor(s * 0.45), s * 0.022
    c.tri(cx, cy - 13 * k, cx + 9 * k, cy + 11 * k, cx, cy + 6 * k, mc.vehicle)
    c.tri(cx, cy - 13 * k, cx, cy + 6 * k, cx - 9 * k, cy + 11 * k, mc.vehicle)
  else
    local hc = hud.COLORS
    local half = floor(s / 2)
    c.fill(x0, y0, s, half, hc.sky)
    c.fill(x0, y0 + half, s, s - half, hc.ground)
    c.fill(x0, y0 + half, s, max(1, floor(b * 0.04)), hc.ink)
    local t = max(2, floor(b * 0.07))
    local wy = y0 + half - floor(t / 2)
    local wing = floor(s * 0.22)
    c.fill(x0 + floor(s * 0.18), wy, wing, t, hc.amber)
    c.fill(x0 + floor(s * 0.6), wy, wing, t, hc.amber)
    c.fill(x0 + half - floor(t / 2), wy, t, t, hc.amber)
  end
end

--- Draws the screen. `opts.view` is "hud" (the default) or "map", and
--- `opts.full` has it fill everything below the bar, or `opts.log` the message
--- log, `opts.logSkip` messages back from the newest; `opts.mapView` and
--- `opts.maps` are the map's (core/maps.lua). `opts.tiles` names the tile in
--- each slot, top first (keys or places in core/tiles.lua's list); `opts.tx`
--- is the transmitter's battery ({volts}); `opts.units`, `opts.coords` and
--- `opts.cells` are the pilot's (core/options.lua); `opts.settings`, true
--- where the widget can be operated, adds the settings button at the bottom
--- right, beside the message log.
---
--- Returns what can be tapped: `main`, the HUD's or map's area, `swap`, the
--- button that swaps them, `gear`, the settings button's
--- when drawn, `map`, the map's controls, and `log`, the message log's; areas
--- are {x1, y1, x2, y2}. With the full log, also
--- `logTotal`, `logFit` and `logStep` (core/panels.lua's messages).
function M.paint(c, s, opts)
  local w, h = c.w, c.h
  local u = opts.units or units.DEFAULT
  local sc = panels.scale(w, h)
  local gap = floor(4 * sc)
  local barH = floor(24 * sc)
  local msgH = floor(MESSAGE_LINES * 14 * sc + 12 * sc)
  local colW = floor(w * 0.36)
  local full = opts.full
  local mainW = full and w or w - colW
  local mainH = full and h - barH or h - barH - msgH
  if opts.log then
    -- Neither the HUD nor the map: their cost is not spent on a hidden view.
    c.fill(0, barH, w, h - barH, T.bg)
    local lh = h - barH - 2 * gap
    local total, fit, step = panels.messages(c, gap, barH + gap, w - 2 * gap, lh, s, sc, opts.logSkip or 0)
    panels.bar(c, 0, 0, w, barH, s, sc, opts.tx, hud.failsafeText(s), opts.now)
    return { log = { 0, barH, w, h }, logTotal = total, logFit = fit, logStep = step }
  end
  local hits = { main = { 0, barH, mainW, barH + mainH } }

  -- First, so what reaches past its edges (the map's tiles) is drawn over.
  if opts.view == "map" then
    hits.map = maps.paint(c, 0, barH, mainW, mainH, s, sc, opts.mapView, opts.maps)
  else
    local hudOpts = { now = opts.now, units = u, corners = full and FULL_CORNERS or NO_CORNERS }
    if c.origin then
      -- The canvas offsets for itself (EdgeTX, where a wrapper's extra call
      -- per draw is a sixth of the frame budget); it is sized to the HUD's
      -- part while the HUD draws.
      c.origin(0, barH)
      c.w, c.h = mainW, mainH
      hud.paint(c, s, hudOpts)
      c.origin(0, 0)
      c.w, c.h = w, h
    else
      hud.paint(subcanvas.new(c, 0, barH, mainW, mainH), s, hudOpts)
    end
  end
  -- Top right of the HUD or map, below the HUD's heading ribbon and above its
  -- altitude tape, where neither draws anything.
  local sb = floor(32 * sc)
  local sx, sy = mainW - sb - floor(6 * sc), barH + floor(24 * sc) + floor(6 * sc)
  swapButton(c, sx, sy, sb, opts.view == "map" and "map" or "hud")
  hits.swap = { sx, sy, sx + sb, sy + sb }
  panels.bar(c, 0, 0, w, barH, s, sc, opts.tx, hud.failsafeText(s), opts.now)
  if full then
    return hits
  end

  local bodyH = mainH
  c.fill(mainW, barH, colW, bodyH, T.bg)
  c.fill(0, h - msgH, w, msgH, T.bg)
  local chosen = opts.tiles or tiles.DEFAULT
  local slotH = floor((bodyH - gap) / 2)
  local tileOpts = { units = u, coords = opts.coords, cells = opts.cells }
  for i = 1, 2 do
    local tile = tiles.get(chosen[i]) or tiles.get(tiles.DEFAULT[i])
    local y = barH + gap + (i - 1) * slotH
    tile.draw(c, mainW + gap, y, colW - 2 * gap, slotH - gap, s, sc, tileOpts)
  end
  local logH = max(1, msgH - gap)
  local logW = w - 2 * gap
  if opts.settings then
    -- A square the log's height: a finger wide on every radio.
    local bx = w - gap - logH
    panels.settings(c, bx, h - msgH, logH, sc)
    hits.gear = { bx, h - msgH, w, h }
    logW = logW - logH - gap
  end
  panels.messages(c, gap, h - msgH, logW, logH, s, sc)
  hits.log = { 0, h - msgH, gap + logW, h }
  return hits
end

return M
