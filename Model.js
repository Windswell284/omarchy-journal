.pragma library

// Date math and Markdown (de)serialization for the monthly calendar.
//
// The log scrolls as one continuous run of days, so days are addressed
// globally by date key ("2026-08-30") and only grouped back into months at
// the point where they are written to disk. One Obsidian note per month:
//
//   # August 2026
//
//   - **1 S** dentist 3pm
//   - **2 S**
//   - **3 M** ship v2
//
// Every day of the month is written, not just the filled ones, so the note is
// editable by hand without having to guess where a day belongs.

var MONTHS = ["January", "February", "March", "April", "May", "June",
              "July", "August", "September", "October", "November", "December"]

// Sunday-indexed, matching Date.getDay(). The bullet journal convention is a
// single letter per day and lives with T/T and S/S colliding -- the number
// beside it already disambiguates.
var DAY_LETTERS = ["S", "M", "T", "W", "T", "F", "S"]

// The facing page. Ids are internal; titles are what land in the note as "## "
// headings and what the panel labels each box with.
// `was` lists headings a section used to be written under. A note carrying an
// old heading is read into the same section and rewritten under the new one, so
// renaming a box migrates its contents instead of dropping them.
var SECTIONS = [
  { id: "focus",    title: "Focus",         was: ["Goals / Focus"] },
  { id: "tasks",    title: "Tasks",         was: [] },
  { id: "grateful", title: "Grateful",      was: [] },
  { id: "notes",    title: "Notes",         was: ["Next Month"] }
]

var SECTION_RE = /^##\s+(.+?)\s*$/

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

function daysInMonth(year, month) {
  // Day 0 of the next month is the last day of this one.
  return new Date(year, month + 1, 0).getDate()
}

function monthTitle(year, month) {
  return MONTHS[month] + " " + year
}

// File stem, e.g. 2026-08. Doubles as the key a month is tracked by, and
// sorts chronologically in Obsidian's file list.
function monthKey(year, month) {
  return year + "-" + pad2(month + 1)
}

function dateKey(year, month, day) {
  return monthKey(year, month) + "-" + pad2(day)
}

function yearOf(key) { return parseInt(key.substring(0, 4), 10) }
function monthOf(key) { return parseInt(key.substring(5, 7), 10) - 1 }

function stepMonth(year, month, delta) {
  var d = new Date(year, month + delta, 1)
  return { year: d.getFullYear(), month: d.getMonth() }
}

// One flat run of days spanning `before` months back to `after` months on from
// the given month. `weekEnd` marks the row that gets the heavy rule -- Saturday
// closes the week, so the thick line sits under it. Months are not marked off
// in any way: the run reads as one unbroken ruled page, and the date resetting
// to 1 is the only boundary there is.
function buildDays(year, month, before, after, today) {
  var days = []
  var start = stepMonth(year, month, -before)
  var count = before + after + 1
  var todayKey = today ? dateKey(today.getFullYear(), today.getMonth(), today.getDate()) : ""

  for (var i = 0; i < count; i++) {
    var at = stepMonth(start.year, start.month, i)
    var total = daysInMonth(at.year, at.month)
    var key = monthKey(at.year, at.month)
    for (var day = 1; day <= total; day++) {
      var dow = new Date(at.year, at.month, day).getDay()
      var dk = dateKey(at.year, at.month, day)
      days.push({
        year: at.year,
        month: at.month,
        day: day,
        monthKey: key,
        dateKey: dk,
        letter: DAY_LETTERS[dow],
        weekEnd: dow === 6,
        isToday: dk === todayKey
      })
    }
  }
  return days
}

// Index of a given date within a run from buildDays, or -1. The run is
// contiguous, so this is a scan only over the month rather than the whole
// range once the first day of the month is found.
function indexOfDate(days, year, month, day) {
  var wanted = dateKey(year, month, day)
  for (var i = 0; i < days.length; i++) {
    if (days[i].dateKey === wanted) return i
  }
  return -1
}

function indexOfMonth(days, year, month) {
  var wanted = monthKey(year, month)
  for (var i = 0; i < days.length; i++) {
    if (days[i].monthKey === wanted) return i
  }
  return -1
}

function serializeMonth(year, month, entries, sections) {
  var lines = ["# " + monthTitle(year, month), ""]
  var total = daysInMonth(year, month)
  for (var day = 1; day <= total; day++) {
    var dow = new Date(year, month, day).getDay()
    var value = entries[dateKey(year, month, day)]
    var body = value === undefined || value === null ? "" : String(value)
    lines.push("- **" + day + " " + DAY_LETTERS[dow] + "**" + (body ? " " + body : ""))
  }
  // Every heading is written whether or not it has anything under it, for the
  // same reason every day is: the note is a form to fill in, and a missing
  // heading is a worse thing to hand someone than an empty one.
  for (var i = 0; i < SECTIONS.length; i++) {
    var text = sections && sections[SECTIONS[i].id] ? String(sections[SECTIONS[i].id]) : ""
    lines.push("")
    lines.push("## " + SECTIONS[i].title)
    lines.push("")
    if (text) {
      var body = text.split("\n")
      for (var k = 0; k < body.length; k++) {
        lines.push(body[k] === "" ? "" : "- " + stripBullet(body[k]))
      }
    }
  }
  return lines.join("\n") + "\n"
}

// Lenient on the way in: the bold markers and the weekday letter are both
// optional, so a line hand-typed in Obsidian as "- 4 ship v2" still lands on
// the right day. Bullets that don't start with a day number (a stray note, a
// nested list) are left alone rather than being forced onto a day.
var LINE_RE = /^\s*[-*]\s*(?:\*\*)?\s*(\d{1,2})\s*[A-Za-z]?\s*(?:\*\*)?\s*(.*?)\s*$/

// A note is the day log first, then the facing-page sections under "## "
// headings. Splitting on the first heading matters more than it looks: the day
// regex below happily reads "- 3 emails to send" under Tasks as the 3rd, so
// section prose has to be cut away before days are parsed at all.
function splitNote(text) {
  var lines = String(text || "").split("\n")
  var days = []
  var sections = []
  var inSections = false
  for (var i = 0; i < lines.length; i++) {
    if (!inSections && SECTION_RE.test(lines[i])) inSections = true
    if (inSections) sections.push(lines[i])
    else days.push(lines[i])
  }
  return { days: days.join("\n"), sections: sections.join("\n") }
}

// Tolerant of spacing and slashes, so "## Goals/Focus" typed by hand in
// Obsidian still matches the "Goals / Focus" we write.
function normalizeTitle(title) {
  return String(title).toLowerCase().replace(/[\s\/]+/g, "")
}

function sectionIdForTitle(title) {
  var want = normalizeTitle(title)
  for (var i = 0; i < SECTIONS.length; i++) {
    var section = SECTIONS[i]
    if (normalizeTitle(section.title) === want) return section.id
    for (var j = 0; j < section.was.length; j++) {
      if (normalizeTitle(section.was[j]) === want) return section.id
    }
  }
  return ""
}

// Section lines are stored as Markdown list items so Obsidian renders them as
// a list, but the marker is punctuation rather than content: it is stripped on
// the way in and put back on the way out, so nothing upstream ever sees it.
var BULLET_RE = /^\s*[-*+\u2022]\s+/

function stripBullet(line) {
  return String(line).replace(BULLET_RE, "")
}

function parseSections(text) {
  var out = {}
  if (!text) return out
  var lines = String(text).split("\n")
  var current = ""
  var buffer = []
  for (var i = 0; i < lines.length; i++) {
    var heading = SECTION_RE.exec(lines[i])
    if (heading) {
      if (current) out[current] = trimBlank(buffer)
      buffer = []
      current = sectionIdForTitle(heading[1])
    } else if (current) {
      buffer.push(stripBullet(lines[i]))
    }
  }
  if (current) out[current] = trimBlank(buffer)
  return out
}

// Drop the blank lines a heading is padded with, keep any inside the body.
function trimBlank(lines) {
  var start = 0
  var end = lines.length
  while (start < end && lines[start].replace(/\s/g, "") === "") start++
  while (end > start && lines[end - 1].replace(/\s/g, "") === "") end--
  return lines.slice(start, end).join("\n")
}

function parseNote(text) {
  var split = splitNote(text)
  return { days: parseMonth(split.days), sections: parseSections(split.sections) }
}

function parseMonth(text) {
  var byDay = {}
  if (!text) return byDay
  var lines = String(text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.charAt(0) === "#") continue
    var match = LINE_RE.exec(line)
    if (!match) continue
    var day = parseInt(match[1], 10)
    if (!(day >= 1 && day <= 31)) continue
    byDay[day] = match[2] || ""
  }
  return byDay
}

// Replace every day of one month in the flat store. Days absent from the note
// are cleared rather than left behind, so deleting a line in Obsidian deletes
// it here too.
function applyMonth(entries, key, byDay) {
  var year = yearOf(key)
  var month = monthOf(key)
  var total = daysInMonth(year, month)
  for (var day = 1; day <= total; day++) {
    var value = byDay[day]
    entries[dateKey(year, month, day)] = value === undefined ? "" : value
  }
}

function monthHasContent(year, month, entries, sections) {
  var total = daysInMonth(year, month)
  for (var day = 1; day <= total; day++) {
    var value = entries[dateKey(year, month, day)]
    if (value && String(value).length > 0) return true
  }
  for (var i = 0; i < SECTIONS.length; i++) {
    var text = sections ? sections[SECTIONS[i].id] : ""
    if (text && String(text).length > 0) return true
  }
  return false
}
