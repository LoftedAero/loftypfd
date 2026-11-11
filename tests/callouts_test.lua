-- Voice callouts and alerts (core/callouts.lua) and the clips they say
-- (core/phrases.lua).

local use, T = ...
local callouts = use("callouts")
local phrases = use("phrases")
local vehicle = use("vehicle")

-- A plane on the bench, telemetry arriving: Manual, disarmed, a 3D fix.
local function plane()
  local s = vehicle.new()
  s.mavType, s.modeNumber, s.armed, s.fix = 1, 0, false, 3
  return s
end

-- Runs the watcher over `seconds` at 20 Hz, telemetry arriving, and returns
-- every callout said.
local function run(w, s, from, seconds, level)
  local said = {}
  for i = 0, math.floor(seconds * 20) do
    local now = from + i / 20
    s.lastFrame = now
    for _, item in ipairs(w:update(s, now, level or "all")) do
      said[#said + 1] = item
    end
  end
  return said
end

local function ids(said)
  local out = {}
  for _, item in ipairs(said) do
    out[#out + 1] = item.id .. (item.say and ("=" .. tostring(type(item.say[1]) == "string" and item.say[1] or "?")) or (":" .. tostring(item.tone)))
  end
  return table.concat(out, " ")
end

T.case("the state as found is not said; changes are, once settled", function()
  local w, s = callouts.new(), plane()
  T.eq(ids(run(w, s, 0, 4)), "", "nothing for what was there at the start")
  s.modeNumber = 5
  T.eq(ids(run(w, s, 4, 0.3)), "", "a mode not yet held for half a second")
  T.eq(ids(run(w, s, 4.35, 1)), "mode=mode-fbwa", "then said, once")
  s.modeNumber = 4
  run(w, s, 5.4, 0.2)
  s.modeNumber = 5
  T.eq(ids(run(w, s, 5.65, 1)), "", "a flick that comes back is not said")
  s.armed = true
  T.eq(ids(run(w, s, 6.7, 0.5)), "armed=armed", "armed")
  s.armed = false
  T.eq(ids(run(w, s, 7.3, 0.5)), "disarmed=disarmed", "disarmed")
end)

T.case("plain CRSF: armed only once it is known, no GPS callouts without a fix type", function()
  local w, s = callouts.new(), vehicle.new()
  s.modeShort = "MANU"
  run(w, s, 0, 4)
  s.armed = false
  T.eq(ids(run(w, s, 4, 0.5)), "", "learning the arm state is not a change")
  s.lat, s.lon, s.sats = -35, 149, 10
  T.eq(ids(run(w, s, 4.6, 0.5)), "", "a position, but no fix type")
end)

T.case("battery: messages and the failsafe bit, worse only, percent steps down", function()
  local w, s = callouts.new(), plane()
  s.battery[1].pct = 64
  run(w, s, 0, 4)
  s.battery[1].pct = 49
  T.eq(ids(run(w, s, 4, 0.2)), "batt-pct=battery", "50 percent")
  local said = run(w, s, 4.3, 0.2)
  T.eq(#said, 0, "said once")
  s.battery[1].pct = 31
  said = run(w, s, 4.6, 0.2)
  T.eq(ids(said), "batt-pct=battery", "the lowest step passed, not each")
  T.eq(said[1].say[2][1], 40, "40 percent")
  T.eq(said[1].say[2][2], "percent", "in percent")
  vehicle.addMessage(s, "Battery 1 is low 10.50V used 1200 mAh", 4, 5)
  s.battFailsafe = true
  T.eq(ids(run(w, s, 5, 0.5)), "batt-low=battery-low", "the message says low; the bit adds nothing")
  vehicle.addMessage(s, "Battery 1 is low 10.40V used 1250 mAh", 4, 6)
  T.eq(ids(run(w, s, 6, 0.5)), "", "low again is not said")
  vehicle.addMessage(s, "Battery 1 is critical 9.90V used 1500 mAh", 4, 7)
  said = run(w, s, 7, 0.5)
  T.eq(ids(said), "batt-crit=battery-critical", "critical is worse")
  T.ok(said[1].haptic, "and vibrates")
end)

T.case("failsafes: the message names it, the bit alone says Failsafe", function()
  local w, s = callouts.new(), plane()
  s.armed = true
  run(w, s, 0, 4)
  vehicle.addMessage(s, "RC Short Failsafe On", 4, 4)
  s.failsafe = true
  local said = run(w, s, 4, 0.5)
  T.eq(ids(said), "failsafe=failsafe-radio", "radio failsafe, said once")
  T.ok(said[1].haptic and said[1].pri == "crit", "critical, vibrates")
  vehicle.addMessage(s, "RC Short Failsafe Cleared", 4, 5)
  s.failsafe = false
  said = run(w, s, 5, 0.5)
  T.eq(ids(said), "failsafe=failsafe-cleared", "cleared")
  T.ok(not said[1].haptic, "no buzz for good news")
  s.failsafe = true
  T.eq(ids(run(w, s, 12, 0.5)), "failsafe=failsafe", "a bit with no message")
  s.ekfFailsafe = true
  T.eq(ids(run(w, s, 13, 0.5)), "ekf:warn", "EKF is a beep")
  s.fenceBreach = true
  T.eq(ids(run(w, s, 14, 0.5)), "fence-breach=fence-breached", "fence")
end)

T.case("messages: clips where there are, tones by severity, repeats quiet", function()
  local w, s = callouts.new(), plane()
  run(w, s, 0, 4)
  local function say(text, severity, at)
    vehicle.addMessage(s, text, severity, at)
    return ids(run(w, s, at, 0.2))
  end
  T.eq(say("Bad GPS Health", 2, 4), "sev-crit=bad-gps-health", "a critical message with a clip")
  T.eq(say("Bad GPS Health", 2, 9), "", "ArduPilot's repeat is quiet")
  T.eq(say("Bad GPS Health", 2, 60), "sev-crit=bad-gps-health", "said again after a quiet spell")
  T.eq(say("Something unusual", 2, 61), "sev-crit:warn", "no clip: the warning tone")
  T.eq(say("Compass not calibrated", 3, 62), "sev-err:warn", "an error, no clip")
  T.eq(say("Gyro: disarm to calibrate", 4, 63), "sev-warn:warn", "a warning beeps")
  T.eq(say("Gyro: setup menu ready (76 entries)", 6, 64), "", "information is quiet")
  T.eq(say("Bad or No Terrain Data", 2, 65), "", "terrain is off")
  T.eq(say("PreArm: Throttle too high", 3, 66), "", "PreArm is off")
  T.eq(say("Arm: Throttle too high", 3, 67), "arm-refused:warn", "a refused arm beeps")
  T.eq(say("Flight mode change failed", 3, 68), "mode-refused:warn", "a refused mode beeps")
  T.eq(say("GPS Glitch", 2, 69), "gps-glitch=gps-glitch", "GPS glitch")
  T.eq(say("RollD: 0.0123", 3, 70), "", "Plane's autotune gains are progress")
  T.eq(say("Roll: Finished", 3, 71), "autotune=tune-roll-done", "Plane's autotune, per axis")
  T.eq(say("AutoTune: Success", 6, 72), "autotune=autotune-success", "Copter's autotune")
  T.eq(say("Transition done", 6, 73), "transition=transition-done", "a transition")
  T.eq(say("Crash detected", 0, 74), "sev-crit=crash", "a crash")
  T.eq(say("Mission complete", 6, 75), "mission-done=mission-complete", "mission complete")
end)

T.case("alerts only and off", function()
  local w, s = callouts.new(), plane()
  s.battery[1].pct = 64
  run(w, s, 0, 4, "alerts")
  s.battery[1].pct = 49
  s.modeNumber = 5
  T.eq(ids(run(w, s, 4, 1, "alerts")), "mode=mode-fbwa", "information left out")
  s.armed = true
  T.eq(ids(run(w, s, 5, 1, "off")), "", "off says nothing")
  s.armed = false
  T.eq(ids(run(w, s, 6, 1, "all")), "disarmed=disarmed", "and nothing builds up while off")
end)

T.case("warning beeps can wait for arming; spoken messages and refusals do not", function()
  local w, s = callouts.new(), plane()
  local said = {}
  local function at(now)
    s.lastFrame = now
    for _, item in ipairs(w:update(s, now, "all", false)) do
      said[#said + 1] = item.id .. (item.tone and ":tone" or "")
    end
  end
  for i = 0, 80 do
    at(i / 20)
  end
  vehicle.addMessage(s, "Gyro: disarm to calibrate", 4, 5)
  vehicle.addMessage(s, "Compass not calibrated", 3, 5)
  vehicle.addMessage(s, "Arm: Throttle too high", 3, 5)
  vehicle.addMessage(s, "Bad GPS Health", 2, 5)
  at(5)
  T.eq(table.concat(said, " "), "sev-crit arm-refused:tone", "disarmed: no message tones; a clip and a refusal stay")
  said = {}
  s.armed = true
  at(5.1)
  vehicle.addMessage(s, "Gyro: disarm to calibrate again", 4, 6)
  at(6)
  T.eq(table.concat(said, " "), "armed sev-warn:tone", "armed: the beep")
end)

T.case("the settings for the button and the beeps", function()
  local options = use("options")
  local set = options.resolve(function()
    return nil
  end)
  T.eq(set.devicesButton, true, "the devices button shows by default")
  T.eq(set.beepsDisarmed, false, "warning beeps wait for arming by default")
  set = options.resolve(function(o)
    return (o.key == "devicesButton" or o.key == "warnBeeps") and 2 or (o.key == "warnBeeps" and 1) or nil
  end)
  T.eq(set.devicesButton, false, "hidden")
end)

T.case("a lost link pauses; what changed meanwhile is said when it is back", function()
  local w, s = callouts.new(), plane()
  run(w, s, 0, 4)
  s.lastFrame = 4
  s.modeNumber = 11
  T.eq(#w:update(s, 10, "all"), 0, "nothing while lost")
  T.eq(ids(run(w, s, 10, 1)), "mode=mode-rtl", "said on its return")
end)

T.case("critical first", function()
  local w, s = callouts.new(), plane()
  s.armed = true
  run(w, s, 0, 4)
  s.modeNumber = 11
  run(w, s, 4, 0.2)
  s.fenceBreach = true
  local said = run(w, s, 4.25, 0.5)
  T.eq(ids(said), "fence-breach=fence-breached mode=mode-rtl", "the breach before the mode")
end)

T.case("every clip has a name EdgeTX can play and words", function()
  local n = 0
  for name, words in pairs(phrases.all()) do
    n = n + 1
    T.ok(#name <= phrases.MAX_NAME, name .. " is at most " .. phrases.MAX_NAME .. " characters")
    T.ok(string.find(name, "^[a-z0-9%-]+$") ~= nil, name .. ": lower case, digits and hyphens")
    T.ok(#words > 0, name .. " says something")
  end
  T.ok(n > 60, n .. " clips")
  T.eq(phrases.modeClip("Loiter to QLand"), "mode-loiter-to-qland", "a mode's clip")
  T.eq(phrases.modeWords("FBWA"), "Fly by wire A mode", "the GCS's words")
  T.eq(phrases.modeWords("Guided_NoGPS"), "Guided no G P S mode", "spoken forms")
  -- Every clip the rules can say exists.
  local all = phrases.all()
  for _, name in ipairs({ "armed", "disarmed", "battery", "battery-low", "battery-critical", "battery-failsafe",
    "gps-fix", "gps-lost", "gps-glitch", "failsafe", "failsafe-radio", "failsafe-gcs", "failsafe-throttle",
    "failsafe-cleared", "fence-breached", "mission-complete", "transition-done", "transition-failed",
    "autotune-success", "autotune-failed", "tune-roll-done", "tune-pitch-done", "tune-yaw-done", "crash",
    "hard-landing", "bad-gps-health" }) do
    T.ok(all[name], name .. " has a clip")
  end
end)

T.case("a cycle stays cheap on EdgeTX", function()
  local w, s = callouts.new(), plane()
  run(w, s, 0, 4)
  s.lastFrame = 10
  local n = 0
  debug.sethook(function()
    n = n + 1
  end, "", 1)
  w:update(s, 10, "all")
  debug.sethook()
  T.ok(n < 600, "a quiet cycle took " .. n .. " instructions")
end)
