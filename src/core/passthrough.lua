-- ArduPilot passthrough telemetry: 32-bit words keyed by a FrSky data ID.
--
-- The same words arrive over S.Port, F.Port and CRSF (ArduPilot's custom
-- frame), so this decoder serves all three. Layouts follow ArduPilot's
-- AP_Frsky_SPort_Passthrough.cpp, which is the only definition there is.

local use = ...
local bits = use("bits")
local vehicle = use("vehicle")

local field, flag, signed = bits.field, bits.flag, bits.signed

local M = {}

local POW10 = { [0] = 1, 10, 100, 1000 }

-- ArduPilot packs most numbers as a few significant digits times a power of
-- ten (prep_number). `digits` 2 or 3 and `power` 0-2 select the layout; the
-- sign bit sits above the digits.
local function num(w, offset, digits, power, isSigned)
  if digits == 2 and power == 0 then
    if isSigned then
      local v = field(w, offset, 6)
      return flag(w, offset + 6) and -v or v
    end
    return field(w, offset, 7)
  end
  local dbits = digits == 2 and 7 or 10
  local v = field(w, offset + power, dbits) * POW10[field(w, offset, power)]
  if isSigned and flag(w, offset + power + dbits) then
    v = -v
  end
  return v
end
M.num = num

local function battery(s, i, w)
  local b = s.battery[i]
  b.volts = field(w, 0, 9) / 10
  b.amps = num(w, 9, 2, 1, false) / 10
  b.used = field(w, 17, 15)
end

local HANDLERS = {
  [0x5001] = function(s, w)
    -- The mode is sent as custom_mode + 1 so that 0 can mean "none".
    local mode = field(w, 0, 5)
    s.modeNumber = mode > 0 and mode - 1 or nil
    s.flying = flag(w, 7)
    if not vehicle.recent(s, "crsf.armed") then
      s.armed = flag(w, 8)
    end
    s.battFailsafe = flag(w, 9)
    s.ekfFailsafe = flag(w, 10)
    s.failsafe = flag(w, 12)
    s.fencePresent = flag(w, 13)
    s.fenceBreach = flag(w, 14)
    -- Throttle is -100..100 scaled to -63..63.
    s.throttle = math.floor(num(w, 19, 2, 0, true) / 0.63 + 0.5)
    s.imuTemp = field(w, 26, 6) + 19
  end,

  [0x5002] = function(s, w)
    local status = field(w, 4, 2)
    -- 0-2 are NO_GPS, NO_FIX and 2D; 3 is a 3D fix, refined by the
    -- advanced status into DGPS and the RTK types, as GPS_FIX_TYPE numbers them.
    s.fix = status < 3 and status or 3 + field(w, 14, 2)
    s.hdop = num(w, 6, 2, 1, false) / 10
    -- CRSF's GPS frame has the count uncapped (this field stops at 15).
    if not vehicle.recent(s, "crsf.gps") then
      s.sats = field(w, 0, 4)
      s.altMsl = num(w, 22, 2, 2, true) / 10
    end
  end,

  [0x5003] = function(s, w)
    if not vehicle.recent(s, "crsf.battery") then
      battery(s, 1, w)
    end
  end,

  [0x5004] = function(s, w)
    s.homeDist = num(w, 0, 3, 2, false)
    if not vehicle.recent(s, "crsf.alt") then
      s.alt = num(w, 12, 3, 2, true) / 10
    end
    s.homeBearing = field(w, 25, 7) * 3
    -- The aircraft's own home outranks the radio's (core/home.lua).
    vehicle.mark(s, "pt.home")
  end,

  [0x5005] = function(s, w)
    if not vehicle.recent(s, "crsf.climb") then
      s.climb = num(w, 0, 2, 1, true) / 10
    end
    local speed = num(w, 9, 2, 1, false) / 10
    -- With FRSKY_OPTIONS bit 2 the aircraft alternates airspeed (flagged)
    -- and groundspeed; otherwise it sends airspeed when it has an estimate
    -- and groundspeed when not, with nothing saying which.
    if flag(w, 28) then
      s.speedsSplit = true
      s.airspeed = speed
    elseif s.speedsSplit then
      s.groundspeed = speed
    else
      s.speed = speed
    end
    if not vehicle.recent(s, "crsf.yaw") then
      s.yaw = field(w, 17, 11) * 0.2
    end
  end,

  [0x5006] = function(s, w)
    s.roll = field(w, 0, 11) * 0.2 - 180
    s.pitch = field(w, 11, 10) * 0.2 - 90
    s.range = num(w, 21, 3, 1, false) / 100
    vehicle.mark(s, "pt.attitude")
  end,

  [0x5007] = function(s, w)
    local id = field(w, 24, 8)
    local value = field(w, 0, 24)
    if id == 1 then
      s.mavType = value
    elseif id == 4 then
      s.battery[1].capacity = value
    elseif id == 5 then
      s.battery[2].capacity = value
    elseif id == 6 then
      s.features = value
    end
  end,

  [0x5008] = function(s, w)
    battery(s, 2, w)
  end,

  [0x500A] = function(s, w)
    s.rpm1 = signed(field(w, 0, 16), 16) * 10
    s.rpm2 = signed(field(w, 16, 16), 16) * 10
  end,

  [0x500B] = function(s, w)
    s.terrainHeight = num(w, 0, 3, 2, true) / 10
    s.terrainUnhealthy = flag(w, 13)
  end,

  [0x500C] = function(s, w)
    s.windDir = num(w, 0, 2, 0, false) * 3
    s.windSpeed = num(w, 7, 2, 1, false) / 10
  end,

  [0x500D] = function(s, w)
    s.wpIndex = field(w, 0, 11)
    s.wpDist = num(w, 11, 3, 2, false)
    s.wpBearing = field(w, 23, 7) * 3
  end,

  [0x0800] = function(s, w)
    if vehicle.recent(s, "crsf.gps") then
      return
    end
    -- Bit 31 says longitude, bit 30 negative; the rest is minutes * 10000.
    local deg = field(w, 0, 30) / 600000
    if flag(w, 30) then
      deg = -deg
    end
    if flag(w, 31) then
      s.lon = deg
    else
      s.lat = deg
    end
  end,
}

-- Status text arrives four 7-bit characters at a time, each word sent up to
-- three times. The message ends at a zero character, or at ArduPilot's 50
-- character limit, and its last word carries the severity in the top bit of
-- three of its bytes.
local TEXT_LIMIT = 50

local function text(s, w, now)
  local t = s.passthroughText
  if not t then
    t = { chars = {} }
    s.passthroughText = t
  end
  if w == t.last then
    return
  end
  t.last = w
  local done = false
  for shift = 24, 0, -8 do
    local c = field(w, shift, 7)
    if c == 0 then
      done = true
      break
    end
    t.chars[#t.chars + 1] = string.char(c)
  end
  if done or #t.chars >= TEXT_LIMIT then
    local severity = (flag(w, 23) and 4 or 0) + (flag(w, 15) and 2 or 0) + (flag(w, 7) and 1 or 0)
    local message = table.concat(t.chars)
    t.chars = {}
    if message ~= "" then
      vehicle.addMessage(s, message, severity, now)
    end
  end
end

--- Applies one passthrough word. Returns whether the ID was one of ArduPilot's.
function M.apply(s, appId, value, now)
  -- Radios hand the word over as a 32-bit integer that may read negative;
  -- the field readers mask it, so it is used as it comes.
  local handler = HANDLERS[appId]
  if appId ~= 0x5000 and not handler then
    return false
  end
  s.lastFrame = now
  s.passthrough = true
  if handler then
    handler(s, value)
  elseif not s.wholeText then
    text(s, value, now)
  end
  return true
end

return M
