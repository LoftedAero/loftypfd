-- The map (core/maps.lua) and the flight display's taps (core/flight.lua).

local use, T = ...
local maps = use("maps")
local flight = use("flight")
local vehicle = use("vehicle")

local INDEX = "# Lofty PFD maps\n"
  .. "satellite|Satellite|14|18|-35.3632|149.1652|Imagery \194\169 Esri, Maxar, Earthstar Geographics, and the GIS User Community\n"
  .. "street|Street|12|17|||\194\169 OpenStreetMap contributors\r\n"
  .. "not a layer\n"

local function canvas(w, h)
  local c = { w = w, h = h, texts = {}, images = {}, lines = 0, tris = 0 }
  function c.fill() end
  function c.tri()
    c.tris = c.tris + 1
  end
  function c.line(x1, y1, x2, y2)
    assert(x1 == x1 and y2 == y2, "NaN coordinate")
    c.lines = c.lines + 1
  end
  function c.text(x, y, str)
    c.texts[#c.texts + 1] = str
  end
  function c.textWidth(str, size)
    return #str * size * 0.6
  end
  function c.image(path, x, y, size)
    c.images[#c.images + 1] = { path = path, x = x, y = y, size = size }
  end
  function c.has(str)
    for _, t in ipairs(c.texts) do
      if t == str then
        return true
      end
    end
  end
  return c
end

local function aircraft()
  local s = vehicle.new()
  s.lat, s.lon, s.yaw = -35.3632, 149.1652, 30
  return s
end

-- The tile under a position, by the textbook formula, in doubles.
local function tileOf(lat, lon, z)
  local n = 2 ^ z
  local r = math.rad(lat)
  return math.floor((lon + 180) / 360 * n), math.floor((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n)
end

T.case("the index: Lofty GCS's layers, with the credit the fonts can draw", function()
  local layers = maps.parseIndex(INDEX)
  T.eq(#layers, 2, "two layers, the bad line skipped")
  T.eq(layers[1].id, "satellite", "id")
  T.eq(layers[1].minZoom, 14, "min zoom")
  T.eq(layers[1].maxZoom, 18, "max zoom")
  T.near(layers[1].lat, -35.3632, 1e-6, "center")
  T.eq(string.sub(layers[1].credit, 1, 15), "Imagery (c) Esr", "(c) for the sign no radio font has")
  T.eq(layers[2].lat, nil, "a layer without a center")
  T.eq(layers[2].credit, "(c) OpenStreetMap contributors", "CRLF")
  T.eq(#maps.parseIndex(nil), 0, "no index")
end)

T.case("the tile under the aircraft covers the middle of the map", function()
  local set = { layers = maps.parseIndex(INDEX), root = "maps/" }
  for _, z in ipairs({ 14, 17, 18 }) do
    local v = maps.newView()
    v.zoom = z
    local c = canvas(480, 320)
    maps.paint(c, 0, 24, 300, 200, aircraft(), 1, v, set)
    local tx, ty = tileOf(-35.3632, 149.1652, z)
    local want = "maps/satellite/" .. z .. "/" .. tx .. "/" .. ty .. ".jpg"
    local found
    for _, img in ipairs(c.images) do
      T.ok(not string.find(img.path, "%.0"), "whole tile numbers: " .. img.path)
      if img.path == want then
        found = img
      end
    end
    T.ok(found, "the center's tile at zoom " .. z)
    T.ok(found.x <= 150 and found.x + 256 > 150 and found.y <= 124 and found.y + 256 > 124, "under the center")
    -- Only what covers the map: at most two columns and two rows of 256 px
    -- over 300x200.
    T.ok(#c.images <= 4, #c.images .. " tiles for 300x200")
  end
end)

T.case("what the GCS's map draws: aircraft, trail, home, zoom, credit", function()
  local set = { layers = maps.parseIndex(INDEX), root = "maps/" }
  local v = maps.newView()
  local s = aircraft()
  maps.track(v, s)
  s.lat = s.lat + 0.0001
  maps.track(v, s)
  s.radioHome = { lat = -35.3632, lon = 149.1652 }
  local c = canvas(480, 320)
  local hits = maps.paint(c, 0, 24, 300, 200, s, 1, v, set)
  T.eq(c.tris, 2, "the arrow, as two triangles")
  T.ok(c.lines >= 1 + 5 + 4, "trail, house and the arrow's edge")
  T.ok(not c.has("Follow") and not c.has("Street"), "always following, satellite only")
  local credit
  for _, t in ipairs(c.texts) do
    if string.find(t, "^Imagery") then
      credit = t
    end
  end
  T.ok(credit and c.textWidth(credit, 9) <= 300, "the credit, shortened to fit")
  T.eq(#hits, 2, "zoom in and out")
  T.ok(hits[1][3] - hits[1][1] >= 44, "a finger wide")
  T.eq(hits[1][4], hits[2][2], "stacked")
end)

T.case("nothing to show: no map, or no position", function()
  local c = canvas(480, 320)
  maps.paint(c, 0, 24, 300, 200, aircraft(), 1, maps.newView(), { layers = {}, root = "maps/" })
  T.ok(c.has("No stored map") and #c.images == 0, "no index")
  local layers = maps.parseIndex(INDEX)
  layers[1].lat = nil
  c = canvas(480, 320)
  maps.paint(c, 0, 24, 300, 200, vehicle.new(), 1, maps.newView(), { layers = layers, root = "maps/" })
  T.ok(c.has("No position"), "no aircraft position and no stored center")
  c = canvas(480, 320)
  maps.paint(c, 0, 24, 300, 200, vehicle.new(), 1, maps.newView(), { layers = maps.parseIndex(INDEX), root = "maps/" })
  T.ok(#c.images > 0 and not c.has("No position"), "the stored area before any telemetry")
  c = canvas(480, 320)
  maps.paint(c, 0, 24, 300, 200, aircraft(), 1, maps.newView(), { layers = { layers[2] }, root = "maps/" })
  T.ok(c.has("No stored map"), "street tiles only: not the radio's layer")
end)

T.case("zoom stays within the stored levels; the map follows the aircraft", function()
  local layers = maps.parseIndex(INDEX)
  local v = maps.newView()
  for _ = 1, 5 do
    maps.zoom(v, layers, 1)
  end
  T.eq(v.zoom, 18, "the highest stored")
  for _ = 1, 9 do
    maps.zoom(v, layers, -1)
  end
  T.eq(v.zoom, 14, "the lowest stored")
  local s = aircraft()
  local lat, lon = maps.center(layers[1], s)
  T.ok(lat == s.lat and lon == s.lon, "centered on the aircraft")
  lat = maps.center(layers[1], vehicle.new())
  T.eq(lat, layers[1].lat, "on the stored area before a position")
end)

T.case("the trail: a point each few meters, a hundred and twenty kept, a new one per state", function()
  local v = maps.newView()
  local s = aircraft()
  maps.track(v, s)
  s.lat = s.lat + 0.00001 -- a meter
  maps.track(v, s)
  T.eq(#v.trail, 3, "one point: a meter is not enough")
  for i = 1, 200 do
    s.lat = s.lat + 0.0001
    maps.track(v, s)
  end
  T.eq(#v.trail, 120 * 3, "capped")
  maps.track(v, aircraft())
  T.eq(#v.trail, 3, "a new state starts over")
end)

T.case("a tap fills the screen; the button swaps HUD and map", function()
  local f = flight.new({ layers = maps.parseIndex(INDEX), root = "maps/" })
  local s = aircraft()
  local c = canvas(480, 320)
  f:paint(c, s, { now = 0, settings = true })
  local main, swap = f.hits.main, f.hits.swap
  local x, y = (main[1] + main[3]) / 2, (main[2] + main[4]) / 2
  T.ok(swap[1] >= main[1] and swap[3] <= main[3] and swap[2] >= main[2] and swap[4] <= main[4],
    "the swap button is on the HUD")
  T.eq(f:event("tap", swap[1] + 2, swap[2] + 2, 10), true, "the button")
  T.eq(f.view, "map", "swaps at once")
  T.ok(not f.full, "and fills nothing")
  f:paint(canvas(480, 320), s, { now = 10, settings = true })
  T.eq(f:event("tap", x, y, 11), true, "a tap on the map")
  T.ok(f.full and f.view == "map", "fills the screen with it")
  f:paint(canvas(480, 320), s, { now = 11 })
  T.eq(f.hits.gear, nil, "no settings button over a full screen")
  T.eq(f.hits.main[3], 480, "the whole width")
  T.ok(f.hits.swap, "the swap button stays")
  -- The map's controls answer and neither fill nor swap.
  local zoomIn = f.hits.map[1]
  f:event("tap", zoomIn[1] + 1, zoomIn[2] + 1, 13)
  T.ok(f.view == "map" and f.full and f.mapView.zoom == 18, "zoomed, still the full map")
  T.eq(f:event("prev", nil, nil, 14), true, "the rotary zooms the map")
  T.eq(f.mapView.zoom, 17, "out")
  T.eq(f:event("drag", 5, 5, 14), false, "a drag is not the map's")
  swap = f.hits.swap
  f:event("tap", swap[1] + 2, swap[2] + 2, 15)
  T.ok(f.view == "hud" and f.full, "swapped while full: the HUD fills the screen")
  f:event("tap", x, y, 16)
  T.ok(not f.full, "a tap goes back")
  f:paint(canvas(480, 320), s, { now = 16, settings = true })
  local gear = f.hits.gear
  T.eq(f:event("tap", gear[1] + 2, gear[2] + 2, 16), "browser", "the settings button")
  T.eq(f:event("next", nil, nil, 16), false, "the rotary is not the HUD's")
end)

T.case("a tap on the message log opens a full-screen list that scrolls", function()
  local f = flight.new({ layers = maps.parseIndex(INDEX), root = "maps/" })
  local s = aircraft()
  for i = 1, 40 do
    vehicle.addMessage(s, "msg " .. i, 6, i)
  end
  vehicle.addMessage(s, "debug", 7, 41)
  f:paint(canvas(480, 320), s, { now = 0, settings = true })
  local log = f.hits.log
  local x, y = log[1] + 20, (log[2] + log[4]) / 2
  T.ok(y > f.hits.main[4], "the log is below the main view")
  T.eq(f:event("tap", x, y, 10), true, "taken")
  T.ok(f.log, "a tap opens it")
  local c = canvas(480, 320)
  f:paint(c, s, { now = 13, settings = true })
  T.ok(c.has("msg 40") and c.has("msg 25"), "the newest, and many more lines")
  T.ok(not c.has("debug"), "no debug messages")
  T.eq(f.hits.main, nil, "no HUD underneath")
  T.eq(f.hits.gear, nil, "no settings button")
  T.eq(f.hits.logTotal, 40, "forty to scroll through")
  T.eq(f:event("next", nil, nil, 13), true, "the rotary scrolls")
  f:event("next", nil, nil, 13)
  c = canvas(480, 320)
  f:paint(c, s, { now = 13 })
  T.ok(c.has("msg 38") and not c.has("msg 39"), "two back")
  f:event("drag", 0, f.hits.logStep * 1.5, 13)
  T.eq(f.logSkip, 1, "a drag down shows newer, by whole lines")
  for _ = 1, 100 do
    f:event("next", nil, nil, 13)
  end
  T.eq(f.logSkip, 40 - f.hits.logFit, "stops at the oldest")
  f:event("tap", 100, 200, 14)
  T.ok(not f.log, "a tap closes it")
  f:paint(canvas(480, 320), s, { now = 15 })
  T.ok(f.hits.main and f.hits.log, "back to the flight display")
end)

T.case("a map frame stays well inside EdgeTX's budget, with a full trail", function()
  local set = { layers = maps.parseIndex(INDEX), root = "maps/" }
  local v = maps.newView()
  local s = aircraft()
  for i = 1, 150 do
    s.lat, s.lon = -35.3632 + 0.0003 * math.sin(i / 10), 149.1652 + 0.0003 * math.cos(i / 10)
    maps.track(v, s)
  end
  local c = canvas(480, 320)
  local n = 0
  debug.sethook(function()
    n = n + 1
  end, "", 1)
  maps.paint(c, 0, 24, 480, 296, s, 1, v, set)
  debug.sethook()
  -- The core's share; EdgeTX's drawing adds about as much again per line.
  T.ok(n < 6000, "a full-screen map with 120 trail points took " .. n .. " instructions")
end)

T.case("tiles load a few a frame, the rest drawn as ground meanwhile", function()
  local imagecache = use("imagecache")
  local loads = 0
  local cache = imagecache.new(function(path)
    loads = loads + 1
    return { path = path }
  end, 12, nil, 1)
  cache.frame()
  T.ok(cache.get("a") ~= nil, "the first loads")
  T.eq(cache.get("b"), nil, "the second waits")
  cache.frame()
  T.ok(cache.get("a") ~= nil and cache.get("b") ~= nil, "next frame: kept, and the next loaded")
  T.eq(cache.get("c"), nil, "one a frame")
  T.eq(loads, 2, "each loaded once")
end)
