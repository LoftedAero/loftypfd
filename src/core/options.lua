-- The widget's settings, as both radios' own widget-settings pages list them.
--
-- Each is a choice, which a radio stores as its place in `choices`, counting
-- from 1. EdgeTX keeps them by place in this list, so new ones go on the end.
-- Names, choices, order and defaults are Lofty GCS's Preferences (Units,
-- Appearance) wherever it has the same setting, so a pilot meets one set of
-- words in both.

local use = ...
local tiles = use("tiles")
local palette = use("palette")

local M = {}

local function cellChoices()
  local out = { "Automatic" }
  for n = 1, 14 do
    out[#out + 1] = n .. "S"
  end
  return out
end

M.LIST = {
  { key = "topTile", name = "Top tile", choices = tiles.names(), default = 1 },
  { key = "bottomTile", name = "Bottom tile", choices = tiles.names(), default = 2 },
  { key = "theme", name = "Theme", choices = palette.CHOICES, default = 1 },
  {
    key = "distance", name = "Distance and altitude", choices = { "Meters", "Feet" },
    values = { "m", "ft" }, default = 1,
  },
  {
    key = "speed", name = "Speed",
    choices = { "Meters per second", "Kilometers per hour", "Knots", "Miles per hour" },
    values = { "ms", "kmh", "kts", "mph" }, default = 1,
  },
  -- "Follow distance" is feet per minute with feet and meters per second
  -- with meters (core/units.lua). Lofty GCS adds the unit it resolves to;
  -- a radio's choice list is fixed text.
  {
    key = "climb", name = "Climb rate", choices = { "Follow distance", "Meters per second", "Feet per minute" },
    values = { "follow", "ms", "fpm" }, default = 1,
  },
  -- Lofty GCS has no such choice: it shows decimal degrees.
  {
    key = "coords", name = "Coordinates", choices = { "Decimal degrees", "Degrees, minutes, seconds" },
    values = { "decimal", "dms" }, default = 1,
  },
  -- Worked out from the first voltage unless set: that is wrong for a pack
  -- plugged in partly flat (core/vehicle.lua).
  { key = "cells", name = "Cell count", choices = cellChoices(), default = 1 },
}

--- The settings from what a radio stored, `get(option)` giving an option's
--- place in its choices; anything missing or out of range is the default,
--- as an option added since the widget was set up reads.
function M.resolve(get)
  local v = {}
  for _, o in ipairs(M.LIST) do
    local i = get(o)
    if type(i) ~= "number" or i < 1 or i > #o.choices then
      i = o.default
    end
    i = math.floor(i)
    v[o.key] = o.values and o.values[i] or i
  end
  return {
    tiles = { v.topTile, v.bottomTile },
    theme = v.theme,
    units = { distance = v.distance, speed = v.speed, verticalSpeed = v.climb },
    coords = v.coords,
    cells = v.cells > 1 and v.cells - 1 or nil,
  }
end

return M
