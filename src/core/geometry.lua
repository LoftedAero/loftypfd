-- Plane geometry for the horizon: polygons clipped to the screen and broken
-- into triangles, since filled triangles are the one shape both radios fill
-- at any angle.
--
-- A polygon is a flat array {x1, y1, x2, y2, ...}, convex, so clipping by a
-- half-plane keeps it convex and a fan from its first vertex covers it.

local M = {}

--- The rectangle as a polygon.
function M.rect(x, y, w, h)
  return { x, y, x + w, y, x + w, y + h, x, y + h }
end

--- The part of `poly` where nx * x + ny * y <= c (Sutherland-Hodgman).
function M.clip(poly, nx, ny, c)
  local out = {}
  local n = #poly
  if n == 0 then
    return out
  end
  local px, py = poly[n - 1], poly[n]
  local pd = nx * px + ny * py - c
  for i = 1, n, 2 do
    local x, y = poly[i], poly[i + 1]
    local d = nx * x + ny * y - c
    if (pd <= 0) ~= (d <= 0) then
      local t = pd / (pd - d)
      out[#out + 1] = px + (x - px) * t
      out[#out + 1] = py + (y - py) * t
    end
    if d <= 0 then
      out[#out + 1] = x
      out[#out + 1] = y
    end
    px, py, pd = x, y, d
  end
  return out
end

--- Calls tri(x1, y1, x2, y2, x3, y3) for each triangle of a convex polygon.
function M.fan(poly, tri)
  local n = #poly
  for i = 3, n - 3, 2 do
    tri(poly[1], poly[2], poly[i], poly[i + 1], poly[i + 2], poly[i + 3])
  end
end

-- One Liang-Barsky edge test: narrows [t0, t1], or returns nil when the
-- segment lies wholly outside that edge.
local function edge(p, q, t0, t1)
  if p == 0 then
    if q < 0 then
      return nil
    end
    return t0, t1
  end
  local t = q / p
  if p < 0 then
    if t > t1 then
      return nil
    end
    if t > t0 then
      t0 = t
    end
  else
    if t < t0 then
      return nil
    end
    if t < t1 then
      t1 = t
    end
  end
  return t0, t1
end

--- A segment clipped to a rectangle (Liang-Barsky); nil when it misses.
--- Allocates nothing: it runs for every line a frame draws on some radios.
function M.clipSegment(x1, y1, x2, y2, rx, ry, rw, rh)
  local dx, dy = x2 - x1, y2 - y1
  local t0, t1 = edge(-dx, x1 - rx, 0, 1)
  if t0 then
    t0, t1 = edge(dx, rx + rw - x1, t0, t1)
  end
  if t0 then
    t0, t1 = edge(-dy, y1 - ry, t0, t1)
  end
  if t0 then
    t0, t1 = edge(dy, ry + rh - y1, t0, t1)
  end
  if not t0 then
    return nil
  end
  return x1 + dx * t0, y1 + dy * t0, x1 + dx * t1, y1 + dy * t1
end

--- A thick segment as a quadrilateral polygon.
function M.thick(x1, y1, x2, y2, width)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len == 0 then
    return {}
  end
  local ox, oy = -dy / len * width / 2, dx / len * width / 2
  return { x1 + ox, y1 + oy, x2 + ox, y2 + oy, x2 - ox, y2 - oy, x1 - ox, y1 - oy }
end

return M
