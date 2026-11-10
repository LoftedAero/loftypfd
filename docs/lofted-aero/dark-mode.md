# Dark mode

Every window ships light and dark. `css/lofted-aero-dark.css` holds the
palette and the fixes for the system's own classes; an app's sheet holds only
the dark values of its own colors.

## The attribute, before first paint

The theme is resolved to an explicit `data-theme` on `<html>`, `light` or
`dark`, never absent, rather than left to `prefers-color-scheme` in the
stylesheet. The palette then exists once, under one selector, instead of
twice in a media query where the copies drift; and an explicit choice has to
beat the OS in both directions, which in pure CSS takes three blocks to
express and one to get wrong.

An inline script in `index.html` stamps it before anything else loads:

```html
<script>
  ;(function () {
    try {
      var c = localStorage.getItem('<app>.theme') || 'system'
      var dark =
        c === 'dark' ||
        (c === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches)
      document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light')
      document.documentElement.style.colorScheme = dark ? 'dark' : 'light'
    } catch (e) {
      /* storage blocked: the stylesheet's light default stands */
    }
  })()
</script>
```

Without it the window is white for as long as the app takes to load, which
reads as a bug rather than a load. It also sets `color-scheme`, which is what
makes scrollbars and select popups dark: furniture the browser draws and no
stylesheet reaches. Keep it inline and dependency-free so it runs first.

The key is the app's own (`loftgcs.theme`, `loftedaero.theme`). Each app has
its own storage anyway, so a shared name would not make them follow each
other.

## The toggle

One button in the app bar, ahead of the connection controls because it is
window chrome rather than part of the work. It shows the theme you are in
(sun in light, moon in dark), and pressing it means "make it the other one".
It sits on the app bar, which is dark in both themes, so its colors are fixed.

A new window follows the machine. That needs no control of its own: it is what
happens until somebody presses the button, after which their choice stands.
There is no third state and no way back to following the OS. Either would
need a tooltip to be discoverable, and a control that has to be explained is
not one. The icon says everything the button does.

An app with a preferences dialog may put the theme there instead of on the bar.

## The palette

The ramp is inverted, not merely darkened: surfaces get lighter as they come
closer to the reader, because that is how depth reads without shadows. The
brand hues shift too. `#F7941D` and `#4684C5` are tuned for contrast against
white, and the deep variants exist to be legible on white, so on a dark ground
the roles swap: the soft tints become dim washes behind text, and the deep
tints become the readable text colors.

Disabled controls are the one place the ramp is retuned rather than inverted.
`--la-ink-3` on a dark field reads as text that failed to load, so disabled
text moves one step up to `--la-ink-2`.

## Traps

**A token used for two jobs.** `--la-charcoal` is the app bar's background and
heading ink. Dark needs those to go opposite ways and a token cannot, so
charcoal stays a dark surface and every use of it as text points at `--la-ink`.
The dark sheet does this for the system's titles; an app that uses charcoal as
text in its own sheet needs the same override there, or its heading is
near-black on near-black. A test that reads the app's sheet finds them; 3BSM
Config's `test/theme-test.js` is the reference.

**A pale pill with dark text.** Status chips, wizard steps: inverting the
surface without the text leaves it unreadable. Each pair needs an explicit dark
counterpart.

**A color inside a data URI.** The `.la-select` chevron is an inlined SVG with
its fill in the URL, so it cannot follow a token. The dark sheet re-inlines it
with one value changed. The same goes for anything else painted from a string
rather than a property.

**A part of a control the OS draws.** The list a `<select>` drops down is
painted by the platform and does not reliably follow `color-scheme`: on
Windows it comes up white on a dark window, and near-white option text reads
as blank rows. The dark sheet pins both halves, in both themes.

**A permanently dark ground.** The app bar, a video overlay, a preview of
goggles' OSD are dark in both themes. Text on them uses an app token for
light-on-dark, never `--la-surface`, which is dark in the dark theme.

**Things that are not themed at all.** A photo of a board, an LED's actual
color, the white chip behind the logo. These stay put in both themes (the
photo is matched against hardware on the bench), so write them as literals
with a comment saying why, and nobody "fixes" them.

Check dark mode by looking at it. Dropdowns, disabled controls and anything on
a permanently dark ground are the usual problems.
