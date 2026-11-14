-- The device client against a fake gyro (tests/lib/fakegyro.lua).

local use, T = ...
local devices = use("devices")

local fake = T.lib("fakegyro")
local fakeDevice, run, FC, command = fake.new, fake.run, fake.FC, fake.command

-- A client that has found the fake device.
local function found(opts)
  local dev = fakeDevice(opts)
  local client = devices.new(dev.push)
  client:ping()
  local now = run(client, dev, 0, 3)
  return dev, client, now
end

T.case("finds a device and reads its top level only", function()
  local dev, client, now = found()
  local d = client.devices[FC]
  T.ok(d, "device found")
  T.eq(d.name, "Gyro", "name")
  T.eq(d.count, 8, "count")
  client:load(FC)
  now = run(client, dev, now)
  T.eq(d.entries[0].name, "root", "entry 0 is the root folder")
  local loaded, total = client:progress(FC, 0)
  T.eq(total, 5, "the top level is what entry 0 lists")
  T.eq(loaded, 5, "and all of it loaded")
  local top = client:children(FC, 0)
  T.eq(#top, 5, "top level")
  T.eq(top[1].name, "Status", "first")
  T.eq(top[2].type, devices.FIELD.folder, "folder")
  T.eq(dev.reads[3], nil, "a folder's entries are not read before it opens")
  T.eq(d.entries[8].value, string.rep("ArduPlane V4.7.0-dev gyro ", 3), "chunked entry")
  T.near(d.entries[6].value, 0.25, 1e-9, "decimals")

  client:open(FC, 2)
  run(client, dev, now)
  T.eq(select(1, client:progress(FC, 2)), 3, "the folder loaded, the dropped read retried")
  T.ok(d.entries[5] and d.entries[5].hidden, "hidden entries are read with their folder")
  local fs = client:children(FC, 2)
  T.eq(#fs, 2, "hidden entry left out")
  T.eq(fs[1].options[2], "RTL if GPS", "options")
  T.eq(fs[2].value, 100, "number")
  T.eq(fs[2].unit, "m", "unit")
end)

T.case("a device that does not answer entry 0 is read in full", function()
  local dev, client, now = found({ root = false })
  client:load(FC)
  run(client, dev, now)
  local d = client.devices[FC]
  T.ok(d.full, "fell back")
  T.eq(dev.reads[0], 3, "entry 0 asked three times")
  local loaded, total = client:progress(FC)
  T.eq(loaded, total, "everything loaded")
  T.eq(#client:children(FC, 0), 5, "the top level from the entries' parents")
  T.eq(#client:children(FC, 2), 2, "and a folder from its listing")
end)

T.case("a device whose entry 0 lists nothing is read in full", function()
  local dev, client, now = found({ root = "empty" })
  client:load(FC)
  run(client, dev, now)
  T.eq(dev.reads[0], 1, "entry 0 asked once")
  local loaded, total = client:progress(FC, 0)
  T.eq(loaded, total, "everything loaded")
  T.eq(total, 8, "counted over the whole device")
  T.eq(#client:children(FC, 0), 5, "top level")
end)

T.case("a full load reads every entry", function()
  local dev, client, now = found()
  client:loadAll(FC)
  run(client, dev, now)
  local loaded, total = client:progress(FC)
  T.eq(loaded, total, "everything loaded")
  T.eq(total, 8, "count")
end)

T.case("a folder opened moves its reads ahead of the queue", function()
  local dev, client, now = found({ radio = true })
  client:load(FC)
  run(client, dev, now)
  -- the two folders' entries queued behind each other
  client:loadAll(FC)
  client:open(FC, 9)
  local order = {}
  for _, j in ipairs(client.jobs) do
    order[#order + 1] = j.id
  end
  T.eq(table.concat(order, ","), "10,11,12,13,14,3,4,5", "the open folder first, each read once")
end)

T.case("an entry too short to parse is not stored and does not stop the client", function()
  -- every prefix of every entry the fake holds parses or is refused, never raises
  local dev = fakeDevice({ radio = true })
  for id, data in pairs(dev.entries) do
    local nameEnd = 3
    while data[nameEnd] ~= 0 do
      nameEnd = nameEnd + 1
    end
    for n = 0, #data do
      local d = { table.unpack(data, 1, n) }
      local ok, e = pcall(devices.parseEntry, id, d)
      T.ok(ok, "entry " .. id .. " cut to " .. n .. " bytes: " .. tostring(e))
      if n < nameEnd then
        T.eq(e, nil, "entry " .. id .. " cut inside its name is refused")
      end
    end
  end
  T.eq(devices.parseEntry(3, { 0 }), nil, "only the parent byte")
  T.eq(devices.parseEntry(3, {}), nil, "nothing")
  local rtl = dev.entries[4]
  T.eq(devices.parseEntry(4, { table.unpack(rtl, 1, #rtl - 3) }), nil, "a number cut inside its step")
  local status = dev.entries[1]
  T.eq(devices.parseEntry(1, { table.unpack(status, 1, #status - 1) }), nil, "a text with no end")
  T.eq(devices.parseEntry(1, status).value, "DISARMED MANUAL GPS none", "the whole text")
end)

T.case("an entry the stock chunking cuts short is left out after three tries", function()
  local dev, client, now = found({ oldChunks = true })
  -- 54 bytes after the parent, as "Learn gain knob" was in SITL
  local name = "Learn gain knob"
  dev.entries[7] = command(0, name, 0, string.rep("x", 49 - #name))
  T.eq(#dev.entries[7] - 1, 54, "the entry is 54 bytes")
  T.eq(#fake.chunkFrame(7, dev.entries[7], 0, true), 5, "sent as the parent alone")
  client:load(FC)
  now = run(client, dev, now)
  local d = client.devices[FC]
  T.eq(d.entries[7], nil, "not stored")
  T.ok(d.failed[7], "left out")
  T.eq(dev.reads[7], 3, "asked three times")
  local loaded, total = client:progress(FC, 0)
  T.eq(loaded, total, "the top level settles")
  T.eq(#client:children(FC, 0), 4, "the rest shows")
  T.eq(d.entries[8].value, string.rep("ArduPlane V4.7.0-dev gyro ", 3), "a two-chunk entry with the stray byte")
  -- the folder opened again asks again, three times more
  client:open(FC, 0)
  run(client, dev, now)
  T.eq(dev.reads[7], 6, "asked again on opening")
end)

T.case("a write is read back", function()
  local dev, client, now = found()
  client:load(FC)
  now = run(client, dev, now)
  client:open(FC, 2)
  now = run(client, dev, now)
  client:write(FC, 3, 1)
  run(client, dev, now, 5)
  T.eq(client.devices[FC].entries[3].value, 1, "new value")
end)

T.case("a command runs, polls and is canceled", function()
  local dev, client, now = found()
  client:load(FC)
  now = run(client, dev, now)
  client:command(FC, 7, devices.COMMAND.start)
  now = run(client, dev, now, 2)
  local e = client.devices[FC].entries[7]
  T.eq(e.status, devices.COMMAND.progress, "running")
  T.eq(e.info, "Ch6 Low: MANUAL", "text")
  -- it keeps polling at the device's 250 ms interval
  local polls = 0
  local push = dev.push
  dev.push = function(t, p)
    if t == 0x2D and p[4] == devices.COMMAND.poll then
      polls = polls + 1
    end
    return push(t, p)
  end
  client.push = dev.push
  now = run(client, dev, now, 10)
  T.ok(polls >= 3, "polled")
  client:command(FC, 7, devices.COMMAND.cancel)
  run(client, dev, now, 3)
  T.eq(client.devices[FC].entries[7].status, devices.COMMAND.ready, "closed")
  T.eq(client.devices[FC].running, nil, "not running")
end)

T.case("encodes writes by type", function()
  T.eq(#devices.encodeValue({ type = 8 }, -5), 4, "float is four bytes")
  local b = devices.encodeValue({ type = 8 }, -5)
  T.eq(b[1], 255, "two's complement")
  T.eq(b[4], 251, "low byte")
  T.eq(devices.encodeValue({ type = 9 }, 2)[1], 2, "selection index")
  local u16 = devices.encodeValue({ type = 2 }, 1500)
  T.eq(u16[1] * 256 + u16[2], 1500, "uint16")
end)
