-- The HUD against a canvas that records what it is asked to draw.

local use, T = ...
local hud = use("hud")
local vehicle = use("vehicle")

local function canvas(w, h)
  local c = { w = w, h = h, texts = {}, tris = 0, fills = 0 }
  function c.fill()
    c.fills = c.fills + 1
  end
  function c.tri(x1, y1, x2, y2, x3, y3)
    for _, v in ipairs({ x1, y1, x2, y2, x3, y3 }) do
      assert(v == v, "NaN coordinate")
    end
    c.tris = c.tris + 1
  end
  function c.line() end
  function c.text(x, y, str, size, color, align, bold)
    assert(type(str) == "string", "text is a string")
    c.texts[#c.texts + 1] = str
  end
  function c.textWidth(str, size)
    return #str * size * 0.6
  end
  function c.has(str)
    for _, t in ipairs(c.texts) do
      if t == str then
        return true
      end
    end
    return false
  end
  return c
end

local function flying()
  local s = vehicle.new()
  s.roll, s.pitch, s.yaw = 25, -5, 93
  s.airspeed, s.groundspeed, s.climb, s.alt = 18.4, 21.2, 1.3, 87.4
  s.fix, s.sats, s.hdop = 3, 14, 0.8
  s.battery[1].volts, s.battery[1].amps, s.battery[1].pct = 15.9, 24.1, 61
  s.mavType, s.modeNumber, s.armed, s.throttle = 1, 5, true, 64
  s.link.lq, s.link.rssi = 99, -61
  s.lastFrame = 10
  return s
end

T.case("draws a flying aircraft at both radio sizes", function()
  for _, size in ipairs({ { 800, 480 }, { 480, 320 }, { 480, 272 } }) do
    local c = canvas(size[1], size[2])
    hud.paint(c, flying(), { now = 10 })
    T.ok(c.tris > 8, "horizon and symbols drawn")
    T.ok(c.has("FBWA"), "mode")
    T.ok(c.has("093"), "heading")
    T.ok(c.has("15.9V  24.1A  61%"), "battery")
    T.ok(c.has("+1.3 m/s"), "climb")
    T.ok(not c.has("DISARMED"), "armed")
  end
end)

T.case("no telemetry yet: dashes, no horizon, no claims", function()
  local c = canvas(480, 320)
  hud.paint(c, vehicle.new(), { now = 0 })
  -- the two tape value boxes and the heading chevron, nothing more
  T.eq(c.tris, 7, "no horizon or aircraft")
  T.ok(c.has("-"), "dashes")
  T.ok(not c.has("DISARMED"), "armed state not invented")
  T.ok(not c.has("Link lost"), "nothing lost yet")
end)

T.case("a lost link shows; messages stay in the log", function()
  local s = flying()
  vehicle.addMessage(s, "PreArm: Throttle below failsafe", 4, 9)
  local c = canvas(800, 480)
  hud.paint(c, s, { now = 11 })
  T.ok(not c.has("PreArm: Throttle below failsafe"), "not on the HUD")
  c = canvas(800, 480)
  hud.paint(c, s, { now = 20 })
  T.ok(c.has("Link lost"), "lost link")
end)

T.case("plain CRSF: satellites without a fix type", function()
  local s = flying()
  s.fix = nil
  local c = canvas(480, 320)
  hud.paint(c, s, { now = 10 })
  T.ok(c.has("14"), "sats")
  T.ok(not c.has("GPS"), "no fix guessed")
end)

T.case("feet and knots", function()
  local c = canvas(480, 320)
  hud.paint(c, flying(), { now = 10, units = { distance = "ft", speed = "kts", verticalSpeed = "follow" } })
  T.ok(c.has("287"), "altitude in feet")
  T.ok(c.has("+256 ft/min"), "climb in feet per minute")
end)

T.case("tape and compass ticks", function()
  local ticks = hud.tapeTicks(12, 15, 5)
  T.eq(ticks[1].value, 0, "first")
  T.eq(ticks[#ticks].value, 25, "last")
  T.ok(ticks[1].major, "0 is major")
  T.ok(not ticks[2].major, "5 is minor")
  local labels = {}
  for _, t in ipairs(hud.compassTicks(358, 48, 15)) do
    labels[#labels + 1] = t.label
  end
  T.eq(table.concat(labels, " "), "NW 330 345 N 15 30 NE", "around north")
  T.eq(hud.angleDelta(350, 10), 20, "wraps")
end)

-- Radios stop a draw call after about 20,000 Lua instructions. EdgeTX lays
-- out and draws in one refresh; Ethos lays out in wakeup, which has no such
-- limit, and replays a display list in paint. Each must leave room for the
-- platform's own drawing code and for what is still to come.
local function busy()
  local s = flying()
  s.roll, s.armed = 35, false
  vehicle.addMessage(s, "PreArm: Throttle below failsafe", 4, 9)
  return s
end

local function count(fn)
  local n = 0
  debug.sethook(function()
    n = n + 1
  end, "", 1)
  fn()
  debug.sethook()
  return n
end

T.case("EdgeTX: one frame drawn directly stays within budget", function()
  local noop = function() end
  local c = { w = 480, h = 320, fill = noop, tri = noop, line = noop, text = noop, shadowText = noop }
  function c.textWidth(str, size)
    return #str * size * 0.6
  end
  local n = count(function()
    hud.paint(c, busy(), { now = 10 })
  end)
  -- The core's share; EdgeTX's drawing code adds a few thousand more.
  T.ok(n < 10000, "a 480x320 frame took " .. n .. " instructions")
end)

T.case("Ethos: replaying a frame stays within paint's budget", function()
  local displaylist = use("displaylist")
  local rec = displaylist.recorder(function(str, size)
    return #str * size * 0.6
  end)
  rec.reset(800, 480)
  hud.paint(rec, busy(), { now = 10 })
  local noop = function() end
  local n = count(function()
    displaylist.replay(rec, { fill = noop, tri = noop, line = noop, text = noop })
  end)
  T.ok(n < 6000, "replaying 800x480 took " .. n .. " instructions")
end)

-- The convention every attitude indicator gets wrong once: in a right bank
-- (positive roll) the world tilts the other way, so the horizon's right end
-- is higher on the screen and the bank pointer swings left of center.
T.case("a right bank raises the horizon's right end", function()
  local lines, tris = {}, {}
  local noop = function() end
  local c = { w = 480, h = 320, fill = noop, text = noop }
  function c.line(x1, y1, x2, y2, color, width)
    lines[#lines + 1] = { x1, y1, x2, y2 }
  end
  function c.tri(x1, y1, x2, y2, x3, y3, color)
    tris[#tris + 1] = { x1, y1, x2, y2, x3, y3, color = color }
  end
  function c.textWidth(str, size)
    return #str * size * 0.6
  end
  local s = flying()
  s.roll, s.pitch = 30, 0
  hud.paint(c, s, { now = 10 })
  local horizon = lines[1]
  local leftY = horizon[1] < horizon[3] and horizon[2] or horizon[4]
  local rightY = horizon[1] < horizon[3] and horizon[4] or horizon[2]
  T.ok(rightY < leftY, "right end higher: left y " .. leftY .. ", right y " .. rightY)
  local pointer
  for _, t in ipairs(tris) do
    if t.color == hud.COLORS.amber and t[2] < 160 then
      pointer = t
      break
    end
  end
  T.ok(pointer and pointer[1] < 240, "bank pointer left of center")
end)
