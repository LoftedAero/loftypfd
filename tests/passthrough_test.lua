-- Words built by hand from ArduPilot's packing (AP_Frsky_SPort_Passthrough.cpp),
-- with the arithmetic in the comments so a reader can check the vectors.

local use, T = ...
local passthrough = use("passthrough")
local vehicle = use("vehicle")

local function shl(v, n)
  return v * 2 ^ n
end

T.case("attitude and range", function()
  local s = vehicle.new()
  -- roll +30: (3000 + 18000) * 0.05 = 1050; pitch -10: (-1000 + 9000) * 0.05 = 400
  passthrough.apply(s, 0x5006, 1050 + shl(400, 11), 0)
  T.near(s.roll, 30, 1e-9, "roll")
  T.near(s.pitch, -10, 1e-9, "pitch")
  T.eq(s.range, 0, "range")
end)

T.case("autopilot status", function()
  local s = vehicle.new()
  -- FBWA (5) sent as 6, flying, armed, throttle 100% = 63
  passthrough.apply(s, 0x5001, 6 + shl(1, 7) + shl(1, 8) + shl(63, 19), 0)
  T.eq(s.modeNumber, 5, "mode")
  T.eq(s.armed, true, "armed")
  T.eq(s.flying, true, "flying")
  T.eq(s.throttle, 100, "throttle")
  T.eq(s.failsafe, false, "failsafe")
  -- negative throttle: -50% is -31.5, truncated to -31: 31 with the sign at bit 6
  passthrough.apply(s, 0x5001, 6 + shl(31 + 64, 19), 0)
  T.eq(s.throttle, -49, "reverse throttle")
  T.eq(s.armed, false, "disarmed")
end)

T.case("mode name waits for the vehicle type", function()
  local s = vehicle.new()
  passthrough.apply(s, 0x5001, 19, 0) -- QHover (18) + 1
  T.eq(vehicle.modeName(s), nil, "no type yet")
  -- parameter 1, the frame type: MAV_TYPE 20 (VTOL quadrotor)
  passthrough.apply(s, 0x5007, shl(1, 24) + 20, 0)
  T.eq(s.mavType, 20, "type")
  T.eq(vehicle.modeName(s), "QHover", "name")
  T.ok(vehicle.isVtol(s), "VTOL mode")
end)

T.case("gps status", function()
  local s = vehicle.new()
  -- 12 sats, status 3 with advanced status 2 (RTK float), HDOP 0.8 (8 dm:
  -- 8 << 1 = 16), MSL 584.3 m = 5843 dm, sent as 58 * 100 (58 << 2 | 2 = 234)
  passthrough.apply(s, 0x5002, 12 + shl(3, 4) + shl(16, 6) + shl(2, 14) + shl(234, 22), 0)
  T.eq(s.sats, 12, "sats")
  T.eq(s.fix, 5, "fix")
  T.near(s.hdop, 0.8, 1e-9, "hdop")
  T.near(s.altMsl, 580, 1e-9, "msl")
end)

T.case("battery", function()
  local s = vehicle.new()
  -- 16.4 V = 164; 12.3 A = 123 dA, sent as 12 * 10 (12 << 1 | 1 = 25); 1234 mAh
  passthrough.apply(s, 0x5003, 164 + shl(25, 9) + shl(1234, 17), 0)
  T.near(s.battery[1].volts, 16.4, 1e-9, "volts")
  T.near(s.battery[1].amps, 12, 1e-9, "amps")
  T.eq(s.battery[1].used, 1234, "used")
  passthrough.apply(s, 0x5008, 82, 0)
  T.near(s.battery[2].volts, 8.2, 1e-9, "second pack")
end)

T.case("home", function()
  local s = vehicle.new()
  -- 1234 m sent as 123 * 10 (123 << 2 | 1 = 493); -12.3 m = -123 dm
  -- (123 << 2 = 492, sign at bit 12: 4588); bearing 90 = 30 * 3
  passthrough.apply(s, 0x5004, 493 + shl(4588, 12) + shl(30, 25), 0)
  T.eq(s.homeDist, 1230, "distance")
  T.near(s.alt, -12.3, 1e-9, "altitude")
  T.eq(s.homeBearing, 90, "bearing")
end)

T.case("velocity and yaw", function()
  local s = vehicle.new()
  -- climb -2.5 m/s = -25 dm/s (25 << 1 = 50, sign at bit 8: 306);
  -- speed 23.4 m/s sent as 23 * 10 (23 << 1 | 1 = 47); yaw 270 = 1350 * 0.2
  passthrough.apply(s, 0x5005, 306 + shl(47, 9) + shl(1350, 17), 0)
  T.near(s.climb, -2.5, 1e-9, "climb")
  T.near(s.speed, 23, 1e-9, "unlabeled speed")
  T.eq(s.airspeed, nil, "airspeed unknown")
  T.near(s.yaw, 270, 1e-9, "yaw")
  -- the airspeed flag (bit 28) splits the two speeds from then on:
  -- 4 m/s = 40 dm/s (40 << 1 = 80), 3 m/s = 30 dm/s (60)
  passthrough.apply(s, 0x5005, shl(80, 9) + shl(1, 28), 0)
  passthrough.apply(s, 0x5005, shl(60, 9), 0)
  T.near(s.airspeed, 4, 1e-9, "airspeed")
  T.near(s.groundspeed, 3, 1e-9, "groundspeed")
end)

T.case("latitude and longitude", function()
  local s = vehicle.new()
  -- -35.363261: 353632610 / 100 * 6 = 21217956, negative flag 0x40000000
  passthrough.apply(s, 0x0800, 21217956 + 0x40000000, 0)
  -- 149.165230: 1491652300 / 100 * 6 = 89499138, longitude flag 0x80000000
  passthrough.apply(s, 0x0800, 89499138 + 0x80000000, 0)
  T.near(s.lat, -35.363261, 1e-5, "lat")
  T.near(s.lon, 149.16523, 1e-5, "lon")
end)

T.case("a radio that hands over signed words", function()
  local s = vehicle.new()
  passthrough.apply(s, 0x0800, 89499138 + 0x80000000 - 2 ^ 32, 0)
  T.near(s.lon, 149.16523, 1e-5, "lon")
end)

local function chars(a, b, c, d)
  return shl(string.byte(a), 24) + shl(b and string.byte(b) or 0, 16) + shl(c and string.byte(c) or 0, 8) + (d and string.byte(d) or 0)
end

T.case("status text", function()
  local s = vehicle.new()
  local got
  s.onMessage = function(m)
    got = m
  end
  -- "Hi there", warning (4): two full words, then a word of zeros carrying
  -- the severity at bit 23. Each word arrives three times.
  for _, w in ipairs({ chars("H", "i", " ", "t"), chars("h", "e", "r", "e"), shl(1, 23) }) do
    for _ = 1, 3 do
      passthrough.apply(s, 0x5000, w, 7)
    end
  end
  T.eq(got and got.text, "Hi there", "text")
  T.eq(got.severity, 4, "severity")
  T.eq(got.time, 7, "time")
  -- "Arm", info (6): the severity rides in the character bytes' top bits
  passthrough.apply(s, 0x5000, chars("A", "r", "m") + shl(1, 23) + shl(1, 15), 8)
  T.eq(got.text, "Arm", "short text")
  T.eq(got.severity, 6, "short severity")
  T.eq(#s.messages, 2, "kept")
end)

T.case("unknown ids are ignored", function()
  local s = vehicle.new()
  T.eq(passthrough.apply(s, 0x0210, 5, 0), false, "handled")
  T.eq(s.lastFrame, nil, "not a frame from the aircraft")
end)
