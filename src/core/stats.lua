-- A flight's statistics, kept by the radio from what the aircraft and the
-- link sent: the time since arming, the highest altitude and speed, and the
-- lowest link quality. They start again at each arming and stay after
-- disarming, so they can be read after landing. Where armed is unknown
-- (plain CRSF without the disarmed star) there is no flight time, and the
-- rest run from when telemetry started.

local M = {}

local function higher(a, b)
  if b == nil then
    return a
  end
  return (a == nil or b > a) and b or a
end

local function lower(a, b)
  if b == nil then
    return a
  end
  return (a == nil or b < a) and b or a
end

--- Follows state `s` at time `now`, in seconds; call once a cycle.
function M.update(s, now)
  local st = s.stats
  if s.armed and not st.armed then
    for k in pairs(st) do
      st[k] = nil
    end
    st.armedAt = now
  end
  st.armed = s.armed
  if s.armed and st.armedAt then
    st.time = now - st.armedAt
  end
  st.alt = higher(st.alt, s.alt)
  st.airspeed = higher(st.airspeed, s.airspeed)
  st.groundspeed = higher(st.groundspeed, s.groundspeed)
  st.speed = higher(st.speed, s.speed)
  st.lq = lower(st.lq, s.link.lq)
end

return M
