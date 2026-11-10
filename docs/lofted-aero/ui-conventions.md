# UI conventions

How screens in a Lofted Aero app are put together: the layer between the
components ([design-system.md](design-system.md)) and the general rules
([ux-rules.md](ux-rules.md)). These hold in every app. Each app keeps its own
`ui-conventions.md` for what applies only to it, with the classes and tokens
that implement it there.

A convention goes here when it would apply in a second app. One that applies to
a single screen stays in a code comment on that screen.

## Space

### Fill the window

Screens are used full-screen. A layout that leaves two thirds of a 1920px
window empty is wrong even if each part of it is well made.

### Cap the column count, never the width

A `max-width` stops the tracks growing and turns the slack into side padding,
on exactly the screens the layout exists to fill. Cap how many columns there
are and let each keep its share of the width. Tile cards with `auto-fill`,
not `auto-fit`, which stretches a lone card, and `align-items: start`.

### Three columns, not four

Four columns of settings make a row nobody reads across.

## Empty and disconnected states

### The navigation offers what can be done now

With nothing connected, a screen that needs a live device leaves the
navigation. A screen whose subject is a document (a file, a plan, a firmware
image) stays. Someone on a screen that disappears is taken to another. A
screen kept for offline use makes clear what it is working on: a file opened
offline never offers to write itself to a device, even after one connects.

### A screen renders itself, never a description of itself

If a screen cannot be used yet, draw it and disable its controls. A card
describing the screen can hide the control that fixes the state. When changing
an empty state, check what it takes away as well as what it says.

### Never draw a value the device did not give

A reading with nothing behind it is a dash, not `0`: `0.0V` means both "no
monitor fitted" and "a dead pack". It carries no status color either; a green
"Disarmed" for an absent aircraft is a claim, not a placeholder. Once a device
is connected, its set of readings is fixed, so the row is one shape on every
device and "none fitted" is itself a reading.

### Color a reading with the device's thresholds, or not at all

A threshold invented in the app presents the app's opinion as the device's.
Color from the device's own configured limits; with none configured, show no
color. A level (a battery's fill, signal bars) needs no threshold, since it
only pictures the number beside it.

### Say it once, where it is already visible

If the empty state is legible from the screen itself, do not add a banner
saying so. Put any prompt where the absence already shows.

## Actions and writes

### A card's actions live on its title row

Buttons go on the title row, right-aligned, and the body holds only settings,
so actions are always in the same place. Settings that belong together sit in
one row, each label above its control. A full-height actions column is
scanned from the top: device actions, then files, then settings.

### A write answers inside the control that made it

"Saved" appears in the control just changed, so there is no doubt which field
it means. The control never changes size while it shows; give it its column's
width rather than its content's.

### A setting that gates other settings writes itself

Other edits stage until Write. A setting that decides whether other settings
exist is written immediately, followed by a re-read in the background,
because until it is written the screen has nothing to show. It never writes
on a keystroke (a dropdown commits on change, a number field on Enter or
blur), and a failed write falls back to a staged edit.

### A restart is not a disconnect

The app asks for the restart and reconnects on its own, returning to the
screen that asked. The placeholder meanwhile says what is happening rather
than asking for a device.

### Red is status, except for destructive actions

Green and red are status colors, never actions. The one exception is a
control whose purpose is destructive: stop all motors, delete, "disconnect
anyway".

### One prompt per thing to fix

A control that carries a setting, with a hint saying what "off" means, is
already the prompt. Do not add an emphasized panel offering the same change.

## Alignment and rhythm

### A control sits beside its label

`.la-field` is `1fr auto`, which in a wide card puts hundreds of pixels
between a label and its value. Pin the label column instead, so the pair
reads as one thing and the controls in a card line up.

### One width for a column of controls

Every dropdown and input in a column is the same width, and the action row
under them matches. Derive both from one token rather than a measured number,
or a reworded label silently breaks the alignment.

### Nothing in a bar absorbs the window's slack

An element that grows in a bar turns spare width into a short string in a very
long box. Give a bar's contents their own size, and make room by dropping
whole items at a breakpoint rather than squeezing them: a clipped reading is a
wrong reading. Set each breakpoint against the longest string a real device
produces.

### A control never moves because a reading changed

Anchor a bar's fixed groups to its edges and let only the live part float
between them. An app bar with the app on the left, status in the middle and
the link on the right is a three-track grid (`1fr auto 1fr`), not a row with
two spacers, which would center the status between unequal groups rather than
on the window. Each reading gets a slot as wide as its longest string, noted
beside the width in the CSS.

### One width for a row of gauges

Repeated readings in a row share one slot width, so their icons land on a
constant pitch. Make the slot fit by cutting what the row does not need:
where an icon already pictures the level, secondary numbers go in the tooltip.

### A filled shape is read by its edge

When an item has a background (a pill, a chip), the eye measures spacing from
its edge, not its text. Measure gaps the same way.

### One dialog with variants keeps one shape

Where a dialog changes its fields by mode, everything around the fields stays
put: same card width, same rows, same box width whatever the box holds.

### A panel is framed one way

A hairline border, the small radius and the surface background together make
a panel. Each app has one class for that frame, and a test listing the
selectors allowed to draw it.

### A screen with a column fills the window; only its panes scroll

The screen takes the window's height and its panes scroll inside their own
frames, so an actions column stays beside what it acts on without sticky
positioning. The column sits in the pane's grid row, so the two start and end
on the same lines.

### A panel inside a panel is one panel

Two surfaces of the same color, one inset in the other, read as one box with a
line through it. A screen either is a card or contains framed panels, never
both.

### Sibling screens share a shape

Screens that do the same job in different modes put the same elements in the
same places, so switching between them moves nothing.

### A card keeps its name and place in every configuration

A card that does one job has the same title and position on every device
variant. Only a card with no counterpart appears or disappears; fit the other
differences inside the card.

### The same card twice is one height

Two instances of one thing sit side by side in one grid row so they share a
height.

### Anything that grows goes last

A list that gains rows goes at the bottom of its column, so nothing under it
moves.

## Where a control lives

### Tools belong on the thing they act on

Drawing tools go on the map as a palette, not in a column as full-width text
buttons. A column is for what persists: device actions, files, settings.

### Judge an icon at the size it is drawn

An icon that reads well at 96px can be illegible at 16px. A legible
unconventional icon beats an illegible conventional one. A control joining an
existing set takes that set's size, shape and styling exactly.

### Replace a text field with the gesture that produces the value

Where a value comes from somewhere else and cannot be checked by reading it,
let the user point at the thing (a place on a map) and show the result as a
readout. A transposed digit in a latitude still parses.

### An action in a dropdown needs its own entry

A select entry that opens something (a file picker) cannot also be the entry
showing the current choice: re-selecting the selected option fires no change,
so the action becomes unreachable once it has succeeded. Reset the control
before the picker opens, since a canceled picker triggers no re-render.

### A file dialog opens where the last one left off

One remembered folder per screen, persisted. Files chosen together usually
live together.

### Prefer a revealed control to a permanent one

A rarely used action that belongs to an object opens from that object rather
than occupying a row of its own.

### Work the screen starts by itself may not prompt

A background probe uses only what it already has (a port already granted) and
gives up otherwise; only an action the user pressed may raise a chooser. Show
that background work is running, or its result appearing a second later looks
like the app changing its mind.

### Order questions so each answer narrows the next

Put first the question whose answer constrains the rest. A choice the earlier
answer rules out is disabled, not hidden. A question the app has answered
outright is not asked, but the answer stays visible as a readout.

## Words

### Use the vocabulary people already have

The established tools' terms beat invented ones, but only where they are
accurate. A label that is wrong half the time teaches people to stop reading
labels.

### No trailing "…" on a control

Not on buttons, menu items, or the option that opens a picker. An ellipsis
meaning "asks for more first" goes stale silently when behavior changes, and
"never" is easier to apply. Progress text (`Writing…`) keeps it, as does
elision inside a value.

### An error names what the user did

Say which thing failed, in the terms the user entered, and what state it is
in: "Nothing is listening at 127.0.0.1:5760", not the exception. Match on the
error code, which is stable, not the message text. Canceling is not failing:
closing a picker never produces an error state.

### Work that is not about one screen is reported on the app bar

A download that affects every screen shows its progress on the bar, outside
the layout flow so it moves nothing. Progress is blue, not green: it is
activity, not a verdict.

### A value that cannot fit its box is shortened, not clipped

A multi-select reads "2 selected"; a long option shows a short name that
keeps what distinguishes it. The full text stays in the hover text.

### Merge rows that never appear together

Two lines that are never both shown are one line.

### Reassurance goes in the confirm dialog

"This is recoverable" and "nothing is erased" go in the dialog for that
action, where they are read, not as standing text on the screen. Standing
warnings are the ones people learn to skip. Domain knowledge that changes the
number someone types stays beside the field.

### Keep hints short

A `.la-hint` says the one thing needed at the moment it is read; the reasoning
goes in a code comment.

## Structure

### Split a screen by sitting, not by length

The test is whether anyone would change something in both halves in one
session. Things set at different times go on different screens; things done
together stay together.

### Draw a two-axis set as a matrix

Roll, pitch and yaw against P, I and D is a grid. As three cards, the one
comparison anyone makes spans three headings.

### Group a long menu with accurate headings

A heading that is wrong for some of its items is worse than none.

### A table is one treatment

Every settings table shares one frame, header band, row rule and row metrics;
a table declares only its columns.

## Small and touch screens

For a window too small for the desktop layout, such as a handheld at
732×412 CSS pixels.

### A screen keeps everything and rearranges it

A compact layout never drops a setting or an action. It moves what does not
fit behind one tap: a side panel, a sheet, an expanding row, a row that
scrolls sideways.

### Navigation lives in the app bar

The content area is too short to give a row to a selector. A button in the
bar names the current screen and opens the list, at one width for every name.

### A column becomes a side panel

Every screen's column opens the same way: one square button with a
side-panel icon at the top right of the pane, and a floating panel hanging
under the row that holds it. That row stays usable: the button closes the
panel again, and a Write beside it stays in reach, with its count. Anything
else in that row over the panel's side steps aside while the panel is open.
Controls in the same row as the button are its height. Something in a closed
panel that needs seeing (a failed write, a transfer) puts a dot on its button.

### What is wide and short rises from below

Over a full-window view (a map, video), content wider than it is tall opens as
a sheet from the bottom, under a handle that rides on its top edge and closes
it again. The view stays in sight above it. Controls sharing the bottom edge
with the handle ride up with it, so they stay in reach. The handle is in the
middle unless something else owns the middle, then at the right; over a view
that is itself read, such as a HUD, it is a caret alone.

### A command that moves the aircraft is slid, not tapped

On a handheld a tap lands by accident. Arming, disarming and anything like
them are confirmed by sliding; the slider takes the buttons' place and
withdraws when its command stops applying. A choice made in a picker is one
tap, because the picker is already a deliberate second step.

### Every control is a finger wide

At least 44px on its short side. Where something must look smaller, its hit
area is still 44px.

### A tap that closes something only closes it

A tap outside a panel closes it and does nothing else; on a map it never also
drops a point.

### A wide table shows what is watched and opens the rest

A row keeps the columns read at a glance, and a chevron opens the ones set
once in a row beneath. Columns are never squeezed until their controls
overlap.

### A finger nudges with arrows

Where a desktop moves a selection with the arrow keys, a touch screen gets a
pad of arrow buttons at touch size, stepping once per tap and repeating while
held. The number boxes stay for an exact value.

### A set of pictures is one scrolling row

Thumbnails side by side, with the last one cut off so the row reads as
scrollable, instead of full-size pictures stacked down the page.
