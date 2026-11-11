-- The map: stored tiles under the aircraft, after Lofty GCS's Fly map
-- (src/ui/tabs/flight/MapView.tsx).
--
-- Tiles are Lofty GCS's offline maps, copied to the radio by its "Copy to
-- radio" (src/services/radio-maps.ts there): maps/index.txt names the layers
-- and maps/<layer>/<z>/<x>/<y>.jpg holds 256 px Web Mercator tiles. The map is
-- north up at whole zoom levels, the tiles drawn at their own size.
--
-- What is drawn is the GCS's: the aircraft as an orange arrow along its
-- heading, a blue trail, home as a green outlined house, zoom buttons and the
-- imagery's credit, which its terms keep on screen. The overlays' colors are
-- the GCS's literals: they sit on imagery, which no theme reaches.
--
-- Satellite only, always following the aircraft (Eric's choice): a pilot
-- glancing at a radio wants the aircraft over the ground, not a map to
-- browse. So there is no layer switch, no Follow and no panning, and the zoom
-- buttons are a finger wide.
--
-- EdgeTX has single-precision floats, which hold a world pixel at zoom 18 only
-- to a few pixels. Everything is placed by its difference from the view's
-- center, in degrees and in Mercator units, which keeps the small numbers
-- exact.

local use = ...
local palette = use("palette")

local M = {}

local floor, max, min, pi = math.floor, math.max, math.min, math.pi
local rad, sin, cos, log, tan = math.rad, math.sin, math.cos, math.log, math.tan

local TILE = 256
-- Meters per degree of latitude, as core/home.lua.
local M_PER_DEG = 111320
-- The layer the radio shows; the index may list others.
local LAYER = "satellite"
-- Where the GCS puts a new view (its first fix).
local START_ZOOM = 17
-- A trail point when the aircraft has moved this far; the GCS keeps every
-- position, but a radio draws each point every frame.
local TRAIL_STEP_M = 3
local TRAIL_POINTS = 120

local VEHICLE_FILL = { 247, 148, 29 } -- #F7941D
local VEHICLE_EDGE = { 45, 45, 47 } -- #2D2D2F
local TRAIL = { 70, 132, 197 } -- #4684C5
local HOME = { 47, 174, 78 } -- #2FAE4E
-- For the swap button's picture of the map (core/layout.lua).
M.COLORS = { trail = TRAIL, vehicle = VEHICLE_FILL }

--- The layers in maps/index.txt: one a line, "id|label|min zoom|max zoom|
--- center lat|center lon|credit". Lines it cannot read are skipped. Neither
--- radio's font has "©", so the credit says "(c)".
function M.parseIndex(text)
  local layers = {}
  for line in string.gmatch(text or "", "[^\r\n]+") do
    local id, label, z0, z1, lat, lon, credit =
      string.match(line, "^([%w_%-]+)|([^|]*)|(%d+)|(%d+)|([%-%d%.]*)|([%-%d%.]*)|(.*)$")
    if id then
      layers[#layers + 1] = {
        id = id, label = label, minZoom = tonumber(z0), maxZoom = tonumber(z1),
        lat = tonumber(lat), lon = tonumber(lon),
        credit = (string.gsub(credit, "\194\169", "(c)")),
      }
    end
  end
  return layers
end

--- Web Mercator's northing of a latitude, in radians of the projection.
local function merc(lat)
  return log(tan(pi / 4 + rad(lat) / 2))
end
M.merc = merc

--- A view of the map: its zoom and the trail.
function M.newView()
  return { zoom = nil, trail = {}, state = nil }
end

--- Adds the aircraft's position to the trail, a point each few meters. A new
--- state (a replay starting over, another model) starts a new trail.
function M.track(v, s)
  if v.state ~= s then
    v.state, v.trail = s, {}
  end
  if not (s.lat and s.lon) then
    return
  end
  local t = v.trail
  local n = #t
  if n > 0 then
    local north = (s.lat - t[n - 2]) * M_PER_DEG
    local east = (s.lon - t[n - 1]) * M_PER_DEG * cos(rad(s.lat))
    if north * north + east * east < TRAIL_STEP_M * TRAIL_STEP_M then
      return
    end
  end
  -- lat, lon and the latitude's northing, three to a point.
  t[n + 1], t[n + 2], t[n + 3] = s.lat, s.lon, merc(s.lat)
  if n + 3 > TRAIL_POINTS * 3 then
    table.remove(t, 1)
    table.remove(t, 1)
    table.remove(t, 1)
  end
end

--- The satellite layer of the index, or nil.
local function layerOf(layers)
  for _, l in ipairs(layers) do
    if l.id == LAYER then
      return l
    end
  end
end

--- The zoom shown: the view's, else the GCS's first-fix zoom, within the
--- layer's stored levels.
local function zoomOf(v, layer)
  local z = v.zoom or START_ZOOM
  return max(layer.minZoom, min(layer.maxZoom, z))
end

--- Zooms in (+1) or out (-1) within the stored levels.
function M.zoom(v, layers, dir)
  local layer = layerOf(layers)
  if layer then
    v.zoom = max(layer.minZoom, min(layer.maxZoom, zoomOf(v, layer) + dir))
  end
end

--- Where the view looks: the aircraft, else the stored area.
function M.center(layer, s)
  if s.lat and s.lon then
    return s.lat, s.lon
  elseif layer and layer.lat then
    return layer.lat, layer.lon
  end
end

--- Home's position: the radio's own, else worked back from the aircraft's
--- position and the home distance and bearing it sends.
local function homeOf(s)
  if s.radioHome then
    return s.radioHome.lat, s.radioHome.lon
  elseif s.homeDist and s.homeBearing and s.lat and s.lon then
    local b = rad(s.homeBearing)
    local lat = s.lat + s.homeDist * cos(b) / M_PER_DEG
    return lat, s.lon + s.homeDist * sin(b) / (M_PER_DEG * cos(rad(s.lat)))
  end
end

local function frame(c, x, y, w, h, color)
  c.line(x, y, x + w - 1, y, color, 1)
  c.line(x, y + h - 1, x + w - 1, y + h - 1, color, 1)
  c.line(x, y, x, y + h - 1, color, 1)
  c.line(x + w - 1, y, x + w - 1, y + h - 1, color, 1)
end

-- The GCS's arrow, "M0 -13 L9 11 L0 6 L-9 11 Z" in a 34 px box, turned to
-- heading `hdg` around (x, y) at scale `k`.
local ARROW = { 0, -13, 9, 11, 0, 6, -9, 11 }
local function arrow(c, x, y, hdg, k)
  local a = rad(hdg)
  local ca, sa = cos(a) * k, sin(a) * k
  local p = {}
  for i = 1, 8, 2 do
    local px, py = ARROW[i], ARROW[i + 1]
    p[i], p[i + 1] = x + px * ca - py * sa, y + px * sa + py * ca
  end
  c.tri(p[1], p[2], p[3], p[4], p[5], p[6], VEHICLE_FILL)
  c.tri(p[1], p[2], p[5], p[6], p[7], p[8], VEHICLE_FILL)
  local wd = max(1, floor(1.5 * k + 0.5))
  c.line(p[1], p[2], p[3], p[4], VEHICLE_EDGE, wd)
  c.line(p[3], p[4], p[5], p[6], VEHICLE_EDGE, wd)
  c.line(p[5], p[6], p[7], p[8], VEHICLE_EDGE, wd)
  c.line(p[7], p[8], p[1], p[2], VEHICLE_EDGE, wd)
end

-- The GCS's home, "M-8 2 L0 -7 L8 2 L8 8 L-8 8 Z", outlined.
local HOUSE = { -8, 2, 0, -7, 8, 2, 8, 8, -8, 8 }
local function house(c, x, y, k)
  local wd = max(2, floor(2.5 * k + 0.5))
  for i = 1, 9, 2 do
    local j = i + 2 > 10 and 1 or i + 2
    c.line(x + HOUSE[i] * k, y + HOUSE[i + 1] * k, x + HOUSE[j] * k, y + HOUSE[j + 1] * k, HOME, wd)
  end
end

--- Draws the map for state `s` into the rectangle x, y, w, h of canvas `c`,
--- at scale `sc` (as the panels'). `maps` is {layers, root}, `root` the
--- folder tiles are read from. Tiles reach past the rectangle: the caller
--- draws whatever surrounds it afterwards. Returns the controls' hit areas,
--- each {x1, y1, x2, y2, action, arg}.
function M.paint(c, x, y, w, h, s, sc, v, maps)
  local T = palette.T
  local hits = {}
  local layer = layerOf(maps.layers)
  -- Behind the tiles, so a tile not stored leaves a plain square.
  c.fill(x, y, w, h, T.surface2)
  local lat, lon = M.center(layer, s)
  if not (layer and lat) then
    local word = layer and "No position" or "No stored map"
    local size = 12 * sc
    local tw = c.textWidth(word, size)
    local ch = floor(22 * sc)
    c.fill(x + (w - tw) / 2 - 10 * sc, y + (h - ch) / 2, tw + 20 * sc, ch, T.surface)
    c.text(x + w / 2, y + h / 2, word, size, T.ink2, "center")
    return hits
  end

  local z = zoomOf(v, layer)
  -- An integer, so tile numbers in paths print without a fraction.
  local n = 1 << z
  local kx = n * TILE / 360
  local ky = n * TILE / (2 * pi)
  local m0 = merc(lat)
  local cx, cy = x + w / 2, y + h / 2
  -- The tile under the center, and where its corner lands.
  local tx = floor((lon + 180) / 360 * n)
  local ty = floor((1 - m0 / pi) / 2 * n)
  local left = cx + (tx * 360 / n - 180 - lon) * kx
  local top = cy + (m0 - pi * (1 - 2 * ty / n)) * ky
  local c0 = tx - math.ceil((left - x) / TILE)
  local r0 = ty - math.ceil((top - y) / TILE)
  local root = maps.root .. layer.id .. "/" .. z .. "/"
  local sy = top + (r0 - ty) * TILE
  for row = r0, ty + math.ceil((y + h - top) / TILE) - 1 do
    if row >= 0 and row < n then
      local sx = left + (c0 - tx) * TILE
      for col = c0, tx + math.ceil((x + w - left) / TILE) - 1 do
        c.image(root .. (col % n) .. "/" .. row .. ".jpg", floor(sx), floor(sy), TILE)
        sx = sx + TILE
      end
    end
    sy = sy + TILE
  end

  -- The trail, then home, then the aircraft on top, as the GCS stacks them.
  local t = v.trail
  local tw = max(1, floor(3 * sc * 0.75 + 0.5))
  local px, py
  for i = 1, #t, 3 do
    local qx, qy = cx + (t[i + 1] - lon) * kx, cy + (m0 - t[i + 2]) * ky
    if px then
      c.line(px, py, qx, qy, TRAIL, tw)
    end
    px, py = qx, qy
  end
  local k = 0.75 * sc
  local hlat, hlon = homeOf(s)
  if hlat then
    house(c, cx + (hlon - lon) * kx, cy + (m0 - merc(hlat)) * ky, k)
  end
  if s.lat and s.lon then
    arrow(c, cx + (s.lon - lon) * kx, cy + (m0 - merc(s.lat)) * ky, s.yaw or 0, k)
  end

  -- Zoom at the top left, as Leaflet's, a finger wide; the marks are fills,
  -- which stay crisp at any size where a font's "+" would not.
  local pad = floor(6 * sc)
  local b = floor(44 * sc)
  local bx, by = x + pad, y + pad
  c.fill(bx, by, b, 2 * b, T.surface)
  frame(c, bx, by, b, 2 * b, T.lineStrong)
  c.line(bx, by + b, bx + b - 1, by + b, T.line, 1)
  local arm = floor(8 * sc)
  local th = max(2, floor(3 * sc))
  local mx = bx + floor((b - th) / 2)
  local my = by + floor((b - th) / 2)
  c.fill(bx + b / 2 - arm, my, 2 * arm, th, T.ink)
  c.fill(mx, by + b / 2 - arm, th, 2 * arm, T.ink)
  c.fill(bx + b / 2 - arm, my + b, 2 * arm, th, T.ink)
  hits[#hits + 1] = { bx, by, bx + b, by + b, action = "zoom", arg = 1 }
  hits[#hits + 1] = { bx, by + b, bx + b, by + 2 * b, action = "zoom", arg = -1 }

  -- The credit, bottom right on Leaflet's translucent strip, shortened to fit
  -- but never left out.
  local cs = 9 * sc
  local credit = layer.credit
  local room = w - 2 * pad
  while #credit > 4 and c.textWidth(credit, cs) > room do
    credit = string.sub(credit, 1, -3) .. "."
  end
  local cw = c.textWidth(credit, cs) + 8 * sc
  local chh = floor(13 * sc)
  c.fill(x + w - cw, y + h - chh, cw, chh, T.surface, 0.8)
  c.text(x + w - 4 * sc, y + h - chh / 2, credit, cs, palette.name == "dark" and T.ink3 or T.ink, "right")
  return hits
end

--- Acts on a tap at a control from the last paint's `hits`; true if one was
--- hit.
function M.tap(v, layers, hits, x, y)
  for _, hit in ipairs(hits or {}) do
    if x >= hit[1] and x < hit[3] and y >= hit[2] and y < hit[4] then
      M.zoom(v, layers, hit.arg)
      return true
    end
  end
  return false
end

return M
