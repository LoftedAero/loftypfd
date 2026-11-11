-- The EdgeTX screen as the core's canvas (core/hud.lua): the widget and the
-- tool both draw through it.

local use, DIR = ...
local geometry = use("geometry")

local floor = math.floor

-- EdgeTX's color fonts and their line heights on 480x272 and 480x320
-- (fonts/lvgl/std in the firmware).
local FONTS = {
  { flag = TINSIZE, h = 12 },
  { flag = SMLSIZE, h = 17 },
  { flag = 0, h = 21, bold = BOLD },
  { flag = MIDSIZE, h = 29 },
  { flag = DBLSIZE, h = 40 },
}

-- The HUD sizes are CSS pixels of an em; a face's line height is about a
-- quarter more. Cached: text is the most frequent call.
local picked = {}
local function font(size, bold)
  local key = bold and -size or size
  local f = picked[key]
  if not f then
    local want, best, err = size * 1.25, nil, math.huge
    for _, candidate in ipairs(FONTS) do
      local e = math.abs(candidate.h - want)
      if e < err then
        best, err = candidate, e
      end
    end
    f = (bold and best.bold) or best.flag
    picked[key] = f
  end
  return f
end

-- Colors, cached by the core's color tables. Weak keys: the horizon's
-- gradient makes new tables every frame.
local colors = setmetatable({}, { __mode = "k" })
local function color(c)
  local v = colors[c]
  if not v then
    v = lcd.RGB(c[1], c[2], c[3])
    colors[c] = v
  end
  return v
end

local ALIGN = { left = 0, center = CENTER, right = RIGHT }

local screen = { w = 0, h = 0 }

-- Coordinates go to the firmware as they are: EdgeTX's Lua floors a
-- fractional argument where it wants an integer, which saves the
-- instructions flooring every coordinate here would cost.

-- The color lookup is written out in each function rather than called:
-- these run a couple of hundred times a frame.

-- An origin the layout sets while the HUD draws in its part of the screen:
-- applied here, it costs an addition per coordinate, where a wrapping canvas
-- costs a function call per draw.
local ox, oy = 0, 0
function screen.origin(x, y)
  ox, oy = x, y
end

function screen.fill(x, y, w, h, c, alpha)
  -- EdgeTX's opacity runs the other way: 0 opaque, 15 invisible.
  local opacity = alpha and floor((1 - alpha) * 15 + 0.5) or 0
  lcd.drawFilledRectangle(x + ox, y + oy, w + 0.5, h + 0.5, colors[c] or color(c), opacity)
end

function screen.tri(x1, y1, x2, y2, x3, y3, c)
  lcd.drawFilledTriangle(x1 + ox, y1 + oy, x2 + ox, y2 + oy, x3 + ox, y3 + oy, colors[c] or color(c))
end

-- EdgeTX skips a line with any end off the screen, so lines are clipped
-- first; a wider line is several, offset across its shorter axis.
function screen.line(x1, y1, x2, y2, c, width)
  x1, y1, x2, y2 = x1 + ox, y1 + oy, x2 + ox, y2 + oy
  local maxX, maxY = screen.maxX, screen.maxY
  if x1 < 0 or x2 < 0 or y1 < 0 or y2 < 0 or x1 > maxX or x2 > maxX or y1 > maxY or y2 > maxY then
    x1, y1, x2, y2 = geometry.clipSegment(x1, y1, x2, y2, 0, 0, maxX, maxY)
    if not x1 then
      return
    end
  end
  local col = colors[c] or color(c)
  if not width or width <= 1 then
    lcd.drawLine(x1, y1, x2, y2, SOLID, col)
    return
  end
  local steep = math.abs(y2 - y1) > math.abs(x2 - x1)
  local first = -floor(width / 2)
  for k = first, first + width - 1 do
    if steep then
      lcd.drawLine(x1 + k, y1, x2 + k, y2, SOLID, col)
    else
      lcd.drawLine(x1, y1 + k, x2, y2 + k, SOLID, col)
    end
  end
end

function screen.text(x, y, str, size, c, align, bold)
  lcd.drawText(x + ox, y + oy, str, (picked[bold and -size or size] or font(size, bold)) | VCENTER | ALIGN[align or "left"] | (colors[c] or color(c)))
end

-- EdgeTX draws the dark shadow itself, saving the HUD a second call.
function screen.shadowText(x, y, str, size, c, align, bold)
  lcd.drawText(x + ox, y + oy, str, (picked[bold and -size or size] or font(size, bold)) | VCENTER | SHADOWED | ALIGN[align or "left"] | (colors[c] or color(c)))
end

function screen.textWidth(str, size, bold)
  return (lcd.sizeText(str, font(size, bold)))
end

-- Map tiles and other images by path, drawn at `size` square. Twelve kept:
-- a full-screen map shows nine. Two are decoded a refresh, so a new zoom level
-- fills in rather than holding the screen (core/imagecache.lua).
local images = use("imagecache").new(function(path)
  local bmp = Bitmap.open(path)
  local w = bmp and Bitmap.getSize(bmp)
  return (w and w > 0) and { bmp, w } or false
end, 12, function()
  -- A dropped bitmap counts against EdgeTX's allowance until collected.
  collectgarbage("step")
end, 2)
screen.frame = images.frame
function screen.image(path, x, y, size)
  local b = images.get(path)
  if b then
    lcd.drawBitmap(b[1], x + ox, y + oy, floor(size * 100 / b[2]))
  end
end

--- Sets the size drawing is clipped to.
function screen.size(w, h)
  screen.w, screen.h = w, h
  screen.maxX, screen.maxY = w - 1, h - 1
end

return screen
