-- Development only: a device that answers from a recorded menu
-- (tools/sitl.py menu), so a simulator with no CRSF device can show the
-- browser. tools/build.py --menu puts it beside the core as core/snapshot.lua
-- with the recording as menu.txt; the platforms use it in place of the link
-- when that file is there.
--
-- Reads are answered from the recording. A write to a selection or a number
-- changes the recorded value; a command asks for confirmation once and is
-- then ready again.

local use = ...
local bits = use("bits")

local M = {}

local function bytes(hex)
  local d = {}
  for k = 1, #hex - 1, 2 do
    d[#d + 1] = tonumber(string.sub(hex, k, k + 1), 16)
  end
  return d
end

--- A link over the recording's text: push(frameType, payload) as a radio
--- sends, pop() for the answers. Frames stay hex until asked for: decoding
--- them all at once is more than a radio lets a script do in one call.
function M.new(text)
  local info, entries, chunks = nil, {}, {}
  for ty, hex in string.gmatch(text, "%S+ (%d+) (%x+)") do
    if tonumber(ty) == 0x29 then
      info = hex
    elseif tonumber(ty) == 0x2B then
      local id = tonumber(string.sub(hex, 5, 6), 16)
      local left = tonumber(string.sub(hex, 7, 8), 16)
      entries[id] = entries[id] or {}
      -- keyed by chunks left, as the frame says it
      entries[id][left] = hex
      chunks[id] = math.max(chunks[id] or 0, left + 1)
    end
  end

  -- An entry's frame, decoded the first time it is wanted.
  local function frameOf(id, left)
    local f = entries[id][left]
    if type(f) == "string" then
      f = bytes(f)
      entries[id][left] = f
    end
    return f
  end

  local queue = {}
  local function answer(frameType, d)
    queue[#queue + 1] = { frameType, d }
  end

  -- Where an entry's value starts in its frame: after the header (4 bytes),
  -- parent, type and name.
  local function valueAt(d)
    local _, i = bits.cstring(d, 7)
    return i
  end

  local function write(id, p)
    if chunks[id] ~= 1 then
      return
    end
    local d = frameOf(id, 0)
    local t = d[6] % 128
    local i = valueAt(d)
    if t == 9 then
      local _, after = bits.cstring(d, i)
      d[after] = p[4]
    elseif t == 8 then
      for k = 0, 3 do
        d[i + k] = p[4 + k]
      end
    elseif t == 13 then
      d[i] = p[4] == 1 and 3 or 0
      answer(0x2B, d)
    end
  end

  local link = {}
  function link.push(frameType, p)
    if frameType == 0x28 and info then
      if type(info) == "string" then
        info = bytes(info)
      end
      answer(0x29, info)
    elseif frameType == 0x2C and entries[p[3]] then
      local f = entries[p[3]][chunks[p[3]] - 1 - p[4]] and frameOf(p[3], chunks[p[3]] - 1 - p[4])
      if f then
        answer(0x2B, f)
      end
    elseif frameType == 0x2D and entries[p[3]] then
      write(p[3], p)
    end
    return true
  end
  function link.pop()
    local f = table.remove(queue, 1)
    if f then
      return f[1], f[2]
    end
  end
  return link
end

return M
