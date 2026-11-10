-- The primary flight display, drawn through a canvas the platform supplies.
--
-- The layout is Lofty GCS's Fly-screen HUD (src/ui/tabs/flight/hud-paint.ts):
-- heading ribbon across the top, short tapes for speed (left) and altitude
-- (right) beside an attitude indicator with a bank scale marked at 10, 20,
-- 30, 45 and 60 degrees, the amber aircraft symbol, captioned readings under
-- the tapes, GPS and link in the top corners, battery and mode in the bottom
-- ones. A pilot who knows one knows the other.
--
-- The canvas (see docs/architecture.md, "The canvas"):
--   c.w, c.h
--   c.fill(x, y, w, h, color, alpha)       alpha 0-1, nil for opaque
--   c.tri(x1, y1, x2, y2, x3, y3, color, alpha)
--   c.line(x1, y1, x2, y2, color, width)   width in whole pixels, nil for 1
--   c.shadowText(...)                      optional: c.text's arguments,
--                                           drawn with a dark shadow
--   c.text(x, y, str, size, color, align, bold)   y is the text's middle;
--                                           size in pixels; align
--                                           "left", "center" or "right"
--   c.textWidth(str, size, bold)
-- Colors are {r, g, b}. Sizes are the GCS's, times the HUD's scale; the
-- platform picks its nearest font.

local use = ...
local geometry = use("geometry")
local units = use("units")
local vehicle = use("vehicle")

local M = {}

local floor, abs, sin, cos, rad, max, min = math.floor, math.abs, math.sin, math.cos, math.rad, math.max, math.min

-- The HUD's own colors, Lofty GCS's (hud-paint.ts). They are not design
-- tokens: the HUD is a permanently dark ground in both themes.
local C = {
  -- Solid sky and ground: the GCS's gradients (#1D5F9E-#79B9E8 and
  -- #A67C46-#4A3520) at about a third of the way out from the horizon, the
  -- average of what a radio screen shows. A gradient drawn in bands showed
  -- its steps, and each band cost a clip per frame.
  sky = { 93, 158, 210 },
  ground = { 138, 103, 59 },
  ink = { 255, 255, 255 },
  -- The GCS's 62% white, as an opaque gray: radios cannot blend text.
  dim = { 200, 204, 212 },
  amber = { 247, 148, 29 },
  -- Home on the ribbon: white, since amber is the aircraft's own symbology.
  home = { 255, 255, 255 },
  green = { 53, 208, 127 },
  red = { 255, 69, 58 },
  panel = { 14, 17, 22 },
  shadow = { 0, 0, 0 },
  edge = { 120, 124, 132 },
  -- No telemetry yet: the bg of the dark theme, so nothing pretends to be sky.
  empty = { 19, 20, 23 },
}
M.COLORS = C

local PANEL_ALPHA = 0.26
local CHIP_ALPHA = 0.82
local BOX_ALPHA = 0.92

local DASH = "-"

local ALL_CORNERS = { gps = true, link = true, battery = true, mode = true }

-- Ticks for a vertical tape centered on `value`, from a rounded anchor so
-- the marks hold still and the tape slides past them.
function M.tapeTicks(value, halfSpan, step, majorEvery)
  majorEvery = majorEvery or 2
  local ticks = {}
  local lo = math.ceil((value - halfSpan) / step)
  local hi = floor((value + halfSpan) / step)
  for n = lo, hi do
    ticks[#ticks + 1] = { value = n * step, offset = n * step - value, major = n % majorEvery == 0 }
  end
  return ticks
end

local CARDINALS = { [0] = "N", [45] = "NE", [90] = "E", [135] = "SE", [180] = "S", [225] = "SW", [270] = "W", [315] = "NW" }

--- Shortest signed angle from a to b, degrees.
function M.angleDelta(a, b)
  return ((b - a) % 360 + 540) % 360 - 180
end

-- Labels for the heading ribbon; a cardinal replaces the number at its bearing.
function M.compassTicks(heading, halfSpan, step)
  local out = {}
  local center = floor(heading / step + 0.5) * step
  local reach = math.ceil(halfSpan / step) * step
  for d = center - reach, center + reach, step do
    local bearing = d % 360
    local offset = M.angleDelta(heading, d)
    if abs(offset) <= halfSpan then
      out[#out + 1] = { offset = offset, label = CARDINALS[bearing] or tostring(bearing), major = bearing % 30 == 0 }
    end
  end
  return out
end

--- Which failsafe the aircraft is in, in words, or nil. ArduPilot's generic
--- flag also covers the radio and ground-station failsafes, which it does
--- not tell apart, so those read plain "FAILSAFE".
function M.failsafeText(s)
  if s.battFailsafe then
    return "BATTERY FAILSAFE"
  elseif s.ekfFailsafe then
    return "EKF FAILSAFE"
  elseif s.failsafe then
    return "FAILSAFE"
  elseif s.fenceBreach then
    return "FENCE BREACH"
  end
  return nil
end

-- MAVLink's GPS_FIX_TYPE in words, as the GCS says it.
local FIX = { [0] = "No GPS", "No fix", "2D", "3D", "DGPS", "RTK float", "RTK fixed" }

-- The bank scale's lines as a flat list of x1, y1, x2, y2, width: the arc in
-- 10 degree segments and the marks at 10, 20, 30, 45 and 60 degrees. Kept for
-- the last size asked for; a radio's widget size rarely changes.
local bankCache = { key = nil, lines = nil }
local function bankScale(cx, cy, r, sc, heavy, light)
  local key = cx .. "," .. cy .. "," .. r .. "," .. sc
  if bankCache.key == key then
    return bankCache.lines
  end
  local out, n = {}, 0
  local function add(x1, y1, x2, y2, width)
    out[n + 1], out[n + 2], out[n + 3], out[n + 4], out[n + 5] = x1, y1, x2, y2, width
    n = n + 5
  end
  local function arcPoint(deg, radius)
    local t = rad(deg - 90)
    return cx + cos(t) * radius, cy + sin(t) * radius
  end
  local px, py = arcPoint(-60, r)
  for deg = -50, 60, 10 do
    local qx, qy = arcPoint(deg, r)
    add(px, py, qx, qy, light)
    px, py = qx, qy
  end
  for _, deg in ipairs({ -60, -45, -30, -20, -10, 10, 20, 30, 45, 60 }) do
    local big = abs(deg) == 30 or abs(deg) == 60
    local ax, ay = arcPoint(deg, r)
    local bx, by = arcPoint(deg, r + (big and 10 or 6) * sc)
    add(ax, ay, bx, by, big and heavy or light)
  end
  bankCache.key, bankCache.lines = key, out
  return out
end

--- Draws the HUD for state `s`. `opts.units` are the pilot's units and
--- `opts.now` the clock, in the state's seconds. `opts.corners` says which
--- corner readings to draw ({gps, link, battery, mode}); a layout that shows
--- them in its own panels leaves them out. All are drawn by default.
function M.paint(c, s, opts)
  local w, h = c.w, c.h
  local corners = opts.corners or ALL_CORNERS
  local now = opts.now or 0
  local u = opts.units or units.DEFAULT
  local sc = max(0.75, min(1.5, min(w, h) / 320))
  local ribbonH = floor(24 * sc)
  local tapeW = floor(50 * sc)
  local gap = floor(6 * sc)
  local cx = floor(w / 2)
  local cy = floor(ribbonH + (h - ribbonH) / 2)
  local pxPerDeg = (h - ribbonH) / 70

  -- Text over the picture gets a dark shadow. A platform that draws one
  -- itself supplies c.shadowText and saves the second call.
  local shadowText = c.shadowText
  local function write(str, x, y, size, color, align, bold)
    if shadowText then
      shadowText(x, y, str, size, color or C.ink, align, bold)
      return
    end
    c.text(x + 1, y + 1, str, size, C.shadow, align, bold)
    c.text(x, y, str, size, color or C.ink, align, bold)
  end

  local tri, line = c.tri, c.line
  local function poly(p, color, alpha)
    for i = 3, #p - 3, 2 do
      tri(p[1], p[2], p[i], p[i + 1], p[i + 2], p[i + 3], color, alpha)
    end
  end

  -- Line widths in whole pixels: radios draw 1 px lines, so a wider one is
  -- several, which the platform draws.
  local heavy = floor(1.6 * sc + 0.5)
  -- Major rungs are heavy only on a big screen; at 480x320 one pixel reads
  -- well and two cost a second call each.
  local rungWidth = sc >= 1.25 and heavy or 1
  -- Light lines stay one pixel at every size: a wider line costs a call per
  -- pixel, and the frame budget is tight at 800x480.
  local light = 1

  -- A dim caption and a bright value; returns the width drawn.
  local capSize, valSize = 9 * sc, 13 * sc
  local function pair(caption, value, x, y, align)
    local capW = caption ~= "" and c.textWidth(caption, capSize) + floor(5 * sc) or 0
    local valW = c.textWidth(value, valSize)
    if align == "right" then
      write(value, x, y, valSize, C.ink, "right")
      write(caption, x - valW - floor(5 * sc), y, capSize, C.dim, "right")
    else
      write(caption, x, y, capSize, C.dim, "left")
      write(value, x + capW, y, valSize, C.ink, "left")
    end
    return capW + valW
  end

  local hasAttitude = s.roll ~= nil and s.pitch ~= nil

  -- Horizon. Sky and ground run the full height, behind the ribbon too.
  -- Radios cap the instructions a script may run per frame (Ethos about
  -- 20,000), so every element is drawn with as few calls as it allows;
  -- tests/hud_test.lua holds the budget.
  if hasAttitude then
    local a = -rad(s.roll)
    local sa, ca = sin(a), cos(a)
    local P = s.pitch * pxPerDeg
    -- The horizon's center and its normal, pointing into the ground.
    local hx, hy = cx - P * sa, cy + P * ca
    local nx, ny = -sa, ca
    local c0 = nx * hx + ny * hy
    local screen = geometry.rect(0, 0, w, h)
    -- The whole screen is sky, and the ground is painted over it: radios
    -- leave hairline gaps between filled triangles, which then show sky
    -- rather than the black behind.
    c.fill(0, 0, w, h, C.sky)
    poly(geometry.clip(screen, -nx, -ny, -c0), C.ground)
    local x1, y1, x2, y2 = geometry.clipSegment(hx - ca * 2 * w, hy - sa * 2 * w, hx + ca * 2 * w, hy + sa * 2 * w, 0, 0, w, h)
    if x1 then
      line(x1, y1, x2, y2, C.ink, heavy)
    end

    -- Pitch ladder: finer near the horizon, dashed below it, numbered on the
    -- left only, stopping at the ribbon. Only rungs that can be on screen
    -- are visited: the panel spans 70 degrees.
    local function place(uu, v)
      local vv = v + P
      return cx + uu * ca - vv * sa, cy + uu * sa + vv * ca
    end
    local lo = max(-60, math.ceil((s.pitch - 35) / 5) * 5)
    local hi = min(60, floor((s.pitch + 35) / 5) * 5)
    for deg = lo, hi, 5 do
      local major = deg % 10 == 0
      if deg ~= 0 and (major or pxPerDeg >= 6) then
        local v = -deg * pxPerDeg
        local half = (major and 34 or 16) * sc
        local mx, my = place(0, v)
        if my > ribbonH + 4 * sc and my < h and mx > 0 and mx < w then
          -- Points along a rung are its center plus a multiple of the
          -- rung's direction (ca, sa); its ticks go along (-sa, ca).
          local width = major and rungWidth or light
          if deg > 0 then
            line(mx - half * ca, my - half * sa, mx + half * ca, my + half * sa, C.ink, width)
          else
            local dash = 2 * half / 3
            for k = 0, 2 do
              local f0 = -half + dash * k
              local f1 = f0 + dash * 0.6
              line(mx + f0 * ca, my + f0 * sa, mx + f1 * ca, my + f1 * sa, C.ink, width)
            end
          end
          if major then
            local tick = (deg > 0 and 1 or -1) * 5 * sc
            local tx, ty = -tick * sa, tick * ca
            local lx, ly = mx - half * ca, my - half * sa
            local rx, ry = mx + half * ca, my + half * sa
            line(lx, ly, lx + tx, ly + ty, C.ink, light)
            line(rx, ry, rx + tx, ry + ty, C.ink, light)
            local off = half + 6 * sc
            write(tostring(abs(deg)), mx - off * ca, my - off * sa, 10 * sc, C.ink, "right")
          end
        end
      end
    end
  else
    c.fill(0, 0, w, h, C.empty)
  end

  -- Bank scale and pointer, with the slip trapezoid riding under it.
  local r = min(w, h - ribbonH) * 0.36
  if hasAttitude then
    -- The arc and its marks never move: computed once per size.
    local scale = bankScale(cx, cy, r, sc, heavy, light)
    for i = 1, #scale, 5 do
      line(scale[i], scale[i + 1], scale[i + 2], scale[i + 3], C.ink, scale[i + 4])
    end
    -- Zero mark: a fixed hollow triangle.
    local zy = cy - r
    line(cx, zy - 2 * sc, cx - 6 * sc, zy - 12 * sc, C.ink, 1)
    line(cx - 6 * sc, zy - 12 * sc, cx + 6 * sc, zy - 12 * sc, C.ink, 1)
    line(cx + 6 * sc, zy - 12 * sc, cx, zy - 2 * sc, C.ink, 1)
    -- The moving pointer.
    local a = -rad(s.roll)
    local sa, ca = sin(a), cos(a)
    local function rot(x, y)
      return cx + x * ca - y * sa, cy + x * sa + y * ca
    end
    local p1x, p1y = rot(0, -r + 1 * sc)
    local p2x, p2y = rot(-6 * sc, -r + 11 * sc)
    local p3x, p3y = rot(6 * sc, -r + 11 * sc)
    tri(p1x, p1y, p2x, p2y, p3x, p3y, C.amber)
    local t1x, t1y = rot(-6.5 * sc, -r + 13.5 * sc)
    local t2x, t2y = rot(6.5 * sc, -r + 13.5 * sc)
    local t3x, t3y = rot(5 * sc, -r + 17.5 * sc)
    local t4x, t4y = rot(-5 * sc, -r + 17.5 * sc)
    poly({ t1x, t1y, t2x, t2y, t3x, t3y, t4x, t4y }, C.amber)
  end

  -- Heading ribbon: a translucent band, ticks every 15 degrees, a box with
  -- the heading and an amber chevron under it.
  c.fill(0, 0, w, ribbonH, C.panel, PANEL_ALPHA)
  local heading = s.yaw or s.course
  local boxW = floor(40 * sc)
  -- Where home sits on the ribbon, worked out first so the labels can step
  -- around it. Out of the ribbon's span it waits at the nearer edge.
  local homeX, homeDir
  if heading and s.homeBearing and s.homeDist and s.homeDist > 0 then
    local edge = 44
    local off = M.angleDelta(heading, s.homeBearing)
    if abs(off) > edge then
      homeDir = off > 0 and 1 or -1
      off = homeDir * edge
    end
    homeX = cx + off * (w / 2 / 48)
  end
  if heading then
    local halfSpan = 48
    local pxPerHdg = w / 2 / halfSpan
    local boxHalf = boxW / 2 + 14 * sc
    -- Walked directly rather than through compassTicks, which builds a table
    -- per tick: this runs every frame.
    local first = math.ceil((heading - halfSpan) / 15) * 15
    for d = first, heading + halfSpan, 15 do
      local x = cx + (d - heading) * pxPerHdg
      local bearing = d % 360
      local major = bearing % 30 == 0
      local len = major and 6 * sc or 3.5 * sc
      c.fill(floor(x), floor(ribbonH - len), 1, floor(len), major and C.ink or C.dim)
      if major and abs(x - cx) > boxHalf and not (homeX and abs(x - homeX) < 16 * sc) then
        local cardinal = CARDINALS[bearing]
        write(cardinal or tostring(bearing), x, ribbonH - 13 * sc, (cardinal and 11 or 9.5) * sc,
          cardinal and C.ink or C.dim, "center", cardinal ~= nil)
      end
    end
  end
  c.fill(cx - boxW / 2, 1, boxW, ribbonH - 2, C.panel, CHIP_ALPHA)
  c.tri(cx, ribbonH + 6 * sc, cx - 5 * sc, ribbonH, cx + 5 * sc, ribbonH, C.amber)

  -- Home, as a house on the ribbon at its bearing; at the edge, with an
  -- arrow pointing on round.
  if homeX then
    local hx = homeX
    local base = ribbonH - 2 * sc
    local half = 5 * sc
    c.fill(hx - half, base - 6 * sc, 2 * half, 6 * sc, C.home)
    c.tri(hx - half - 2 * sc, base - 6 * sc, hx + half + 2 * sc, base - 6 * sc, hx, base - 12 * sc, C.home)
    if homeDir then
      local dir = homeDir
      local ax = hx + dir * (half + 4 * sc)
      c.tri(ax, base - 9 * sc, ax, base - 1 * sc, ax + dir * 5 * sc, base - 5 * sc, C.home)
    end
  end
  -- Text on its own dark box needs no shadow.
  c.text(cx, ribbonH / 2, heading and string.format("%03d", floor(heading + 0.5) % 360) or DASH, 12.5 * sc, C.ink, "center", true)

  -- Tapes.
  local tapeH = max(80, (h - ribbonH) * 0.52)
  local tapeTop = max(ribbonH + gap, cy - tapeH / 2)
  local speedMs = s.airspeed or s.speed or s.groundspeed
  local function tape(x, value, step, side)
    local midY = tapeTop + tapeH / 2
    c.fill(x, tapeTop, tapeW, tapeH, C.panel, PANEL_ALPHA)
    if value then
      local pxPerUnit = tapeH / (step * 7)
      -- As tapeTicks, walked directly to build no tables per frame.
      local halfSpan = tapeH / 2 / pxPerUnit * 0.98
      for n = math.ceil((value - halfSpan) / step), floor((value + halfSpan) / step) do
        local ty = midY - (n * step - value) * pxPerUnit
        local major = n % 2 == 0
        local len = (major and 8 or 4) * sc
        local tx = side == "left" and x + tapeW - len or x
        c.fill(floor(tx), floor(ty), floor(len), 1, major and C.ink or C.dim)
        if major then
          local lx = side == "left" and x + tapeW - len - 4 * sc or x + len + 4 * sc
          write(tostring(n * step), lx, ty, 10 * sc, C.ink, side == "left" and "right" or "left")
        end
      end
    end
    -- The live value in a box pointing at the horizon.
    local bh, nose = 20 * sc, 6 * sc
    local outline
    if side == "left" then
      outline = { x, midY - bh / 2, x + tapeW, midY - bh / 2, x + tapeW + nose, midY, x + tapeW, midY + bh / 2, x, midY + bh / 2 }
    else
      outline = { x + tapeW, midY - bh / 2, x, midY - bh / 2, x - nose, midY, x, midY + bh / 2, x + tapeW, midY + bh / 2 }
    end
    poly(outline, C.panel, BOX_ALPHA)
    for i = 1, #outline, 2 do
      local j = i + 2 > #outline and 1 or i + 2
      line(outline[i], outline[i + 1], outline[j], outline[j + 1], C.edge, 1)
    end
    c.text(x + tapeW / 2, midY, value and tostring(floor(value + 0.5)) or DASH, 14 * sc, C.ink, "center", true)
  end
  tape(gap, speedMs and units.toSpeed(speedMs, u.speed), units.tapeStep("speed", u.speed), "left")
  tape(w - tapeW - gap, s.alt and units.toDistance(s.alt, u.distance), units.tapeStep("altitude", u.distance), "right")

  -- Climb as a bar from the altitude box, up or down the tape's inner edge.
  -- Square-root scaled so a gentle climb shows and 10 m/s reaches the end.
  if s.climb then
    local reach = tapeH / 2 - 10 * sc
    local len = math.sqrt(min(abs(s.climb), 10) / 10) * reach
    local bx = w - tapeW - gap - 6 * sc
    local midY = tapeTop + tapeH / 2
    if len >= 1 then
      c.fill(bx, s.climb > 0 and midY - len or midY, 3 * sc, len, C.ink)
    end
  end

  -- The aircraft: wings either side of a center vee, amber on a dark edge.
  -- The wings and their tips are rectangles; only the vee needs triangles.
  if hasAttitude then
    local function symbol(width, color)
      local half = width / 2
      c.fill(cx - 46 * sc, cy - half, 32 * sc + half, width, color)
      c.fill(cx + 14 * sc - half, cy - half, 32 * sc + half, width, color)
      c.fill(cx - 14 * sc - half, cy - half, width, 6 * sc + half, color)
      c.fill(cx + 14 * sc - half, cy - half, width, 6 * sc + half, color)
      poly(geometry.thick(cx - 11 * sc, cy, cx, cy + 7 * sc, width), color)
      poly(geometry.thick(cx, cy + 7 * sc, cx + 11 * sc, cy, width), color)
    end
    symbol(5.5 * sc, C.shadow)
    symbol(2.6 * sc, C.amber)
  end

  -- Readings under the tapes: the speeds left, climb and throttle right.
  local left, right = gap, w - gap
  local u1 = tapeTop + tapeH + 17 * sc
  local u2 = u1 + 15 * sc
  local spdLabel = " " .. units.speedLabel(u.speed)
  local function spd(v)
    return v and units.formatSpeed(v, u.speed) .. spdLabel or DASH
  end
  pair("AS", spd(s.airspeed or s.speed), left, u1, "left")
  pair("GS", spd(s.groundspeed), left, u2, "left")
  local vs = DASH
  if s.climb then
    vs = (s.climb >= 0 and "+" or "") .. units.formatVerticalSpeed(s.climb, u) .. " " .. units.verticalSpeedLabel(u)
  end
  pair("V/S", vs, right, u1, "right")
  pair("THR", s.throttle and (s.throttle .. "%") or DASH, right, u2, "right")

  -- Corners: GPS top left, link top right, battery bottom left, mode bottom
  -- right.
  local corner = 13 * sc
  local topLine = ribbonH + 18 * sc
  -- Plain CRSF has a satellite count but no fix type, so the fix is left out
  -- rather than guessed.
  local gx = left
  if not corners.gps then
    -- moved to the layout's panels
  elseif s.fix or not s.sats then
    gx = gx + pair("GPS", s.fix and FIX[min(s.fix, 6)] or DASH, gx, topLine, "left") + 10 * sc
  end
  if corners.gps and s.sats then
    gx = gx + pair("SATS", tostring(s.sats), gx, topLine, "left") + 10 * sc
  end
  if corners.gps and s.hdop and s.fix and s.fix >= 2 then
    pair("HDOP", string.format("%.1f", s.hdop), gx, topLine, "left")
  end
  if corners.link then
    local l = s.link or {}
    local lx = right
    -- The transmitter's battery, where the layout has no bar to carry it.
    if opts.tx then
      lx = lx - pair("TX", opts.tx.volts and string.format("%.1fV", opts.tx.volts) or DASH, lx, topLine, "right") - 10 * sc
    end
    if l.rssi then
      lx = lx - pair("RSSI", tostring(l.rssi), lx, topLine, "right") - 10 * sc
    end
    pair("LQ", l.lq and (l.lq .. "%") or DASH, lx, topLine, "right")
  end

  local b = s.battery[1]
  local parts = {}
  if b.volts then
    parts[#parts + 1] = string.format("%.1fV", b.volts)
  end
  if b.amps and b.volts then
    parts[#parts + 1] = string.format("%.1fA", b.amps)
  end
  if b.pct then
    parts[#parts + 1] = b.pct .. "%"
  end
  if corners.battery then
    write(#parts > 0 and table.concat(parts, "  ") or DASH, left, h - 10 * sc, corner, C.ink, "left")
  end
  if corners.mode then
    write(vehicle.modeName(s) or DASH, right, h - 10 * sc, corner, C.ink, "right", true)
  end

  -- State over the aircraft: disarmed, failsafe.
  local stateY = cy - min(w, h) * 0.17
  if s.armed == false then
    write("DISARMED", cx, stateY, 20 * sc, C.red, "center", true)
  end
  local failsafe = M.failsafeText(s)
  if failsafe then
    write(failsafe, cx, stateY + 26 * sc, 20 * sc, C.red, "center", true)
  end

  -- A chip under the center when the link is lost. The aircraft's messages
  -- are in the log under the HUD, so they are not said here a second time.
  local chip
  if s.lastFrame and now - s.lastFrame > vehicle.LOST_S then
    chip = "Link lost"
  end
  if chip then
    local size = 12 * sc
    local room = w - 2 * (tapeW + gap) - 24 * sc
    local text = chip
    while #text > 4 and c.textWidth(text, size, true) > room do
      text = string.sub(text, 1, -2)
    end
    if text ~= chip then
      text = string.gsub(text, "%s+$", "") .. "..."
    end
    local tw = c.textWidth(text, size, true) + 20 * sc
    local y = cy + min(w, h) * 0.17
    c.fill(cx - tw / 2, y - 10 * sc, tw, 20 * sc, C.panel, CHIP_ALPHA)
    c.text(cx, y, text, size, C.red, "center", true)
  end
end

return M
