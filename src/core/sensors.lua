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

-- The sensors read, by EdgeTX 2.12's names, and where EdgeTX keeps each:
-- the CRSF frame type it came in (the sensor's id) and its place in that
-- frame (its instance). Those are the same in every version; the names are
-- not, since 2.11 calls the GPS and the baro altitude both "Alt", a model
-- keeps the names its sensors were discovered with, and a pilot can rename
-- any of them. So a sensor is found by where it is kept.
M.CRSF = {
  Ptch = { 0x1E, 0 }, Roll = { 0x1E, 1 }, Yaw = { 0x1E, 2 },
  GPS = { 0x02, 0 }, GSpd = { 0x02, 2 }, Hdg = { 0x02, 3 }, GAlt = { 0x02, 4 }, Sats = { 0x02, 5 },
  RxBt = { 0x08, 0 }, Curr = { 0x08, 1 }, Capa = { 0x08, 2 }, ["Bat%"] = { 0x08, 3 },
  Alt = { 0x09, 0 }, VSpd = { 0x07, 0 }, FM = { 0x21, 0 },
  ["1RSS"] = { 0x14, 0 }, ["2RSS"] = { 0x14, 1 }, RQly = { 0x14, 2 }, RSNR = { 0x14, 3 }, ANT = { 0x14, 4 },
}

local byPlace = {}
for name, at in pairs(M.CRSF) do
  byPlace[at[1] * 256 + at[2]] = name
end

--- The name a sensor is read by, from the table EdgeTX's model.getSensor
--- returns, or nil for one not read. Only a sensor the radio discovered has
--- an id and an instance.
function M.nameOf(sensor)
  if type(sensor) == "table" and sensor.id and sensor.instance then
    return byPlace[sensor.id * 256 + sensor.instance]
  end
end

-- The model's sensor list is read a few slots a call, and the whole list
-- again every few seconds, so a sensor discovered, renamed or deleted
-- meanwhile is followed.
local SLOTS_PER_CALL, RESCAN_S = 8, 3

local Finder = {}
Finder.__index = Finder

--- Finds the sensors read in a model's sensor list. `getSensor(slot)` and
--- `fieldInfo(name)` are EdgeTX's model.getSensor and getFieldInfo. `ids`
--- holds each name's source id for getSourceValue once a pass is complete.
function M.finder(getSensor, fieldInfo)
  local f = setmetatable({ getSensor = getSensor, fieldInfo = fieldInfo, ids = {}, next = 0 }, Finder)
  f:restart(0)
  return f
end

function Finder:restart(now)
  self.slot, self.found, self.seen, self.base, self.next = 0, {}, {}, nil, now
end

--- Reads the next few slots; call every cycle.
function Finder:step(now)
  if now < self.next then
    return
  end
  for _ = 1, SLOTS_PER_CALL do
    local slot = self.slot
    local sensor = self.getSensor(slot)
    if sensor == nil then
      -- Past the last slot. Sensor n's source id is the first sensor's plus
      -- 3n (value, minimum, maximum), so one id found by name gives all.
      local ids = {}
      if self.base then
        for name, n in pairs(self.found) do
          ids[name] = self.base + 3 * n
        end
      end
      self.ids = ids
      self:restart(now + RESCAN_S)
      return
    end
    local label = sensor.name
    if label and label ~= "" then
      -- A name finds the first sensor that has it, so only a name no earlier
      -- slot had finds this one; a field that is not a sensor has no unit.
      if not self.base and not self.seen[label] then
        local info = self.fieldInfo(label)
        if info and info.unit then
          self.base = info.id - 3 * slot
        end
      end
      self.seen[label] = true
      local name = M.nameOf(sensor)
      if name and not self.found[name] then
        self.found[name] = slot
      end
    end
    self.slot = slot + 1
  end
end

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
