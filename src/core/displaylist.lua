-- A canvas that records draw calls, and their replay onto a real one.
--
-- Radios stop a script after about 20,000 Lua instructions per call, and a
-- full HUD at 800x480 is most of that in layout and most of it again in
-- drawing. Ethos gives wakeup and paint each their own budget, so the HUD is
-- laid out into this list in one and replayed in the other.
--
-- Operations live in one flat array, a fixed stride apart, and the array is
-- reused from frame to frame, so recording allocates nothing.

local M = {}

local FILL, TRI, LINE, TEXT, ICON = 1, 2, 3, 4, 5
local STRIDE = 9

--- A recording canvas. `measure(str, size, bold)` answers textWidth, which
--- layout needs before anything is drawn.
function M.recorder(measure)
  local ops = {}
  local c = { ops = ops, n = 0, w = 0, h = 0 }
  local function push(kind, a, b, d, e, f, g, h2, k)
    local n = c.n
    ops[n + 1], ops[n + 2], ops[n + 3], ops[n + 4], ops[n + 5] = kind, a, b, d, e
    ops[n + 6], ops[n + 7], ops[n + 8], ops[n + 9] = f, g, h2, k
    c.n = n + STRIDE
  end
  function c.fill(x, y, w, h, color, alpha)
    push(FILL, x, y, w, h, color, alpha)
  end
  function c.tri(x1, y1, x2, y2, x3, y3, color, alpha)
    push(TRI, x1, y1, x2, y2, x3, y3, color, alpha)
  end
  function c.line(x1, y1, x2, y2, color, width)
    push(LINE, x1, y1, x2, y2, color, width)
  end
  function c.text(x, y, str, size, color, align, bold)
    push(TEXT, x, y, str, size, color, align, bold)
  end
  function c.icon(name, x, y, size)
    push(ICON, name, x, y, size)
  end
  c.textWidth = measure
  --- Starts a new frame of the given size.
  function c.reset(w, h)
    c.n, c.w, c.h = 0, w, h
  end
  return c
end

--- Draws a recording onto canvas `t`.
function M.replay(rec, t)
  local ops = rec.ops
  local fill, tri, line, text, icon = t.fill, t.tri, t.line, t.text, t.icon
  for i = 1, rec.n, STRIDE do
    local k = ops[i]
    if k == TRI then
      tri(ops[i + 1], ops[i + 2], ops[i + 3], ops[i + 4], ops[i + 5], ops[i + 6], ops[i + 7], ops[i + 8])
    elseif k == LINE then
      line(ops[i + 1], ops[i + 2], ops[i + 3], ops[i + 4], ops[i + 5], ops[i + 6])
    elseif k == TEXT then
      text(ops[i + 1], ops[i + 2], ops[i + 3], ops[i + 4], ops[i + 5], ops[i + 6], ops[i + 7])
    elseif k == ICON then
      icon(ops[i + 1], ops[i + 2], ops[i + 3], ops[i + 4])
    else
      fill(ops[i + 1], ops[i + 2], ops[i + 3], ops[i + 4], ops[i + 5], ops[i + 6])
    end
  end
end

return M
