-- The colors the panels and the device browser draw with, in the theme being
-- shown. The HUD is not themed: it is a dark ground in both (core/hud.lua).
--
-- `T` is filled in place, so a module can keep a reference to it and see the
-- theme change. The radio's theme decides unless the pilot chose one.

local use = ...
local theme = use("theme")

local M = {}

M.T = {}

-- The app bar is a dark ground in both themes, so what is drawn on it takes
-- the dark theme's colors (docs/lofted-aero/dark-mode.md).
M.BAR = theme.dark

-- What the design system writes as literals rather than tokens: the primary
-- button's label and the modal's scrim (design/lofted-aero.css and its dark
-- sheet).
local EXTRA = {
  light = { onOrange = { 255, 255, 255 }, scrim = theme.light.charcoal, scrimAlpha = 0.45 },
  dark = { onOrange = { 26, 18, 6 }, scrim = theme.dark.bg, scrimAlpha = 0.7 },
}

--- The theme choices a radio's settings offer, in the order stored: Lofty
--- GCS's, with the radio in place of the system.
M.CHOICES = { "Match the radio", "Light", "Dark" }

--- Shows `name`, "light" or "dark".
function M.set(name)
  if name ~= "light" then
    name = "dark"
  end
  if M.name == name then
    return
  end
  M.name = name
  for k, v in pairs(theme[name]) do
    M.T[k] = v
  end
  for k, v in pairs(EXTRA[name]) do
    M.T[k] = v
  end
end

--- The theme for a choice (a place in CHOICES) on a radio whose own theme is
--- dark or not; nil, as from a radio that cannot say, counts as dark.
function M.pick(choice, radioDark)
  if choice == 2 then
    return "light"
  elseif choice == 3 then
    return "dark"
  end
  return radioDark == false and "light" or "dark"
end

--- Whether a color reads as a dark background (Rec. 601 luma).
function M.isDark(r, g, b)
  return r * 299 + g * 587 + b * 114 < 128000
end

M.set("dark")

return M
