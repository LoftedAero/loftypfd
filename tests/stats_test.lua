-- A flight's statistics (core/stats.lua).

local use, T = ...
local stats = use("stats")
local vehicle = use("vehicle")

T.case("a flight's statistics start at arming and stay after disarming", function()
  local s = vehicle.new()
  s.armed, s.alt, s.link.lq = false, 3, 100
  stats.update(s, 10)
  T.eq(s.stats.time, nil, "no flight time while disarmed")
  T.eq(s.stats.alt, 3, "but the bench's altitude counts until arming")
  s.armed, s.alt = true, 0
  stats.update(s, 20)
  T.eq(s.stats.time, 0, "arming starts the time")
  T.eq(s.stats.alt, 0, "and the rest")
  s.alt, s.groundspeed, s.link.lq = 120, 22, 64
  stats.update(s, 80)
  s.alt, s.groundspeed, s.link.lq = 40, 15, 99
  stats.update(s, 140)
  T.eq(s.stats.time, 120, "two minutes")
  T.eq(s.stats.alt, 120, "highest")
  T.eq(s.stats.groundspeed, 22, "fastest")
  T.eq(s.stats.lq, 64, "lowest LQ")
  s.armed = false
  stats.update(s, 200)
  T.eq(s.stats.time, 120, "kept after disarming")
  s.armed = true
  stats.update(s, 300)
  T.eq(s.stats.time, 0, "the next flight starts again")
  T.eq(s.stats.alt, 40, "from what is now")
end)

T.case("armed unknown: no flight time, the rest from the start", function()
  local s = vehicle.new()
  s.alt = 12
  stats.update(s, 1)
  s.alt = 30
  stats.update(s, 5)
  T.eq(s.stats.time, nil, "no time")
  T.eq(s.stats.alt, 30, "highest")
  T.eq(s.stats.lq, nil, "no LQ sent, none kept")
end)
