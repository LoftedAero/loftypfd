-- Every arrangement at every radio size, with a busy state and an empty one.

local use, T = ...
local layout = use("layout")
local vehicle = use("vehicle")

local function canvas(w, h)
  local noop = function() end
  local c = { w = w, h = h, fill = noop, tri = noop, line = noop, texts = {} }
  function c.text(x, y, str)
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

local function busy()
  local s = vehicle.new()
  s.roll, s.pitch, s.yaw = 25, -5, 93
  s.airspeed, s.groundspeed, s.climb, s.alt, s.altMsl = 18.4, 21.2, 1.3, 87.4, 671.4
  s.fix, s.sats, s.hdop, s.lat, s.lon = 3, 14, 0.8, -35.363261, 149.16523
  s.homeDist, s.homeBearing = 1240, 200
  local b = s.battery[1]
  b.volts, b.amps, b.used, b.capacity = 15.9, 24.1, 1234, 5000
  s.mavType, s.modeNumber, s.armed, s.throttle, s.lastFrame = 1, 5, true, 64, 10
  s.link.lq = 99
  vehicle.addMessage(s, "EKF3 IMU0 is using GPS", 6, 8)
  vehicle.addMessage(s, "Bad or No Terrain Data", 2, 9)
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

T.case("draws a busy state and an empty one at every size", function()
  for _, size in ipairs({ { 800, 480 }, { 480, 320 }, { 480, 272 } }) do
    local c = canvas(size[1], size[2])
    layout.paint(c, busy(), { now = 10, tx = { volts = 8.1 } })
    T.ok(c.has("15.9 V"), "battery")
    T.ok(c.has("1234 / 5000 mAh"), "used")
    T.ok(c.has("3.98 V/cell"), "per cell")
    T.ok(c.has("1.24 km"), "home")
    T.ok(c.has("Bad or No Terrain Data"), "messages")
    T.ok(not c.has("Messages"), "the log has no title")
    T.ok(c.has("FBWA"), "mode in the bar")
    T.ok(c.has("8.1V"), "transmitter in the bar")
    layout.paint(canvas(size[1], size[2]), vehicle.new(), { now = 0 })
  end
end)

T.case("the pilot picks the tiles", function()
  local c = canvas(480, 320)
  layout.paint(c, busy(), { now = 10, tiles = { 2, 2 } })
  T.ok(not c.has("Battery"), "no battery tile")
  local positions = 0
  for _, t in ipairs(c.texts) do
    if t == "Position" then
      positions = positions + 1
    end
  end
  T.eq(positions, 2, "position in both slots")
  c = canvas(480, 320)
  layout.paint(c, busy(), { now = 10, tiles = { 99, "nonsense" } })
  T.ok(c.has("Battery") and c.has("Position"), "an unknown tile falls back to the default")
end)

T.case("a repeated message shows once, with a count", function()
  local s = busy()
  vehicle.addMessage(s, "Bad or No Terrain Data", 2, 11)
  vehicle.addMessage(s, "Bad or No Terrain Data", 2, 12)
  local c = canvas(800, 480)
  layout.paint(c, s, { now = 12 })
  T.ok(c.has("Bad or No Terrain Data  (3)"), "counted")
  T.eq(s.messages[#s.messages].count, 3, "kept newest")
end)

T.case("stays within EdgeTX's budget", function()
  local c = canvas(480, 320)
  c.shadowText = c.text
  local n = count(function()
    layout.paint(c, busy(), { now = 10, tx = { volts = 8.1 } })
  end)
  T.ok(n < 13000, "a 480x320 frame took " .. n .. " instructions")
end)

T.case("the settings button shows only where the widget can be operated", function()
  local c = canvas(480, 320)
  T.eq(layout.paint(c, busy(), { now = 10 }), nil, "no button")
  for _, size in ipairs({ { 480, 272 }, { 480, 320 }, { 800, 480 } }) do
    c = canvas(size[1], size[2])
    local a = layout.paint(c, busy(), { now = 10, settings = true })
    T.ok(a, "drawn, with its area")
    T.ok(a[3] == size[1] and a[4] == size[2], "at the bottom right")
    T.ok(a[3] - a[1] >= 44 and a[4] - a[2] >= 44, "a finger wide each way")
  end
end)

T.case("a theme is the pilot's choice, else the radio's", function()
  local palette = use("palette")
  T.eq(palette.pick(1, false), "light", "Radio, on a light radio")
  T.eq(palette.pick(1, true), "dark", "Radio, on a dark radio")
  T.eq(palette.pick(1, nil), "dark", "a radio that cannot say")
  T.eq(palette.pick(2, true), "light", "Light")
  T.eq(palette.pick(3, false), "dark", "Dark")
  T.ok(palette.isDark(38, 39, 43) and not palette.isDark(228, 238, 242), "EdgeTX backgrounds")
end)

T.case("light: light cards, the bar still a dark ground", function()
  local palette = use("palette")
  local theme = use("theme")
  palette.set("light")
  local c = canvas(480, 320)
  local fills, inks, icons = {}, {}, {}
  function c.fill(x, y, w, h, color)
    fills[color] = true
  end
  function c.text(x, y, str, size, color)
    inks[str] = color
  end
  function c.icon(name)
    icons[#icons + 1] = name
  end
  layout.paint(c, busy(), { now = 10, tx = { volts = 8.1 }, settings = true })
  palette.set("dark")
  T.ok(fills[theme.light.surface] and fills[theme.light.bg], "light cards on a light ground")
  T.ok(not fills[theme.dark.surface], "no dark cards")
  T.eq(inks["FBWA"], theme.dark.ink, "the bar's text is light on dark")
  T.eq(inks["15.9 V"], theme.light.ink, "a card's text is dark on light")
  T.eq(icons[1], "gear-light", "the gear for the theme")
end)

T.case("settings: defaults, and anything out of range is the default", function()
  local options = use("options")
  local set = options.resolve(function()
    return nil
  end)
  T.eq(set.tiles[1], 1, "Battery on top")
  T.eq(set.units.distance, "m", "meters")
  T.eq(set.units.speed, "ms", "m/s")
  T.eq(set.units.verticalSpeed, "follow", "climb follows distance")
  T.eq(set.coords, "decimal", "decimal degrees")
  T.eq(set.cells, nil, "cells worked out")
  local picks = { distance = 2, speed = 3, climb = 3, coords = 2, cells = 7, theme = 0 }
  set = options.resolve(function(o)
    return picks[o.key]
  end)
  T.eq(set.units.distance, "ft", "feet")
  T.eq(set.units.speed, "kts", "knots")
  T.eq(set.units.verticalSpeed, "fpm", "ft/min")
  T.eq(set.coords, "dms", "DMS")
  T.eq(set.cells, 6, "6S")
  T.eq(set.theme, 1, "0, as an option added later reads, is the default")
end)

T.case("coordinates in degrees, minutes and seconds", function()
  local units = use("units")
  T.eq(units.formatCoords(-35.363261, 149.16523, "dms"), "35\194\17621'47.7\"S 149\194\17609'54.8\"E", "south east")
  T.eq(units.formatCoords(51.4779, -0.0015, "dms"), "51\194\17628'40.4\"N 0\194\17600'05.4\"W", "north west")
  T.eq(units.formatCoords(0.9999999, 0, "dms"), "1\194\17600'00.0\"N 0\194\17600'00.0\"E", "carries up")
  T.eq(units.formatCoords(-35.363261, 149.16523, "decimal"), "-35.36326  149.16523", "decimal")
end)

T.case("the pilot's units, coordinates and cell count on screen", function()
  local options = use("options")
  local picks = { distance = 2, speed = 3, coords = 2, cells = 6 }
  local set = options.resolve(function(o)
    return picks[o.key]
  end)
  for _, size in ipairs({ { 800, 480 }, { 480, 320 }, { 480, 272 } }) do
    local c = canvas(size[1], size[2])
    local widths = {}
    local text = c.text
    -- by characters: the degree sign is two bytes
    function c.textWidth(str, sz)
      return #string.gsub(str, "\194\176", "o") * sz * 0.6
    end
    function c.text(x, y, str, sz)
      widths[str] = c.textWidth(str, sz)
      text(x, y, str)
    end
    layout.paint(c, busy(), {
      now = 10, tiles = { 1, 2 }, units = set.units, coords = set.coords, cells = set.cells,
    })
    T.ok(c.has("3.18 V/cell"), "15.9 V over the pilot's 5S")
    T.ok(c.has("4068 ft") or c.has("0.77 mi"), "home in feet")
    local dms = "35\194\17621'47.7\"S 149\194\17609'54.8\"E"
    T.ok(c.has(dms), "coordinates in DMS")
    T.ok(widths[dms] <= size[1] * 0.36 - 8, "and they fit the tile at " .. size[1])
  end
end)

T.case("the bar: Lofty GCS's status pill and link, with the mode", function()
  local panels = use("panels")
  local s = busy()
  T.eq(panels.status(vehicle.new(), 10), "No telemetry", "nothing heard yet")
  T.eq(panels.status(s, 20), "Link lost", "silent past the limit")
  T.eq(panels.status(s, 10, "EKF FAILSAFE"), "Failsafe", "a failsafe")
  T.eq(panels.status(s, 10), "Armed", "armed")
  s.armed = false
  T.eq(panels.status(s, 10), "Disarmed", "disarmed, not Ready: no prearm health over CRSF")
  s.armed = nil
  T.eq(panels.status(s, 10), "Connected", "armed state unknown")

  for _, size in ipairs({ { 800, 480 }, { 480, 320 }, { 480, 272 } }) do
    local c = canvas(size[1], size[2])
    local bar = {}
    local record = c.text
    function c.text(x, y, str, ...)
      if y <= 18 then
        bar[#bar + 1] = str
      end
      record(x, y, str, ...)
    end
    layout.paint(c, busy(), { now = 10, tx = { volts = 8.1 } })
    T.eq(table.concat(bar, "|"), "Armed|8.1V|TX|LQ 99%|FBWA", "pill, transmitter, link, mode at " .. size[1])
  end

  local c = canvas(480, 320)
  local bar = {}
  local record = c.text
  function c.text(x, y, str, ...)
    if y < 24 then
      bar[#bar + 1] = str
    end
    record(x, y, str, ...)
  end
  layout.paint(c, vehicle.new(), { now = 10, tx = { volts = 8.1 } })
  T.eq(table.concat(bar, "|"), "No telemetry|8.1V|TX|-", "before an aircraft: the radio's side, no mode")
end)
