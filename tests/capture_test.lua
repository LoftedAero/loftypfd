-- The capture a test build writes (core/capture.lua), and its replay.

local use, T = ...
local capture = use("capture")
local replay = use("replay")
local vehicle = use("vehicle")

local function opener(text)
  return function()
    local done = false
    return function()
      if done then
        return nil
      end
      done = true
      return text
    end
  end
end

T.case("a capture: frames, words, sends, and a second's summary", function()
  local out = {}
  local c = capture.new(function(text)
    out[#out + 1] = text
  end)
  c:header(0, "X20PRO 1.6.6")
  c:frame(0.5, 30, { 0x06, 0xd1, 0xeb, 0x8c, 0xc2, 0xa4 })
  c:sport(0.6, 0x5006, -2147483000)
  c:sent(0.7, 0x2C, { 0xC8, 0xEA, 1, 0 })
  T.eq(#out, 0, "kept until the second's write")
  local s = vehicle.new()
  s.roll, s.armed, s.mode = -30, false, nil
  s.link.lq = 99
  c:timing(0.012, 0.004)
  c:timing(0.008, 0.009)
  c:update(1, s, 7.5)
  T.eq(#out, 1, "one write")
  local text = out[1]
  T.ok(string.find(text, "0.000 H X20PRO 1.6.6\n", 1, true), "header")
  T.ok(string.find(text, "0.500 30 06d1eb8cc2a4\n", 1, true), "a CRSF frame in replay's form")
  T.ok(string.find(text, "0.600 S 20486 -2147483000\n", 1, true), "an S.Port word")
  T.ok(string.find(text, "0.700 P 44 c8ea0100\n", 1, true), "a frame sent")
  T.ok(string.find(text, "1.000 D -30.0 - - - - - - - 0\n", 1, true), "the radio's decoding, dashes for nothing")
  T.ok(string.find(text, "1.000 L 99 - 7.50\n", 1, true), "link")
  T.ok(string.find(text, "1.000 W 12.0 9.0 ", 1, true), "the slowest of each")
  c:update(1.5, s, 7.5)
  T.eq(#out, 1, "nothing more within the second")
end)

T.case("a capture plays back, S.Port words included", function()
  local s = vehicle.new()
  -- Passthrough attitude (0x5006): roll 10 and pitch 0, in fifths of a
  -- degree from -180 and -90.
  local text = "0.000 H X20PRO\n0.000 30 06d1eb8cc2a4\n0.100 S 20486 922550\n0.200 L 99 - 7.50\n"
  local p = replay.new(opener(text))
  p:update(s, 10)
  T.near(s.pitch, 10, 0.01, "the CRSF frame")
  p:update(s, 10.15)
  T.near(s.roll, 10, 0.01, "the S.Port word")
  T.ok(s.passthrough, "as passthrough")
end)

-- EdgeTX's sensors as a capture records them (Y lines), and decoded again as
-- tools/hwtest.py does: the same state as the radio's.
T.case("EdgeTX's sensors are recorded as they change, and play back", function()
  local sensors = use("sensors")
  local out = {}
  local c = capture.new(function(text)
    out[#out + 1] = text
  end)
  local values = {
    Ptch = { 0.1, true, true }, Roll = { -0.5, true, true }, Yaw = { 3.0, true, true },
    GPS = { { lat = -35.3632611, lon = 149.1652301 }, true, true }, GSpd = { 36, true, true },
    Hdg = { 90, true, true }, GAlt = { 600, true, true }, Sats = { 12, true, true },
    RxBt = { 12.6, true, true }, FM = { "FBWA *", true, true }, RQly = { 99, true, true },
  }
  local direct = vehicle.new()
  local function call(now)
    sensors.apply(direct, function(name)
      local v = values[name]
      if v then
        c:sensor(name, v[1], v[2], v[3])
        return v[1], v[2], v[3]
      end
    end, now)
    c:sensorsDone(now)
  end
  call(1)
  -- unchanged and none fresh: nothing to write
  for _, v in pairs(values) do
    v[3] = false
  end
  call(1.05)
  call(1.1)
  values.Roll = { -0.6, true, true }
  call(1.15)
  c:flush()
  local text = table.concat(out)
  local lines = {}
  for line in string.gmatch(text, "[^\n]+") do
    lines[#lines + 1] = line
  end
  T.eq(#lines, 3, "the first call, the one that cleared the fresh flags, and the change")
  T.ok(string.find(lines[1], "FM=sFBWA%20*/cf", 1, true), "a string's space escaped")
  T.ok(string.find(lines[1], "GPS=g-35.3632611,149.1652301/cf", 1, true), "the GPS as lat,lon")
  T.eq(lines[3], "1.150 Y Roll=n-0.6/cf", "only what changed")

  local reader = capture.sensorReader()
  local played = vehicle.new()
  for _, line in ipairs(lines) do
    local t, fields = string.match(line, "^(%S+) Y ?(.*)$")
    reader.apply(fields)
    sensors.apply(played, reader.read, tonumber(t))
  end
  for _, k in ipairs({ "roll", "pitch", "yaw", "lat", "lon", "groundspeed", "sats", "altMsl", "armed", "modeShort", "lastFrame" }) do
    T.eq(played[k], direct[k], k)
  end
  T.eq(played.battery[1].volts, direct.battery[1].volts, "volts")
  T.eq(played.link.lq, direct.link.lq, "link quality")
end)
