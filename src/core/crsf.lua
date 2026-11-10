-- CRSF telemetry frames, as the radio hands them over: a frame type and its
-- payload bytes, without the sync byte, length or CRC.
--
-- Encodings follow ArduPilot's AP_CRSF_Telem.cpp, which sends them. Standard
-- frames are big-endian; ArduPilot's custom frame wraps passthrough words,
-- which are little-endian, as the flight controller holds them.

local use = ...
local bits = use("bits")
local passthrough = use("passthrough")
local vehicle = use("vehicle")

local u16be, i16be, u24be, i32be = bits.u16be, bits.i16be, bits.u24be, bits.i32be
local u16le, u32le = bits.u16le, bits.u32le

local M = {}

M.ADDRESS = {
  broadcast = 0x00,
  flightController = 0xC8,
  radio = 0xEA,
  receiver = 0xEC,
  transmitter = 0xEE,
}

M.TYPE = {
  gps = 0x02,
  vario = 0x07,
  battery = 0x08,
  baroVario = 0x09,
  linkStats = 0x14,
  attitude = 0x1E,
  flightMode = 0x21,
  devicePing = 0x28,
  deviceInfo = 0x29,
  entry = 0x2B,
  read = 0x2C,
  write = 0x2D,
  -- ArduPilot's custom frame, and the number it used before TBS reserved one.
  custom = 0x80,
  customLegacy = 0x7F,
}

local DEG = 180 / math.pi

-- What each standard frame means, as values in units. The frame handlers
-- below decode into these, and so does EdgeTX's sensor reader
-- (core/sensors.lua), since EdgeTX keeps these frames for itself and hands
-- Lua the radio's telemetry sensors instead: one meaning, two sources.
local set = {}
M.set = set

--- Attitude in radians.
function set.attitude(s, pitch, roll, yaw)
  if not vehicle.recent(s, "pt.attitude") then
    s.pitch = pitch * DEG
    s.roll = roll * DEG
  end
  s.yaw = (yaw * DEG) % 360
  vehicle.mark(s, "crsf.yaw")
end

--- Position in degrees, ground speed in m/s, course in degrees, altitude
--- above sea level in meters. ArduPilot sends 0, 0 until its first fix,
--- which is not a position.
function set.gps(s, lat, lon, groundspeed, course, altMsl, sats)
  if lat ~= 0 or lon ~= 0 then
    s.lat, s.lon = lat, lon
  end
  s.groundspeed = groundspeed
  s.course = course
  s.altMsl = altMsl
  s.sats = sats
  vehicle.mark(s, "crsf.gps")
end

--- Climb in m/s.
function set.vario(s, climb)
  s.climb = climb
  vehicle.mark(s, "crsf.climb")
end

--- The first battery: volts, amps, mAh used, percent left.
function set.battery(s, volts, amps, used, pct)
  local b = s.battery[1]
  -- A pack with no monitor reads 0 V, and with no capacity set it reads
  -- 0%; neither is a reading, so both stay empty.
  b.volts = volts > 0 and volts or nil
  b.amps = amps
  b.used = used
  b.pct = pct and pct > 0 and pct or nil
  vehicle.mark(s, "crsf.battery")
end

--- Altitude above home in meters, and climb in m/s when the frame has it.
function set.baro(s, alt, climb)
  s.alt = alt
  vehicle.mark(s, "crsf.alt")
  if climb then
    set.vario(s, climb)
  end
end

--- The flight mode's text, with ArduPilot's star when disarmed.
function set.flightMode(s, name)
  -- With RC_OPTIONS bit 12 ArduPilot marks a disarmed vehicle with a star.
  -- Without it nothing says, so armed stays unknown until a star is seen.
  if string.sub(name, -1) == "*" then
    name = string.sub(name, 1, -2)
    s.armed = false
    s.starsArmed = true
  elseif s.starsArmed then
    s.armed = true
  end
  if s.starsArmed then
    vehicle.mark(s, "crsf.armed")
  end
  s.modeShort = string.gsub(name, "%s+$", "")
  vehicle.mark(s, "crsf.mode")
end

local HANDLERS = {
  [0x1E] = function(s, d)
    set.attitude(s, i16be(d, 1) / 10000, i16be(d, 3) / 10000, i16be(d, 5) / 10000)
  end,

  [0x02] = function(s, d)
    -- Ground speed is km/h * 10, course centidegrees, altitude meters + 1000.
    set.gps(s, i32be(d, 1) / 1e7, i32be(d, 5) / 1e7, u16be(d, 9) / 36, u16be(d, 11) / 100,
      u16be(d, 13) - 1000, d[15])
  end,

  [0x07] = function(s, d)
    set.vario(s, i16be(d, 1) / 100)
  end,

  [0x08] = function(s, d)
    set.battery(s, u16be(d, 1) / 10, i16be(d, 3) / 10, u24be(d, 5), d[8])
  end,

  [0x09] = function(s, d)
    -- Altitude above home: decimeters offset by 10000, or with the top bit
    -- set, whole meters. Climb is logarithmic:
    -- |v| = 100 * (e^(0.026 * |n|) - 1) cm/s.
    local packed = u16be(d, 1)
    local alt = packed >= 0x8000 and packed - 0x8000 or (packed - 10000) / 10
    local n = bits.signed(d[3], 8)
    local cms = 100 * (math.exp(0.026 * math.abs(n)) - 1)
    set.baro(s, alt, (n < 0 and -cms or cms) / 100)
  end,

  [0x14] = function(s, d)
    local l = s.link
    -- Uplink RSSI is sent as -dBm for each antenna; the active one counts.
    l.rssi = -(d[5] == 1 and d[2] or d[1])
    l.lq = d[3]
    l.snr = bits.signed(d[4], 8)
    l.rfMode = d[6]
    l.txPower = d[7]
    l.downRssi = -d[8]
    l.downLq = d[9]
    l.downSnr = bits.signed(d[10], 8)
  end,

  [0x21] = function(s, d)
    set.flightMode(s, (bits.cstring(d, 1)))
  end,
}

-- The shortest payload each frame type can be; anything shorter is skipped
-- rather than read past its end.
local MIN_LENGTH = { [0x1E] = 6, [0x02] = 15, [0x07] = 2, [0x08] = 8, [0x09] = 3, [0x14] = 10, [0x21] = 1 }

local function custom(s, d, now)
  local sub = d[1]
  if sub == 0xF0 and #d >= 7 then
    passthrough.apply(s, u16le(d, 2), u32le(d, 4), now)
  elseif sub == 0xF2 and #d >= 2 then
    for k = 0, math.min(d[2], math.floor((#d - 2) / 6)) - 1 do
      local i = 3 + k * 6
      passthrough.apply(s, u16le(d, i), u32le(d, i + 2), now)
    end
  elseif sub == 0xF1 and #d >= 3 then
    -- ArduPilot also sends the message as passthrough words, seconds
    -- later; from here on those are ignored (core/passthrough.lua).
    s.wholeText = true
    vehicle.addMessage(s, bits.cstring(d, 3), d[2], now)
  end
end

--- Applies one telemetry frame. Returns whether it carried vehicle data;
--- device-menu frames are left to the device client.
function M.apply(s, frameType, d, now)
  if frameType == 0x80 or frameType == 0x7F then
    custom(s, d, now)
    return true
  end
  local handler = HANDLERS[frameType]
  if not handler or #d < MIN_LENGTH[frameType] then
    return false
  end
  s.lastFrame = now
  handler(s, d)
  return true
end

return M
