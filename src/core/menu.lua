-- The device browser: every CRSF device on the link and its settings, in the
-- Lofted Aero theme being shown (core/palette.lua).
--
-- Pages stack, so Back goes up one level (the ExpressLRS script jumps to the
-- top). A setting is edited in its own box and written on Enter; the box
-- shows what the device reads back. A command opens a dialog that follows
-- the device's status and text until the device says it is done. A command
-- that learns the setting above it shares that setting's row.
--
-- Input arrives as abstract events from the platform: "next" and "prev"
-- (rotary or arrows), "enter", "back", "tap" at x, y, and "drag" by dy.
-- Taps are matched against what the last paint drew.

local use = ...
local devices = use("devices")
local palette = use("palette")

local M = {}

local T, B = palette.T, palette.BAR
local F = devices.FIELD
local CMD = devices.COMMAND
local floor, max, min = math.floor, math.max, math.min

-- Devices are asked who they are this often while the device list shows.
local PING_S = 2
-- Readings in the open folder (info entries) are read again this often.
local INFO_S = 2

local App = {}
App.__index = App

--- A browser over `client` (core/devices.lua).
function M.new(client)
  local app = setmetatable({ client = client, stack = {}, hits = {}, nextPing = 0, nextInfo = 0 }, App)
  app.stack[1] = { kind = "devices", focus = 1, scroll = 0 }
  client:ping()
  return app
end

--- Opens a device's top level directly, as Gyro Setup's fallback does.
function App:openDevice(address)
  local dev = self.client.devices[address]
  if dev then
    self.client:load(address)
    self.stack[#self.stack + 1] = { kind = "folder", address = address, folder = 0, title = dev.name, focus = 1, scroll = 0 }
  end
end

local function page(self)
  return self.stack[#self.stack]
end

local function focusable(row)
  if row.device then
    return true
  end
  local t = row.entry.type
  return t <= 5 or t == F.float or t == F.select or t == F.folder or t == F.command
end

local function editable(e)
  local t = e.type
  return t <= 5 or t == F.float or t == F.select
end

-- Whether command `cmd` learns `setting`: "Learn " and the start of the
-- setting's name ("Learn arm switch" for "Arm switch", "Learn autotune sw"
-- for "Autotune switch"), which is how the gyro names them.
local function learns(cmd, setting)
  if cmd.type ~= F.command or not editable(setting) then
    return false
  end
  local name = string.lower(cmd.name or "")
  if string.sub(name, 1, 6) ~= "learn " then
    return false
  end
  local what = string.sub(name, 7)
  return what ~= "" and string.sub(string.lower(setting.name or ""), 1, #what) == what
end

-- The rows of a page: devices by address, or a folder's visible entries. A
-- command that learns the setting just above it becomes that row's `learn`,
-- a button beside the value, which halves the gyro's Radio folder.
local function rows(self, p)
  local out = {}
  if p.kind == "devices" then
    local addresses = {}
    for address in pairs(self.client.devices) do
      addresses[#addresses + 1] = address
    end
    table.sort(addresses)
    for _, address in ipairs(addresses) do
      out[#out + 1] = { device = self.client.devices[address] }
    end
    return out
  end
  for _, e in ipairs(self.client:children(p.address, p.folder)) do
    local last = out[#out]
    if last and not last.learn and learns(e, last.entry) then
      last.learn = e
    else
      out[#out + 1] = { entry = e }
    end
  end
  return out
end

-- The focus, moved onto a focusable row if it sits on another.
local function settle(list, p, dir)
  local n = #list
  if n == 0 then
    p.focus = 1
    return
  end
  local i = min(max(p.focus, 1), n)
  for _ = 1, n do
    if focusable(list[i]) then
      p.focus = i
      return
    end
    i = (i + (dir or 1) - 1) % n + 1
  end
  p.focus = min(max(p.focus, 1), n)
end

local function entryOf(self, address, id)
  local dev = self.client.devices[address]
  return dev and dev.entries[id]
end

--- The text a setting shows for `value` (its raw value when nil).
function M.valueText(e, value)
  local t = e.type
  local unit = e.unit or ""
  if t == F.select then
    local option = e.options and e.options[(value or e.value or 0) + 1]
    return option and (unit ~= "" and option .. " " .. unit or option) or "-"
  elseif t == F.float then
    local raw = value or e.raw
    if not raw then
      return "-"
    end
    local text = string.format("%." .. (e.decimals or 0) .. "f", raw / 10 ^ (e.decimals or 0))
    return unit ~= "" and text .. " " .. unit or text
  elseif t <= 5 then
    local v = value or e.value
    if not v then
      return "-"
    end
    return unit ~= "" and floor(v) .. " " .. unit or tostring(floor(v))
  elseif t == F.info or t == F.string then
    return (e.value and e.value ~= "") and e.value or "-"
  end
  return ""
end

-- The value an edit starts from and steps through.
local function current(e)
  if e.type == F.float then
    return e.raw
  end
  return e.value
end

--- The next value from `value` in direction `dir` (+1 or -1), within the
--- entry's bounds; a selection skips options with no name, which ExpressLRS
--- uses for ones that do not apply.
function M.step(e, value, dir)
  local lo, hi = e.min or 0, e.max or 0
  if e.type == F.select then
    hi = min(hi, #(e.options or {}) - 1)
    local v = value
    repeat
      v = v + dir
      if v < lo or v > hi then
        return value
      end
    until e.options[v + 1] ~= ""
    return v
  end
  local stepBy = e.type == F.float and max(e.step or 1, 1) or 1
  return max(lo, min(hi, value + dir * stepBy))
end

local function startEdit(self, p, e)
  if current(e) == nil then
    return
  end
  self.edit = { address = p.address, id = e.id, value = current(e) }
end

local function commit(self)
  local ed = self.edit
  self.edit = nil
  local e = entryOf(self, ed.address, ed.id)
  if e and ed.value ~= current(e) then
    -- Shown dim until the device's read-back replaces the entry.
    e.pending = ed.value
    self.client:write(ed.address, ed.id, ed.value)
  end
end

local function runCommand(self, p, e)
  self.client:command(p.address, e.id, CMD.start)
  self.dialog = { address = p.address, id = e.id, asked = e, title = e.name }
end

-- Every entry of the open folder read again, after a command that may have
-- changed them (a template, learned sticks, an orientation).
local function reloadFolder(self, p)
  if p.kind ~= "folder" then
    return
  end
  for _, row in ipairs(rows(self, p)) do
    self.client:refresh(p.address, row.entry.id)
    if row.learn then
      self.client:refresh(p.address, row.learn.id)
    end
  end
end

local function closeDialog(self, action)
  local d = self.dialog
  if action then
    self.client:command(d.address, d.id, action)
  end
  self.dialog = nil
  reloadFolder(self, page(self))
end

local function activate(self, p, row)
  if row.device then
    self.client:load(row.device.address)
    self.stack[#self.stack + 1] = {
      kind = "folder", address = row.device.address, folder = 0, title = row.device.name, focus = 1, scroll = 0,
    }
    return
  end
  if row.learn and p.part == 2 then
    runCommand(self, p, row.learn)
    return
  end
  local e = row.entry
  if e.type == F.folder then
    self.stack[#self.stack + 1] = { kind = "folder", address = p.address, folder = e.id, title = e.name, focus = 1, scroll = 0 }
    -- Read again, shown as they were meanwhile: a write elsewhere can change
    -- them (the gyro's Wing type sets four channels' functions).
    for _, child in ipairs(self.client:children(p.address, e.id)) do
      self.client:refresh(p.address, child.id)
    end
  elseif e.type == F.command then
    runCommand(self, p, e)
  elseif focusable(row) then
    startEdit(self, p, e)
  end
end

-- The dialog's entry once the device has answered the command, else nil.
local function answered(self)
  local d = self.dialog
  local e = entryOf(self, d.address, d.id)
  if e and e ~= d.asked then
    return e
  end
end

--- Sends what is due and follows the device. Call every cycle.
function App:update(now)
  local p = page(self)
  if p.kind == "devices" and now >= self.nextPing then
    self.nextPing = now + PING_S
    self.client:ping()
  end
  if p.kind == "folder" and not self.dialog and not self.edit and now >= self.nextInfo then
    self.nextInfo = now + INFO_S
    for _, row in ipairs(rows(self, p)) do
      if row.entry.type == F.info and #self.client.jobs == 0 then
        self.client:refresh(p.address, row.entry.id)
      end
    end
  end
  if self.dialog then
    local e = answered(self)
    if e and e.status == CMD.ready then
      closeDialog(self)
    end
  end
  self.client:update(now)
end

local function inside(h, x, y)
  return x >= h[1] and x < h[3] and y >= h[2] and y < h[4]
end

--- Takes an input event. Returns "exit" when Back leaves the top page.
function App:event(ev, x, y)
  local p = page(self)
  if self.dialog then
    local e = answered(self)
    local status = e and e.status
    if ev == "back" then
      closeDialog(self, CMD.cancel)
    elseif ev == "enter" and status == CMD.confirmationNeeded then
      self.client:command(self.dialog.address, self.dialog.id, CMD.confirm)
      self.dialog.asked = e
    elseif ev == "tap" then
      for _, h in ipairs(self.hits) do
        if h.dialog and inside(h, x, y) then
          if h.action == CMD.confirm then
            self.client:command(self.dialog.address, self.dialog.id, CMD.confirm)
            self.dialog.asked = e
          else
            closeDialog(self, CMD.cancel)
          end
          return
        end
      end
    end
    return
  end

  local list = rows(self, p)
  if self.edit then
    local e = entryOf(self, self.edit.address, self.edit.id)
    if not e then
      self.edit = nil
      return
    end
    if ev == "next" or ev == "prev" then
      self.edit.value = M.step(e, self.edit.value, ev == "next" and 1 or -1)
    elseif ev == "enter" then
      commit(self)
    elseif ev == "back" then
      self.edit = nil
    elseif ev == "tap" then
      for _, h in ipairs(self.hits) do
        if h.step and inside(h, x, y) then
          self.edit.value = M.step(e, self.edit.value, h.step)
          return
        elseif h.commit and inside(h, x, y) then
          commit(self)
          return
        end
      end
      -- A tap anywhere else only closes the edit.
      self.edit = nil
    end
    return
  end

  settle(list, p)
  if ev == "next" or ev == "prev" then
    -- A row with a Learn button is two stops: the value, then the button.
    local dir = ev == "next" and 1 or -1
    local r = list[p.focus]
    if dir == 1 and r and r.learn and p.part ~= 2 then
      p.part = 2
    elseif dir == -1 and r and r.learn and p.part == 2 then
      p.part = 1
    elseif #list > 0 then
      p.focus = (p.focus - 1 + dir) % #list + 1
      settle(list, p, dir)
      p.part = (dir == -1 and list[p.focus].learn) and 2 or 1
    end
  elseif ev == "enter" then
    if list[p.focus] then
      activate(self, p, list[p.focus])
    end
  elseif ev == "back" then
    if #self.stack == 1 then
      return "exit"
    end
    self.stack[#self.stack] = nil
  elseif ev == "tap" then
    for _, h in ipairs(self.hits) do
      if inside(h, x, y) then
        if h.back then
          return self:event("back")
        elseif h.row then
          p.focus, p.part = h.row, h.part or 1
          activate(self, p, list[h.row])
        end
        return
      end
    end
  elseif ev == "drag" then
    p.drag = (p.drag or 0) - x
  end
end

-- Painting. Sizes follow the panels beside the HUD (core/panels.lua): one
-- scale from the screen's short side, 1 at 320 px.

--- Scale for a screen of this size.
function M.scale(w, h)
  return max(0.75, min(1.5, min(w, h) / 320))
end

-- Text shortened to fit `width`, never clipped. Remembered per string and
-- width: measuring is the dear part on a radio.
local fitted = setmetatable({}, { __mode = "k" })
local function fit(c, str, size, width, bold)
  local key = str .. "\0" .. size .. "\0" .. floor(width)
  local cache = fitted[c]
  if not cache then
    cache = {}
    fitted[c] = cache
  end
  local out = cache[key]
  if out then
    return out
  end
  out = str
  if c.textWidth(str, size, bold) > width then
    local n = #str
    repeat
      n = n - 1
      out = string.sub(str, 1, n) .. ".."
    until n <= 1 or c.textWidth(out, size, bold) <= width
  end
  cache[key] = out
  return out
end

-- Words wrapped into at most `lines` lines of `width`.
local function wrap(c, str, size, width, lines)
  local out, line = {}, nil
  for word in string.gmatch(str, "%S+") do
    local try = line and line .. " " .. word or word
    if line and c.textWidth(try, size) > width then
      out[#out + 1] = line
      line = word
    else
      line = try
    end
  end
  out[#out + 1] = line
  while #out > lines do
    local last = table.remove(out)
    out[#out] = out[#out] .. " " .. last
  end
  for i = 1, #out do
    out[i] = fit(c, out[i], size, width)
  end
  return out
end

local function frame(c, x, y, w, h, color)
  c.line(x, y, x + w - 1, y, color, 1)
  c.line(x, y + h - 1, x + w - 1, y + h - 1, color, 1)
  c.line(x, y, x, y + h - 1, color, 1)
  c.line(x + w - 1, y, x + w - 1, y + h - 1, color, 1)
end

-- A chevron pointing left (dir -1) or right (dir 1), centered on x, y.
local function chevron(c, x, y, s, dir, color, width)
  c.line(x - dir * s / 2, y - s, x + dir * s / 2, y, color, width)
  c.line(x + dir * s / 2, y, x - dir * s / 2, y + s, color, width)
end

-- A button: the design system's roles, "primary" orange, "secondary" blue,
-- "ghost" outlined.
local function button(c, x, y, w, h, label, role, sc)
  if role == "primary" then
    c.fill(x, y, w, h, T.orange)
    c.text(x + w / 2, y + h / 2, label, 12 * sc, T.onOrange, "center", true)
  elseif role == "secondary" then
    c.fill(x, y, w, h, T.blueSoft)
    frame(c, x, y, w, h, T.blue)
    c.text(x + w / 2, y + h / 2, label, 12 * sc, T.blueDeep, "center", true)
  else
    frame(c, x, y, w, h, T.lineStrong)
    c.text(x + w / 2, y + h / 2, label, 12 * sc, T.ink2, "center", true)
  end
end

local function bar(self, c, w, sc, p)
  local h = floor(30 * sc)
  c.fill(0, 0, w, h, T.charcoal)
  chevron(c, h / 2, h / 2, 6 * sc, -1, B.ink, max(1, floor(2 * sc)))
  self.hits[#self.hits + 1] = { 0, 0, h, h, back = true }
  local title = p.kind == "devices" and "Devices" or p.title or "-"
  local right = 0
  if p.kind == "folder" then
    local loaded, count = self.client:progress(p.address)
    if loaded < count then
      local text = loaded .. "/" .. count
      c.text(w - 8 * sc, h / 2, text, 11 * sc, B.ink3, "right")
      right = c.textWidth(text, 11 * sc) + 16 * sc
    end
  end
  c.text(h + 2 * sc, h / 2, fit(c, title, 13 * sc, w - h - right - 10 * sc, true), 13 * sc, B.ink, "left", true)
  return h
end

-- One setting's row. The control column is one width for every row.
local function row(self, c, r, i, x, y, w, rh, sc, p, focused)
  local pad = 8 * sc
  local size = 12 * sc
  if focused then
    c.fill(x + 1, y, w - 2, rh, T.surface2)
    c.fill(x + 1, y, max(2, floor(3 * sc)), rh, T.blue)
  end
  local cy = y + rh / 2
  local cw = floor(w * 0.42)
  local cx = x + w - pad - cw
  if r.device then
    c.text(x + pad, cy, fit(c, r.device.name or "-", size, w - 3 * pad), size, T.ink)
    chevron(c, x + w - pad - 3 * sc, cy, 4 * sc, 1, T.ink3, max(1, floor(1.5 * sc)))
    self.hits[#self.hits + 1] = { x, y, x + w, y + rh, row = i }
    return
  end
  local e = r.entry
  local t = e.type
  local labelW = (t == F.folder) and (w - 3 * pad) or (cx - x - 2 * pad)
  c.text(x + pad, cy, fit(c, e.name or "-", size, labelW), size, T.ink2)
  if t == F.folder then
    chevron(c, x + w - pad - 3 * sc, cy, 4 * sc, 1, T.ink3, max(1, floor(1.5 * sc)))
    self.hits[#self.hits + 1] = { x, y, x + w, y + rh, row = i }
  elseif t == F.command then
    local bh = rh - 8 * sc
    button(c, cx, cy - bh / 2, cw, bh, "Start", "secondary", sc)
    self.hits[#self.hits + 1] = { cx, y, cx + cw, y + rh, row = i }
  elseif t == F.info or t == F.string then
    c.text(x + w - pad, cy, fit(c, M.valueText(e), size, cw), size, T.ink, "right")
  else
    local bh = rh - 8 * sc
    local by = cy - bh / 2
    -- The value's box, less the Learn button where the row has one.
    local bw = cw
    if r.learn then
      local lw = floor(min(64 * sc, cw * 0.4))
      local lx = cx + cw - lw
      bw = cw - lw - floor(6 * sc)
      button(c, lx, by, lw, bh, "Learn", "secondary", sc)
      if focused and p.part == 2 then
        frame(c, lx - 2, by - 2, lw + 4, bh + 4, T.blue)
        frame(c, lx - 3, by - 3, lw + 6, bh + 6, T.blue)
      end
      self.hits[#self.hits + 1] = { lx, y, lx + lw, y + rh, row = i, part = 2 }
    end
    local ed = self.edit
    local editing = ed and ed.address == p.address and ed.id == e.id
    c.fill(cx, by, bw, bh, editing and T.bg or T.surface2)
    frame(c, cx, by, bw, bh, editing and T.orange or T.lineStrong)
    local value, color = nil, T.ink
    if editing then
      value = M.valueText(e, ed.value)
      local aw = bh
      chevron(c, cx + aw / 2, cy, 4 * sc, -1, T.orange, max(1, floor(1.5 * sc)))
      chevron(c, cx + bw - aw / 2, cy, 4 * sc, 1, T.orange, max(1, floor(1.5 * sc)))
      self.hits[#self.hits + 1] = { cx, by, cx + aw, by + bh, step = -1 }
      self.hits[#self.hits + 1] = { cx + bw - aw, by, cx + bw, by + bh, step = 1 }
      self.hits[#self.hits + 1] = { cx + aw, by, cx + bw - aw, by + bh, commit = true }
      c.text(cx + bw / 2, cy, fit(c, value, size, bw - 2 * aw), size, T.ink, "center")
    else
      if e.pending then
        value, color = M.valueText(e, e.pending), T.ink3
      else
        value = M.valueText(e)
      end
      c.text(cx + bw - 6 * sc, cy, fit(c, value, size, bw - 12 * sc), size, color, "right")
      self.hits[#self.hits + 1] = { x, y, x + w, y + rh, row = i, part = 1 }
    end
  end
end

local function list(self, c, x, y, w, h, sc, p)
  c.fill(x, y, w, h, T.surface)
  frame(c, x, y, w, h, T.line)
  local items = rows(self, p)
  local rh = floor(30 * sc)
  local visible = max(1, floor((h - 2) / rh))
  settle(items, p)
  if p.drag then
    -- A drag scrolls by whole rows and takes the focus along, so the
    -- focus never pulls the list back.
    local by = (p.drag > 0 and floor or math.ceil)(p.drag / rh)
    p.drag = p.drag - by * rh
    p.scroll = max(0, min(p.scroll + by, #items - visible))
    p.focus = max(p.scroll + 1, min(p.focus, p.scroll + visible))
    p.part = 1
    settle(items, p)
  elseif p.focus <= p.scroll then
    p.scroll = p.focus - 1
  elseif p.focus > p.scroll + visible then
    p.scroll = p.focus - visible
  end
  p.scroll = max(0, min(p.scroll, #items - visible))
  if #items == 0 then
    c.text(x + w / 2, y + rh / 2, "-", 12 * sc, T.ink3, "center")
    return
  end
  for k = 1, min(visible, #items - p.scroll) do
    local i = p.scroll + k
    local ry = y + 1 + (k - 1) * rh
    if k > 1 then
      c.line(x + 8 * sc, ry, x + w - 8 * sc, ry, T.line, 1)
    end
    row(self, c, items[i], i, x, ry, w, rh, sc, p, i == p.focus and not self.dialog)
  end
  if #items > visible then
    local th = h * visible / #items
    local ty = y + (h - th) * p.scroll / (#items - visible)
    c.fill(x + w - max(2, floor(3 * sc)) - 1, ty, max(2, floor(3 * sc)), th, T.lineStrong)
  end
end

local function dialog(self, c, w, h, sc)
  local d = self.dialog
  local e = answered(self)
  c.fill(0, 0, w, h, T.scrim, T.scrimAlpha)
  local dw = min(w - 32 * sc, floor(340 * sc))
  local dh = floor(150 * sc)
  local x, y = floor((w - dw) / 2), floor((h - dh) / 2)
  c.fill(x, y, dw, dh, T.surface)
  frame(c, x, y, dw, dh, T.lineStrong)
  local pad = 10 * sc
  local titleY = y + pad + 7 * sc
  c.text(x + pad, titleY, fit(c, d.title or "-", 13 * sc, dw - 2 * pad, true), 13 * sc, T.ink, "left", true)
  c.fill(x + pad, titleY + 10 * sc, dw - 2 * pad, max(1, floor(1.5 * sc + 0.5)), T.orange)
  local text = e and e.info ~= "" and e.info or "-"
  local lines = wrap(c, text, 12 * sc, dw - 2 * pad, 3)
  for i, line in ipairs(lines) do
    c.text(x + pad, titleY + 10 * sc + (i + 0.3) * 17 * sc, line, 12 * sc, e and T.ink or T.ink3)
  end
  local bh, bw = floor(28 * sc), floor(84 * sc)
  local by = y + dh - pad - bh
  local okX = x + dw - pad - bw
  if e and e.status == CMD.confirmationNeeded then
    button(c, okX, by, bw, bh, "OK", "primary", sc)
    self.hits[#self.hits + 1] = { okX, by, okX + bw, by + bh, dialog = true, action = CMD.confirm }
    okX = okX - bw - 8 * sc
  end
  button(c, okX, by, bw, bh, "Cancel", "ghost", sc)
  self.hits[#self.hits + 1] = { okX, by, okX + bw, by + bh, dialog = true, action = CMD.cancel }
end

--- Draws the browser on canvas `c` (core/hud.lua's canvas, with textWidth)
--- of `w` by `h`.
function App:paint(c, w, h)
  local sc = M.scale(w, h)
  self.hits = {}
  local p = page(self)
  c.fill(0, 0, w, h, T.bg)
  local top = bar(self, c, w, sc, p)
  local pad = floor(6 * sc)
  list(self, c, pad, top + pad, w - 2 * pad, h - top - 2 * pad, sc, p)
  if self.dialog then
    self.hits = {}
    dialog(self, c, w, h, sc)
  end
end

return M
