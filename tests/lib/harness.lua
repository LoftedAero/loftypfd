-- Loads core modules the way the radios do, and a minimal test API.
--
-- Core modules get an environment that refuses unknown globals, reads and
-- writes alike: on a radio every script shares one global table, and a core
-- module that reached for a platform API (lcd, system) would only fail on
-- the radio that lacks it.

local read = ...

-- EdgeTX gives strings no methods (s:sub fails), so neither do the tests:
-- everything uses string.sub(s, ...).
getmetatable("").__index = nil

local strictEnv = setmetatable({}, {
  __index = function(_, k)
    local v = _G[k]
    if v == nil then
      error("core module read the undefined global '" .. tostring(k) .. "'", 2)
    end
    return v
  end,
  __newindex = function(_, k)
    error("core module wrote the global '" .. tostring(k) .. "'", 2)
  end,
})

local cache = {}
local function use(name)
  if cache[name] == nil then
    local text = read("src/core/" .. name .. ".lua")
    local chunk = assert(load(text, "@src/core/" .. name .. ".lua", "t", strictEnv))
    cache[name] = chunk(use)
  end
  return cache[name]
end

local T = { passed = 0, failures = {} }

local function fail(msg, level)
  error(msg, (level or 1) + 2)
end

function T.eq(actual, expected, what)
  if actual ~= expected then
    fail((what or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

function T.near(actual, expected, tolerance, what)
  if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
    fail((what or "value") .. ": expected " .. tostring(expected) .. " +/- " .. tolerance .. ", got " .. tostring(actual))
  end
end

function T.ok(value, what)
  if not value then
    fail((what or "condition") .. " was false")
  end
end

function T.case(name, fn)
  local ok, err = pcall(fn)
  if ok then
    T.passed = T.passed + 1
  else
    T.failures[#T.failures + 1] = name .. ": " .. tostring(err)
  end
end

-- A helper from tests/lib, given the same loader and API as a test.
function T.lib(name)
  return assert(load(read("tests/lib/" .. name .. ".lua"), "@tests/lib/" .. name .. ".lua"))(use, T)
end

-- A string's bytes as a table, for building payloads.
function T.bytes(s)
  return { string.byte(s, 1, -1) }
end

return { use = use, T = T }
