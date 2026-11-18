-- Records what the radio receives and sends, so a link can be checked on the
-- bench against the flight controller's own MAVLink (tools/hwtest.py).
--
-- Only a test build captures (tools/build.py --capture). A capture is lines
-- of "<seconds> <kind> <fields>". CRSF frames are in replay's form, so a
-- capture also plays back in the simulators:
--
--   <t> <frame type> <payload hex>   a CRSF frame received
--   <t> S <app ID> <value>           an S.Port passthrough word, decimal
--   <t> P <frame type> <payload hex> a CRSF frame the radio sent
--   <t> L <lq> <rssi> <tx volts>     the link sensors
--   <t> D <roll> <pitch> <yaw> <lat> <lon> <alt> <volts> <mode> <armed>
--                                    the radio's own decoding, each second,
--                                    spaces in the mode's name as "_"
--   <t> W <wakeup ms> <paint ms> <memory kB>
--                                    the slowest calls of the last second
--   <t> A <row> <clip or tone> ...   a voice callout or alert played
--   <t> H <text>                     the radio and its firmware
--   <t> Y <name>=<value>/<flags> ... the telemetry sensors EdgeTX gave
--                                    core/sensors.lua, those that changed
--   <t> B, T, U <fields>             the platform's own measurements (src/ethos)
--   <t> G <percent>                  EdgeTX's busiest refresh this second
--                                    (getUsage)
--
-- A value the radio does not have is "-". Lines are kept and written a
-- second at a time: the platform's writer opens, appends and closes, so a
-- capture survives the radio being switched off.

local use = ...
local vehicle = use("vehicle")

local M = {}

local format, concat = string.format, table.concat

-- Seconds between writes, and between the D, L and W lines.
local EVERY_S = 1

local Capture = {}
Capture.__index = Capture

--- A capture appending through `write(text)`.
function M.new(write)
  return setmetatable({ write = write, lines = {}, written = nil, slow = { 0, 0 },
    sensorsLast = {}, sensorParts = {}, sensorFresh = false }, Capture)
end

-- A frame's bytes as hex in one format call: byte by byte cost EdgeTX's
-- capture build a sixth of its instruction limit in a burst of frames.
local HEX = {}

local function hex(d)
  local n = #d
  local pattern = HEX[n]
  if not pattern then
    pattern = string.rep("%02x", n)
    HEX[n] = pattern
  end
  return format(pattern, table.unpack(d, 1, n))
end

local function add(self, line)
  local lines = self.lines
  lines[#lines + 1] = line
end

local function num(v, digits)
  if v == nil then
    return "-"
  end
  return format("%." .. digits .. "f", v)
end

--- A CRSF frame received: its type and the payload as the radio gave it.
function Capture:frame(t, frameType, d)
  add(self, format("%.3f %d %s\n", t, frameType, hex(d)))
end

--- A CRSF frame the radio sent.
function Capture:sent(t, frameType, d)
  add(self, format("%.3f P %d %s\n", t, frameType, hex(d)))
end

--- An S.Port passthrough word.
function Capture:sport(t, appId, value)
  add(self, format("%.3f S %d %d\n", t, appId, value))
end

-- A sensor value as text: "n" and a number, "g" and the GPS's "lat,lon", or
-- "s" and a string with its spaces and separators as %xx; "-" for none.
local function escape(c)
  return format("%%%02x", string.byte(c))
end

local function encode(v)
  local t = type(v)
  if t == "number" then
    return "n" .. format("%.7g", v)
  elseif t == "table" and v.lat and v.lon then
    return "g" .. format("%.7f,%.7f", v.lat, v.lon)
  elseif t == "string" then
    return "s" .. string.gsub(v, "[%s%%/=]", escape)
  end
  return "-"
end

--- One sensor as core/sensors.lua read it: what getSourceValue returned.
--- Called from the read itself, so an unchanged sensor costs a comparison.
function Capture:sensor(name, v, current, fresh)
  if fresh then
    self.sensorFresh = true
  end
  local last = self.sensorsLast
  local was = last[name]
  if was and was[1] == v and was[2] == current and was[3] == fresh then
    return
  end
  local text = name .. "=" .. encode(v) .. "/" .. (current and "c" or "") .. (fresh and "f" or "")
  if not was then
    was = {}
    last[name] = was
  end
  was[1], was[2], was[3] = v, current, fresh
  -- The GPS is a new table each read, so it is compared as text.
  if was.text ~= text then
    was.text = text
    local parts = self.sensorParts
    parts[#parts + 1] = text
  end
end

--- After a call's reads: a Y line of the sensors that changed. A call with
--- any fresh is written even when none changed, since a fresh value is what
--- tells the link is alive.
function Capture:sensorsDone(t)
  local parts = self.sensorParts
  if #parts > 0 then
    add(self, format("%.3f Y %s\n", t, concat(parts, " ")))
    self.sensorParts = {}
  elseif self.sensorFresh then
    add(self, format("%.3f Y\n", t))
  end
  self.sensorFresh = false
end

local function unescape(h)
  return string.char(tonumber(h, 16))
end

local function decodeValue(text)
  local tag, rest = string.sub(text, 1, 1), string.sub(text, 2)
  if tag == "n" then
    return tonumber(rest)
  elseif tag == "g" then
    local lat, lon = string.match(rest, "^([^,]+),(.+)$")
    return { lat = tonumber(lat), lon = tonumber(lon) }
  elseif tag == "s" then
    return (string.gsub(rest, "%%(%x%x)", unescape))
  end
  return nil
end

--- Plays Y lines back: `apply(fields)` takes a line's text after the "Y"
--- and updates what is held; `read(name)` answers as getSourceValue did,
--- for core/sensors.lua.
function M.sensorReader()
  local held = {}
  local r = {}
  function r.apply(fields)
    for item in string.gmatch(fields or "", "%S+") do
      local name, value, flags = string.match(item, "^(.-)=([^/]*)/(%a*)$")
      if name then
        held[name] = { decodeValue(value), string.find(flags, "c", 1, true) ~= nil,
          string.find(flags, "f", 1, true) ~= nil }
      end
    end
  end
  function r.read(name)
    local h = held[name]
    if h then
      return h[1], h[2], h[3]
    end
  end
  return r
end

--- A callout played (core/callouts.lua): its row, then each clip, number
--- or tone.
function Capture:callout(t, item)
  local parts = { format("%.3f A %s", t, item.id) }
  for _, part in ipairs(item.say or {}) do
    parts[#parts + 1] = type(part) == "table" and (part[1] .. part[2]) or part
  end
  if item.tone then
    parts[#parts + 1] = "tone-" .. item.tone
  end
  add(self, concat(parts, " ") .. "\n")
end

--- A line of the platform's own, for measurements a test build takes.
function Capture:line(t, kind, text)
  add(self, format("%.3f %s %s\n", t, kind, text))
end

--- The radio and its firmware, once.
function Capture:header(t, text)
  add(self, format("%.3f H %s\n", t, text))
end

--- The slowest wakeup and paint so far this second, in seconds.
function Capture:timing(wakeup, paint)
  local slow = self.slow
  if wakeup and wakeup > slow[1] then
    slow[1] = wakeup
  end
  if paint and paint > slow[2] then
    slow[2] = paint
  end
end

--- Once a second: the radio's own decoding of `s`, its link sensors
--- (`s.link`), the transmitter's battery `tx` in volts and the timings; then
--- everything kept is written. Call every cycle.
function Capture:update(t, s, tx)
  if self.written and t - self.written < EVERY_S then
    return
  end
  self.written = t
  local b = s.battery and s.battery[1] or {}
  local armed = s.armed == nil and "-" or (s.armed and "1" or "0")
  local mode = string.gsub(vehicle.modeName(s) or "-", " ", "_")
  add(self, format("%.3f D %s %s %s %s %s %s %s %s %s\n", t, num(s.roll, 1), num(s.pitch, 1), num(s.yaw, 1),
    num(s.lat, 7), num(s.lon, 7), num(s.alt, 1), num(b.volts, 2), mode, armed))
  local l = s.link or {}
  add(self, format("%.3f L %s %s %s\n", t, num(l.lq, 0), num(l.rssi, 0), num(tx, 2)))
  local slow = self.slow
  add(self, format("%.3f W %.1f %.1f %.0f\n", t, slow[1] * 1000, slow[2] * 1000, collectgarbage("count")))
  slow[1], slow[2] = 0, 0
  self:flush()
end

--- Writes everything kept.
function Capture:flush()
  if #self.lines > 0 then
    self.write(concat(self.lines))
    self.lines = {}
  end
end

return M
