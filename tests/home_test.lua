local use, T = ...
local home = use("home")
local vehicle = use("vehicle")
local passthrough = use("passthrough")

T.case("distance and bearing", function()
  -- 0.001 degrees of latitude north is 111.3 m; due east at 60 degrees of
  -- latitude a degree of longitude is half as long as one of latitude.
  local d, b = home.vector(0, 0, 0.001, 0)
  T.near(d, 111.32, 0.01, "north distance")
  T.near(b, 0, 1e-6, "north")
  d, b = home.vector(60, 0, 60, 0.002)
  T.near(d, 111.32, 0.1, "east distance at 60")
  T.near(b, 90, 1e-6, "east")
  _, b = home.vector(0, 0, -0.001, -0.001)
  T.near(b, 225, 1e-6, "southwest")
end)

T.case("home follows while disarmed and locks at arming", function()
  local s = vehicle.new()
  s.armed, s.lat, s.lon = false, -35.0, 149.0
  home.update(s)
  T.eq(s.homeDist, 0, "at home")
  s.lat = -35.001
  home.update(s)
  T.eq(s.homeDist, 0, "still at home: it follows while disarmed")
  s.armed = true
  s.lat = -35.002
  home.update(s)
  T.near(s.homeDist, 111.32, 0.01, "locked at arming")
  T.near(s.homeBearing, 0, 1e-6, "home is north")
end)

T.case("with no armed state the first position stands", function()
  local s = vehicle.new()
  s.lat, s.lon = -35.0, 149.0
  home.update(s)
  s.lat = -34.999
  home.update(s)
  T.near(s.homeDist, 111.32, 0.01, "first position kept")
  T.near(s.homeBearing, 180, 1e-6, "home is south")
end)

T.case("the aircraft's own home outranks the radio's", function()
  local s = vehicle.new()
  s.armed, s.lat, s.lon = true, -35.0, 149.0
  home.update(s)
  -- 0x5004: 1234 m sent as 123 * 10 (493), bearing 90 (30 * 3)
  passthrough.apply(s, 0x5004, 493 + 30 * 2 ^ 25, 5)
  s.lat = -34.9
  home.update(s)
  T.eq(s.homeDist, 1230, "aircraft's distance kept")
  T.eq(s.homeBearing, 90, "aircraft's bearing kept")
end)
