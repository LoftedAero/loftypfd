-- The device browser against the fake gyro (tests/lib/fakegyro.lua).

local use, T = ...
local devices = use("devices")
local menu = use("menu")
local fake = T.lib("fakegyro")

local function canvas(w, h)
  local noop = function() end
  local c = { w = w, h = h, fill = noop, tri = noop, line = noop, texts = {} }
  function c.text(x, y, str)
    assert(type(str) == "string", "text is a string")
    c.texts[#c.texts + 1] = { x = x, y = y, str = str }
  end
  function c.textWidth(str, size)
    return #str * size * 0.6
  end
  function c.has(str)
    for _, t in ipairs(c.texts) do
      if t.str == str then
        return t
      end
    end
  end
  return c
end

-- A browser on the fake gyro, run until the device has answered everything.
local function browser(opts)
  local dev = fake.new(opts)
  -- armed: what the browser is told of the aircraft; pings: how many it sent
  local b = { dev = dev, pings = 0 }
  local client = devices.new(function(frameType, payload)
    if frameType == 0x28 then
      b.pings = b.pings + 1
    end
    return dev.push(frameType, payload)
  end)
  local app = menu.new(client)
  local now = 0
  b.client, b.app = client, app
  function b.run(steps)
    for _ = 1, steps or 100 do
      app:update(now, b.armed)
      for _, r in ipairs(dev.answer()) do
        client:handle(r[1], r[2], now)
      end
      now = now + 0.1
    end
  end
  function b.paint(w, h)
    local c = canvas(w or 480, h or 320)
    app:paint(c, c.w, c.h)
    return c
  end
  -- Taps the middle of the control under the first thing drawn with `str`,
  -- or else of the first on its line.
  function b.tap(str)
    local c = b.paint()
    local t = assert(c.has(str), "nothing reads " .. str)
    local found
    for _, h in ipairs(app.hits) do
      if t.y >= h[2] and t.y < h[4] and (h.row or h.commit or h.dialog or h.back) then
        if t.x >= h[1] and t.x < h[3] then
          found = h
          break
        end
        found = found or h
      end
    end
    assert(found, "no control at " .. str)
    return app:event("tap", (found[1] + found[3]) / 2, (found[2] + found[4]) / 2)
  end
  b.run(5)
  return b
end

local function written(dev, id)
  for _, f in ipairs(dev.sent) do
    if f[1] == 0x2D and f[2][3] == id then
      return f[2][4]
    end
  end
end

T.case("devices, a device, a folder, and Back one level at a time", function()
  local b = browser()
  T.ok(b.paint().has("Gyro"), "the gyro is listed")
  b.app:event("enter")
  b.run()
  local c = b.paint()
  T.ok(c.has("Gyro"), "the device's name is the title")
  T.ok(c.has("5 Failsafe"), "a folder")
  T.ok(c.has("DISARMED MANUAL GPS none"), "a reading")
  T.ok(not c.has("Link loss"), "a folder's entries stay in it")
  b.app:event("enter")
  b.run(20)
  c = b.paint()
  T.ok(c.has("Link loss") and c.has("100 m"), "the folder's entries")
  T.ok(not c.has("RTL"), "hidden entries do not show")
  b.app:event("back")
  T.ok(b.paint().has("5 Failsafe"), "Back goes up one level")
  b.app:event("back")
  T.ok(b.paint().has("Devices"), "and then to the devices")
  T.eq(b.app:event("back"), "exit", "Back at the top leaves")
end)

T.case("focus skips readings and wraps", function()
  local b = browser()
  b.app:event("enter")
  b.run()
  b.paint()
  local p = b.app.stack[2]
  T.eq(p.focus, 2, "starts on the first setting, not the Status reading")
  b.app:event("next")
  b.app:event("next")
  T.eq(p.focus, 4, "Gain knob min, then Check mode switch")
  b.app:event("next")
  T.eq(p.focus, 2, "past the Firmware reading back to the top")
end)

T.case("a selection is stepped, written and read back", function()
  local b = browser()
  b.app:event("enter")
  b.run()
  b.app:event("enter")
  b.run(20)
  b.app:event("enter")
  b.app:event("next")
  T.ok(b.paint().has("RTL if GPS"), "the edit shows the new value")
  T.eq(b.dev.sent[1], nil, "nothing written yet")
  b.app:event("enter")
  b.app:update(100)
  T.eq(written(b.dev, 3), 1, "option 1 written")
  b.run()
  local c = b.paint()
  T.ok(c.has("RTL if GPS"), "read back")
  T.eq(b.client.devices[fake.FC].entries[3].pending, nil, "no longer pending")
end)

T.case("Back leaves an edit unwritten", function()
  local b = browser()
  b.app:event("enter")
  b.run()
  b.app:event("enter")
  b.run(20)
  b.app:event("enter")
  b.app:event("next")
  b.app:event("back")
  b.run()
  T.eq(written(b.dev, 3), nil, "nothing written")
  T.ok(b.paint().has("FBWA glide"), "the device's value")
  T.ok(b.paint().has("5 Failsafe"), "Back closed only the edit")
end)

T.case("a number steps by the device's step and stops at its limits", function()
  local b = browser()
  b.app:event("enter")
  b.run()
  b.app:event("enter")
  b.run(20)
  local e = b.client.devices[fake.FC].entries[4]
  T.eq(menu.step(e, 100, 1), 110, "step 10")
  T.eq(menu.step(e, 395, 1), 400, "stops at the maximum")
  T.eq(menu.step(e, 20, -1), 20, "and the minimum")
  T.eq(menu.valueText(b.client.devices[fake.FC].entries[6]), "0.25", "decimals")
end)

T.case("touch: a tap opens a folder, edits, steps and writes", function()
  local b = browser()
  b.tap("Gyro")
  b.run()
  b.tap("5 Failsafe")
  b.run(20)
  b.tap("FBWA glide")
  T.ok(b.app.edit, "the tap opened the edit")
  b.paint()
  local step
  for _, h in ipairs(b.app.hits) do
    if h.step == 1 then
      step = h
    end
  end
  b.app:event("tap", (step[1] + step[3]) / 2, (step[2] + step[4]) / 2)
  b.tap("RTL if GPS")
  b.app:update(100)
  T.eq(written(b.dev, 3), 1, "the tap on the value wrote it")
end)

T.case("a command runs in a dialog until it is canceled", function()
  local b = browser()
  b.app:event("enter")
  b.run()
  b.app:event("next")
  b.app:event("next")
  b.app:event("enter")
  b.run(20)
  local c = b.paint()
  T.ok(c.has("Check mode switch"), "the dialog's title")
  T.ok(c.has("Ch6 Low: MANUAL"), "the device's text")
  T.ok(c.has("Cancel") and not c.has("OK"), "progress offers only Cancel")
  b.app:event("back")
  b.run(10)
  T.eq(b.app.dialog, nil, "closed")
  T.eq(b.client.devices[fake.FC].entries[7].status, 0, "the device is ready again")
end)

T.case("a long name is shortened, not clipped", function()
  local b = browser()
  b.app:event("enter")
  b.run()
  local c = b.paint(320, 240)
  for _, t in ipairs(c.texts) do
    T.ok(c.textWidth(t.str, 12 * 0.75) <= 320, t.str .. " fits")
  end
end)

T.case("a frame stays well inside the radio's budget", function()
  local b = browser()
  b.app:event("enter")
  b.run()
  b.app:event("enter")
  b.run(20)
  local c = canvas(480, 320)
  local n = 0
  debug.sethook(function()
    n = n + 1
  end, "", 1)
  b.app:paint(c, 480, 320)
  b.app:update(1000)
  debug.sethook()
  T.ok(n < 6000, "a 480x320 frame took " .. n .. " instructions")
end)

T.case("a channel and the command that learns it share a row", function()
  local b = browser({ radio = true })
  b.app:event("enter")
  b.run()
  b.tap("2 Radio")
  b.run(5)
  local c = b.paint()
  T.ok(c.has("Learn sticks"), "a command with no setting above keeps its row")
  T.ok(c.has("Arm switch") and c.has("Autotune switch"), "the channels")
  T.ok(not c.has("Learn arm switch") and not c.has("Learn autotune sw"), "their commands have no rows")
  local learns = 0
  for _, t in ipairs(c.texts) do
    learns = learns + (t.str == "Learn" and 1 or 0)
  end
  T.eq(learns, 2, "a Learn button on each channel's row")
  -- the rotary: Learn sticks, Arm switch's value, its Learn, Autotune switch
  local p = b.app.stack[3]
  T.eq(p.focus, 1, "starts on Learn sticks")
  b.app:event("next")
  T.ok(p.focus == 2 and p.part == 1, "the arm switch's value")
  b.app:event("next")
  T.ok(p.focus == 2 and p.part == 2, "its Learn button")
  b.app:event("next")
  T.ok(p.focus == 3 and p.part == 1, "the next channel")
  b.app:event("prev")
  T.ok(p.focus == 2 and p.part == 2, "back onto the Learn button")
  b.app:event("enter")
  b.run(20)
  T.ok(b.paint().has("Learn arm switch"), "Enter on Learn runs the command, named in the dialog")
  b.app:event("back")
  b.run(10)
  T.eq(b.app.dialog, nil, "canceled")
  -- touch: the value edits, the button learns
  b.tap("Ch6")
  T.ok(b.app.edit and b.app.edit.id == 13, "a tap on the value edits it")
  b.app:event("back")
  T.eq(b.tap("Learn"), nil)
  b.run(10)
  T.ok(b.paint().has("Learn arm switch"), "a tap on Learn runs it")
end)

T.case("a folder's entries are read again when it opens", function()
  local b = browser()
  b.app:event("enter")
  b.run()
  b.tap("5 Failsafe")
  b.run(20)
  T.ok(b.paint().has("FBWA glide"), "loaded")
  b.app:event("back")
  -- changed on the device by something else, after the browser loaded it
  b.dev.entries[3][#b.dev.entries[3] - 4] = 1
  b.tap("5 Failsafe")
  T.ok(b.paint().has("FBWA glide"), "shown as it was meanwhile")
  b.run(20)
  T.ok(b.paint().has("RTL if GPS"), "the device's value, not the cached one")
end)

T.case("the bar counts a folder's entries while they load", function()
  local b = browser({ radio = true })
  local function counter()
    for _, t in ipairs(b.paint().texts) do
      if string.match(t.str, "^%d+/%d+$") then
        return t.str
      end
    end
  end
  b.app:event("enter")
  T.eq(counter(), nil, "nothing counted before entry 0 answers")
  b.run(1)
  T.eq(counter(), "0/6", "the top level once it has")
  b.run()
  T.eq(counter(), nil, "nothing once it has loaded")
  b.tap("5 Failsafe")
  T.eq(counter(), "0/3", "the folder's three entries, the hidden one too")
  b.run(20)
  T.eq(counter(), nil, "nothing once loaded")
  T.eq(b.dev.reads[10], nil, "the other folder not read")
end)

T.case("readings are read again only while armed", function()
  local b = browser()
  b.app:event("enter")
  b.run()
  local function statusReads(seconds)
    local before = b.dev.reads[1] or 0
    b.run(seconds * 10)
    return (b.dev.reads[1] or 0) - before
  end
  -- disarmed, each read would stop ArduPilot's telemetry for 5 s
  T.eq(statusReads(10), 0, "disarmed: not read again")
  b.armed = true
  local n = statusReads(10)
  T.ok(n >= 4 and n <= 6, "armed: every 2 s (" .. n .. " in 10 s)")
end)

T.case("disarmed, pings are spaced wider than ArduPilot's 5 s", function()
  local b = browser()
  local before = b.pings
  b.run(300)
  local disarmed = b.pings - before
  T.ok(disarmed >= 4 and disarmed <= 6, "disarmed: every 6 s (" .. disarmed .. " in 30 s)")
  b.armed = true
  before = b.pings
  b.run(300)
  local armed = b.pings - before
  -- the first waits out the 6 s already set
  T.ok(armed >= 13 and armed <= 16, "armed: every 2 s (" .. armed .. " in 30 s)")
end)
