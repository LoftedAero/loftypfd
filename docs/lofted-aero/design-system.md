# The design system

What `css/lofted-aero.css` defines, and how a window is built from it. Nothing
in the sheet names an app; everything specific to one window goes in that
app's own sheet.

How screens behave and read is in [ux-rules.md](ux-rules.md); how they are
composed from these parts is in [ui-conventions.md](ui-conventions.md). The
dark theme is in [dark-mode.md](dark-mode.md).

## 1. Linking it

Three sheets, in this order, so the app's rules win without `!important`:

```
lofted-aero.css        the system
lofted-aero-dark.css   its dark theme
app.css                the app's own
```

An Electron app with plain HTML links them in `index.html`; a Vite app imports
them in that order from its entry module. Either way the fonts come first:

```html
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
<link
  rel="stylesheet"
  href="https://fonts.googleapis.com/css2?family=Work+Sans:wght@400;600;700&family=Roboto+Mono:wght@400&display=swap"
/>
```

The round badge for the app bar is `assets/LoftedAeroIcon.png`.

**Never edit a vendored copy.** If an app needs something the system lacks,
add it to the design system and release it, or put it in that app's sheet. Editing the shared
file for one app's convenience is how three apps end up with three different
button sizes. The design system repo's `docs/adopting.md` covers vendoring
and the check that keeps a copy honest.

### Fonts on a machine with no internet

Work Sans is loaded from Google Fonts, so it does not load on a bench PC with
no internet, which is the normal case beside a test stand. That is fine:
`--la-font` names `Segoe UI` next, and nothing in the layout depends on the
exact face. An app that needs the brand face offline bundles the `.woff2`
files with an `@font-face` block in its own sheet; it does not remove the
fallbacks.

## 2. Tokens

The brand colors are the documentation site's
(`lofted-aero-guides/docs/stylesheets/extra.css`), captured from
loftedaero.com. If the brand changes, update both places together.

| Token              | Value     | Used for                                                     |
| ------------------ | --------- | ------------------------------------------------------------ |
| `--la-orange`      | `#F7941D` | the action color: primary buttons, card title rules          |
| `--la-orange-deep` | `#C05A00` | orange text (links), where the bright orange fails contrast  |
| `--la-blue`        | `#4684C5` | working controls: secondary buttons, slider thumbs, switches |
| `--la-blue-deep`   | `#2F6EA8` | their hover state, and blue text                             |
| `--la-charcoal`    | `#2D2D2F` | the app bar, headings                                        |
| `--la-gold`        | `#FFC540` | a spare accent from the brand ramp                           |

The grays are one ramp (`--la-ink`, `--la-ink-2`, `--la-ink-3`, `--la-line`,
`--la-line-strong`, `--la-surface`, `--la-surface-2`, `--la-bg`) so surfaces
stay related. The semantic colors are `--la-ok`, `--la-warn` and `--la-bad`.

Alongside them: `--la-space-1` to `--la-space-6` (a 4px scale),
`--la-size-xs` to `--la-size-xl`, `--la-radius`, `--la-radius-sm`,
`--la-radius-pill`, three shadows, `--la-ring` (the keyboard-focus ring),
`--la-ease`, and the bar heights `--la-appbar-h` and `--la-actionbar-h`.

**Build from the tokens, never from literals.** No raw hex, no raw pixel gap,
no second font stack. If a token is missing, add the token. A window built
from them can be retuned by editing `:root`, and the dark theme only works on
what goes through a token.

An app's own tokens are `--app-*`, defined in its sheet. Defining a token is
the one place a literal belongs.

### Color roles

Four button roles, stated rather than implied:

- **Orange** (`.la-btn--primary`): the thing the window is for. Connect, Save,
  the confirming button in a dialog. One per region.
- **Blue** (`.la-btn--secondary`): the working controls used over and over.
- **Ghost** (`.la-btn--ghost`): reversible or dismissive. Cancel, Close,
  Disconnect.
- **Danger** (`.la-btn--danger`): destructive or lossy. "Disconnect anyway"
  with unsaved changes.

Green and red are status only (`--la-ok`, `--la-bad`), never an action, and
never alone: a word or an icon goes with the color.

## 3. The app shell

Every Lofted Aero window is the same three-part frame:

```html
<div class="la-app">
  <header class="la-appbar">
    <img
      class="la-appbar__logo la-appbar__logo--badge"
      src="LoftedAeroIcon.png"
      alt="Lofted Aero"
    />
    <span class="la-appbar__title">App Name</span>
    <span class="la-appbar__spacer"></span>
    <div class="la-readout la-readout--wide" data-placeholder="Not connected"></div>
    <select class="la-select"></select>
    <button class="la-btn la-btn--primary">Connect</button>
    <button class="la-btn la-btn--ghost">Disconnect</button>
  </header>

  <main class="la-main">… cards …</main>

  <footer class="la-actionbar">
    <button class="la-btn la-btn--primary la-btn--lg">Save Settings</button>
    <span class="la-actionbar__spacer"></span>
    <button class="la-link-btn"></button>
  </footer>
</div>
```

- `.la-app` is a three-row grid at the window's height. **Only `.la-main`
  scrolls**, so the connection controls and the save button never move.
- The bar is charcoal so the orange reads as an action against it. Controls on
  it get a light-on-dark variant automatically (`.la-appbar .la-select`,
  `.la-appbar .la-btn--ghost`, `.la-appbar .la-readout`).
- `.la-appbar__logo--badge` uses the round icon. The wide `LoftedAeroLogo.png`
  is the stacked lockup and is unreadable at bar height; use
  `.la-appbar__logo` (which puts it on a white chip) only if the bar is tall.
- The bar degrades on a narrow window: the readout gives up its width first,
  then the app name goes below 860px. Nothing is clipped.

## 4. Components

### Card

The unit of grouping.

```html
<section class="la-card">
  <h2 class="la-card__title">General Settings</h2>
  <p class="la-card__subtitle">Advanced</p>
  <!-- optional second group -->
  <div class="la-field">…</div>
  <p class="la-card__note">Measured at boot</p>
  <!-- optional footnote -->
</section>
```

`.la-card__title` carries the orange underline, the same divider `##` headings
get on the documentation site.

### Field

One labeled control: label left, control right, so a card's values line up in
a column.

```html
<div class="la-field">
  <label class="la-field__label" for="alim"
    >Angle Limit <span class="la-field__unit">deg</span></label
  >
  <input class="la-input la-input--num" type="number" id="alim" min="0" max="105" step="1" />
</div>
```

`.la-field--stacked` puts the label above, for a wide control.

**The unit goes in `.la-field__unit`, not in the label text,** so "Angle Limit
deg" reads as a label and its unit rather than one phrase.

### Controls

| Class                 | Notes                                                                                           |
| --------------------- | ----------------------------------------------------------------------------------------------- |
| `.la-input`           | text or number. `.la-input--num` sizes it for a number. Spin buttons appear only on hover.      |
| `.la-select`          | a native `<select>` with the chevron inlined as a data URI: no icon font, no network.           |
| `.la-slider`          | `<input type="range">`. Chromium only, so only the `-webkit-` pseudo-elements are styled.       |
| `.la-slider--readout` | the slider as a meter: a value the device reports and the user cannot drag. Keep it `disabled`. |
| `.la-switch`          | wraps a real checkbox or radio, so it keeps its keyboard behavior and `.checked`.               |
| `.la-radio`           | one option of a small exclusive set, grouped in a `.la-radio-group`.                            |
| `.la-btn`             | `--primary`, `--secondary`, `--ghost`, `--danger`; sizes `--sm`, `--lg`, `--block`.             |
| `.la-link-btn`        | a button that reads as a link.                                                                  |
| `.la-hint`            | a message belonging to the control above it; `--error` for a refusal. Empty, it collapses.      |

**A validation message goes in a `.la-hint` beside the control, not in the
app's status line.** A control inside a modal has the status line behind the
scrim, where a refusal cannot be read at the moment it is needed. The status
line is for what happened to the device; the hint is for what happened to the
field.

**A control that comes and goes gets `.la-invisible`, not `.hidden`.**
`display: none` reflows everything below it, which in a desktop window means
the layout changing height while someone is working in it. `.la-invisible`
keeps the space.

A switch's input stays a sibling before the track:

```html
<label class="la-switch">
  <span class="la-field__unit">Enable</span>
  <input type="checkbox" />
  <span class="la-switch__track"></span>
</label>
```

A radio is the same shape, the input before the mark:

```html
<div class="la-radio-group">
  <label class="la-radio">
    <input type="radio" name="startMode" />
    <span class="la-radio__mark"></span>
    None
  </label>
</div>
```

**An exclusive choice is drawn as radio dots, not switches.** Three switches
in a row read as three things that turn on independently. Use `.la-switch`
only for a single on/off.

### Indicators

```html
<span class="la-led la-led--ok" title="Servo 1: detected">
  <span class="la-led__dot">1</span>
  <span class="la-led__label">Servo 1</span>
</span>
```

States are `--ok`, `--bad` and `--idle`. **Color alone is not a readable
signal**: the dot carries its number and the `title` says the state in words.
Change them together.

`.la-readout` is a value the app writes and the user cannot type in: a status
line, a measured voltage. Empty, it shows its `data-placeholder`.

`.la-log` is a monospace scrolling pane, for a read-only `<textarea>`.

### Modal

```html
<div class="la-modal hidden">
  <div class="la-modal__card">
    <h2 class="la-modal__title">Unsaved changes</h2>
    <p class="la-modal__body"></p>
    <div class="la-modal__actions">
      <button class="la-btn la-btn--ghost">Cancel</button>
      <button class="la-btn la-btn--danger">Disconnect anyway</button>
    </div>
  </div>
</div>
```

- The outer element is the scrim; `.hidden` on it hides the whole thing.
- The card is centered in the scrim, not placed at pixel offsets, which is
  what lets the window resize.
- Actions go bottom right: dismissive on the left, confirming on the right.
- `.la-modal--toast` is the non-blocking variant: no scrim, top left, and the
  window behind stays usable.
- The card is `max-height: 100%` with its own scrolling, so a modal never
  grows past a small window.
- The scrim is `position: fixed`, and an ancestor with a `transform` or
  `filter` becomes its containing block and clips it. Render a modal at the
  top of the document (a portal, in React), and center overlays with margins
  or grid, not `translate`.

## 5. Window size

Windows resize. In an Electron app:

```js
mainWindow = new BrowserWindow({
  width: 1180,
  height: 950,
  minWidth: 760,
  minHeight: 620,
  show: false, // paint before showing: no flash of white
  backgroundColor: '#F1F2F5', // --la-bg
})
mainWindow.once('ready-to-show', () => mainWindow.show())
```

The minimums are where the layout stops working, measured, not guessed. Below
them the OS will not shrink the window; above them `.la-main` scrolls.

Two rules that are easy to get wrong:

- `.la-app` sets `grid-template-columns: minmax(0, 1fr)`. A default `auto`
  column is sized to the widest row's content, so one bar that will not fit
  silently widens the whole app past the window and clips every row.
- Anything with a hard pixel size (a dial, a sprite) sits in a `flex: none`
  box that centers itself, rather than trying to stretch.

## 6. Legacy Chromium

Section 10 of the sheet carries margin fallbacks for Chromium below 84 (no
`gap` in a flex container) and below 86 (no `:focus-visible`), keyed off
`no-flexgap` and `no-focusvisible` classes that a probe in an app's
`index.html` adds to `<html>`. Neither can be feature-detected in CSS:
`@supports (gap: 8px)` is true on a browser whose flex containers ignore it,
because grid has had `gap` since Chromium 66.

Every app is now on Electron 44, so nothing in section 10 applies. It goes in
the next major release, with each app's probe. Until then, a flex container with a `gap` added
to the system still gets its fallback in section 10, in the same change.

## 7. Adding to the system

1. Does an existing component nearly do it? Prefer a modifier
   (`.la-btn--danger`) to a new class.
2. Is it about one app? It goes in that app's sheet, with a comment saying why.
3. Is it general? Add it to the right numbered section of `lofted-aero.css`,
   built from the tokens, with the section comment updated; give it a dark
   value in `lofted-aero-dark.css` if it paints a color the tokens cannot
   reach; release it; then vendor the release into every app.
