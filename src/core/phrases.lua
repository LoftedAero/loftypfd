-- The words a radio says, each a recorded clip: neither radio has
-- text-to-speech. tools/voice.py makes a clip for every phrase here and every
-- mode, so this table is the one list of what can be said. Numbers are not
-- clips: the radio says them in its own voice and language.
--
-- The words are Lofty GCS's (src/services/voice there), spelled the way its
-- speech engine is given them, so both say a callout the same way.
--
-- Clip names are the file names. EdgeTX plays at most 42 characters of path,
-- and its clips live in /SOUNDS/en/lofty/ (17), so a name has 21 at most.

local use = ...
local modes = use("modes")

local M = {}

M.MAX_NAME = 21

M.CLIPS = {
  armed = "Armed",
  disarmed = "Disarmed",
  battery = "Battery",
  ["battery-low"] = "Battery low",
  ["battery-critical"] = "Battery critical",
  ["battery-failsafe"] = "Battery failsafe",
  ["gps-fix"] = "G P S 3D fix",
  ["gps-lost"] = "G P S fix lost",
  ["gps-glitch"] = "G P S glitch",
  failsafe = "Failsafe",
  ["failsafe-radio"] = "Radio failsafe",
  ["failsafe-gcs"] = "Ground station failsafe",
  ["failsafe-throttle"] = "Throttle failsafe",
  ["failsafe-cleared"] = "Failsafe cleared",
  ["fence-breached"] = "Fence breached",
  ["mission-complete"] = "Mission complete",
  ["transition-done"] = "Transition done",
  ["transition-failed"] = "Transition failed",
  ["autotune-success"] = "Autotune success",
  ["autotune-failed"] = "Autotune failed",
  ["tune-roll-done"] = "Roll autotune finished",
  ["tune-pitch-done"] = "Pitch autotune finished",
  ["tune-yaw-done"] = "Yaw autotune finished",
  crash = "Crash detected",
  ["hard-landing"] = "Hard landing detected",
  ["bad-gps-health"] = "Bad G P S health",
  ["bad-gyro-health"] = "Bad gyro health",
  ["bad-accel-health"] = "Bad accelerometer health",
  ["bad-compass-health"] = "Bad compass health",
  ["bad-baro-health"] = "Bad barometer health",
  ["bad-lidar-health"] = "Bad lidar health",
  ["bad-optflow-health"] = "Bad optical flow health",
}

-- ArduPilot's mode names where the written form reads badly aloud, as the
-- GCS's speech-text.ts has them.
local MODE_WORDS = {
  AltHold = "Altitude hold",
  PosHold = "Position hold",
  RTL = "Return to launch",
  Smart_RTL = "Smart return to launch",
  ["Auto RTL"] = "Auto return to launch",
  FBWA = "Fly by wire A",
  FBWB = "Fly by wire B",
  QStabilize = "Q stabilize",
  QHover = "Q hover",
  QLoiter = "Q loiter",
  QLand = "Q land",
  QRTL = "Q return to launch",
  QAutotune = "Q autotune",
  QAcro = "Q acro",
  ["Loiter to QLand"] = "Loiter to Q land",
  Avoid_ADSB = "Avoid A D S B",
  Guided_NoGPS = "Guided no G P S",
  SystemID = "System I D",
  Heli_Autorotate = "Autorotate",
  AutoTune = "Autotune",
  ZigZag = "Zig zag",
  FlowHold = "Flow hold",
}

--- A mode's clip name: "mode-" and the name in lower case, hyphenated.
function M.modeClip(name)
  local slug = string.gsub(string.lower(name), "[^%w]+", "-")
  return "mode-" .. slug
end

--- What a mode's clip says.
function M.modeWords(name)
  return (MODE_WORDS[name] or (string.gsub(name, "_", " "))) .. " mode"
end

--- Every clip: name to words.
function M.all()
  local out = {}
  for name, words in pairs(M.CLIPS) do
    out[name] = words
  end
  for _, name in ipairs(modes.names()) do
    out[M.modeClip(name)] = M.modeWords(name)
  end
  return out
end

return M
