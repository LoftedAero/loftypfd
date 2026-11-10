-- A canvas for one rectangle of another: the HUD draws in its own
-- coordinates and lands where a layout puts it.

local M = {}

--- A canvas drawing into (x, y, w, h) of `base`.
function M.new(base, x, y, w, h)
  local fill, tri, line, text = base.fill, base.tri, base.line, base.text
  local c = { w = w, h = h, textWidth = base.textWidth }
  function c.fill(px, py, pw, ph, color, alpha)
    fill(px + x, py + y, pw, ph, color, alpha)
  end
  function c.tri(x1, y1, x2, y2, x3, y3, color, alpha)
    tri(x1 + x, y1 + y, x2 + x, y2 + y, x3 + x, y3 + y, color, alpha)
  end
  function c.line(x1, y1, x2, y2, color, width)
    line(x1 + x, y1 + y, x2 + x, y2 + y, color, width)
  end
  function c.text(px, py, str, size, color, align, bold)
    text(px + x, py + y, str, size, color, align, bold)
  end
  if base.shadowText then
    local shadow = base.shadowText
    function c.shadowText(px, py, str, size, color, align, bold)
      shadow(px + x, py + y, str, size, color, align, bold)
    end
  end
  return c
end

return M
