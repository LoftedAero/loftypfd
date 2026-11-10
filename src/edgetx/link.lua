-- What the widget and the tool share on EdgeTX: the CRSF link, and the
-- device browser's input (core/menu.lua) from EdgeTX's events.

local use, DIR = ...

local M = {}

--- The whole of a file, read a chunk at a time (EdgeTX's io has no "*a").
function M.readAll(path)
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

--- The link: push(frameType, payload) and pop(). A recorded device menu
--- beside the widget stands in for the radio's in a simulator, which has no
--- device; it is only ever there in a development build.
function M.open()
  local recording = M.readAll(DIR .. "menu.txt")
  if recording then
    return use("snapshot").new(recording)
  end
  return {
    push = crossfireTelemetryPush or function() return false end,
    pop = crossfireTelemetryPop or function() end,
  }
end

local palette = use("palette")

--- Whether the radio's theme is dark, judged by its background color
--- (COLOR_THEME_SECONDARY3); EdgeTX has no flag for it. lcd.getColor returns
--- a flag with the color as RGB565 in its top 16 bits.
function M.radioDark()
  if not (lcd.getColor and COLOR_THEME_SECONDARY3) then
    return nil
  end
  local v = lcd.getColor(COLOR_THEME_SECONDARY3)
  if not v then
    return nil
  end
  local c = (v >> 16) & 0xFFFF
  return palette.isDark((c >> 8) & 0xF8, (c >> 3) & 0xFC, (c << 3) & 0xF8)
end

local EVENTS = {}
local function on(event, name)
  if event then
    EVENTS[event] = name
  end
end
on(EVT_VIRTUAL_NEXT, "next")
on(EVT_VIRTUAL_PREV, "prev")
on(EVT_VIRTUAL_ENTER, "enter")
on(EVT_VIRTUAL_EXIT, "back")

--- The browser's event for an EdgeTX event, with its x and y; nil for one
--- it does not take.
function M.event(event, touch)
  if event and EVENTS[event] then
    return EVENTS[event]
  elseif touch and event == EVT_TOUCH_TAP then
    return "tap", touch.x, touch.y
  elseif touch and event == EVT_TOUCH_SLIDE then
    return "drag", touch.slideY
  end
end

return M
