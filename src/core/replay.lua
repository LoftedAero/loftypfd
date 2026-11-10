-- Plays back a recorded CRSF stream as if it were arriving now.
--
-- For the simulators, which have no telemetry link, and for a radio on the
-- bench: a flight recorded from ArduPilot SITL (tools/sitl.py record) is fed
-- through the same decoder a live link uses. A recording is lines of
-- "<seconds> <frame type> <payload hex>"; it loops when it runs out.

local use = ...
local crsf = use("crsf")
local vehicle = use("vehicle")

local M = {}

local Player = {}
Player.__index = Player

--- `open()` returns a reader: a function giving the next chunk of the file,
--- or nil at its end. Files are read a chunk at a time, since a recording
--- is larger than an EdgeTX script should hold.
function M.new(open)
  return setmetatable({ open = open }, Player)
end

local function nextLine(self)
  while true do
    local i = string.find(self.buf, "\n", self.pos, true)
    if i then
      local line = string.sub(self.buf, self.pos, i - 1)
      self.pos = i + 1
      return line
    end
    local chunk = self.read and self.read()
    if not chunk then
      local rest = string.sub(self.buf, self.pos)
      self.buf, self.pos = "", 1
      return rest ~= "" and rest or nil
    end
    self.buf = string.sub(self.buf, self.pos) .. chunk
    self.pos = 1
  end
end

local function parse(line)
  local t, ftype, hex = string.match(line, "^(%S+)%s+(%d+)%s+(%x*)")
  if not t then
    return nil
  end
  local data = {}
  for k = 1, #hex - 1, 2 do
    data[#data + 1] = tonumber(string.sub(hex, k, k + 1), 16)
  end
  return tonumber(t), tonumber(ftype), data
end

--- Applies the frames due by `now` to state `s`, at most `limit` of them;
--- returns the new state when the recording started over, so the caller can
--- replace its own. Past the limit the recording falls behind rather than
--- catching up: after a stall (a busy simulator) a burst of every frame
--- since would use up the radio's instruction budget.
function Player:update(s, now, limit)
  if not self.read then
    self.read = self.open()
    self.buf, self.pos = "", 1
    self.base = now
    self.pending, self.last = nil, nil
  end
  local restarted
  local left = limit or math.huge
  while true do
    if not self.pending then
      local line = nextLine(self)
      if not line then
        -- Start over with a fresh state, as a new flight would.
        self.read = nil
        restarted = vehicle.new()
        break
      end
      local t, ftype, data = parse(line)
      if t then
        self.pending = { t = t, type = ftype, data = data }
      end
    end
    local p = self.pending
    if p then
      if p.t > now - self.base then
        break
      end
      if left == 0 then
        -- The recording resumes from the last frame played, its spacing kept.
        self.base = now - (self.last or p.t)
        break
      end
      crsf.apply(s, p.type, p.data, now)
      self.pending = nil
      self.last = p.t
      left = left - 1
    end
  end
  return restarted
end

return M
