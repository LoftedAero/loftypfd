-- The flight display's state and input: whether the HUD or the map shows,
-- whether it or the message log fills the screen, and the map's own view.
--
-- A tap on the HUD or the map has it fill everything below the status bar,
-- and another goes back; a tap on the message log opens it as a full-screen
-- list, which the rotary or a drag scrolls, and a tap closes it. A button on
-- the HUD or map swaps them (Eric's choice). Double taps were tried first:
-- on the X20 Ethos reads the touchscreen only between frames, 300 ms apart,
-- and never saw a finger lift between two quick taps.

local use = ...
local layout = use("layout")
local maps = use("maps")

local M = {}


local Flight = {}
Flight.__index = Flight

--- A flight display. `mapSet` is {layers, root} (core/maps.lua): the layers
--- in maps/index.txt and the folder the tiles are read from.
function M.new(mapSet)
  return setmetatable({
    view = "hud", full = false, mapView = maps.newView(), maps = mapSet, hits = {},
    log = false, logSkip = 0, logDrag = 0,
  }, Flight)
end

local function inside(r, x, y)
  return r and x >= r[1] and x < r[3] and y >= r[2] and y < r[4]
end

--- Follows the aircraft: the map's trail. Call every cycle.
function Flight:update(s, now)
  maps.track(self.mapView, s)
end

-- Scrolls the full log by `by` messages, older for positive, within what
-- the last paint had.
function Flight:scroll(by)
  local hits = self.hits
  local most = math.max(0, (hits.logTotal or 0) - (hits.logFit or 0))
  self.logSkip = math.max(0, math.min(most, self.logSkip + by))
end

--- Takes an input event (core/menu.lua's: "next", "prev", "enter", "back",
--- "tap" at x, y, "drag" by x, y). Returns "browser" when the settings
--- button was tapped, else whether the event was used.
function Flight:event(ev, x, y, now)
  local hits = self.hits
  if ev == "tap" then
    if inside(hits.gear, x, y) then
      return "browser"
    end
    if inside(hits.log, x, y) then
      self.log = not self.log
      self.logSkip, self.logDrag = 0, 0
      return true
    end
    if inside(hits.swap, x, y) then
      self.view = self.view == "map" and "hud" or "map"
      return true
    end
    if self.view == "map" and maps.tap(self.mapView, self.maps.layers, hits.map, x, y) then
      return true
    end
    if inside(hits.main, x, y) then
      self.full = not self.full
      return true
    end
    return false
  elseif self.log then
    if ev == "next" or ev == "prev" then
      self:scroll(ev == "next" and 1 or -1)
      return true
    elseif ev == "drag" then
      -- Whole lines; a finger moving down shows newer ones, as a list does.
      local step = hits.logStep or 1
      self.logDrag = self.logDrag - (y or 0)
      local by = (self.logDrag > 0 and math.floor or math.ceil)(self.logDrag / step)
      self.logDrag = self.logDrag - by * step
      self:scroll(by)
      return true
    end
  elseif self.view == "map" then
    if ev == "next" or ev == "prev" then
      maps.zoom(self.mapView, self.maps.layers, ev == "next" and 1 or -1)
      return true
    end
  end
  return false
end

--- Draws the screen (core/layout.lua's paint, with `opts` as there) and keeps
--- what can be tapped.
function Flight:paint(c, s, opts)
  opts.view, opts.full, opts.mapView, opts.maps = self.view, self.full, self.mapView, self.maps
  opts.log, opts.logSkip = self.log, self.logSkip
  self.hits = layout.paint(c, s, opts)
end

return M
