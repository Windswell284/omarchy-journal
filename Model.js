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

function serializeMonth(year, month, entries) {
  var lines = ["# " + monthTitle(year, month), ""]
  var total = daysInMonth(year, month)
  for (var day = 1; day <= total; day++) {
    var dow = new Date(year, month, day).getDay()
    var value = entries[dateKey(year, month, day)]
    var body = value === undefined || value === null ? "" : String(value)
    lines.push("- **" + day + " " + DAY_LETTERS[dow] + "**" + (body ? " " + body : ""))
  }
  return lines.join("\n") + "\n"
}

// Lenient on the way in: the bold markers and the weekday letter are both
// optional, so a line hand-typed in Obsidian as "- 4 ship v2" still lands on
// the right day. Bullets that don't start with a day number (a stray note, a
// nested list) are left alone rather than being forced onto a day.
var LINE_RE = /^\s*[-*]\s*(?:\*\*)?\s*(\d{1,2})\s*[A-Za-z]?\s*(?:\*\*)?\s*(.*?)\s*$/

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

function monthHasContent(year, month, entries) {
  var total = daysInMonth(year, month)
  for (var day = 1; day <= total; day++) {
    var value = entries[dateKey(year, month, day)]
    if (value && String(value).length > 0) return true
  }
  return false
}
