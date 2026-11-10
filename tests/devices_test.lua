-- The device client against a fake gyro (tests/lib/fakegyro.lua).

local use, T = ...
local devices = use("devices")

local fake = T.lib("fakegyro")
local fakeDevice, run, FC, command = fake.new, fake.run, fake.FC, fake.command

T.case("finds a device and loads its menu", function()
  local dev = fakeDevice()
  local client = devices.new(dev.push)
  client:ping()
  local now = run(client, dev, 0, 3)
  local d = client.devices[FC]
  T.ok(d, "device found")
  T.eq(d.name, "Gyro", "name")
  T.eq(d.count, 8, "count")
  client:load(FC)
  run(client, dev, now)
  local loaded, total = client:progress(FC)
  T.eq(loaded, total, "everything loaded, the dropped read retried")

  local top = client:children(FC, 0)
  T.eq(#top, 5, "top level")
  T.eq(top[1].name, "Status", "first")
  T.eq(top[2].type, devices.FIELD.folder, "folder")
  local fs = client:children(FC, 2)
  T.eq(#fs, 2, "hidden entry left out")
  T.eq(fs[1].options[2], "RTL if GPS", "options")
  T.eq(fs[2].value, 100, "number")
  T.eq(fs[2].unit, "m", "unit")
  T.near(d.entries[6].value, 0.25, 1e-9, "decimals")
  T.eq(d.entries[8].value, string.rep("ArduPlane V4.7.0-dev gyro ", 3), "chunked entry")
end)

T.case("a write is read back", function()
  local dev = fakeDevice()
  local client = devices.new(dev.push)
  client:ping()
  local now = run(client, dev, 0, 3)
  client:load(FC)
  now = run(client, dev, now)
  client:write(FC, 3, 1)
  run(client, dev, now, 5)
  T.eq(client.devices[FC].entries[3].value, 1, "new value")
end)

T.case("a command runs, polls and is canceled", function()
  local dev = fakeDevice()
  local client = devices.new(dev.push)
  client:ping()
  local now = run(client, dev, 0, 3)
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
