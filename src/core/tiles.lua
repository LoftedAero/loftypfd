-- The tiles a pilot can put in the two slots beside the HUD.
--
-- Each tile draws itself into a rectangle. The order here is the order the
-- radios' settings list them in, and a setting stores a tile by its place
-- in this list, so new tiles go on the end.

local use = ...
local panels = use("panels")

local M = {}

M.LIST = {
  { key = "battery", name = "Battery", draw = function(c, x, y, w, h, s, sc, opts)
    panels.battery(c, x, y, w, h, s, sc, opts)
  end },
  { key = "position", name = "Position", draw = function(c, x, y, w, h, s, sc, opts)
    panels.position(c, x, y, w, h, s, sc, opts)
  end },
  -- For a pack with a voltage monitor and no current sensor.
  { key = "batteryVoltage", name = "Battery voltage", draw = function(c, x, y, w, h, s, sc, opts)
    panels.batteryVoltage(c, x, y, w, h, s, sc, opts)
  end },
  { key = "link", name = "Link", draw = function(c, x, y, w, h, s, sc)
    panels.link(c, x, y, w, h, s, sc)
  end },
  { key = "stats", name = "Stats", draw = function(c, x, y, w, h, s, sc, opts)
    panels.stats(c, x, y, w, h, s, sc, opts)
  end },
  -- The model's timers, which the platform reads only while this shows.
  { key = "timers", name = "Timers", draw = function(c, x, y, w, h, s, sc, opts)
    panels.timers(c, x, y, w, h, s, sc, opts)
  end },
}

--- The default for each slot, top first.
M.DEFAULT = { "battery", "position" }

local byKey = {}
for i, t in ipairs(M.LIST) do
  byKey[t.key] = t
  t.index = i
end

--- A tile by key, or by its place in the list (a radio setting's value).
function M.get(id)
  if type(id) == "number" then
    return M.LIST[id]
  end
  return byKey[id]
end

--- Whether either slot of `chosen` (keys or places) shows the tile `key`.
function M.shows(chosen, key)
  for i = 1, 2 do
    local t = M.get((chosen or M.DEFAULT)[i])
    if t and t.key == key then
      return true
    end
  end
  return false
end

--- The tiles' names, in list order, for a radio's choice field.
function M.names()
  local out = {}
  for i, t in ipairs(M.LIST) do
    out[i] = t.name
  end
  return out
end

return M
