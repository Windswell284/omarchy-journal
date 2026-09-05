"""Reading and writing the monthly note, and the shorthand glossary.

Pure functions over strings: no calendar, no network, no files. `journal-sync`
supplies the I/O. Kept separate so the half of the sync that is easy to get
subtly wrong can be exercised on its own.

The note format is `print-month`'s, and the day-line regex is deliberately the
same one: a line is a day if it starts with a number, the weekday letter and
the bold markers are optional, and anything below the first `## ` heading is
not a day at all.
"""

import re, unicodedata

DAY_LETTERS = ["S", "M", "T", "W", "T", "F", "S"]          # Sunday-indexed

LINE_RE = re.compile(r"^\s*[-*]\s*(?:\*\*)?\s*(\d{1,2})\s*[A-Za-z]?\s*(?:\*\*)?\s*(.*?)\s*$")
SECTION_RE = re.compile(r"^##\s+(.+?)\s*$")

# A clock time, 12- or 24-hour. The am/pm is optional here because it may sit
# on the far side of a range ("1-2 pm" gives its meridiem only once, at the
# end) -- resolve_meridiem puts it back.
_T = r"(\d{1,2})(?::(\d{2}))?\s*(?:([ap])\.?\s*m\.?)?"
TIME_RE = re.compile(_T, re.I)
# A time, or a range of them, anchored at either end of the segment. The
# trailing form needs a break before it so that "test21" and "Marathon 26" keep
# their numbers instead of being read as a clock.
LEAD_RE = re.compile(r"^\s*" + _T + r"\s*(?:[-‒-―]\s*" + _T + r")?\s*", re.I)
TAIL_RE = re.compile(r"(?<!\w)" + _T + r"\s*(?:[-‒-―]\s*" + _T + r")?\s*$", re.I)
DEFAULT_MINUTES = 60
# An entry with no time of its own is a block, not an appointment: shorter, so
# several in a row still fit inside an evening.
INFERRED_MINUTES = 30


# --- times ------------------------------------------------------------------

def _mins(h, m, ap):
    """Minutes past midnight, or None if the hour is not a real one."""
    h, m = int(h), int(m or 0)
    if ap:
        if not 1 <= h <= 12 or m > 59:
            return None
        h = h % 12 + (12 if ap.lower() == "p" else 0)
    elif h > 23 or m > 59:
        return None
    return h * 60 + m


def _resolve_meridiem(start, end, groups):
    """Carry a single trailing am/pm back over a range that omits it.

    "1-2 pm" means 1pm to 2pm, not 1am to 2pm. A bare start with a marked end
    borrows the end's meridiem; if that puts the start after the end ("11-1 pm")
    the start is the other half of the clock.
    """
    sh, sm, sap, eh, em, eap = groups
    if end is None or sap or not eap:
        return start, end
    start2 = _mins(sh, sm, eap)
    if start2 is None:
        return start, end
    if start2 > end and int(sh) != 12:
        other = "a" if eap.lower() == "p" else "p"
        alt = _mins(sh, sm, other)
        if alt is not None and alt <= end:
            return alt, end
    return start2, end


def _match_time(m):
    """(start, end) in minutes past midnight from a LEAD_RE/TAIL_RE match.

    A bare run of digits is not a time. Something has to say so -- a colon or
    an am/pm, anywhere in the expression -- or "Level 3" becomes an event at
    three in the morning. One marker covers a whole range, so "1-2 pm" passes
    on the strength of its single trailing "pm".
    """
    g = m.groups()
    if not (g[1] or g[2] or g[4] or g[5]):
        return None, None
    start, end = _mins(g[0], g[1], g[2]), None
    if g[3] is not None:
        end = _mins(g[3], g[4], g[5])
        if end is None:
            return None, None
    if start is None:
        return None, None
    return _resolve_meridiem(start, end, g)


def split_time(text):
    """Peel a leading or trailing time off a segment.

    Returns (start, end, rest). Both times are minutes past midnight, or None
    for an all-day entry. A time is only taken when something is left over: a
    day whose whole text is "3 pm" is a note about three o'clock, not an event
    with an empty title.
    """
    for rx, cut in ((LEAD_RE, lambda m: text[m.end():]),
                    (TAIL_RE, lambda m: text[:m.start()])):
        m = rx.match(text) if rx is LEAD_RE else rx.search(text)
        if not m or not m.group(0).strip():
            continue
        start, end = _match_time(m)
        if start is None:
            continue
        rest = cut(m).strip(" ,;-–—")
        if rest:
            return start, end, rest
    return None, None, text.strip()


def fmt_time(mins):
    """Minutes past midnight as the shorthand writes it: "1 pm", "2:15 pm"."""
    h, m = divmod(mins, 60)
    ap = "am" if h < 12 else "pm"
    h12 = h % 12 or 12
    return f"{h12}:{m:02d} {ap}" if m else f"{h12} {ap}"


# --- day lines --------------------------------------------------------------

def _follows(event):
    """When an entry with no time of its own starts: as the one before ended.

    None where there is nothing to follow -- the entry before was itself
    all-day, or its own block would not fit inside the day.
    """
    start, end = event[0], event[1]
    if start is None:
        return None
    after = end if end is not None else start + DEFAULT_MINUTES
    return after if after + INFERRED_MINUTES <= 24 * 60 else None


def split_events(text):
    """One day's text as a list of (start, end, title) shorthand events.

    Every comma separates. An entry carrying no time of its own is all-day
    when it opens the line, and otherwise starts where the entry before it
    finished, so "5:30 pm dinner, Salvation" puts Salvation at 6:30. A
    timeless entry with no timed entry before it stays all-day: there is
    nothing for it to follow.

    The inferred time is not written back into the note -- the entry stays
    timeless there and is placed again on every read, so putting something
    new in front of it moves it along rather than leaving it stranded at an
    hour it never asked for.

    The cost is that a title can no longer hold a comma -- "dinner with Bob,
    Sue" is two entries now. safe_title() is the other half of that.
    """
    text = text.strip()
    if not text:
        return []
    out = []
    for p in text.split(","):
        p = p.strip()
        if not p:
            continue
        start, end, title = split_time(p)
        if end is not None and start is not None and end - start == DEFAULT_MINUTES:
            end = None          # "1-2 pm" and "1 pm" are the same hour; saying
                                # so here keeps the note and the calendar from
                                # disagreeing about an event neither changed
        if not title:
            continue
        inferred = False
        if start is None and out:
            start = _follows(out[-1])
            if start is not None:
                end = start + INFERRED_MINUTES
                inferred = True
        out.append((start, end, title, inferred))
    return out


def safe_title(title):
    """Keep a title from splitting itself in two when it is read back.

    Titles arrive from the calendar, where a comma is ordinary prose
    ("Dinner, 7 pm at the club"). Written to the note unaltered it would parse
    as two entries on the next sync, and the real event would be deleted to
    make room for them. A semicolon reads the same and separates nothing.
    """
    return title.replace(",", ";")


def join_events(events):
    """Render events back as one day's text -- the inverse of split_events.

    An entry whose time was inferred is written without one, so the next read
    places it again from wherever it now sits in the line.
    """
    bits = []
    for ev in events:
        start, end, title = ev[0], ev[1], ev[2]
        title = safe_title(title)
        if start is None or (len(ev) > 3 and ev[3]):
            bits.append(title)
        elif end is None:
            bits.append(f"{fmt_time(start)} {title}")
        else:
            bits.append(f"{fmt_time(start)}-{fmt_time(end)} {title}")
    return ", ".join(bits)


# --- the note ---------------------------------------------------------------

def parse_note(text):
    """Split a monthly note into {day: text} and {section: [lines]}.

    Days are read only above the first `## ` heading, so a bullet like
    "- 3 emails to send" under Tasks is not mistaken for the 3rd.
    """
    days, sections, current = {}, {}, None
    for line in text.splitlines():
        sm = SECTION_RE.match(line)
        if sm:
            current = sm.group(1)
            sections.setdefault(current, [])
            continue
        if current is not None:
            if line.strip():
                sections[current].append(re.sub(r"^\s*[-*+•]\s+", "", line).strip())
            continue
        m = LINE_RE.match(line)
        if m:
            days[int(m.group(1))] = m.group(2).strip()
    return days, sections


def replace_day(text, day, new_text):
    """Rewrite one day's line in place, leaving every other byte alone.

    Editing the note rather than regenerating it means a hand-made heading, a
    stray blank line or an unrecognised section survives a sync untouched.
    """
    out, done = [], False
    section_seen = False
    for line in text.splitlines(keepends=True):
        if not section_seen and SECTION_RE.match(line):
            section_seen = True
        if not section_seen and not done:
            m = LINE_RE.match(line)
            if m and int(m.group(1)) == day:
                nl = line[len(line.rstrip("\r\n")):]
                letter = re.search(r"\d{1,2}\s*([A-Za-z])", line)
                lab = f"{day} {letter.group(1)}" if letter else str(day)
                body = f" {new_text}" if new_text else ""
                out.append(f"- **{lab}**{body}{nl or chr(10)}")
                done = True
                continue
        out.append(line)
    return "".join(out), done


# --- the glossary -----------------------------------------------------------

def _fold(s):
    """Casefold and strip accents, for matching only."""
    s = unicodedata.normalize("NFKD", s)
    return "".join(c for c in s if not unicodedata.combining(c)).casefold()


class Glossary:
    """The bidirectional shorthand table.

    `phrases` match a whole title; `terms` match a word inside one. Expansion
    runs out to the calendar and contraction back in, off the same entries, so
    a title edited on the phone comes home in the shorthand it left as.
    """

    def __init__(self, phrases=None, terms=None, known=None):
        self.phrases = dict(phrases or {})
        self.terms = dict(terms or {})
        # Words that are already the way they should read. They expand to
        # themselves, so recording them as terms would be noise -- but they
        # still have to be remembered, or every scan asks about them again.
        self.known = set(known or ())

    @classmethod
    def load(cls, data):
        return cls(data.get("phrases"), data.get("terms"), data.get("known"))

    def dump(self):
        return {"phrases": self.phrases, "terms": self.terms,
                "known": sorted(self.known)}

    def _sorted(self, mapping, reverse):
        """Entries longest-key-first, so the specific wins over the general."""
        pairs = [(v, k) for k, v in mapping.items()] if reverse else list(mapping.items())
        return sorted(pairs, key=lambda kv: -len(kv[0]))

    def expand(self, text):
        """Shorthand out to a full calendar title.

        With no entries this is the identity, which is the default and the
        point: a title is passed through exactly as typed. Only the time is
        translated. Entries exist for anyone who wants them and change nothing
        until they are added.
        """
        for k, v in self._sorted(self.phrases, False):
            if _fold(k) == _fold(text):
                return v
        return self._sub(text, self._sorted(self.terms, False))

    def contract(self, text):
        """A calendar title back down to shorthand."""
        for k, v in self._sorted(self.phrases, True):
            if _fold(k) == _fold(text):
                return v
        return self._sub(text, self._sorted(self.terms, True))

    @staticmethod
    def _sub(text, pairs):
        """Replace whole words only, and never inside an earlier replacement."""
        spans = []                      # (start, end) already written into
        for src, dst in pairs:
            if not src:
                continue
            for m in re.finditer(rf"(?<!\w){re.escape(src)}(?!\w)", text, re.I):
                if any(s < m.end() and m.start() < e for s, e in spans):
                    continue
                spans.append((m.start(), m.end()))
                text = text[:m.start()] + dst + text[m.end():]
                shift = len(dst) - (m.end() - m.start())
                spans = [(s + shift, e + shift) if s > m.start() else (s, e)
                         for s, e in spans]
                break                   # one hit per entry per pass
        return text

    def unknown_terms(self, text):
        """Words that no entry covers -- what `suggest` offers to define."""
        known = ({_fold(k) for k in self.terms} | {_fold(v) for v in self.terms.values()}
                 | {_fold(k) for k in self.known})
        out = []
        for w in re.findall(r"[A-Za-z][\w'&.]*", text):
            if _fold(w) not in known and w.lower() not in _STOPWORDS:
                out.append(w)
        return out


def _capitalize(s):
    """Sentence case, without flattening a word the glossary already cased."""
    return s[:1].upper() + s[1:] if s and s[:1].islower() else s


_STOPWORDS = {
    "a", "an", "and", "at", "for", "from", "in", "of", "on", "the", "to", "with",
    "am", "pm", "w", "re",
}
