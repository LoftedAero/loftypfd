-- The widget's screen: a status bar across the top, the HUD on the left with
-- two tiles in a column beside it, and the message log across the bottom.
--
-- The status bar is Lofty GCS's app bar band (mode, armed, link); the
-- column, its actions column beside what it relates to. The HUD shrinks to
-- make room: everything a pilot needs without swiping is on this screen.

local use = ...
local hud = use("hud")
local panels = use("panels")
local subcanvas = use("subcanvas")
local palette = use("palette")
local tiles = use("tiles")
local units = use("units")

local M = {}

local floor, max = math.floor, math.max
local T = palette.T

-- The bar carries mode, armed state and link, so the HUD draws none of its
-- corner readings.
local NO_CORNERS = {}

-- Lines in the message log.
local MESSAGE_LINES = 4

--- Draws the screen. `opts.tiles` names the tile in each slot, top first
--- (keys or places in core/tiles.lua's list); `opts.tx` is the
--- transmitter's battery ({volts}); `opts.units`, `opts.coords` and
--- `opts.cells` are the pilot's (core/options.lua); `opts.settings`, true where the widget
--- can be operated, adds the settings button at the bottom right, beside the
--- message log. Returns that button's area, {x1, y1, x2, y2}, when drawn.
function M.paint(c, s, opts)
  local w, h = c.w, c.h
  local u = opts.units or units.DEFAULT
  local sc = panels.scale(w, h)
  local gap = floor(4 * sc)
  local barH = floor(24 * sc)
  local msgH = floor(MESSAGE_LINES * 14 * sc + 12 * sc)
  local colW = floor(w * 0.36)
  local hudW = w - colW
  local bodyH = h - barH - msgH

  panels.bar(c, 0, 0, w, barH, s, sc, opts.tx, hud.failsafeText(s), opts.now)
  local hudOpts = { now = opts.now, units = u, corners = NO_CORNERS }
  if c.origin then
    -- The canvas offsets for itself (EdgeTX, where a wrapper's extra call
    -- per draw is a sixth of the frame budget); it is sized to the HUD's part
    -- while the HUD draws.
    c.origin(0, barH)
    c.w, c.h = hudW, bodyH
    hud.paint(c, s, hudOpts)
    c.origin(0, 0)
    c.w, c.h = w, h
  else
    hud.paint(subcanvas.new(c, 0, barH, hudW, bodyH), s, hudOpts)
  end

  c.fill(hudW, barH, colW, bodyH, T.bg)
  c.fill(0, h - msgH, w, msgH, T.bg)
  local chosen = opts.tiles or tiles.DEFAULT
  local slotH = floor((bodyH - gap) / 2)
  local tileOpts = { units = u, coords = opts.coords, cells = opts.cells }
  for i = 1, 2 do
    local tile = tiles.get(chosen[i]) or tiles.get(tiles.DEFAULT[i])
    local y = barH + gap + (i - 1) * slotH
    tile.draw(c, hudW + gap, y, colW - 2 * gap, slotH - gap, s, sc, tileOpts)
  end
  local logH = max(1, msgH - gap)
  local logW = w - 2 * gap
  local button
  if opts.settings then
    -- A square the log's height: a finger wide on every radio.
    local bx = w - gap - logH
    panels.settings(c, bx, h - msgH, logH, sc)
    button = { bx, h - msgH, w, h }
    logW = logW - logH - gap
  end
  panels.messages(c, gap, h - msgH, logW, logH, s, sc)
  return button
end

return M
