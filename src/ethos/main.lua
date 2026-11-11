-- Lofty PFD for Ethos: the flight display widget, and the device browser as
-- a system tool.
--
-- The work is in the shared core (core/), loaded here with Ethos's loadfile,
-- which resolves paths against this script's folder. This file supplies the
-- canvas the core draws through and the telemetry it decodes.
--
-- Ethos stops a callback after about 20,000 Lua instructions, and on the X20
-- runs about 140,000 a second, so instructions are time too. wakeup reads the
-- telemetry and asks for a paint; paint lays the screen out and draws it in
-- one pass (see paint).

local cache = {}
local function use(name)
  if cache[name] == nil then
    cache[name] = assert(loadfile("core/" .. name .. ".lua"))(use)
  end
  return cache[name]
end

local vehicle = use("vehicle")
local flight = use("flight")
local maps = use("maps")
local imagecache = use("imagecache")
local options = use("options")
local palette = use("palette")
local replay = use("replay")
local crsfDecoder = use("crsf")
local passthrough = use("passthrough")
local home = use("home")
local devices = use("devices")
local menu = use("menu")
local capture = use("capture")
local callouts = use("callouts")

local floor = math.floor

-- Ethos fonts, measured once on the radio, so the HUD's pixel sizes map to
-- the nearest real face rather than to a guess per radio.
local FONT_NAMES = { "FONT_XXS", "FONT_XS", "FONT_S", "FONT_STD", "FONT_L", "FONT_XL", "FONT_XXL" }
local fonts

local function measureFonts()
  fonts = {}
  for _, name in ipairs(FONT_NAMES) do
    local f = _G[name]
    if f then
      lcd.font(f)
      local _, h = lcd.getTextSize("0")
      fonts[#fonts + 1] = { font = f, bold = _G[name .. "_BOLD"], h = h }
    end
  end
end

-- The HUD sizes are CSS pixels of an em; a face's measured height includes
-- its line spacing, about a quarter more. Cached: text is the most frequent
-- call.
local picked = {}
local function pickFont(size, bold)
  local key = bold and -size or size
  local p = picked[key]
  if not p then
    if not fonts then
      measureFonts()
    end
    local want = size * 1.25
    local best, err = nil, math.huge
    for _, f in ipairs(fonts) do
      local e = math.abs(f.h - want)
      if e < err then
        best, err = f, e
      end
    end
    p = { bold and best.bold or best.font, best.h }
    picked[key] = p
  end
  return p[1], p[2]
end

-- Ethos colors, cached by the core's color tables. Weak keys: the horizon's
-- gradient makes new tables every frame.
local opaque = setmetatable({}, { __mode = "k" })
local translucent = setmetatable({}, { __mode = "k" })
local function color(c, alpha)
  if alpha then
    local byAlpha = translucent[c]
    if not byAlpha then
      byAlpha = {}
      translucent[c] = byAlpha
    end
    local v = byAlpha[alpha]
    if not v then
      v = lcd.RGB(c[1], c[2], c[3], alpha)
      byAlpha[alpha] = v
    end
    return v
  end
  local v = opaque[c]
  if not v then
    v = lcd.RGB(c[1], c[2], c[3])
    opaque[c] = v
  end
  return v
end

local ALIGN = { left = TEXT_LEFT, center = TEXT_CENTERED, right = TEXT_RIGHT }

-- The screen.
local screen = {}
function screen.fill(x, y, w, h, c, alpha)
  lcd.color(color(c, alpha))
  lcd.drawFilledRectangle(floor(x), floor(y), floor(w + 0.5), floor(h + 0.5))
end
function screen.tri(x1, y1, x2, y2, x3, y3, c, alpha)
  lcd.color(color(c, alpha))
  lcd.drawFilledTriangle(floor(x1), floor(y1), floor(x2), floor(y2), floor(x3), floor(y3))
end
-- Ethos lines are one pixel wide; a wider one is several, offset across
-- whichever axis the line runs least along.
function screen.line(x1, y1, x2, y2, c, width)
  lcd.color(color(c))
  x1, y1, x2, y2 = floor(x1), floor(y1), floor(x2), floor(y2)
  if not width or width <= 1 then
    lcd.drawLine(x1, y1, x2, y2)
    return
  end
  local steep = math.abs(y2 - y1) > math.abs(x2 - x1)
  local first = -floor(width / 2)
  for k = first, first + width - 1 do
    if steep then
      lcd.drawLine(x1 + k, y1, x2 + k, y2)
    else
      lcd.drawLine(x1, y1 + k, x2, y2 + k)
    end
  end
end
function screen.text(x, y, str, size, c, align, bold)
  local f, h = pickFont(size, bold)
  lcd.font(f)
  lcd.color(color(c))
  lcd.drawText(floor(x), floor(y - h / 2), str, ALIGN[align or "left"])
end

-- Map tiles and other images by path, drawn at `size` square; twelve kept,
-- a full-screen map showing nine. One is decoded a frame: each takes about a
-- third of a second on the X20 (core/imagecache.lua).
local images = imagecache.new(function(path)
  return lcd.loadBitmap(path) or false
end, 12, nil, 1)
screen.frame = images.frame
-- A tile at its own size is drawn without one: given a size, the X20 took
-- 26 ms a tile, presumably scaling, where a map shows six or more.
local TILE = 256
function screen.image(path, x, y, size)
  local b = images.get(path)
  if b and size == TILE then
    lcd.drawBitmap(floor(x), floor(y), b)
  elseif b then
    lcd.drawBitmap(floor(x), floor(y), b, size, size)
  end
end

local function measure(str, size, bold)
  lcd.font((pickFont(size, bold)))
  return (lcd.getTextSize(str))
end
screen.textWidth = measure

-- The whole of a file beside the script, or nil.
local function readAll(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local parts = {}
  repeat
    local chunk = io.read(f, 1024)
    parts[#parts + 1] = chunk
  until not chunk or chunk == ""
  io.close(f)
  return table.concat(parts)
end

-- A test build (tools/build.py --capture) records the link to the next free
-- capture-<n>.txt beside the script, for tools/hwtest.py. Each second's lines
-- are appended and the file closed again, so nothing is lost when the radio
-- is switched off.
local function startCapture(now)
  local f = io.open("capture.on", "r")
  if not f then
    return nil
  end
  io.close(f)
  local name
  for n = 1, 999 do
    name = "capture-" .. n .. ".txt"
    local old = io.open(name, "r")
    if not old then
      break
    end
    io.close(old)
  end
  local c = capture.new(function(text)
    local out = io.open(name, "a")
    if out then
      io.write(out, text)
      io.close(out)
    end
  end)
  local ok, v = pcall(system.getVersion)
  local about = { "Ethos" }
  if ok and type(v) == "table" then
    about[#about + 1] = tostring(v.board)
    about[#about + 1] = tostring(v.version)
  end
  about[#about + 1] = _VERSION
  c:header(now, table.concat(about, " "))
  return c
end

-- One link for the whole script: the widgets and the tool share the
-- aircraft's state and the radio's frame queues, which only one reader may
-- drain. The device client is there while the tool is open.
local link = { state = vehicle.new(), client = nil }

local function openLink()
  if link.pop then
    return
  end
  -- A recorded menu answers for a device, and a recorded flight is played
  -- instead of the link: the simulator has neither. They are only ever there
  -- in a development build.
  local recording = readAll("menu.txt")
  if recording then
    local snapshot = use("snapshot").new(recording)
    link.pop, link.push = snapshot.pop, snapshot.push
  elseif crsf and crsf.getSensor then
    local sensor = crsf.getSensor()
    link.pop = function()
      return sensor:popFrame()
    end
    link.push = function(frameType, payload)
      return sensor:pushFrame(frameType, payload)
    end
  elseif crsf and crsf.popFrame then
    -- Ethos before 1.5 has the queue on crsf itself.
    link.pop, link.push = crsf.popFrame, crsf.pushFrame
  else
    -- No CRSF at all, as in the simulator.
    link.pop = function() end
    link.push = function()
      return false
    end
  end
  link.capture = startCapture(os.clock())
  if link.capture then
    local push = link.push
    link.push = function(frameType, payload)
      local ok = push(frameType, payload)
      if ok ~= false then
        link.capture:sent(os.clock(), frameType, payload)
      end
      return ok
    end
  end
  local f = io.open("replay.txt", "r")
  if f then
    io.close(f)
    link.player = replay.new(function()
      local file = io.open("replay.txt", "r")
      return function()
        local chunk = file and io.read(file, 512)
        if not chunk or chunk == "" then
          if file then
            io.close(file)
            file = nil
          end
          return nil
        end
        return chunk
      end
    end)
  end
end

-- The transmitter's own battery.
local function txVolts(w)
  if w.txSource == nil then
    w.txSource = system.getSource({ category = CATEGORY_SYSTEM, member = MAIN_VOLTAGE }) or false
  end
  return w.txSource and w.txSource:value() or nil
end

-- The settings from the places Ethos keeps (w.values), resolved when they
-- change rather than every frame.
local function resolve(w)
  w.settings = options.resolve(function(o)
    return w.values[o.key]
  end)
end

local function create()
  openLink()
  local w = { tx = {}, values = {} }
  resolve(w)
  -- Map tiles copied by Lofty GCS, in the script's maps folder.
  w.flight = flight.new({ layers = maps.parseIndex(readAll("maps/index.txt")), root = "maps/" })
  return w
end

-- The radio's own theme: Ethos 1.6 has a dark mode, earlier ones are dark.
local function radioDark()
  if lcd.darkMode then
    return lcd.darkMode()
  end
  return true
end

-- The radio's link sensors, found by name: ExpressLRS's link quality and a
-- FrSky receiver's RSSI. Absent ones read as nothing.
local function linkSensor(names)
  for _, name in ipairs(names) do
    local source = system.getSource(name)
    if source then
      return source
    end
  end
  return false
end

local function readLink()
  if link.lqSource == nil then
    link.lqSource = linkSensor({ "RQly", "Rx Quality", "LQ" })
    link.rssiSource = linkSensor({ "1RSS", "RSSI" })
  end
  local l = link.state.link
  if link.lqSource then
    l.lq = link.lqSource:value()
  end
  if link.rssiSource then
    l.rssi = link.rssiSource:value()
  end
end

-- At most this many frames of each kind per wakeup, so a burst after a
-- stall does not hold up the radio.
local FRAMES_PER_CALL = 32

-- Takes what has arrived, once per cycle however many callers ask.
-- Voice callouts and alerts (core/callouts.lua), for the one link however
-- many screens show the widget, at the level the widget was last set to.
-- Ethos plays files relative to the script's folder.
local UNITS = { percent = UNIT_PERCENT }
local function play(step)
  local kind = step[1]
  if kind == "file" then
    system.playFile("audio/en/" .. step[2] .. ".wav")
  elseif kind == "number" then
    system.playNumber(step[2], UNITS[step[3]] or 0)
  elseif kind == "tone" and system.playTone then
    system.playTone(step[2], step[3], step[4])
  elseif kind == "haptic" and system.playHaptic then
    system.playHaptic(step[2], step[3])
  end
end

local function speak(now)
  link.callouts = link.callouts or callouts.new()
  for _, item in ipairs(link.callouts:update(link.state, now, link.voice or "all", link.beepsDisarmed)) do
    if link.capture then
      link.capture:callout(now, item)
    end
    for _, step in ipairs(callouts.sounds(item)) do
      -- A call this radio does not take must not stop the widget.
      local ok, err = pcall(play, step)
      if not ok then
        print("Lofty PFD: " .. tostring(step[1]) .. ": " .. tostring(err))
      end
    end
  end
end

local function poll(now)
  if link.polled == now then
    return
  end
  link.polled = now
  local s = link.state
  -- CRSF: ArduPilot's frames as Ethos hands them over, from the
  -- destination byte on for the extended ones; the device menu's go to the
  -- browser.
  for _ = 1, FRAMES_PER_CALL do
    local command, data = link.pop()
    if not command then
      break
    end
    if link.capture then
      link.capture:frame(now, command, data)
      link.words = (link.words or 0) + 1
    end
    if not (link.client and link.client:handle(command, data, now)) and not link.player then
      crsfDecoder.apply(s, command, data, now)
    end
  end
  if link.player then
    local fresh = link.player:update(s, now, FRAMES_PER_CALL)
    if fresh then
      link.state = fresh
    end
  else
    -- S.Port passthrough, from a FrSky receiver.
    if sport and sport.getSensor then
      -- ArduPilot's GPS (0x0800) through its passthrough words.
      link.sport = link.sport or sport.getSensor({ appIdStart = 0x0800, appIdEnd = 0x50FF })
      for _ = 1, FRAMES_PER_CALL do
        local frame = link.sport:popFrame()
        if not frame then
          break
        end
        if frame:primId() == 0x10 then
          if link.capture then
            link.capture:sport(now, frame:appId(), frame:value())
            link.words = (link.words or 0) + 1
          end
          passthrough.apply(s, frame:appId(), frame:value(), now)
        end
      end
    end
    readLink()
  end
  home.update(link.state)
  speak(now)
end

-- The device browser's client: one for the script, made when the widget or
-- the tool first opens the browser.
local function client()
  if not link.client then
    link.client = devices.new(function(frameType, payload)
      return link.push(frameType, payload)
    end)
  end
  return link.client
end

-- The browser's input (core/menu.lua) from Ethos's events.
local KEYS = {}
local function key(value, name)
  if value then
    KEYS[value] = name
  end
end
key(KEY_ROTARY_RIGHT, "next")
key(KEY_ROTARY_LEFT, "prev")
key(KEY_ENTER_BREAK, "enter")
key(KEY_EXIT_BREAK, "back")

-- A touch that moves less than this is a tap.
local TAP_PX = 10

--- The browser's event for an Ethos event, with its x and y. A touch is a
--- tap when it ends where it started, else a drag while it moves; `t` keeps
--- the touch in progress.
local function input(t, category, value, x, y)
  if category == EVT_KEY then
    return KEYS[value]
  elseif category ~= EVT_TOUCH then
    return nil
  end
  if value == TOUCH_START then
    t.touch = { x = x, y = y, lastX = x, lastY = y, moved = false }
  elseif value == TOUCH_MOVE and t.touch then
    if math.abs(x - t.touch.x) > TAP_PX or math.abs(y - t.touch.y) > TAP_PX then
      t.touch.moved = true
    end
    if t.touch.moved then
      local dx, dy = x - t.touch.lastX, y - t.touch.lastY
      t.touch.lastX, t.touch.lastY = x, y
      return "drag", dx, dy
    end
  elseif value == TOUCH_END and t.touch then
    local moved = t.touch.moved
    t.touch = nil
    if not moved then
      return "tap", x, y
    end
  end
end

local function wakeup(w)
  local now = os.clock()
  link.voice, link.beepsDisarmed = w.settings.voice, w.settings.beepsDisarmed
  poll(now)
  local polled = os.clock()
  if w.app then
    w.app:update(now)
  end
  w.flight:update(link.state, now)
  -- wakeup runs whether or not the screen is showing; decoding must go on,
  -- and a paint is asked for only while someone can see it.
  if lcd.isVisible() then
    lcd.invalidate()
  end
  if link.capture and not link.benched then
    -- How fast this radio runs Lua at all, once: a loop of a known 40,000
    -- instructions (an add and the loop's step, 20,000 times). Here, not in
    -- create, which Ethos stops well short of that.
    link.benched = true
    local t0, x = os.clock(), 0
    for i = 1, 20000 do
      x = x + i
    end
    link.capture:line(now, "B", string.format("40000 instructions in %.1f ms", (os.clock() - t0) * 1000))
  end
  if link.capture then
    -- Each wakeup: draining the queues in ms, and the words taken.
    local c = link.capture
    c:line(now, "T", string.format("%.1f %d", (polled - now) * 1000, link.words or 0))
    link.words = 0
    c:timing(os.clock() - now)
    c:update(now, link.state, txVolts(w))
  end
end

-- Taps and drags go to the flight display (core/flight.lua); its settings
-- button opens the browser in place of it, until Back leaves its top page.
local function event(w, category, value, x, y)
  local ev, ex, ey = input(w, category, value, x, y)
  if link.capture and category == EVT_TOUCH then
    -- Each touch, when Lua was handed it, and what it became.
    link.capture:line(os.clock(), "E", string.format("%s %s %s %s", tostring(value), tostring(x), tostring(y),
      tostring(ev)))
  end
  if w.app then
    if ev and w.app:event(ev, ex, ey) == "exit" then
      w.app = nil
    end
    -- Every touch is the browser's while it shows.
    return ev ~= nil or category == EVT_TOUCH
  end
  -- What the widget does not use stays Ethos's: a long press opens its menu.
  if not ev then
    return false
  end
  local used = w.flight:event(ev, ex, ey, os.clock())
  if used == "browser" then
    w.app = menu.new(client())
    return true
  end
  return used
end

-- The screen is laid out and drawn here, in one pass. On the X20 (Ethos
-- 1.6.3) Lua runs about 140,000 instructions a second, so cost is the
-- instruction count: laying out into a display list in wakeup and replaying
-- it here took 350 ms a frame, the recording alone nearly as much as the
-- layout. Drawing directly fits paint's own limit.
-- In a test build each paint times one kind of draw call, in turn, so the
-- slow ones show without wrapping every call, which paint's instruction limit
-- would not allow.
local KINDS = { "fill", "tri", "line", "text", "image" }
local paints = 0

local function paint(w)
  local start = os.clock()
  screen.frame()
  local kind, plain, calls, spent
  if link.capture then
    paints = paints + 1
    kind = KINDS[paints % #KINDS + 1]
    plain, calls, spent = screen[kind], 0, 0
    screen[kind] = function(...)
      local t0 = os.clock()
      plain(...)
      spent = spent + os.clock() - t0
      calls = calls + 1
    end
  end
  local set = w.settings
  palette.set(palette.pick(set.theme, radioDark()))
  local width, height = lcd.getWindowSize()
  screen.w, screen.h = width, height
  if w.app then
    w.app:paint(screen, width, height)
  else
    w.tx.volts = txVolts(w)
    w.flight:paint(screen, link.state, {
      now = start, tx = w.tx, tiles = set.tiles, units = set.units, coords = set.coords, cells = set.cells,
      settings = set.devicesButton,
    })
  end
  if link.capture then
    screen[kind] = plain
    link.capture:line(start, "K", string.format("%s %d %.1f", kind, calls, spent * 1000))
    link.capture:line(start, "U", string.format("%.1f", (os.clock() - start) * 1000))
    link.capture:timing(nil, os.clock() - start)
  end
end

-- The widget's settings page: each option kept under its key (core/options.lua).
local function configure(w)
  for _, o in ipairs(options.LIST) do
    local choices = {}
    for i, name in ipairs(o.choices) do
      choices[i] = { name, i }
    end
    form.addChoiceField(form.addLine(o.name), nil, choices, function()
      return w.values[o.key] or o.default
    end, function(value)
      w.values[o.key] = value
      resolve(w)
    end)
  end
end

local function read(w)
  for _, o in ipairs(options.LIST) do
    w.values[o.key] = storage.read(o.key)
  end
  resolve(w)
end

local function write(w)
  for _, o in ipairs(options.LIST) do
    storage.write(o.key, w.values[o.key] or o.default)
  end
end

-- The device browser, as a system tool.

local function toolCreate()
  openLink()
  return { app = menu.new(client()) }
end

local function toolWakeup(t)
  local now = os.clock()
  poll(now)
  t.app:update(now)
  if link.capture then
    link.capture:update(now, link.state)
  end
  lcd.invalidate()
end

local function toolPaint(t)
  palette.set(palette.pick(nil, radioDark()))
  local w, h = lcd.getWindowSize()
  t.app:paint(screen, w, h)
end

local function toolEvent(t, category, value, x, y)
  local ev, ex, ey = input(t, category, value, x, y)
  if ev and t.app:event(ev, ex, ey) == "exit" then
    system.exit()
  end
  lcd.invalidate()
  return ev ~= nil or category == EVT_TOUCH
end

local function init()
  system.registerSystemTool({
    name = "Lofty PFD",
    icon = lcd.loadMask("icon.png"),
    -- The browser's own bar carries the title and Back.
    title = false,
    create = toolCreate,
    wakeup = toolWakeup,
    paint = toolPaint,
    event = toolEvent,
  })
  system.registerWidget({
    key = "lftpfd",
    name = "Lofty PFD",
    title = false,
    create = create,
    wakeup = wakeup,
    paint = paint,
    event = event,
    configure = configure,
    read = read,
    write = write,
  })
end

return { init = init }
