# UX rules

The design system ([design-system.md](design-system.md)) defines what a
button, a card and a color are. These rules cover how a screen behaves and
reads. They hold in any app; an app's own ui-conventions.md says how its
screens apply them, and [ui-conventions.md](ui-conventions.md) holds the
conventions every Lofted Aero app shares.

Build the screen, then run the checklist below against it in the running app,
at more than one window size, and in every configuration the screen has. The
sections after the checklist give the reason for each item.

## Checklist

Words

- [ ] No sentence on the screen explains what a control does, how the app
      works, or what will happen next. Labels only.
- [ ] Every remaining hint says why something is disabled or refused, and is
      one short line.
- [ ] No "…" on any button, menu item or option. Progress text keeps it.
- [ ] Every label is unambiguous in context and uses the vocabulary of the
      tools users already know.
- [ ] No value is clipped in its box: shorten it, or count it ("2 selected").
- [ ] Empty values read "-", not "0", "None yet" or a sentence.

Stability

- [ ] No card, tile, row or dialog changes height when a value, state or
      selection changes. Optional content is drawn disabled, not added.
- [ ] Nothing the user reaches for moves when something else changes.
- [ ] Every step of a wizard puts its picture and buttons in the same place,
      measured rather than eyeballed.
- [ ] Transient confirmations appear in a slot that already exists and clear
      themselves.

Consistency

- [ ] Every control in a column, and every button in its row, is one width.
- [ ] Buttons with the same role are the same size everywhere on the screen.
- [ ] The same card has the same name and place in every configuration.
- [ ] A second instance of something (battery, screen, port) gets the first
      one's whole set of settings, not a subset.
- [ ] Cards side by side are the same height; columns end on the same line.
- [ ] The screen does things the same way as its siblings (actions, writes,
      tables, dialogs, empty states).

Layout

- [ ] The screen fills a full-screen window; nothing hugs one side.
- [ ] Nothing scrolls at common full-screen sizes, in any configuration.
      Measured, not assumed.
- [ ] Only panes scroll; the actions column stays in view.
- [ ] No whitespace that a side-by-side arrangement would remove.

Controls

- [ ] Each card's actions are on its title row. One primary action per
      region.
- [ ] Rarely used settings are behind a dialog, opened by a button labeled
      Configure.
- [ ] Each thing can be done in one place. A screen shows what a dialog
      edits; it does not carry a second copy of the editing.
- [ ] Anything the app can work out, it works out, and it asks only on
      failure.
- [ ] A wizard that succeeds closes itself and leaves a brief confirmation.
- [ ] A control that enables another sits right next to it.
- [ ] On a touch screen every control is at least 44px on its short side, and
      a tap that dismisses something does nothing else.

Process

- [ ] Nothing was built that was not asked for.
- [ ] Every change was checked in the running app, not reasoned about.

## 1. Words

### Controls, not prose

A screen is controls and their labels. What a control is for, what a
procedure involves and why a setting matters go in code comments. If a
control needs a sentence, its label is wrong. Descriptions accumulate one
sentence at a time until people learn to skim the screen.

### Don't explain what the app is about to do

If the app can do something, it does it silently; if it cannot, the question
it asks at that moment explains itself. Ask what the reader does differently
for having read a line right now. If nothing, delete it.

The exceptions are a line saying why a control is disabled or a value was
refused, and a status line narrating a long operation someone is watching,
such as a firmware flash. Advice on how to choose a value belongs in the
comment beside the field.

### Short, plain, and in the user's words

A message says the one thing needed, in a sentence a person would say, using
the wording of familiar tools where it is accurate. Once a mechanism is
settled, cut the text written while working it out; it reads as debug
output.

### Action labels say what happens, and to what

A button names its action and direction: Read from vehicle, Write to vehicle,
Open from file, Save to file. A dialog's buttons are the answers, not a
restatement of the question: Takeoff / Waypoint / Cancel.

For a list kept inside the app, such as saved profiles, Load and Save as
already mean "from the list" and "into it", so moving an item in or out as a
file is Import and Export.

A label is the action, not a readout. A value shown elsewhere does not ride
on the button that acts on it: the button says Next and stays disabled until
it can be pressed.

### No trailing "…"

Not on buttons, menu items, or the option that opens a picker. Progress text
(Writing…, Waiting for telemetry…) keeps it, because there it separates
"happening" from "done".

### Labels are unambiguous

If a word could mean two things in context, it is the wrong word, even when
it is the shortest.

### Use the words people already have

Borrow established tools' terms where they are accurate; a label that is
wrong half the time teaches people to stop reading labels. Use the source
system's exact names where users will look them up, such as ArduPilot's
mission command names. Spell out a unit whose symbol is hard to see
("degrees", not "°").

### Shorten or count, never clip

A multi-select shows "2 selected" (or "none"); a sentence-length option
shows a short name that keeps what distinguishes it. The full text goes in
the hover text.

### Empty is a dash

A missing value is "-". Not 0, which is a reading, and not a sentence.

### Consistent punctuation and case

Similar messages end the same way; decide once whether they carry a period.
Use American English.

## 2. Stability

### A card is one height whatever it holds

Entering a value, changing state or making a selection never changes the
height of a tile, dialog or table. Optional content is drawn disabled rather
than added, a field that does not apply yet is grayed rather than hidden, and
a message appears in a slot that already exists.

### Nothing you reach for moves

Anchor fixed controls to edges and let only live content float between them.
Give each changing reading a slot as wide as its longest value.

### The steps of a flow share one layout

Moving between wizard steps changes the words and the picture, never where
they sit. Every step has the same one-line rows in the same places, a warning
replaces a line rather than adding one, and buttons keep a fixed width.
Verify by measuring the picture's position on consecutive steps; the cause of
a shift is often not the element that seems to move it.

### Confirmations are brief and in place

"Saved" or "Stop sent" appears beside what it confirms, in the field or on
the card's title row, and clears after a few seconds. Its slot is a line tall
even while empty, so the confirmation never pushes anything down.

### Anything that grows goes last

A list that gains rows goes at the bottom, so nothing under it moves.

### Sets that change with a selection keep their count

A gallery of options keeps the same number of items when a related setting
changes, and never shows an item inconsistent with the selection.

### Default sizes fit their content

A pane opens at a size that shows its content. An empty pane opens small,
but never smaller than its own text needs, and grows when it gets content.

## 3. Consistency

### One width per column of controls

Every dropdown and input in a column is the same width, and a button beside
them matches. Derive both from one token.

### Same role, same size

Buttons doing the same kind of job on a screen are the same size. A small
button beside regular ones reads as a different kind of thing.

### The same card, the same place, in every configuration

A card that does one job keeps its title and position in every variant of the
screen; only a card with no counterpart appears or disappears. Balance a
layout inside the cards, not by renaming or reshuffling them.

### Matched heights

Cards in a row are one height. Stacked columns end on the same line, with the
last card taking the slack. Two instances of the same card are the same size.

### A second instance gets the whole set

When a thing comes in instances (a second battery, a fourth OSD screen,
another serial port), each gets the same settings in the same cards, with a
switch to choose which is showing. A subset for the extras hides settings
that exist.

### Sibling screens share a shape

When a pattern exists on one screen (a write control, table, empty state,
dialog or column), other screens do it the same way. When changing one
instance, find the others.

### Alignment is exact

Headers sit centered over their columns. Inputs in a row share a baseline
even when some have sub-labels. Controls line up with the labels above them,
and a row of buttons starts at the same edge as the fields above it. Tabs in
a strip are evenly distributed.

### One set of text styles

The same role gets the same size, weight and color everywhere. A sub-label
(identifier, unit) has one consistent quieter style.

### Icons match their set

A new icon in an existing set takes the set's size, shape and style exactly.
Judge an icon at the size it is drawn.

## 4. Layout

### Fill the window

Screens are used full-screen, so fill the width with meaningful structure and
never leave content hugging one side. On ultrawide displays cap the number of
columns, not the page width, which only adds side padding on an ordinary
monitor. A frame is still only as wide as its content needs.

### No scrolling

A setup screen fits a full-screen window without scrolling, in every
configuration. Measure at more than one window size. Prefer two columns, use
three when two cannot fit, and balance them against measured heights.

### Full height, and only panes scroll

A screen with a list and an actions column takes the window's height. The
list scrolls inside its frame, and the actions column stays in view as one
continuous tile.

### Tighten

Remove whitespace a better arrangement would absorb: fields side by side,
a graphic beside the controls, actions on the title row. Stop before text
gets squeezed.

### Split a screen by sitting, not by length

Things set at different times belong on different screens even if one screen
could hold both. Things done together stay together.

### Dialogs are compact and uniform

A dialog is as small as its content, with stacked buttons where that saves
width, uniform padding, and matched field widths across its variants.

## 5. Controls and interaction

### Actions on the title row

A card's actions sit right-aligned on its title row; the body holds settings.
One orange (primary) action per region. Red is only for destructive actions.

### Writing changes

Per-card Revert and Write (with a count) appear on the title row when
something is staged, and an actions column always shows its Write. A setting
that is adjusted live, or that gates other settings, writes on change and
confirms inline; a gating one then re-reads what it exposes in the
background. No global Write is shared between screens, and leaving a screen
with unwritten changes asks first.

### Restarts are prompted, and the app comes back

A change that needs a restart raises one prompt with a Later option. The app
reconnects by itself, returns to the same screen, and blocks conflicting
actions until then.

### Rare settings behind a dialog

Settings touched once and rarely again live in a dialog with its own Write,
not in permanent rows. The button that opens it is labeled Configure on every
screen.

### One place for each thing

When a dialog edits something, the screen that opens it shows the result but
does not edit it too. Two routes to one change mean two sets of controls and
doubt about which is current.

### Work it out; ask only when you can't

Detect what can be detected, derive what can be derived, and prompt only when
that fails or is ambiguous. Background work never raises a prompt.

### Point, don't type

Where a value comes from somewhere else (a place, a heading), pick it with a
gesture and show the result as a readout.

### Related controls sit together

A control that enables, selects or scopes another sits beside it. A setting
that applies to the next item created goes on that item list's header.

### Show the value behind a name

Where a named option stands for a number that matters, show both.

### Guard the dangerous, confirm briefly

An action that can cause harm (rebooting a flying vehicle, overwriting a
configuration) is refused or confirmed in a short dialog. Reassurance goes in
that dialog, not in standing text.

### Touch is a finger, and it slips

On a touch screen every target is at least 44px on its short side, even where
the drawing is smaller. A tap that dismisses a panel or menu only dismisses
it; it never also acts on what lay underneath. A command that is hard to undo
is confirmed by a gesture a stray tap cannot make, such as a slide.

### Disabled looks disabled, quietly

A disabled control is grayed out, with no "not allowed" cursor and no hover
effect.

### Make a multi-step flow visible

A process with an order numbers its steps, and one action at the end
completes it.

### A flow ends by itself

A wizard that succeeds closes itself and leaves a brief word where it was
started ("Calibration saved" on the card's title row). A follow-up such as a
restart goes through the app's usual prompt. A failure keeps the dialog open
with a retry of exactly what failed.

## 6. States

### Offer what can be done now

With no device connected, screens that need one leave the navigation, and
screens that work on a document stay. Don't build UI that exists only in the
disconnected state.

### Render, don't describe

A screen that cannot be used yet is drawn with its controls disabled and
placeholders in its readings, never replaced by a card describing it. Put any
one-line prompt where the absence already shows.

### Identical states look identical

The same state ("Waiting for telemetry") has the same text, font and position
everywhere.

## 7. Process

### Don't build what wasn't asked for

Test rigs, demo fixtures and scaffolding cost time. If one seems necessary,
ask first.

### Offer choices for visual decisions

For a layout or visual question, render several options so the choice can be
made by looking.

### Learn from the references

Before designing, read how established tools do it, including their source.
Borrow what is better and note why.

### Verify by running it

Check every change in the running app, at more than one window size, in
every configuration, and on real hardware when available. Measure rather
than estimate.

### Keep the guidelines current

When a review produces a preference that will apply again, add it here.
