-- What the aircraft has told us.
--
-- Every reading starts as nil and stays nil until a frame carries it, so a
-- screen can draw a dash rather than a zero the aircraft never sent. Units
-- are SI and degrees throughout; conversion for display happens at the edge.

local use = ...
local modes = use("modes")

local M = {}

local MESSAGE_LIMIT = 64

--- A fresh state.
function M.new()
  return {
    -- Attitude, degrees. Yaw is 0-360 from north.
    roll = nil, pitch = nil, yaw = nil,
    -- Speeds in m/s. Passthrough sends one horizontal speed whose kind is
    -- unknown unless the aircraft alternates them (FRSKY_OPTIONS bit 2),
    -- so it lands in `speed` until airspeed and groundspeed can be told apart.
    airspeed = nil, groundspeed = nil, speed = nil, climb = nil,
    speedsSplit = nil,
    -- Altitude above home and above mean sea level, meters.
    alt = nil, altMsl = nil,
    -- GPS: fix uses MAVLink's GPS_FIX_TYPE numbering (0 no GPS, 1 no fix,
    -- 2 2D, 3 3D, 4 DGPS, 5 RTK float, 6 RTK fixed). Plain CRSF has no fix
    -- type, so there it stays nil.
    lat = nil, lon = nil, fix = nil, sats = nil, hdop = nil, course = nil,
    -- Home and the active waypoint: distance in meters, bearing in degrees
    -- from the aircraft.
    homeDist = nil, homeBearing = nil,
    -- The radio's own home, kept when the aircraft sends none (core/home.lua).
    radioHome = nil,
    wpIndex = nil, wpDist = nil, wpBearing = nil,
    -- Batteries by instance: volts, amps, used (mAh), pct, capacity (mAh).
    battery = { {}, {} },
    -- Mode: the number (passthrough) or the four-letter name (CRSF).
    mavType = nil, modeNumber = nil, modeShort = nil,
    armed = nil, flying = nil,
    failsafe = nil, battFailsafe = nil, ekfFailsafe = nil,
    fencePresent = nil, fenceBreach = nil,
    -- Throttle, percent; signed on vehicles that reverse.
    throttle = nil,
    imuTemp = nil,
    windDir = nil, windSpeed = nil,
    rpm1 = nil, rpm2 = nil,
    terrainHeight = nil, terrainUnhealthy = nil,
    range = nil,
    -- The radio link, from the receiver and transmitter rather than the
    -- aircraft: RSSI in dBm, LQ and SNR.
    link = {},
    -- Newest last: { text, severity, time }.
    messages = {},
    -- Called with each completed message, for alerts and voice.
    onMessage = nil,
    -- When anything last arrived, for detecting a lost link, and whether
    -- any of it was passthrough.
    lastFrame = nil,
    passthrough = nil,
    -- Passthrough's telemetry features word (MAVlite, scripting).
    features = nil,
    -- Whether CRSF flight modes carry ArduPilot's disarmed star, which is
    -- what makes `armed` known on plain CRSF.
    starsArmed = nil,
    -- When each source of a reading last delivered it (see M.recent).
    seen = {},
  }
end

-- ArduPilot sends standard CRSF frames alongside passthrough, so most
-- readings have two sources at different rates. The faster one is preferred
-- while it keeps arriving; otherwise a word that waited seconds in the
-- passthrough queue overwrites a fresh frame and the reading jumps back.
-- Rates measured in SITL: CRSF GPS and flight mode every 0.5 s, battery,
-- altitude, climb and attitude every 1 s; passthrough attitude every 0.35 s,
-- its status word (mode, armed) only every 3.4 s.
M.FRESH_S = 2

-- How long without a frame before the link counts as lost.
M.LOST_S = 3

--- Notes that a source just delivered a reading. `s.lastFrame` is the time
--- of the frame being applied.
function M.mark(s, key)
  s.seen[key] = s.lastFrame
end

--- Whether a source delivered a reading within the last couple of seconds.
function M.recent(s, key)
  local t = s.seen[key]
  return t ~= nil and s.lastFrame - t < M.FRESH_S
end

--- The flight mode's display name, or nil when none has arrived.
---
--- Both forms can be present. The CRSF name is preferred while it keeps
--- arriving (it updates seven times as often); otherwise the number, once the
--- vehicle type says which table it belongs to.
function M.modeName(s)
  if s.modeShort and M.recent(s, "crsf.mode") then
    return modes.fromShort(s.modeShort)
  end
  local name = modes.name(s.mavType, s.modeNumber)
  if name then
    return name
  end
  if s.modeShort then
    return modes.fromShort(s.modeShort)
  end
  return nil
end

--- Whether a quadplane is flying on its lift motors.
function M.isVtol(s)
  local name = M.modeName(s)
  return name ~= nil and modes.isVtol(name)
end

--- A pack's cell count, worked out from its voltage the first time one
--- arrives: a full LiPo cell is 4.2 V (4.35 for high-voltage packs), so the
--- count is the voltage over 4.35, rounded up. Right only above 4.35 (n-1)/n V
--- a cell (3.6 V for 6S), so the pilot can set it (core/options.lua).
function M.cells(b)
  if not b.cells and b.volts and b.volts > 0 then
    b.cells = math.max(1, math.ceil(b.volts / 4.35))
  end
  return b.cells
end

--- Records a status message from the aircraft.
---
--- ArduPilot repeats some messages every few seconds ("Bad or No Terrain
--- Data"). A repeat moves the earlier one to the newest place and counts it,
--- so the log is not filled by one message.
function M.addMessage(s, text, severity, now)
  local list = s.messages
  local count = 1
  for i = #list, 1, -1 do
    local m = list[i]
    if m.text == text and m.severity == severity then
      count = (m.count or 1) + 1
      table.remove(list, i)
      break
    end
  end
  local msg = { text = text, severity = severity, time = now, count = count }
  list[#list + 1] = msg
  if #list > MESSAGE_LIMIT then
    table.remove(list, 1)
  end
  if s.onMessage then
    s.onMessage(msg)
  end
end

return M
