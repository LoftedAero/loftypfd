-- Home, when the aircraft does not say where it is.
--
-- Passthrough carries ArduPilot's own home distance and bearing; plain CRSF
-- carries neither. Then the radio keeps a home of its own the way ArduPilot
-- does: it follows the aircraft while disarmed and is fixed at arming. With
-- no armed state (plain CRSF without the disarmed star) the first position
-- seen stands, which is where a model is powered up.

local use = ...
local vehicle = use("vehicle")

local M = {}

local rad, deg, cos, sqrt, atan = math.rad, math.deg, math.cos, math.sqrt, math.atan

-- Meters per degree of latitude. A flat-earth distance is well within a
-- meter over any range a model flies.
local M_PER_DEG = 111320

--- Distance in meters and bearing in degrees from (lat1, lon1) to
--- (lat2, lon2).
function M.vector(lat1, lon1, lat2, lon2)
  local north = (lat2 - lat1) * M_PER_DEG
  local east = (lon2 - lon1) * M_PER_DEG * cos(rad((lat1 + lat2) / 2))
  -- atan with two arguments is the 5.3 and 5.4 form of atan2.
  return sqrt(north * north + east * east), deg(atan(east, north)) % 360
end

--- Updates the radio's home and, unless the aircraft is sending its own,
--- the home distance and bearing in state `s`.
function M.update(s)
  if vehicle.recent(s, "pt.home") or not s.lat or not s.lon then
    return
  end
  local h = s.radioHome
  if s.armed == false or (s.armed == nil and not h) then
    h = h or {}
    h.lat, h.lon = s.lat, s.lon
    s.radioHome = h
  elseif s.armed == true and not h then
    -- Armed before any position arrived: home is the first one.
    s.radioHome = { lat = s.lat, lon = s.lon }
    h = s.radioHome
  end
  if h then
    s.homeDist, s.homeBearing = M.vector(s.lat, s.lon, h.lat, h.lon)
  end
end

return M
