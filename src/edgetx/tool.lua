-- TNS|Lofty PFD|TNE
-- Lofty PFD's device browser as an EdgeTX tool: every CRSF device on the
-- link and its settings (core/menu.lua). It loads the widget's core, so the
-- widget must be installed beside it.

local DIR = "/WIDGETS/LoftyPFD/"

local cache = {}
local function use(name)
  if cache[name] == nil then
    cache[name] = assert(loadScript(DIR .. "core/" .. name .. ".lua"))(use)
  end
  return cache[name]
end

local devices = use("devices")
local menu = use("menu")
local palette = use("palette")
local screen = assert(loadScript(DIR .. "screen.lua"))(use, DIR)
local edgetx = assert(loadScript(DIR .. "link.lua"))(use, DIR)

local app, link

local function init()
  link = edgetx.open()
  app = menu.new(devices.new(function(frameType, payload)
    return link.push(frameType, payload)
  end))
end

-- Frames taken per cycle, so a burst cannot use up the instruction budget.
local FRAMES_PER_CALL = 16

local function run(event, touch)
  local now = getTime() / 100
  for _ = 1, FRAMES_PER_CALL do
    local frameType, data = link.pop()
    if not frameType then
      break
    end
    app.client:handle(frameType, data, now)
  end
  app:update(now)
  palette.set(palette.pick(nil, edgetx.radioDark()))
  local ev, x, y = edgetx.event(event, touch)
  if ev and app:event(ev, x, y) == "exit" then
    return 1
  end
  screen.size(LCD_W, LCD_H)
  app:paint(screen, LCD_W, LCD_H)
  return 0
end

return { init = init, run = run }
