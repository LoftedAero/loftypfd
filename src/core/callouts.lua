-- Voice callouts and alerts, after Lofty GCS's (src/services/voice there):
-- its rows, words and rules, cut to what a radio link carries and to Eric's
-- choices for the radio (2026-11-10): no repeats, nothing the radio already
-- says (telemetry lost, link quality, timers), no pilot-set thresholds, and
-- critical callouts vibrate. Rows that are off are not here at all.
--
-- The rules follow the GCS's: say a change, never a running value; take the
-- state as found for SETTLE_S after telemetry starts; say a mode once it has
-- held for MODE_SETTLE_S. Neither radio has text-to-speech, so a message
-- from the aircraft is spoken only where a clip says it (core/phrases.lua),
-- and otherwise gets its row's tone.
--
-- A callout is {id, pri, say, tone, haptic}: `say` a list of clip names and
-- {number, unit} pairs, `tone` "info" or "warn" for a beep instead.

local use = ...
local vehicle = use("vehicle")
local phrases = use("phrases")

local M = {}

local find, lower, match = string.find, string.lower, string.match

M.SETTLE_S = 3
M.MODE_SETTLE_S = 0.5
-- A message ArduPilot keeps sending is said again only after this long
-- without it: repeats are off.
M.MESSAGE_QUIET_S = 30
-- A message this recent explains a failsafe flag, which is then not said
-- again.
local EXPLAINED_S = 5

-- id = { priority, delivery, beep }: priority "crit" interrupts and
-- vibrates, "warn" goes ahead of "info"; delivery "voice" or "beep"; a beep
-- follows its priority unless it says otherwise, as in the GCS.
M.ROWS = {
  mode = { "warn", "voice" },
  armed = { "warn", "voice" },
  disarmed = { "warn", "voice" },
  ["arm-refused"] = { "warn", "beep" },
  transition = { "info", "voice" },
  ["mode-refused"] = { "warn", "beep" },
  ["batt-low"] = { "warn", "voice" },
  ["batt-crit"] = { "crit", "voice" },
  ["batt-pct"] = { "info", "voice" },
  ["gps-fix"] = { "info", "voice" },
  ["gps-lost"] = { "warn", "voice" },
  ["gps-glitch"] = { "warn", "voice" },
  ["mission-done"] = { "warn", "voice" },
  failsafe = { "crit", "voice" },
  ekf = { "crit", "beep" },
  ["fence-breach"] = { "crit", "voice" },
  ["sev-crit"] = { "crit", "voice" },
  ["sev-err"] = { "warn", "voice" },
  ["sev-warn"] = { "info", "beep", "warn" },
  autotune = { "info", "voice" },
}

-- What the pilot chose (core/options.lua): everything, alerts only, or off.
M.LEVELS = { "all", "alerts", "off" }

local clips
local function hasClip(name)
  clips = clips or phrases.all()
  return clips[name] ~= nil
end

local Watcher = {}
Watcher.__index = Watcher

function M.new()
  return setmetatable({}, Watcher)
end

local function reset(self, s)
  for k in pairs(self) do
    self[k] = nil
  end
  self.state = s
  self.inbox = {}
  self.heard = {}
  self.battLevel = 0
  local inbox = self.inbox
  s.onMessage = function(msg)
    inbox[#inbox + 1] = msg
  end
end

-- A callout for row `id`, saying `say` (nil: the row's tone). `pri`
-- overrides the row's priority.
local function emit(out, id, say, pri)
  local row = M.ROWS[id]
  pri = pri or row[1]
  local item = { id = id, pri = pri, haptic = pri == "crit" }
  if row[2] == "voice" and say then
    item.say = say
  else
    item.tone = row[3] or (pri == "info" and "info" or "warn")
  end
  out[#out + 1] = item
end

local HEALTH = {
  gps = "bad-gps-health", gyro = "bad-gyro-health", accel = "bad-accel-health",
  compass = "bad-compass-health", baro = "bad-baro-health", lidar = "bad-lidar-health",
  optflow = "bad-optflow-health",
}
local AXES = { roll = "tune-roll-done", pitch = "tune-pitch-done", yaw = "tune-yaw-done" }

-- One message from the aircraft: which row it belongs to, if any.
local function message(self, msg, now, out)
  local text = match(msg.text or "", "^%s*(.-)%s*$")
  if text == "" then
    return
  end
  local last = self.heard[text]
  self.heard[text] = now
  if last and now - last < M.MESSAGE_QUIET_S then
    return
  end
  local l = lower(text)

  -- "Arm:" explains an attempt that failed; "PreArm:" repeats every 30 s
  -- while disarmed, and its row is off.
  if find(l, "^arm%s*:") then
    return emit(out, "arm-refused")
  elseif find(l, "^prearm") or find(l, "^#") then
    return
  end
  local battery = match(l, "^battery %d+ is (%a+)")
  if battery == "low" or battery == "critical" then
    self.battMessageAt = now
    local level = battery == "low" and 1 or 2
    if level > self.battLevel then
      self.battLevel = level
      emit(out, level == 1 and "batt-low" or "batt-crit", { level == 1 and "battery-low" or "battery-critical" })
    end
    return
  end
  if find(l, "ekf%d?") and (find(l, "variance") or find(l, "failsafe")) then
    self.ekfMessageAt = now
    return emit(out, "ekf")
  end
  if find(l, "failsafe") then
    self.failsafeMessageAt = now
    if find(l, "cleared") or find(l, "failsafe off") then
      return emit(out, "failsafe", { "failsafe-cleared" }, "warn")
    end
    local which = (find(l, "^rc ") or find(l, "radio")) and "failsafe-radio"
      or find(l, "^gcs") and "failsafe-gcs"
      or find(l, "throttle") and "failsafe-throttle"
      or find(l, "battery") and "battery-failsafe"
      or "failsafe"
    return emit(out, "failsafe", { which })
  end
  if find(l, "gps glitch") then
    return emit(out, "gps-glitch", { "gps-glitch" })
  elseif find(l, "mission complete") then
    return emit(out, "mission-done", { "mission-complete" })
  elseif find(l, "^land %a+ started") or find(l, "^takeoff complete") then
    return
  elseif find(l, "^transition") then
    local say = find(l, "failed") and { "transition-failed" } or find(l, "done") and { "transition-done" } or nil
    return emit(out, "transition", say)
  end
  local tune = match(l, "^autotune:?%s*(%a+)")
  if tune == "success" or tune == "failed" then
    return emit(out, "autotune", { "autotune-" .. tune })
  end
  -- Plane's autotune reports each axis as it finishes, and its gains
  -- ("RollD: 0.0123") at error severity on the way.
  local axis = match(l, "^(%a+):%s*finished")
  if axis and AXES[axis] then
    return emit(out, "autotune", { AXES[axis] })
  elseif find(l, "^%a+[pdi]:%s*[%-%d%.]+$") then
    return
  end
  if find(l, "parachute") and find(l, "released") then
    return
  elseif find(l, "mode change") and (find(l, "failed") or find(l, "denied")) then
    return emit(out, "mode-refused")
  elseif find(l, "fence") and (find(l, "breach") or find(l, "triggered")) then
    -- The status word's fence bit says it, where passthrough sends one.
    if self.state.fencePresent == nil then
      emit(out, "fence-breach", { "fence-breached" })
    end
    return
  elseif find(l, "bad or no terrain data") then
    return
  end

  local severity = msg.severity or 6
  local id = severity <= 2 and "sev-crit" or severity == 3 and "sev-err" or severity == 4 and "sev-warn" or nil
  if not id then
    return
  end
  local health = match(l, "^bad (%a+) health$")
  local say
  if health and HEALTH[health] then
    say = { HEALTH[health] }
  elseif find(l, "crash") then
    say = { "crash" }
  elseif find(l, "hard landing") then
    say = { "hard-landing" }
  end
  emit(out, id, say)
end

-- The readings the rules compare from one call to the next.
local function snapshot(s)
  local b = s.battery and s.battery[1] or {}
  return {
    mode = vehicle.modeName(s), armed = s.armed, fix = s.fix, pct = b.pct,
    failsafe = s.failsafe, ekf = s.ekfFailsafe, batt = s.battFailsafe, fence = s.fenceBreach,
  }
end

local function stateRules(self, prev, v, now, out)
  -- Mode, once settled where the switch landed.
  if v.mode ~= self.modeSaid then
    local p = self.modePending
    if not p or p.name ~= v.mode then
      self.modePending = { name = v.mode, since = now }
    elseif v.mode and now - p.since >= M.MODE_SETTLE_S then
      local clip = phrases.modeClip(v.mode)
      if hasClip(clip) then
        emit(out, "mode", { clip })
      end
      self.modeSaid = v.mode
      self.modePending = nil
    end
  else
    self.modePending = nil
  end

  if prev.armed == false and v.armed == true then
    emit(out, "armed", { "armed" })
  elseif prev.armed == true and v.armed == false then
    emit(out, "disarmed", { "disarmed" })
    self.battLevel = 0
  end

  -- GPS: from a reported no fix or 2D, never from nothing, which is also
  -- what a link looks like before its first GPS word. Plain CRSF has no fix
  -- type, so neither is said there.
  if prev.fix and v.fix then
    if prev.fix >= 1 and prev.fix < 3 and v.fix >= 3 then
      emit(out, "gps-fix", { "gps-fix" })
      self.gpsLostSaid = false
    elseif prev.fix >= 3 and v.fix < 3 and v.armed and not self.gpsLostSaid then
      emit(out, "gps-lost", { "gps-lost" })
      self.gpsLostSaid = true
    end
  end

  -- The status word's flags, unless a message has just said why.
  local function fresh(at)
    return at and now - at < EXPLAINED_S
  end
  if v.failsafe and not prev.failsafe and v.armed and not fresh(self.failsafeMessageAt) then
    emit(out, "failsafe", { "failsafe" })
  end
  if v.ekf and not prev.ekf and not fresh(self.ekfMessageAt) then
    emit(out, "ekf")
  end
  if v.batt and not prev.batt and self.battLevel == 0 and not fresh(self.battMessageAt) then
    self.battLevel = 1
    emit(out, "batt-low", { "battery-failsafe" })
  end
  if v.fence and not prev.fence then
    emit(out, "fence-breach", { "fence-breached" })
  end

  -- Percentage steps from 50, only ever down. The first reading is the
  -- baseline, so a half-flat pack plugged in says nothing.
  if v.pct then
    if not self.pctSaid then
      self.pctSaid = v.pct
    end
    local lowest
    for level = 50, 10, -10 do
      if v.pct <= level then
        lowest = level
      end
    end
    if lowest and lowest < self.pctSaid then
      self.pctSaid = lowest
      emit(out, "batt-pct", { "battery", { lowest, "percent" } })
    end
  end
end

-- The GCS's default beeps (tones.ts): a soft 1000 Hz beep for information,
-- the caution beeper's three 1250 Hz pips for warnings. Frequency, then
-- milliseconds on and off.
local TONES = {
  info = { { 1000, 120, 0 } },
  warn = { { 1250, 90, 70 }, { 1250, 90, 70 }, { 1250, 90, 0 } },
}
-- Milliseconds on and off: long enough to feel through a glove.
local HAPTIC = { 300, 0 }

--- A callout as the steps a radio plays, in order: {"haptic", on, off},
--- {"tone", hz, on, off}, {"file", clip} or {"number", value, unit}.
function M.sounds(item)
  local out = {}
  if item.haptic then
    out[#out + 1] = { "haptic", HAPTIC[1], HAPTIC[2] }
  end
  for _, t in ipairs(item.tone and TONES[item.tone] or {}) do
    out[#out + 1] = { "tone", t[1], t[2], t[3] }
  end
  for _, part in ipairs(item.say or {}) do
    if type(part) == "table" then
      out[#out + 1] = { "number", part[1], part[2] }
    else
      out[#out + 1] = { "file", part }
    end
  end
  return out
end

-- The rows whose tone is only an aircraft's message, which the pilot can
-- quiet while disarmed; a refused arm or mode answers what the pilot did, and
-- stays.
local MESSAGE_ROWS = { ["sev-crit"] = true, ["sev-err"] = true, ["sev-warn"] = true }

--- What to say now about state `s`, at `level` ("all", "alerts" or "off").
--- `beepsDisarmed` false quiets the messages' tones while disarmed; a message
--- with a clip is still said. Call every cycle, after decoding. A new state
--- (another vehicle, a replay starting over) starts the rules afresh.
function Watcher:update(s, now, level, beepsDisarmed)
  if self.state ~= s then
    reset(self, s)
  end
  local out = {}
  local inbox = self.inbox
  -- Nothing is said while the link is down; what changed meanwhile is said
  -- when it comes back, as the GCS does.
  if not s.lastFrame or now - s.lastFrame > vehicle.LOST_S then
    return out
  end
  -- When telemetry first starts, what is there is taken as found.
  if not self.prev then
    self.settleUntil = now + M.SETTLE_S
  end
  local v = snapshot(s)
  if not self.prev or now < self.settleUntil then
    for i = 1, #inbox do
      self.heard[match(inbox[i].text or "", "^%s*(.-)%s*$")] = now
      inbox[i] = nil
    end
    self.prev = v
    self.modeSaid = v.mode
    if v.pct then
      self.pctSaid = v.pct
    end
    return out
  end
  for i = 1, #inbox do
    message(self, inbox[i], now, out)
    inbox[i] = nil
  end
  stateRules(self, self.prev, v, now, out)
  self.prev = v

  -- Prune messages long quiet, so the table stays small.
  for text, at in pairs(self.heard) do
    if now - at > 2 * M.MESSAGE_QUIET_S then
      self.heard[text] = nil
    end
  end

  if level == "off" then
    return {}
  end
  local quiet = beepsDisarmed == false and s.armed == false
  local kept = {}
  for _, item in ipairs(out) do
    if not (level == "alerts" and item.pri == "info") and not (quiet and item.tone and MESSAGE_ROWS[item.id]) then
      kept[#kept + 1] = item
    end
  end
  out = kept
  -- Critical first, then warnings, then information, as the GCS queues them.
  local rank = { crit = 1, warn = 2, info = 3 }
  table.sort(out, function(a, b)
    return rank[a.pri] < rank[b.pri]
  end)
  return out
end

return M
