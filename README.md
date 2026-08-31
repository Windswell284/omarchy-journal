# Monthly Calendar

A bullet journal monthly calendar for the [Omarchy](https://omarchy.org) shell bar.

One ruled line per day, labelled with the date and its weekday initial, with a
heavier rule closing every week — the paper original, typed into rather than
written on. The days run continuously, so the end of one month flows straight
into the next instead of stopping at a page break.

Each month is kept as a plain Markdown note in your Obsidian vault, so the same
log is editable from either side: type in the bar, or open the note and edit it
in Obsidian, and both stay in step.

## Install

```bash
omarchy plugin add https://github.com/Windswell284/omarchy-journal --enable
```

You will be asked which bar section to place it in. To update later:

```bash
omarchy plugin update pyang.journal
```

## Where the notes go

By default, one note per month at:

```
~/Documents/Obsidian/Monthly Calendar/2026-08.md
```

**If your vault is somewhere else, point it there** in
`~/.config/omarchy/shell.json` — find the `pyang.journal` entry in the bar
layout and add `vault` and `folder`:

```json
{ "id": "pyang.journal", "vault": "/home/you/Notes", "folder": "Journal" }
```

`shell.json` hot-reloads on save, so the change applies immediately. The folder
is created on first write if it does not already exist.

## The note format

Every day of the month is written, not just the filled ones, so the note reads
as a log and you never have to guess where a day belongs:

```markdown
# August 2026

- **1 S**
- **2 S** dentist 3pm
- **3 M**
- **4 T** ship v2
```

Parsing is lenient on the way back in: the bold markers and the weekday letter
are both optional, so a line typed by hand in Obsidian as `- 4 ship v2` still
lands on the 4th. Bullets that do not start with a day number are left alone.

## Keys

| Key | Does |
| --- | --- |
| `Left` / `Right`, `h` / `l` | Previous / next month |
| `Up` / `Down`, `j` / `k` | Move a day — carries across month boundaries |
| `Enter` | Start writing on the current day; again moves to the next |
| `Esc` | Stop writing, or close the panel |
| `t` | Jump back to today |
| `[` / `]` | Previous / next month |
| `{` / `}` | Previous / next year |
| `s` | Open or close the facing page |
| `1` `2` `3` `4` | Jump into a facing-page box (opens it first if shut) |
| `Enter` / `Up` / `Down` | Move between lines inside a box |
| `p` | Print the month on screen as a cut-out spread |
| `Tab` | Switch to the neighbouring bar panel |

The wheel scrolls the days continuously. Clicking the month name returns to
today; the chevrons either side of it step a month at a time.

The heading names whichever month is under the middle of the view and follows
along as you scroll; it is shown at full strength for the current month and
slightly dimmed for any other.

## Optional keybinding

To summon it from the keyboard, add this to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + M", "Monthly calendar", "omarchy-shell shell toggle pyang.journal")
```

To summon it straight onto the facing page:

```lua
o.bind("SUPER + SHIFT + M", "Monthly calendar spread", "omarchy-shell pyang.journal spread")
```

`omarchy plugin add` places the widget in the bar but does not create these
bindings, so they have to be added by hand.

## The facing page

A monthly spread is two pages. The right one holds four boxes for the month as
a whole -- Focus and Tasks on the taller top row, Grateful and Notes
beneath. It stays shut until asked for, so the default is exactly the day
log. The boxes follow whichever month the heading names.

They are stored in the same monthly note, under `## ` headings after the days:

```markdown
## Focus

ship v2

## Tasks

- 3 emails to send
```

Note that a bullet like `- 3 emails to send` sits under a heading and is *not*
read back as the 3rd of the month: the note is split at its first `## ` heading
and days are only parsed above it.

IPC methods, for binding to keys: `open`, `close`, `toggle`, `spread`,
`toggleSpread` -- e.g. `omarchy-shell pyang.journal spread`.

## Hacking on it

`Panel.qml` is the whole widget — bar icon, panel, day rows, keys and file I/O.
`Model.js` is the date arithmetic and the Markdown parse/serialize.

One thing that will waste your afternoon otherwise: **run
`omarchy restart shell` after editing the QML.** Saving logs
`Local plugin changed, reloading` but does not rebuild an already-running
widget, so your change appears not to have taken effect.

## Printing

`print-month` renders a month as a spread meant to be cut out and pasted into
a notebook: two 5.25 x 7.25in pages side by side on one 11 x 8.5in landscape
sheet, with hairline cut guides and both pages ruled at the same pitch.

```bash
./print-month                 # this month, into ~/Downloads
./print-month 2026-08         # a given month
./print-month 2026-08 --blank # the ruling only, nothing filled in
./print-month -o spread.pdf   # somewhere else
```

It reads the same note the panel writes and honours the same `vault`/`folder`
override, so a printed month carries whatever is already in it. `--blank` gives
you the template to fill in by hand. Rendering needs `chromium` or
`google-chrome` on PATH. Pressing `p` in the panel prints the month on screen
and notifies you where it landed.

## The bar icon

Drawn, not from a font: no single-cartridge glyph exists in the Nerd Font set.
The outline is traced from a reference photo -- nose profile, cannelure,
case and rim are sampled proportions rather than invented ones.

## Requires

Omarchy 3.x with the Quickshell-based `omarchy-shell`. Draws its bar icon with
`QtQuick.Shapes`.

## License

MIT — see [LICENSE](LICENSE).
