-- Bitmaps loaded from files, kept while they are being drawn.
--
-- A map shows nine tiles at most, and a decoded 256 px tile is 128 kB:
-- EdgeTX refuses a bitmap past its Lua bitmap allowance, so only the most
-- recently drawn are kept. A file that is not there is remembered too, since
-- looking for it again every frame costs a card read.
--
-- Decoding a tile takes about a third of a second on the X20, so a new zoom
-- level froze the screen for two seconds while all its tiles loaded. Only a
-- few are loaded each frame; the rest wait their turn, drawn meanwhile as the
-- map's plain ground, so the map answers at once and fills in.

local M = {}

--- A cache over `load(path)`, which returns a bitmap or false, holding at
--- most `limit` entries; `free(bitmap)`, if given, is called on each one
--- dropped. At most `perFrame` files are loaded between calls to `frame()`
--- (all, if not given); `get` returns nil for one still waiting.
function M.new(load, limit, free, perFrame)
  local entries, count, clock, loaded = {}, 0, 0, 0
  local cache = {}

  --- Starts a frame: its share of loading begins again.
  function cache.frame()
    loaded = 0
  end

  function cache.get(path)
    clock = clock + 1
    local e = entries[path]
    if e then
      e.used = clock
      return e.bitmap
    end
    if perFrame and loaded >= perFrame then
      return nil
    end
    loaded = loaded + 1
    if count >= limit then
      local oldest, at
      for p, other in pairs(entries) do
        if not at or other.used < at then
          oldest, at = p, other.used
        end
      end
      local gone = entries[oldest]
      entries[oldest] = nil
      count = count - 1
      if gone.bitmap and free then
        free(gone.bitmap)
      end
    end
    local bitmap = load(path) or false
    entries[path] = { bitmap = bitmap, used = clock }
    count = count + 1
    return bitmap
  end
  return cache
end

return M
