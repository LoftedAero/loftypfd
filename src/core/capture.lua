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
--   <t> B, T, U <fields>             the platform's own measurements (src/ethos)
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
  return setmetatable({ write = write, lines = {}, written = nil, slow = { 0, 0 } }, Capture)
end

local function hex(d)
  local out = {}
  for i = 1, #d do
    out[i] = format("%02x", d[i])
  end
  return concat(out)
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
