-- A fake device that answers as the gyro's menu does (ArduPlane/gyro_menu.cpp
-- in ardupilot-gyro, AP_CRSF_Telem.cpp), for the device client and the
-- browser.

local FC, RADIO = 0xC8, 0xEA

local function str(out, s)
  for _, b in ipairs({ string.byte(s, 1, -1) }) do
    out[#out + 1] = b
  end
  out[#out + 1] = 0
  return out
end

local function i32(out, v)
  if v < 0 then
    v = v + 2 ^ 32
  end
  out[#out + 1] = math.floor(v / 16777216) % 256
  out[#out + 1] = math.floor(v / 65536) % 256
  out[#out + 1] = math.floor(v / 256) % 256
  out[#out + 1] = math.floor(v % 256)
  return out
end

-- Entries as the device holds them: parent, then the packed entry.
local function folder(parent, name, children)
  local d = str({ parent, 11 }, name)
  for _, c in ipairs(children) do
    d[#d + 1] = c
  end
  d[#d + 1] = 0xFF
  return d
end

local function selection(parent, name, options, value, hidden)
  local d = str({ parent, 9 + (hidden and 128 or 0) }, name)
  str(d, table.concat(options, ";"))
  d[#d + 1] = value
  d[#d + 1] = 0
  d[#d + 1] = #options - 1
  d[#d + 1] = value
  return str(d, "")
end

local function number(parent, name, raw, min, max, decimals, step, unit)
  local d = str({ parent, 8 }, name)
  i32(d, raw)
  i32(d, min)
  i32(d, max)
  i32(d, raw)
  d[#d + 1] = decimals
  i32(d, step)
  return str(d, unit)
end

local function info(parent, name, text)
  return str(str({ parent, 12 }, name), text)
end

local function command(parent, name, status, text)
  local d = str({ parent, 13 }, name)
  d[#d + 1] = status
  d[#d + 1] = 25 -- poll every 250 ms
  return str(d, text)
end

-- The name of a packed entry: from its third byte to the zero.
local function nameOf(d)
  local out = {}
  for k = 3, #d do
    if d[k] == 0 then
      break
    end
    out[#out + 1] = string.char(d[k])
  end
  return table.concat(out)
end

-- The frame answering a read of chunk `chunk` of `data` (parent first), as
-- AP_CRSF_Telem.cpp chunks it: up to 55 bytes of the entry from chunk * 55,
-- the parent before the first chunk only. `old` is the stock maths, which
-- counted the parent in the first chunk's 55 and sent one byte past the end:
-- an entry of 54 or 109 bytes went out with nothing after the parent.
local function chunkFrame(id, data, chunk, old)
  local len = #data - 1
  local start, n, left
  if old then
    local chunks = math.floor(len / 55) + 1
    left = chunks - 1 - chunk
    start, n = chunk * 55, left > 0 and 55 or (len + 1) % 55
  else
    start = math.min(chunk * 55, len)
    n = math.min(len - start, 55)
    left = math.floor((len - start - n + 54) / 55)
  end
  local r = { RADIO, FC, id, left }
  if chunk == 0 then
    r[#r + 1] = data[1]
  end
  for k = start + 1, start + n do
    r[#r + 1] = data[k + 1] or 0
  end
  return r
end

-- With `opts.radio`, also the Radio folder: channels each followed by the
-- command that learns it. `opts.root` false leaves entry 0 unanswered, "empty"
-- answers it with no entries; `opts.oldChunks` chunks as stock ArduPilot did.
local function fakeDevice(opts)
  opts = opts or {}
  local dev = {
    entries = {
      [1] = info(0, "Status", "DISARMED MANUAL GPS none"),
      [2] = folder(0, "5 Failsafe", { 3, 4, 5 }),
      [3] = selection(2, "Link loss", { "FBWA glide", "RTL if GPS" }, 0),
      [4] = number(2, "RTL altitude", 100, 20, 400, 0, 10, "m"),
      [5] = selection(2, "RTL", { "x" }, 0, true),
      [6] = number(0, "Gain knob min", 25, 0, 100, 2, 5, ""),
      [7] = command(0, "Check mode switch", 0, ""),
      -- longer than one 55-byte chunk
      [8] = info(0, "Firmware", string.rep("ArduPlane V4.7.0-dev gyro ", 3)),
    },
    count = 8,
    sent = {},
    -- requests the device drops, by id, to exercise retries
    drop = { [4] = 1 },
    -- reads asked, by id
    reads = {},
  }
  if opts.radio then
    dev.entries[9] = folder(0, "2 Radio", { 10, 11, 12, 13, 14 })
    dev.entries[10] = command(9, "Learn sticks", 0, "")
    dev.entries[11] = selection(9, "Arm switch", { "Off", "Ch5", "Ch6" }, 1)
    dev.entries[12] = command(9, "Learn arm switch", 0, "")
    dev.entries[13] = selection(9, "Autotune switch", { "Off", "Ch5", "Ch6" }, 2)
    dev.entries[14] = command(9, "Learn autotune sw", 0, "")
    dev.count = 14
  end
  function dev.push(frameType, payload)
    dev.sent[#dev.sent + 1] = { frameType, payload }
    return true
  end
  -- Answers everything sent since the last call; returns the replies.
  function dev.answer()
    local replies = {}
    for _, f in ipairs(dev.sent) do
      local t, p = f[1], f[2]
      if t == 0x28 then
        replies[#replies + 1] = { 0x29, str({ RADIO, FC }, "Gyro") }
        local r = replies[#replies][2]
        i32(r, 0x04070000)
        i32(r, 0)
        i32(r, 0)
        r[#r + 1] = dev.count
        r[#r + 1] = 0
      elseif t == 0x2C and p[1] == FC then
        local id, chunk = p[3], p[4]
        if chunk == 0 then
          dev.reads[id] = (dev.reads[id] or 0) + 1
        end
        if id == 0 then
          -- the root folder, answered in one frame as the firmware does:
          -- the top-level entries in order
          if opts.root ~= false then
            local top = {}
            for k = 1, dev.count do
              if opts.root ~= "empty" and dev.entries[k][1] == 0 then
                top[#top + 1] = k
              end
            end
            replies[#replies + 1] = { 0x2B, chunkFrame(0, folder(0, "root", top), 0) }
          end
        elseif dev.drop[id] and dev.drop[id] > 0 then
          dev.drop[id] = dev.drop[id] - 1
        else
          local data = dev.entries[id]
          replies[#replies + 1] = { 0x2B, chunkFrame(id, data, chunk, opts.oldChunks and data[2] ~= 11) }
        end
      elseif t == 0x2D and p[1] == FC then
        local id = p[3]
        local e = dev.entries[id]
        if e[2] == 13 then
          local action = p[4]
          local status, text = 0, ""
          if action == 1 or action == 6 then
            status, text = 2, "Ch6 Low: MANUAL"
          end
          dev.entries[id] = command(e[1], nameOf(e), status, text)
          local r = { RADIO, FC, id, 0 }
          for _, b in ipairs(dev.entries[id]) do
            r[#r + 1] = b
          end
          replies[#replies + 1] = { 0x2B, r }
        else
          if e[2] == 9 then
            dev.entries[id] = selection(2, "Link loss", { "FBWA glide", "RTL if GPS" }, p[4])
          end
          replies[#replies + 1] = { 0x2D, { RADIO, FC, id, p[4] } }
        end
      end
    end
    dev.sent = {}
    return replies
  end
  return dev
end

-- Runs the client against the device until nothing more is sent.
local function run(client, dev, now, steps)
  for _ = 1, steps or 200 do
    client:update(now)
    local replies = dev.answer()
    for _, r in ipairs(replies) do
      client:handle(r[1], r[2], now)
    end
    now = now + 0.1
  end
  return now
end

return { new = fakeDevice, run = run, FC = FC, command = command, info = info, chunkFrame = chunkFrame }
