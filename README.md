# Monthly Calendar

A bullet journal monthly calendar for the [Omarchy](https://omarchy.org) shell bar.

One ruled line per day, labelled with the date and its weekday initial, with a
heavier rule closing every week — the paper original, typed into rather than
written on. The days run continuously, so the end of one month flows straight
into the next instead of stopping at a page break.

Each month is kept as a plain Markdown note in your Obsidian vault, so the same
log is editable from either side: type in the bar, or open the note and edit it
in Obsidian, and both stay in step.

![The panel, with the facing page open](docs/panel.png)

## Install

```bash
omarchy plugin add https://github.com/Windswell284/omarchy-journal --enable
```

You will be asked which bar section to place it in. That gets you the bar icon
and the panel; **keys are a separate step** -- see [Keybindings](#keybindings).

It installs under the id
`pyang.journal` -- that is the name to use in `shell.json`, in `omarchy plugin`
commands and in IPC calls.

```bash
omarchy plugin update pyang.journal     # pull later changes
omarchy plugin disable pyang.journal    # take it off the bar
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
| `Tab` / `Shift+Tab` | Leave the day log for the facing page's first / last box — whether or not you are writing, opening the page if shut |
| `Esc` | Stop writing, or close the panel |
| `t` | Jump back to today |
| `[` / `]` | Previous / next month |
| `{` / `}` | Previous / next year |
| `s` | Open or close the facing page |
| `1` `2` `3` `4` | Jump into a facing-page box (opens it first if shut) |
| `Enter` / `Up` / `Down` | Move between lines inside a box |
| `Tab` / `Shift+Tab` | Next / previous section — the day log, then Focus, Tasks, Grateful, Notes, wrapping |
| `p` | Print the month on screen as a cut-out spread |

The wheel scrolls the days continuously. Clicking the month name returns to
today; the chevrons either side of it step a month at a time.

The heading names the month you are in: the one under the middle of the view
while you scroll, and the one the cursor is on the moment a key moves it, so
stepping off the 31st onto the 1st turns the heading over with it. It is shown
at full strength for the current month and slightly dimmed for any other.

## Keybindings

**`omarchy plugin add` does not set up keys.** It places the widget in the bar
and stops there: the plugin manifest has no way to declare a binding, and
nothing in the install path touches Hyprland. So after installing, the bar icon
works and every key inside the panel works, but nothing summons it.

To add the bindings:

```bash
cd ~/.config/omarchy/plugins/pyang.journal
./install-bindings          # SUPER+M, and SUPER+CTRL+M for the facing page
./install-bindings --remove  # take them out again
```

It backs `bindings.lua` up first, refuses rather than double-binding if either
key is already spoken for, and reloads Hyprland, failing loudly if the reload
reports a config error. Running it twice is a no-op.

Or add them yourself, to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + M", "Monthly calendar", "omarchy-shell pyang.journal toggle")
o.bind("SUPER + CTRL + M", "Monthly calendar (facing page)", "omarchy-shell pyang.journal spread")
```

## The facing page

A monthly spread is two pages. The right one holds four boxes for the month as
a whole -- Focus and Tasks on the taller top row, Grateful and Notes
beneath. It stays shut until asked for, so the default is exactly the day
log. The boxes follow whichever month the heading names.

They are stored in the same monthly note, under `## ` headings after the days:

```markdown
## Focus

- ship v2

## Tasks

- 3 emails to send
```

Section lines are stored as Markdown list items, so they render as a list in
Obsidian. The marker is punctuation rather than content: it is stripped on the
way in and put back on the way out, so it never doubles up, and a line typed
with its own `-` or `*` is not marked twice.

Note that a bullet like `- 3 emails to send` sits under a heading and is *not*
read back as the 3rd of the month: the note is split at its first `## ` heading
and days are only parsed above it.

IPC methods, for binding to keys: `open`, `close`, `toggle`, `spread`,
`toggleSpread` -- e.g. `omarchy-shell pyang.journal spread`.

## Hacking on it

`Panel.qml` is the whole widget — bar icon, panel, day rows, keys and file I/O.
`Model.js` is the date arithmetic and the Markdown parse/serialize.
`print-month` is standalone: it re-implements the note parsing in Python rather
than sharing `Model.js`, so it can run without the shell.

`Model.js` is plain JavaScript with one QML-only line at the top, so it can be
exercised directly:

```bash
node -e 'const s=require("fs").readFileSync("Model.js","utf8").replace(/^\.pragma library\s*$/m,"");
         const M={}; new Function("x", s+"\nObject.assign(x,{parseNote,serializeMonth})")(M);
         console.log(M.parseNote("# Aug 2026\n\n- **1 S** hi\n"))'
```

One thing that will waste your afternoon otherwise: **run
`omarchy restart shell` after editing the QML.** Saving logs
`Local plugin changed, reloading` but does not rebuild an already-running
widget, so your change appears not to have taken effect.

## Printing

`print-month` renders a month as a spread meant to be cut out and pasted into
a notebook: two 5.25 x 7.75in pages side by side on one 11 x 8.5in landscape
sheet, with hairline cut guides and both pages ruled at the same pitch.

```bash
cd ~/.config/omarchy/plugins/pyang.journal

./print-month                 # this month, into ~/Downloads
./print-month 2026-08         # a given month
./print-month 2026-08 --blank # the ruling only, nothing filled in
./print-month -o spread.pdf   # somewhere else
./print-month --pad .14       # inset the content from the cut line
```

![A blank spread, ready to cut out](docs/print.png)

`--pad` is the one dial worth playing with. At the default of 0 the ruling runs
right to the cut line, which gives the most writing room but leaves nothing for
a crooked cut, and sits at the limit of what most printers will put on the
page. The pitch re-solves around whatever you set, so 31 days always fit
exactly rather than the last few running off.

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

Omarchy 3.x with the Quickshell-based `omarchy-shell`. The bar icon is drawn
with `QtQuick.Shapes`, which ships with Qt 6.

Printing additionally needs `python3` and either `chromium` or `google-chrome`
on `PATH`. Nothing else in the plugin depends on them, so it works fine without
if you never print.

## License

MIT — see [LICENSE](LICENSE).
