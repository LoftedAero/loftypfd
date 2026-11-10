-- Converting the aircraft's numbers to the pilot's units.
--
-- The same conventions and rounding as Lofty GCS (src/units.ts), so the radio
-- and the ground station show a value the same way. State stays SI; this is
-- only the way out to the screen.

local M = {}

local M_PER_FT = 0.3048
local SPEED = {
  ms = { per = 1, label = "m/s" },
  kmh = { per = 1 / 3.6, label = "km/h" },
  kts = { per = 1852 / 3600, label = "kts" },
  mph = { per = M_PER_FT * 5280 / 3600, label = "mph" },
}
local DISTANCE = {
  m = { per = 1, label = "m" },
  ft = { per = M_PER_FT, label = "ft" },
}

M.DEFAULT = { distance = "m", speed = "ms", verticalSpeed = "follow" }

function M.toSpeed(ms, unit)
  return ms / SPEED[unit].per
end

function M.speedLabel(unit)
  return SPEED[unit].label
end

function M.toDistance(m, unit)
  return m / DISTANCE[unit].per
end

function M.distanceLabel(unit)
  return DISTANCE[unit].label
end

--- "follow" is the aviation convention: feet per minute whenever distance is
--- in feet. The only place it is resolved.
function M.verticalSpeedUnit(units)
  if units.verticalSpeed ~= "follow" then
    return units.verticalSpeed
  end
  return units.distance == "ft" and "fpm" or "ms"
end

function M.toVerticalSpeed(ms, units)
  return M.verticalSpeedUnit(units) == "fpm" and ms / M_PER_FT * 60 or ms
end

function M.verticalSpeedLabel(units)
  return M.verticalSpeedUnit(units) == "fpm" and "ft/min" or "m/s"
end

--- A rounded string without "-0": an aircraft on the ground often reads a
--- hair under zero, and rounding keeps the sign.
function M.fixed(v, decimals)
  local s = string.format("%." .. decimals .. "f", v)
  if string.match(s, "^%-0%.?0*$") then
    s = string.sub(s, 2)
  end
  return s
end

--- Precision follows the unit: feet and knots drop the decimal that meters
--- keep, so nothing shows more precision than the sensor has.
function M.formatDistance(m, unit)
  local v = M.toDistance(m, unit)
  return M.fixed(v, (unit == "ft" or math.abs(v) >= 100) and 0 or 1)
end

function M.formatSpeed(ms, unit)
  return M.fixed(M.toSpeed(ms, unit), unit == "ms" and 1 or 0)
end

function M.formatVerticalSpeed(ms, units)
  return M.fixed(M.toVerticalSpeed(ms, units), M.verticalSpeedUnit(units) == "fpm" and 0 or 1)
end

-- One coordinate as degrees, minutes and seconds to a tenth (3 m), with its
-- hemisphere letter.
local function dms(v, pos, neg)
  local a = math.abs(v)
  local tenths = math.floor(a * 36000 + 0.5)
  local d = tenths // 36000
  local m = (tenths // 600) % 60
  local s = tenths % 600
  return string.format("%d\194\176%02d'%02d.%d\"%s", d, m, s // 10, s % 10, v < 0 and neg or pos)
end

--- Latitude and longitude as one string: "decimal" degrees to 1 m, or
--- "dms".
function M.formatCoords(lat, lon, format)
  if format == "dms" then
    return dms(lat, "N", "S") .. " " .. dms(lon, "E", "W")
  end
  return string.format("%.5f  %.5f", lat, lon)
end

--- How far apart a tape's labeled ticks sit, in the unit shown. A tape spans
--- seven steps, so the step follows the unit or a feet tape scrolls three
--- times too fast.
function M.tapeStep(kind, unit)
  if kind == "altitude" then
    return unit == "ft" and 25 or 10
  end
  if unit == "kmh" then
    return 20
  elseif unit == "kts" or unit == "mph" then
    return 10
  end
  return 5
end

return M
