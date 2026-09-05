"""Deciding what a two-way sync should do, without doing any of it.

`plan()` takes the three views of a month -- what the note says now, what the
calendar says now, and what the two agreed on at the end of the last run --
and returns a list of actions. It touches no files and no network, so the
interesting half of the sync can be tested in-process.

The last-agreed state is what makes the direction knowable. Without it a
difference between the note and the calendar is just a difference; with it,
a side that has moved away from the agreed value is the side that changed.
"""

from collections import namedtuple

Ev = namedtuple("Ev", "start end title")            # a journal event, shorthand
Action = namedtuple("Action", "kind day payload")   # payload varies by kind

# kinds: create / update / delete act on the calendar,
#        note acts on the note, conflict is reported and skipped
CALENDAR_KINDS = ("create", "update", "delete")


def _key(e):
    return (e.start, e.end, (e.title or "").casefold())


def _match(journal, state):
    """Pair up last run's events with this run's journal lines, per day.

    Tried in descending confidence: identical, then same time, then same
    title. An event whose time and title both moved is a new one and the old
    one is gone -- guessing further would rename the wrong appointment.
    """
    pairs, used_j = {}, set()
    for tier in ("exact", "time", "title"):
        for si, s in enumerate(state):
            if si in pairs:
                continue
            for ji, j in enumerate(journal):
                if ji in used_j:
                    continue
                sv = Ev(s["start"], s["end"], s["title"])
                if ((tier == "exact" and _key(j) == _key(sv))
                        or (tier == "time" and j.start == s["start"] and j.start is not None)
                        or (tier == "title" and j.title.casefold() == (s["title"] or "").casefold())):
                    pairs[si] = ji
                    used_j.add(ji)
                    break
    return pairs, used_j


def _gcal_changed(g, s):
    return (g is None or g["summary"] != s["summary"]
            or g["start"] != s["start"] or g["end"] != s["end"])


def _journal_changed(j, s):
    return j is None or _key(j) != _key(Ev(s["start"], s["end"], s["title"]))


def plan(days, gcal, state, glossary, prefer="newer", note_mtime=None):
    """Work out the actions for one month.

    days       {day int: [Ev]}       the note as it stands
    gcal       {day int: [event]}    the calendar as it stands
    state      {day int: [entry]}    what the two agreed at the last sync
    prefer     newer | journal | gcal   which side wins a two-sided edit
    """
    actions = []
    for day in sorted(set(days) | set(gcal) | set(state)):
        journal = list(days.get(day, []))
        events = {g["id"]: g for g in gcal.get(day, [])}
        entries = list(state.get(day, []))
        pairs, used_j = _match(journal, entries)
        keep_note = list(journal)                   # rebuilt as we go
        note_dirty = False

        for si, s in enumerate(entries):
            j = journal[pairs[si]] if si in pairs else None
            g = events.pop(s["id"], None)
            jc, gc = _journal_changed(j, s), _gcal_changed(g, s)

            if not jc and not gc:
                continue
            if jc and gc:
                winner = _resolve(prefer, s, g, note_mtime)
                if winner == "conflict":
                    actions.append(Action("conflict", day, {"state": s, "journal": j, "gcal": g}))
                    continue
                jc, gc = winner == "journal", winner == "gcal"

            if jc:                                   # the note moved: push it
                if j is None:
                    actions.append(Action("delete", day, {"id": s["id"], "was": s}))
                else:
                    actions.append(Action("update", day, {"id": s["id"], "ev": j,
                                                          "summary": glossary.expand(j.title)}))
            else:                                    # the calendar moved: pull it
                note_dirty = True
                if g is None:
                    if j is not None:
                        keep_note.remove(j)
                    actions.append(Action("delete", day, {"id": s["id"], "was": s, "gone": True}))
                else:
                    new = Ev(g["start"], g["end"], glossary.contract(g["summary"]))
                    if j is not None:
                        keep_note[keep_note.index(j)] = new
                    else:
                        keep_note.append(new)
                    # Carries the calendar's own summary and timestamp, so the
                    # next run compares against what was actually pulled. Left
                    # to be inferred from the note action, a pulled edit looks
                    # unapplied forever and the note is rewritten every sync.
                    actions.append(Action("pull", day, {"id": s["id"], "ev": new, "gcal": g}))

        for ji, j in enumerate(journal):             # in the note, never synced
            if ji not in used_j:
                actions.append(Action("create", day, {"ev": j, "summary": glossary.expand(j.title)}))

        for g in events.values():                    # on the calendar, not the note
            note_dirty = True
            keep_note.append(Ev(g["start"], g["end"], glossary.contract(g["summary"])))
            actions.append(Action("adopt", day, {"id": g["id"], "gcal": g}))

        if note_dirty:
            keep_note.sort(key=lambda e: (e.start is not None, e.start or 0))
            actions.append(Action("note", day, {"events": keep_note}))

    return actions


def _resolve(prefer, s, g, note_mtime):
    """Pick a side when both edited the same event since the last sync."""
    if prefer in ("journal", "gcal"):
        return prefer
    if g is None or note_mtime is None or not g.get("updated"):
        return "conflict"
    return "journal" if note_mtime > g["updated"] else "gcal"
