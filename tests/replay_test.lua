local use, T = ...
local replay = use("replay")
local vehicle = use("vehicle")

-- Pitch 10 deg, roll -30, yaw -90 (attitude frame 30 = 0x1E), then FBWA (33 = 0x21).
local RECORDING = "0.000 30 06d1eb8cc2a4\n0.500 33 4642574100\n1.000 30 000000000000"

-- Hands the file over a few bytes at a time, as a radio's reads would.
local function opener(text, size)
  return function()
    local pos = 1
    return function()
      if pos > #text then
        return nil
      end
      local chunk = string.sub(text, pos, pos + size - 1)
      pos = pos + size
      return chunk
    end
  end
end

T.case("plays frames when they fall due", function()
  local s = vehicle.new()
  local p = replay.new(opener(RECORDING, 7))
  p:update(s, 100)
  T.near(s.pitch, 10, 0.01, "first frame at once")
  T.eq(vehicle.modeName(s), nil, "second not yet")
  p:update(s, 100.6)
  T.eq(vehicle.modeName(s), "FBWA", "second after half a second")
end)

T.case("starts over with a fresh state", function()
  local s = vehicle.new()
  local p = replay.new(opener(RECORDING, 64))
  p:update(s, 0)
  -- the last frame falls due, the file ends, and it starts over
  local fresh = p:update(s, 1.1)
  T.ok(fresh ~= nil, "restarted")
  T.eq(fresh.pitch, nil, "fresh state")
  p:update(fresh, 1.3)
  T.near(fresh.pitch, 10, 0.01, "from the top")
end)

T.case("after a stall it falls behind rather than catching up", function()
  local s = vehicle.new()
  local p = replay.new(opener(RECORDING, 64))
  p:update(s, 0, 1)
  T.near(s.pitch, 10, 0.01, "first frame")
  -- a minute without a call: one frame, not the whole backlog
  p:update(s, 60, 1)
  T.eq(vehicle.modeName(s), "FBWA", "the next frame")
  T.near(s.pitch, 10, 0.01, "not the one after")
  p:update(s, 60.1, 1)
  T.near(s.pitch, 10, 0.01, "and the rest keeps its spacing")
  p:update(s, 60.6, 1)
  T.near(s.pitch, 0, 0.01, "half a second later")
end)
