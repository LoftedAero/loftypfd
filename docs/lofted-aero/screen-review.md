# Screen review

Run this against every screen a change touches before it is merged, and
against every screen before a release build. It is the gate between the rules
([ux-rules.md](ux-rules.md), [ui-conventions.md](ui-conventions.md)) and a
screen someone else will use.

Each app keeps its own `screen-review.md` listing its screens and what is
particular to each. This file is what every screen gets.

## How

- In the running app, not from the code.
- At more than one window size: the smallest the app supports and a common
  full-screen size, plus 732×412 if the app has a compact layout.
- In both themes.
- In every state the screen has. At the least, disconnected and connected:
  they behave as two different screens, and the disconnected one is what a new
  user sees first. A screen with no difference between them still gets both
  checks; confirming there is no difference is the check.

## Every screen

Disconnected:

- [ ] The screen renders itself rather than a card describing itself.
- [ ] Placeholders are dashes, not zeros, and carry no status color.
- [ ] Nothing that commands a device is reachable.
- [ ] Any route out of the empty state names a route that exists in that
      build.

Connected:

- [ ] Every field shows real values with the right units.
- [ ] Anything the device does not have is dropped, or shown empty on purpose
      where "configured but reads nothing" is a different fault from "not
      fitted".
- [ ] Actions round-trip: each command is acknowledged, and a refusal says
      why.

Both:

- [ ] The screen fills the window: no column of cards down one side, no side
      padding on a 16:9 display, and sensible at ultrawide sizes.
- [ ] Nothing scrolls at a common full-screen size, except panes meant to.
- [ ] Nothing changes height or moves when a value, state or selection
      changes.
- [ ] One orange action per region. Green and red only as status.
- [ ] Controls in a column share one width; buttons with one role share one
      size.
- [ ] Copy is short. A hint says the one thing needed when it is read. No "…"
      on a control.
- [ ] Dark mode is checked by looking at it. Dropdowns, disabled controls and
      anything on a permanently dark ground are the usual problems.

Compact layout, where the app has one:

- [ ] Every setting and action is still reachable.
- [ ] Every control is at least 44px on its short side.
- [ ] A tap that closes a panel or menu does nothing else.
- [ ] A panel or sheet scrolls when its content is taller than it is.
- [ ] Checked on the device itself when one is available.
