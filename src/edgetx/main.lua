-- Lofty PFD for EdgeTX: the flight display widget (EdgeTX 2.11 and later).
--
-- The work is in the shared core (core/), loaded with loadScript, which
-- compiles each file to .luac on the radio. This file supplies the canvas the
-- HUD draws through and the telemetry it decodes.
--
-- EdgeTX stops refresh after 20,000 Lua instructions and has no other call to
-- spread the work over, so the HUD draws straight to the screen here; Ethos's
-- display list would cost half as much again to record.

local DIR = "/WIDGETS/LoftyPFD/"

local cache = {}
local function use(name)
  if cache[name] == nil then
    cache[name] = assert(loadScript(DIR .. "core/" .. name .. ".lua"))(use)
  end
  return cache[name]
end

local vehicle = use("vehicle")
local flight = use("flight")
local maps = use("maps")
local options = use("options")
local palette = use("palette")
local replay = use("replay")
local crsf = use("crsf")
local passthrough = use("passthrough")
local sensors = use("sensors")
local home = use("home")
local devices = use("devices")
local menu = use("menu")
local callouts = use("callouts")

local screen = assert(loadScript(DIR .. "screen.lua"))(use, DIR)
local edgetx = assert(loadScript(DIR .. "link.lua"))(use, DIR)

-- The radio's CRSF queue, read here for telemetry and the device menu both.
local link

local function seconds()
  return getTime() / 100
end

-- The settings from the widget's options, resolved when they change rather
-- than every frame.
local function settingsOf(values)
  return options.resolve(function(o)
    return values and values[o.name]
  end)
end

local function create(zone, values)
  link = link or edgetx.open()
  local w = { zone = zone, settings = settingsOf(values), state = vehicle.new(), tx = {} }
  -- Map tiles copied by Lofty GCS, in the widget's maps folder.
  w.flight = flight.new({ layers = maps.parseIndex(edgetx.readAll(DIR .. "maps/index.txt")), root = DIR .. "maps/" })
  -- A recording beside the widget is played instead of the link: the
  -- simulator has none. It is only ever there in a development build.
  -- The file is opened for each chunk and closed again, so it is never held
  -- open: a new build can be copied over it while the simulator runs.
  local path = DIR .. "replay.txt"
  local f = io.open(path, "r")
  if f then
    io.close(f)
    w.player = replay.new(function()
      local offset = 0
      return function()
        local file = io.open(path, "r")
        if not file then
          return nil
        end
        io.seek(file, offset)
        local chunk = io.read(file, 512)
        io.close(file)
        if not chunk or chunk == "" then
          return nil
        end
        offset = offset + #chunk
        return chunk
      end
    end)
  end
  return w
end

local function update(w, values)
  w.settings = settingsOf(values)
end

-- Telemetry sensors by name, their ids looked up once. A sensor EdgeTX has
-- not discovered yet has no id; it is looked for again every few seconds.
local sensorIds, nextLookup = {}, 0
local function readSensor(name)
  local id = sensorIds[name]
  if id then
    return getSourceValue(id)
  end
end

local function lookUpSensors(now)
  if now < nextLookup then
    return
  end
  nextLookup = now + 3
  for _, name in ipairs(sensors.NAMES) do
    if not sensorIds[name] then
      local info = getFieldInfo(name)
      sensorIds[name] = info and info.id
    end
  end
end

-- One widget speaks: each decodes its own copy of the link, so two on
-- screen would say everything twice. Another takes over once the speaker
-- has gone quiet (removed from its screen).
local speaker, speakerSeen = nil, 0

local function speak(w, now)
  if speaker ~= w and now - speakerSeen < 2 then
    return
  end
  speaker, speakerSeen = w, now
  w.callouts = w.callouts or callouts.new()
  for _, item in ipairs(w.callouts:update(w.state, now, w.settings.voice, w.settings.beepsDisarmed)) do
    edgetx.play(item)
  end
end

-- At most this many frames of each kind per call: a burst after a stall
-- must not spend the frame's instruction budget on decoding.
local FRAMES_PER_CALL = 8

local function decode(w)
  local now = seconds()
  local s = w.state
  -- CRSF frames Lua does see: ArduPilot's passthrough, its status text and
  -- the device menu, which goes to the browser. The standard frames come as
  -- sensors, below.
  for _ = 1, FRAMES_PER_CALL do
    local command, data = link.pop()
    if not command then
      break
    end
    if not (w.client and w.client:handle(command, data, now)) and not w.player then
      crsf.apply(s, command, data, now)
    end
  end
  if w.player then
    local fresh = w.player:update(s, now, FRAMES_PER_CALL)
    if fresh then
      w.state, s = fresh, fresh
    end
  else
    -- S.Port passthrough, from a FrSky receiver.
    for _ = 1, FRAMES_PER_CALL do
      local physId, primId, appId, value = sportTelemetryPop()
      if not physId then
        break
      end
      if primId == 0x10 then
        passthrough.apply(s, appId, value, now)
      end
    end
    lookUpSensors(now)
    sensors.apply(s, readSensor, now)
  end
  home.update(s)
  speak(w, now)
end

-- EdgeTX calls background only while the widget is off screen, so refresh
-- decodes too.
local function background(w)
  decode(w)
end

-- The device browser, in place of the flight display until Back leaves
-- its top page.
local function openBrowser(w)
  w.client = w.client or devices.new(function(frameType, payload)
    return link.push(frameType, payload)
  end)
  w.app = menu.new(w.client)
end

-- EdgeTX passes events only in full screen, the one mode in which the
-- widget can be operated; event is nil otherwise.
local function refresh(w, event, touch)
  decode(w)
  local now = seconds()
  local set = w.settings
  palette.set(palette.pick(set.theme, edgetx.radioDark()))
  screen.size(w.zone.w, w.zone.h)
  screen.frame()
  local ev, x, y = edgetx.event(event, touch)
  if w.app then
    if ev and w.app:event(ev, x, y) == "exit" then
      w.app, ev = nil, nil
    else
      w.app:update(now)
      w.app:paint(screen, w.zone.w, w.zone.h)
      return
    end
  end
  w.tx.volts = getValue("tx-voltage")
  w.flight:update(w.state, now)
  if (ev == "enter" and set.devicesButton) or (ev and w.flight:event(ev, x, y, now) == "browser") then
    openBrowser(w)
    return
  end
  w.flight:paint(screen, w.state, {
    now = now, tx = w.tx, tiles = set.tiles, units = set.units, coords = set.coords, cells = set.cells,
    settings = event ~= nil and set.devicesButton,
  })
end

return {
  name = "LoftyPFD",
  options = (function()
    local out = {}
    for i, o in ipairs(options.LIST) do
      out[i] = { o.name, CHOICE, o.default, o.choices }
    end
    return out
  end)(),
  create = create,
  update = update,
  background = background,
  refresh = refresh,
}
