-- The CRSF device menu: what the ExpressLRS script shows under Other Devices.
--
-- Every CRSF device (the transmitter module, the receiver, a flight
-- controller) answers a ping with its name and how many settings it has, and
-- serves each setting as an entry read by number, in chunks. Writes change a
-- value; commands run a short dialog driven by the device. This client loads
-- a device's entries one request at a time, retries what goes unanswered,
-- and keeps the entries current as the device answers.
--
-- The radio's own push function sends a frame: push(frameType, payload) with
-- the payload starting at the destination address. It may refuse while its
-- queue is full; the request then goes out on a later update.

local use = ...
local bits = use("bits")

local u32be, i32be, cstring = bits.u32be, bits.i32be, bits.cstring

local M = {}

local RADIO = 0xEA
local T_PING, T_INFO, T_ENTRY, T_READ, T_WRITE = 0x28, 0x29, 0x2B, 0x2C, 0x2D

M.FIELD = {
  uint8 = 0, int8 = 1, uint16 = 2, int16 = 3, uint32 = 4, int32 = 5,
  float = 8, select = 9, string = 10, folder = 11, info = 12, command = 13,
}

M.COMMAND = {
  ready = 0, start = 1, progress = 2, confirmationNeeded = 3,
  confirm = 4, cancel = 5, poll = 6,
}

-- How long an unanswered read waits before it is sent again. Long enough for
-- a flight controller that answers between telemetry frames on a slow link.
local RETRY_S = 1.0

local INT_SIZE = { [0] = 1, 1, 2, 2, 4, 4 }

local function readInt(d, i, size, isSigned)
  local v = 0
  for k = 0, size - 1 do
    v = v * 256 + (d[i + k] or 0)
  end
  if isSigned then
    v = bits.signed(v, size * 8)
  end
  return v, i + size
end

--- Decodes an entry from its bytes, all chunks joined. Missing trailing
--- fields are left nil rather than failing, since devices differ in what
--- they send after the value.
function M.parseEntry(id, d)
  local e = { id = id, parent = d[1], type = d[2] % 128, hidden = d[2] >= 128 }
  local i
  e.name, i = cstring(d, 3)
  local t = e.type
  if t <= 5 then
    local size, isSigned = INT_SIZE[t], t % 2 == 1
    e.value, i = readInt(d, i, size, isSigned)
    e.min, i = readInt(d, i, size, isSigned)
    e.max, i = readInt(d, i, size, isSigned)
    if d[i + size] then
      e.default, i = readInt(d, i, size, isSigned)
    end
    e.unit = cstring(d, i)
  elseif t == 8 then
    e.raw = i32be(d, i)
    e.min = i32be(d, i + 4)
    e.max = i32be(d, i + 8)
    e.default = i32be(d, i + 12)
    e.decimals = d[i + 16]
    e.step = i32be(d, i + 17)
    e.unit = cstring(d, i + 21)
    e.value = e.raw / 10 ^ e.decimals
  elseif t == 9 then
    local options
    options, i = cstring(d, i)
    e.options = {}
    for option in string.gmatch((options .. ";"), "([^;]*);") do
      e.options[#e.options + 1] = option
    end
    e.value = d[i]
    e.min = d[i + 1]
    e.max = d[i + 2]
    e.default = d[i + 3]
    e.unit = d[i + 4] and cstring(d, i + 4) or ""
  elseif t == 10 or t == 12 then
    e.value = cstring(d, i)
  elseif t == 11 then
    e.children = {}
    while d[i] and d[i] ~= 0xFF do
      e.children[#e.children + 1] = d[i]
      i = i + 1
    end
  elseif t == 13 then
    e.status = d[i]
    e.timeout = d[i + 1]
    e.info = cstring(d, i + 2)
  end
  return e
end

--- The bytes a write of `value` carries for entry `e`: the raw scaled
--- integer for a number, the option index for a selection, a command status.
function M.encodeValue(e, value)
  local t = e.type
  if t <= 5 then
    local out, size = {}, INT_SIZE[t]
    value = math.floor(value)
    for k = size - 1, 0, -1 do
      out[#out + 1] = (value >> (k * 8)) & 0xFF
    end
    return out
  elseif t == 8 then
    return bits.put32be({}, value)
  elseif t == 10 then
    local out = { string.byte(value, 1, -1) }
    out[#out + 1] = 0
    return out
  end
  return { value }
end

local Client = {}
Client.__index = Client

--- A client sending through `push`. Devices are keyed by CRSF address.
function M.new(push)
  return setmetatable({ push = push, devices = {}, jobs = {}, current = nil }, Client)
end

--- Asks every device on the link to say who it is.
function Client:ping()
  self.pingPending = true
end

local function job(self, j, first)
  if first then
    table.insert(self.jobs, 1, j)
  else
    self.jobs[#self.jobs + 1] = j
  end
end

--- Loads every entry of a device, after its info has arrived.
function Client:load(address)
  local dev = self.devices[address]
  if not dev then
    return
  end
  for id = 1, dev.count do
    if not dev.entries[id] then
      job(self, { kind = "read", address = address, id = id, chunk = 0, data = {} })
    end
  end
end

--- Reads one entry again, ahead of anything already queued.
function Client:refresh(address, id)
  job(self, { kind = "read", address = address, id = id, chunk = 0, data = {} }, true)
end

--- Writes a value: for a number the raw integer the device scales by its
--- decimals, for a selection the option index. The entry is read back
--- afterwards, so it shows what the device accepted.
function Client:write(address, id, value)
  local dev = self.devices[address]
  local e = dev and dev.entries[id]
  if not e then
    return
  end
  job(self, { kind = "read", address = address, id = id, chunk = 0, data = {} }, true)
  job(self, { kind = "write", address = address, id = id, bytes = M.encodeValue(e, value) }, true)
end

--- Sends a command action (start, confirm, cancel, poll) to a command entry.
--- The device answers with the entry, carrying the new status and its text.
function Client:command(address, id, action)
  local dev = self.devices[address]
  local e = dev and dev.entries[id]
  if not e then
    return
  end
  if action == M.COMMAND.start or action == M.COMMAND.confirm then
    dev.running = id
  elseif action == M.COMMAND.cancel then
    dev.running = nil
  end
  job(self, { kind = "write", address = address, id = id, bytes = { action }, command = true }, true)
end

local function send(self, frameType, payload)
  return self.push(frameType, payload) ~= false
end

-- Starts the next queued job if nothing is waiting for an answer.
local function next(self, now)
  if self.current then
    return
  end
  local j = self.jobs[1]
  if not j then
    return
  end
  local ok
  if j.kind == "read" then
    ok = send(self, T_READ, { j.address, RADIO, j.id, j.chunk })
  else
    local payload = { j.address, RADIO, j.id }
    for _, b in ipairs(j.bytes) do
      payload[#payload + 1] = b
    end
    ok = send(self, T_WRITE, payload)
  end
  if not ok then
    return
  end
  table.remove(self.jobs, 1)
  if j.kind == "read" then
    j.sent = now
    self.current = j
  elseif j.command then
    -- The answer is the entry itself; wait for it like a read.
    j.kind = "read"
    j.chunk = 0
    j.data = {}
    j.sent = now
    self.current = j
  end
end

--- Sends what is due: the ping, the next request, retries, command polls.
function Client:update(now)
  if self.pingPending and send(self, T_PING, { 0x00, RADIO }) then
    self.pingPending = false
  end
  local c = self.current
  if c and now - c.sent > RETRY_S then
    -- Unanswered: ask again from the first chunk.
    self.current = nil
    c.chunk = 0
    c.data = {}
    job(self, c, true)
  end
  -- A running command is polled at the interval the device asked for.
  for address, dev in pairs(self.devices) do
    local e = dev.running and dev.entries[dev.running]
    if e and e.status == M.COMMAND.progress then
      local interval = (e.timeout or 10) / 100
      if not dev.lastPoll or now - dev.lastPoll >= interval then
        dev.lastPoll = now
        self:command(address, e.id, M.COMMAND.poll)
      end
    end
  end
  next(self, now)
end

local function deviceInfo(self, d)
  local origin = d[2]
  local name, i = cstring(d, 3)
  local dev = self.devices[origin]
  local count, version = d[i + 12], d[i + 13]
  -- A device that changed its menu (new firmware, a different count) starts
  -- over, rather than keeping entries numbered for the old one.
  if not dev or dev.count ~= count or dev.version ~= version or dev.name ~= name then
    dev = { address = origin, entries = {} }
    self.devices[origin] = dev
  end
  dev.name = name
  dev.serial = u32be(d, i)
  dev.hardware = u32be(d, i + 4)
  dev.software = u32be(d, i + 8)
  dev.count = count
  dev.version = version
end

local function entry(self, d, now)
  local origin, id, chunksLeft = d[2], d[3], d[4]
  local dev = self.devices[origin]
  if not dev then
    return
  end
  local c = self.current
  local data
  if c and c.address == origin and c.id == id then
    data = c.data
  elseif chunksLeft == 0 then
    -- An entry the device sent on its own, such as a command's progress.
    data = {}
  else
    return
  end
  for k = 5, #d do
    data[#data + 1] = d[k]
  end
  if chunksLeft > 0 then
    c.chunk = c.chunk + 1
    c.sent = now
    self.current = nil
    job(self, c, true)
    return
  end
  if c and c.address == origin and c.id == id then
    self.current = nil
  end
  local e = M.parseEntry(id, data)
  dev.entries[id] = e
  if e.type == M.FIELD.command and dev.running == id and e.status == M.COMMAND.ready then
    dev.running = nil
  end
end

--- Takes one received frame. Returns whether it belonged to the device menu.
function Client:handle(frameType, d, now)
  if d[1] ~= RADIO and d[1] ~= 0x00 then
    return false
  end
  if frameType == T_INFO then
    deviceInfo(self, d)
  elseif frameType == T_ENTRY then
    entry(self, d, now)
  elseif frameType == T_WRITE then
    -- Some devices echo a write's value; the read-back that follows every
    -- write is what counts.
  else
    return false
  end
  return true
end

--- How many of a device's entries have loaded, and how many it has.
function Client:progress(address)
  local dev = self.devices[address]
  if not dev then
    return 0, 0
  end
  local n = 0
  for id = 1, dev.count do
    if dev.entries[id] then
      n = n + 1
    end
  end
  return n, dev.count
end

--- The visible entries in a folder, in the device's order. Folder 0 is the
--- top level.
function Client:children(address, folder)
  local dev = self.devices[address]
  local out = {}
  if not dev then
    return out
  end
  local f = folder ~= 0 and dev.entries[folder]
  if f and f.children and #f.children > 0 then
    for _, id in ipairs(f.children) do
      local e = dev.entries[id]
      if e and not e.hidden then
        out[#out + 1] = e
      end
    end
    return out
  end
  for id = 1, dev.count do
    local e = dev.entries[id]
    if e and e.parent == folder and not e.hidden then
      out[#out + 1] = e
    end
  end
  return out
end

return M
