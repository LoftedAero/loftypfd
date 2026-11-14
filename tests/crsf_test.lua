-- Frames built by hand from ArduPilot's encoders (AP_CRSF_Telem.cpp).

local use, T = ...
local crsf = use("crsf")
local vehicle = use("vehicle")

local function be16(v)
  if v < 0 then
    v = v + 65536
  end
  return math.floor(v / 256), v % 256
end

local function be32(v)
  if v < 0 then
    v = v + 2 ^ 32
  end
  return math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256, math.floor(v / 256) % 256, math.floor(v % 256)
end

local function cat(...)
  local out = {}
  for _, part in ipairs({ ... }) do
    if type(part) == "table" then
      for _, b in ipairs(part) do
        out[#out + 1] = b
      end
    else
      out[#out + 1] = part
    end
  end
  return out
end

T.case("attitude", function()
  local s = vehicle.new()
  -- pitch 10 deg = 1745, roll -30 deg = -5236, yaw -90 deg = -15708 (rad * 10000)
  local d = cat({ be16(1745) }, { be16(-5236) }, { be16(-15708) })
  T.ok(crsf.apply(s, 0x1E, d, 3), "handled")
  T.near(s.pitch, 10, 0.01, "pitch")
  T.near(s.roll, -30, 0.01, "roll")
  T.near(s.yaw, 270, 0.01, "yaw")
  T.eq(s.lastFrame, 3, "time")
end)

T.case("gps", function()
  local s = vehicle.new()
  -- 25 m/s is 900 (km/h * 10); course 180 is 18000; 584 m is 1584
  local d = cat({ be32(-353632610) }, { be32(1491652300) }, { be16(900) }, { be16(18000) }, { be16(1584) }, 10)
  crsf.apply(s, 0x02, d, 0)
  T.near(s.lat, -35.363261, 1e-7, "lat")
  T.near(s.lon, 149.16523, 1e-7, "lon")
  T.near(s.groundspeed, 25, 1e-9, "groundspeed")
  T.near(s.course, 180, 1e-9, "course")
  T.eq(s.altMsl, 584, "msl")
  T.eq(s.sats, 10, "sats")
  T.eq(s.fix, nil, "no fix type on plain CRSF")
end)

T.case("battery", function()
  local s = vehicle.new()
  crsf.apply(s, 0x08, cat({ be16(164) }, { be16(123) }, 0x00, 0x04, 0xD2, 75), 0)
  local b = s.battery[1]
  T.near(b.volts, 16.4, 1e-9, "volts")
  T.near(b.amps, 12.3, 1e-9, "amps")
  T.eq(b.used, 1234, "used")
  T.eq(b.pct, 75, "pct")
  -- no monitor, no capacity: nothing to show
  crsf.apply(s, 0x08, { 0, 0, 0, 0, 0, 0, 0, 0 }, 0)
  T.eq(b.volts, nil, "no volts")
  T.eq(b.pct, nil, "no pct")
end)

T.case("baro altitude and climb", function()
  local s = vehicle.new()
  -- 123.4 m = 1234 dm + 10000; 2 m/s packs as trunc(ln(200 / 100 + 1) / 0.026) = 42
  crsf.apply(s, 0x09, cat({ be16(11234) }, 42), 0)
  T.near(s.alt, 123.4, 1e-9, "alt")
  T.near(s.climb, 1.98, 0.02, "climb")
  -- 4000 m is past the decimeter range: whole meters with the top bit set
  crsf.apply(s, 0x09, cat({ be16(4000 + 0x8000) }, 256 - 42), 0)
  T.eq(s.alt, 4000, "high alt")
  T.near(s.climb, -1.98, 0.02, "sink")
end)

T.case("flight mode and the disarmed star", function()
  local s = vehicle.new()
  local function mode(name)
    local d = { string.byte(name, 1, -1) }
    d[#d + 1] = 0
    crsf.apply(s, 0x21, d, 0)
  end
  mode("FBWA")
  T.eq(vehicle.modeName(s), "FBWA", "name")
  T.eq(s.armed, nil, "armed unknown without the star option")
  mode("QHOV*")
  T.eq(vehicle.modeName(s), "QHover", "starred name")
  T.eq(s.armed, false, "disarmed")
  mode("QHOV")
  T.eq(s.armed, true, "armed once stars are known")
  T.ok(vehicle.isVtol(s), "VTOL")
  mode("RTL ")
  T.eq(vehicle.modeName(s), "RTL", "padded name")
end)

T.case("link statistics", function()
  local s = vehicle.new()
  -- antenna 1 active: its RSSI counts; SNR -5 is 251
  crsf.apply(s, 0x14, { 70, 55, 98, 251, 1, 5, 3, 60, 100, 8 }, 0)
  T.eq(s.link.rssi, -55, "rssi")
  T.eq(s.link.lq, 98, "lq")
  T.eq(s.link.snr, -5, "snr")
  T.eq(s.link.downRssi, -60, "down rssi")
  T.eq(s.link.rssi1, -70, "first antenna")
  T.eq(s.link.txPower, 100, "power step 3 is 100 mW")
  crsf.apply(s, 0x14, { 64, 0, 98, 10, 0, 5, 7, 60, 100, 8 }, 0)
  T.eq(s.link.rssi2, nil, "0 is no second antenna")
  T.eq(s.link.rssi, -64, "the first")
  T.eq(s.link.txPower, 250, "step 7 is 250 mW")
end)

T.case("ArduPilot's custom frame carries passthrough", function()
  local s = vehicle.new()
  -- 0x5006 roll +30 pitch -10 = 820250 = 0x000C841A, little-endian
  crsf.apply(s, 0x80, { 0xF0, 0x06, 0x50, 0x1A, 0x84, 0x0C, 0x00 }, 0)
  T.near(s.roll, 30, 1e-9, "single")
  T.ok(s.passthrough, "passthrough seen")
  -- two words: 0x5007 frame type 1 (plane), 0x5001 FBWA
  crsf.apply(s, 0x80, { 0xF2, 2, 0x07, 0x50, 0x01, 0x00, 0x00, 0x01, 0x01, 0x50, 0x06, 0x00, 0x00, 0x00 }, 0)
  T.eq(vehicle.modeName(s), "FBWA", "multi")
  -- legacy frame number, status text
  local d = { 0xF1, 3 }
  for _, b in ipairs({ string.byte(("PreArm: Throttle"), 1, -1) }) do
    d[#d + 1] = b
  end
  d[#d + 1] = 0
  crsf.apply(s, 0x7F, d, 0)
  T.eq(s.messages[1].text, "PreArm: Throttle", "text")
  T.eq(s.messages[1].severity, 3, "severity")
end)

T.case("status text over CRSF passthrough shows once", function()
  local s = vehicle.new()
  local d = { 0xF1, 6 }
  for _, b in ipairs({ string.byte(("Hi"), 1, -1) }) do
    d[#d + 1] = b
  end
  d[#d + 1] = 0
  crsf.apply(s, 0x80, d, 0)
  -- the same message as a passthrough word: "Hi", severity 6
  local w = 0x48 * 2 ^ 24 + 0x69 * 2 ^ 16 + 2 ^ 23 + 2 ^ 15
  crsf.apply(s, 0x80, { 0xF0, 0x00, 0x50, w % 256, (w // 256) % 256, (w // 65536) % 256, w // 16777216 }, 1)
  T.eq(#s.messages, 1, "one message")
  T.eq(s.messages[1].count, 1, "not counted twice")
end)

T.case("the faster source wins while it keeps arriving", function()
  local s = vehicle.new()
  local gps = cat({ be32(-353632610) }, { be32(1491652300) }, { be16(900) }, { be16(18000) }, { be16(1584) }, 10)
  crsf.apply(s, 0x02, gps, 10)
  -- a passthrough latitude of -35.0 (21000000 = 35 * 600000) that waited in the queue
  crsf.apply(s, 0x80, { 0xF0, 0x00, 0x08, 0x40, 0x6F, 0x40, 0x41 }, 11)
  T.near(s.lat, -35.363261, 1e-7, "CRSF position kept")
  crsf.apply(s, 0x80, { 0xF0, 0x00, 0x08, 0x40, 0x6F, 0x40, 0x41 }, 13)
  T.near(s.lat, -35, 1e-7, "passthrough once CRSF stops")
  -- the CRSF mode name is preferred over the slower status word
  local fbwa = { string.byte(("FBWA"), 1, -1) }
  fbwa[5] = 0
  crsf.apply(s, 0x21, fbwa, 14)
  crsf.apply(s, 0x80, { 0xF2, 2, 0x07, 0x50, 0x01, 0x00, 0x00, 0x01, 0x01, 0x50, 0x01, 0x00, 0x00, 0x00 }, 14.5)
  T.eq(vehicle.modeName(s), "FBWA", "CRSF name while fresh")
  crsf.apply(s, 0x80, { 0xF0, 0x01, 0x50, 0x01, 0x00, 0x00, 0x00 }, 17)
  T.eq(vehicle.modeName(s), "Manual", "number once the name goes stale")
end)

T.case("a truncated frame is skipped, not read past its end", function()
  local s = vehicle.new()
  T.eq(crsf.apply(s, 0x1E, { 1, 2, 3, 4, 5 }, 0), false, "short attitude")
  T.eq(s.roll, nil, "nothing decoded")
  crsf.apply(s, 0x80, { 0xF0, 0x06, 0x50 }, 0)
  crsf.apply(s, 0x80, { 0xF2, 3, 0x06, 0x50, 0x1A, 0x84, 0x0C, 0x00, 0x01 }, 0)
  T.near(s.roll, 30, 1e-9, "only the whole word of a cut multi-packet frame")
end)

T.case("device menu frames are not telemetry", function()
  local s = vehicle.new()
  T.eq(crsf.apply(s, 0x2B, { 0xEA, 0xC8, 1, 0 }, 0), false, "entry")
end)
