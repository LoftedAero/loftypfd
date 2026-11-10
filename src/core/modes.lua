-- ArduPilot flight mode names.
--
-- The names and vehicle groupings match Lofty GCS (src/protocol/modes.ts), so
-- the radio and the ground station call a mode the same thing. Passthrough
-- carries the mode number; plain CRSF carries ArduPilot's four-letter name
-- (Mode::name4()), mapped here to the same full names.

local M = {}

local COPTER = {
  [0] = "Stabilize",
  [1] = "Acro",
  [2] = "AltHold",
  [3] = "Auto",
  [4] = "Guided",
  [5] = "Loiter",
  [6] = "RTL",
  [7] = "Circle",
  [9] = "Land",
  [11] = "Drift",
  [13] = "Sport",
  [14] = "Flip",
  [15] = "AutoTune",
  [16] = "PosHold",
  [17] = "Brake",
  [18] = "Throw",
  [19] = "Avoid_ADSB",
  [20] = "Guided_NoGPS",
  [21] = "Smart_RTL",
  [22] = "FlowHold",
  [23] = "Follow",
  [24] = "ZigZag",
  [25] = "SystemID",
  [26] = "Heli_Autorotate",
  [27] = "Auto RTL",
  [28] = "Turtle",
}

local PLANE = {
  [0] = "Manual",
  [1] = "Circle",
  [2] = "Stabilize",
  [3] = "Training",
  [4] = "Acro",
  [5] = "FBWA",
  [6] = "FBWB",
  [7] = "Cruise",
  [8] = "AutoTune",
  [10] = "Auto",
  [11] = "RTL",
  [12] = "Loiter",
  [13] = "Takeoff",
  [14] = "Avoid_ADSB",
  [15] = "Guided",
  [17] = "QStabilize",
  [18] = "QHover",
  [19] = "QLoiter",
  [20] = "QLand",
  [21] = "QRTL",
  [22] = "QAutotune",
  [23] = "QAcro",
  [24] = "Thermal",
  [25] = "Loiter to QLand",
  [26] = "Autoland",
}

local ROVER = {
  [0] = "Manual",
  [1] = "Acro",
  [3] = "Steering",
  [4] = "Hold",
  [5] = "Loiter",
  [6] = "Follow",
  [7] = "Simple",
  [8] = "Dock",
  [9] = "Circle",
  [10] = "Auto",
  [11] = "RTL",
  [12] = "Smart_RTL",
  [15] = "Guided",
}

-- MAV_TYPE groupings. Copter covers multirotors and helicopters; plane covers
-- fixed wing and the VTOL types (19-25), which run ArduPlane.
local CLASS = {
  [2] = "copter", [3] = "copter", [4] = "copter", [13] = "copter",
  [14] = "copter", [15] = "copter", [29] = "copter",
  [1] = "plane", [16] = "plane", [19] = "plane", [20] = "plane", [21] = "plane",
  [22] = "plane", [23] = "plane", [24] = "plane", [25] = "plane",
  [10] = "rover", [11] = "rover",
}

local TABLES = { copter = COPTER, plane = PLANE, rover = ROVER }

-- Four-letter names. Where Copter and Plane share one (ACRO, AUTO, RTL) the
-- full name is the same on both, so one table serves every vehicle.
local SHORT = {
  ACRO = "Acro", ALND = "Autoland", ALTH = "AltHold", AROT = "Heli_Autorotate",
  ARTL = "Auto RTL", ATUN = "AutoTune", AUTO = "Auto", AVOI = "Avoid_ADSB",
  BRAK = "Brake", CIRC = "Circle", CRUS = "Cruise", DOCK = "Dock",
  DRIF = "Drift", FBWA = "FBWA", FBWB = "FBWB", FHLD = "FlowHold",
  FLIP = "Flip", FOLL = "Follow", GNGP = "Guided_NoGPS", GUID = "Guided",
  HOLD = "Hold", INIT = "Initializing", L2QL = "Loiter to QLand", LAND = "Land",
  LOIT = "Loiter", MANU = "Manual", PHLD = "PosHold", QACO = "QAcro",
  QATN = "QAutotune", QHOV = "QHover", QLND = "QLand", QLOT = "QLoiter",
  QRTL = "QRTL", QSTB = "QStabilize", RTL = "RTL", SMPL = "Simple",
  SPRT = "Sport", SRTL = "Smart_RTL", STAB = "Stabilize", STER = "Steering",
  SYSI = "SystemID", THML = "Thermal", THRW = "Throw", TKOF = "Takeoff",
  TRAN = "Training", TRTL = "Turtle", ZIGZ = "ZigZag",
}

-- Plane's VTOL modes: the quadplane flies on its lift motors in these.
local VTOL = {
  QStabilize = true, QHover = true, QLoiter = true, QLand = true, QRTL = true,
  QAutotune = true, QAcro = true, ["Loiter to QLand"] = true,
}

--- "copter", "plane", "rover", or nil for a MAV_TYPE outside those.
function M.class(mavType)
  return CLASS[mavType]
end

--- A mode number's name, or nil while the vehicle type is unknown.
function M.name(mavType, number)
  local t = TABLES[CLASS[mavType]]
  if not t or number == nil then
    return nil
  end
  return t[number] or ("Mode " .. number)
end

--- The full name for a CRSF four-letter name; an unknown one is kept as sent.
function M.fromShort(short)
  return SHORT[short] or short
end

--- Whether a named mode flies a quadplane on its lift motors.
function M.isVtol(name)
  return VTOL[name] == true
end

return M
