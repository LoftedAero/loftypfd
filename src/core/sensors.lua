-- Plain CRSF telemetry as EdgeTX hands it over: as the radio's telemetry
-- sensors, since the firmware keeps the standard frames for itself.
--
-- Names, units and precision are EdgeTX's (telemetry/crossfire.cpp and the
-- TR_SENSOR_* strings): attitude in radians, speeds in km/h, altitudes in
-- meters, GPS as a {lat, lon} table, the flight mode as its text with the
-- disarmed star. Each group goes through the same setters as the frames
-- (crsf.set), so the two sources mean the same thing.

local use = ...
local crsf = use("crsf")

local M = {}

M.NAMES = {
  "Ptch", "Roll", "Yaw",
  "GPS", "GSpd", "Hdg", "GAlt", "Sats",
  "RxBt", "Curr", "Capa", "Bat%",
  "Alt", "VSpd", "FM",
  "1RSS", "2RSS", "ANT", "RQly", "RSNR",
}

local set = crsf.set

--- Applies the sensors to state `s`. `read(name)` returns a sensor's value,
--- whether it is current (not timed out) and whether it is fresh (just
--- received), or nothing for a sensor that has never reported: EdgeTX's
--- getSourceValue. A group is applied while it is current; only a fresh one
--- counts as telemetry arriving, so a link that drops shows as lost even
--- while EdgeTX still holds the old values.
function M.apply(s, read, now)
  local arrived = false
  local function get(name)
    local v, current, fresh = read(name)
    if v ~= nil and current then
      if fresh then
        arrived = true
      end
      return v
    end
    return nil
  end

  local pitch, roll, yaw = get("Ptch"), get("Roll"), get("Yaw")
  if pitch and roll and yaw then
    set.attitude(s, pitch, roll, yaw)
  end

  local gps = get("GPS")
  if type(gps) == "table" and gps.lat and gps.lon then
    local speed = get("GSpd")
    set.gps(s, gps.lat, gps.lon, speed and speed / 3.6, get("Hdg"), get("GAlt"), get("Sats"))
  end

  local volts = get("RxBt")
  if volts then
    set.battery(s, volts, get("Curr"), get("Capa"), get("Bat%"))
  end

  local alt = get("Alt")
  if alt then
    set.baro(s, alt)
  end
  local climb = get("VSpd")
  if climb then
    set.vario(s, climb)
  end

  local mode = get("FM")
  if type(mode) == "string" and mode ~= "" then
    set.flightMode(s, mode)
  end

  -- EdgeTX keeps the receiver's RSSI per antenna; the active one counts.
  -- The value is in dBm, which some firmware reports as a positive number.
  local l = s.link
  local antenna = get("ANT")
  local rssi = antenna == 1 and get("2RSS") or get("1RSS")
  if rssi then
    l.rssi = rssi > 0 and -rssi or rssi
  end
  l.lq = get("RQly") or l.lq
  l.snr = get("RSNR") or l.snr

  if arrived then
    s.lastFrame = now
  end
  return arrived
end

return M
