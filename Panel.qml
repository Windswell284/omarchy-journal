import QtQml
import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A bullet journal monthly calendar in the bar.
//
// The paper original is a month name over one ruled line per day, each line
// labelled with the date and the initial of its weekday, and a heavier rule
// closing every week. This is that, with the lines typed into rather than
// written on, and each month persisted as a Markdown note in the Obsidian
// vault so the same log is editable from either side.
//
// The days run continuously rather than a month at a time: scrolling off the
// end of August carries straight into September with both on screen at once,
// the way turning a page in a notebook does. The heading names whichever month
// owns the top of the view and changes as you scroll past a boundary; the
// chevrons and arrow keys jump a whole month at a time.
Panel {
  id: root
  moduleName: "pyang.journal"
  ipcTarget: "pyang.journal"
  // Taking the handler over from Ui/Panel: only one may own a target, and the
  // base one has no way to open straight onto the facing page.
  manageIpc: false

  // ---- Where the notes live. Overridable per-entry in shell.json so the
  //      vault can move without touching this file.
  readonly property string home: Quickshell.env("HOME")
  readonly property string vaultDir: setting("vault", home + "/Documents/Obsidian")
  readonly property string folder: setting("folder", "Monthly Calendar")
  readonly property string journalDir: vaultDir + "/" + folder

  // Where this plugin lives, so the print script can be found next to the QML
  // wherever the plugin was installed.
  readonly property string pluginDir: {
    var here = Qt.resolvedUrl(".").toString()
    return here.replace(/^file:\/\//, "").replace(/\/$/, "")
  }

  // ---- Today, kept honest across midnight by SystemClock so the marked row
  //      rolls over without the panel being reopened.
  property date today: new Date()

  // ---- The run of days on offer. Fixed and generous rather than extended as
  //      you scroll: re-anchoring a list mid-scroll means correcting contentY
  //      by the height of whatever was spliced in, and a pixel out shows up as
  //      a jump. Three years either way is far more than the wheel will cover,
  //      and the chevrons jump by months anyway.
  readonly property int monthsEitherSide: 36
  readonly property var days: Model.buildDays(today.getFullYear(), today.getMonth(),
                                              monthsEitherSide, monthsEitherSide, today)

  // ---- The month named in the heading: the one under the middle of the view,
  //      recomputed as the list scrolls.
  //
  //      Sampled at the midpoint rather than the top edge because with the run
  //      unbroken the two straddle a boundary for a whole screen's worth of
  //      scrolling: a view showing two days of August above fifteen of
  //      September is a September screen, and a heading taken from the top row
  //      would still be insisting on August.
  property int focusIndex: 0
  readonly property var focusDay: days.length > 0
    ? days[Math.max(0, Math.min(focusIndex, days.length - 1))]
    : null
  readonly property int headYear: focusDay ? focusDay.year : today.getFullYear()
  readonly property int headMonth: focusDay ? focusDay.month : today.getMonth()
  readonly property string monthLabel: Model.monthTitle(headYear, headMonth)
  readonly property string noteName: Model.monthKey(headYear, headMonth) + ".md"
  readonly property bool viewingCurrentMonth: headYear === today.getFullYear()
    && headMonth === today.getMonth()

  // ---- Entries, flat, keyed by date ("2026-08-30"), grouped back into months
  //      only when written out.
  //
  //      Deliberately not bound into the fields: a binding would fight the
  //      cursor on every keystroke. Fields read this once per `revision` bump
  //      -- a load from disk -- and push edits back through setEntry().
  property var entries: ({})
  property int revision: 0
  property bool loading: false

  // Plain JS maps keyed by month, never bound to, so mutating them in place is
  // safe. `written` remembers what we last wrote, so the reload our own write
  // triggers can be told apart from a real edit made in Obsidian.
  property var dirtyMonths: ({})
  property var existingMonths: ({})
  property var written: ({})

  // Months that have a FileView. Grows as months come into view and is never
  // pruned: a handful of watchers over a session costs nothing, and dropping
  // one would mean racing its pending write.
  property var loadedKeys: []

  // ---- The facing page. A real monthly spread is two pages: the day log on
  //      the left, and boxes for the month's thinking on the right. It stays
  //      shut until asked for, so the default is exactly the log it was.
  property bool spreadOpen: false
  property bool editingSection: false

  // Section prose, keyed "2026-08|goals". Same deal as `entries`: read by the
  // fields once per revision, never bound into them.
  property var sectionText: ({})

  readonly property string headMonthKey: Model.monthKey(headYear, headMonth)

  // Focus and Tasks carry the month's thinking and take the taller row;
  // Grateful and Notes are shorter by nature and sit under them.
  readonly property var sectionLayout: [
    { id: "focus",    title: "Focus",         col: 0, row: 0 },
    { id: "tasks",    title: "Tasks",         col: 1, row: 0 },
    { id: "grateful", title: "Grateful",      col: 0, row: 1 },
    { id: "notes",    title: "Notes",         col: 1, row: 1 }
  ]

  // ---- Cursor. `cursorIndex` indexes `days`; `editing` is whether that row
  //      currently owns the keyboard.
  property int cursorIndex: 0
  property bool editing: false

  // Guarded so the widget renders before the bar injects itself.
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int rowHeight: Style.space(26)
  readonly property int headerHeight: Style.space(42)
  readonly property int footerHeight: Style.space(20)
  readonly property int gutterWidth: Style.space(15)
  readonly property int letterWidth: Style.space(12)
  readonly property int spineGap: Style.space(14)

  // The card pads its own edges, and the heading and footer each centre inside
  // their own band, so both drift toward the middle of the panel: the month
  // sits low under the top edge, the footer high above the bottom one. Biasing
  // each outward by half the card padding centres them in the band the eye
  // actually reads -- edge of the card to the nearest rule.
  //
  // The footer needs slightly less of a push than the heading: the gap between
  // the list and the footer already sits above its text, so half of it is
  // correction the heading needs and the footer does not.
  readonly property int headerBias: Math.round(panel.padding / 2) + Style.space(1)
  readonly property int footerBias: headerBias - Math.round(Style.space(4) / 2)

  readonly property color ruleColor: Util.alpha(fg, 0.16)
  readonly property color weekRuleColor: Util.alpha(fg, 0.45)
  readonly property color mutedColor: Util.alpha(fg, 0.55)

  // Months other than the current one, in the heading. Its own tone rather
  // than the shared muted grey: this only needs to read as "not this month",
  // not as disabled, so it sits much closer to full strength than the footer
  // and chevrons do.
  readonly property color awayMonthColor: Util.alpha(fg, 0.75)

  // Facing-page box titles. Full-strength foreground put them at exactly the
  // weight of the lines underneath, so the eye read them as a first entry
  // rather than a heading. Larger than the entries and held back a little is
  // what separates the two -- uppercase and letterspacing alone did not.
  readonly property color sectionTitleColor: Util.alpha(fg, 0.7)

  // ---------------------------------------------------------------- entries

  function contentFor(dateKey) {
    var value = root.entries[dateKey]
    return value === undefined || value === null ? "" : String(value)
  }

  function sectionSlot(monthKey, id) {
    return monthKey + "|" + id
  }

  function sectionFor(monthKey, id) {
    var value = root.sectionText[sectionSlot(monthKey, id)]
    return value === undefined || value === null ? "" : String(value)
  }

  function setSection(monthKey, id, text) {
    if (root.loading) return
    if (sectionFor(monthKey, id) === text) return
    root.sectionText[sectionSlot(monthKey, id)] = text
    root.dirtyMonths[monthKey] = true
    saveTimer.restart()
  }

  function sectionLines(monthKey, id) {
    var text = sectionFor(monthKey, id)
    return text === "" ? [] : text.split("\n")
  }

  function sectionLineAt(monthKey, id, index) {
    var lines = sectionLines(monthKey, id)
    return index >= 0 && index < lines.length ? lines[index] : ""
  }

  function setSectionLine(monthKey, id, index, text) {
    if (root.loading) return
    var lines = sectionLines(monthKey, id)
    while (lines.length <= index) lines.push("")
    if (lines[index] === text) return
    lines[index] = text
    // Trailing blanks are an artefact of the ruling, not content.
    while (lines.length > 0 && lines[lines.length - 1].replace(/\s/g, "") === "") lines.pop()
    setSection(monthKey, id, lines.join("\n"))
  }

  function sectionsOf(monthKey) {
    var out = ({})
    for (var i = 0; i < Model.SECTIONS.length; i++) {
      var id = Model.SECTIONS[i].id
      out[id] = sectionFor(monthKey, id)
    }
    return out
  }

  function setEntry(dateKey, monthKey, text) {
    if (root.loading) return
    if (contentFor(dateKey) === text) return
    root.entries[dateKey] = text
    root.dirtyMonths[monthKey] = true
    saveTimer.restart()
  }

  // A month's note has arrived, or been confirmed absent -- `text` null means
  // there is no file.
  function ingest(key, text) {
    // Our own write coming back around. Re-parsing it would be harmless but
    // would reset every field in that month mid-sentence.
    if (text !== null && String(text) === String(root.written[key] || " ")) return
    root.loading = true
    var parsed = text === null ? { days: ({}), sections: ({}) } : Model.parseNote(text)
    Model.applyMonth(root.entries, key, parsed.days)
    for (var i = 0; i < Model.SECTIONS.length; i++) {
      var id = Model.SECTIONS[i].id
      var body = parsed.sections[id]
      root.sectionText[sectionSlot(key, id)] = body === undefined ? "" : body
    }
    root.existingMonths[key] = text !== null
    root.loading = false
    root.revision += 1
  }

  // Give a month a FileView the first time it comes into view. Called from the
  // row delegates, so exactly the months you can actually see get loaded.
  function ensureLoaded(key) {
    if (!key || root.loadedKeys.indexOf(key) >= 0) return
    var next = root.loadedKeys.slice()
    next.push(key)
    root.loadedKeys = next
  }

  function flushMonth(key) {
    var index = root.loadedKeys.indexOf(key)
    if (index < 0) return
    var file = monthFiles.objectAt(index)
    if (!file) return
    var year = Model.yearOf(key)
    var month = Model.monthOf(key)
    // Browsing through a month must not litter the vault with empty notes;
    // only write once there is something to write, or a note already exists
    // (so clearing the last entry still saves).
    var sections = sectionsOf(key)
    if (!root.existingMonths[key] && !Model.monthHasContent(year, month, root.entries, sections)) return
    var out = Model.serializeMonth(year, month, root.entries, sections)
    root.written[key] = out
    file.setText(out)
    root.existingMonths[key] = true
  }

  function flush() {
    saveTimer.stop()
    for (var key in root.dirtyMonths) {
      if (root.dirtyMonths[key]) flushMonth(key)
    }
    root.dirtyMonths = ({})
  }

  // ------------------------------------------------------------- navigation

  function goToIndex(index, edit) {
    if (index < 0 || index >= root.days.length) return
    root.cursorIndex = index
    if (edit === true) root.editing = true
    dayList.positionViewAtIndex(index, ListView.Contain)
  }

  // Month steps put the target month's first day at the top of the view, so a
  // chevron reads as "turn to this month" rather than nudging the scroll.
  function goToMonth(year, month) {
    var index = Model.indexOfMonth(root.days, year, month)
    if (index < 0) return
    root.editing = false
    root.cursorIndex = index
    dayList.positionViewAtIndex(index, ListView.Beginning)
  }

  function moveMonth(delta) {
    if (delta === 0) return
    var stepped = Model.stepMonth(root.headYear, root.headMonth, delta)
    goToMonth(stepped.year, stepped.month)
  }

  function goToToday() {
    root.today = new Date()
    var index = Model.indexOfDate(root.days, root.today.getFullYear(),
                                  root.today.getMonth(), root.today.getDate())
    if (index < 0) return
    root.cursorIndex = index
    dayList.positionViewAtIndex(index, ListView.Center)
  }

  function moveCursor(delta, edit) {
    var next = root.cursorIndex + delta
    if (next < 0 || next >= root.days.length) return
    goToIndex(next, edit)
  }

  // Reach the boxes from the keyboard: 1-4 read across the grid the way it
  // looks, opening the facing page first if it is shut.
  function focusSection(index) {
    if (index < 0 || index >= root.sectionLayout.length) return
    root.spreadOpen = true
    Qt.callLater(function() {
      var box = sectionBoxes.itemAt(index)
      if (box && box.focusLine) box.focusLine(0)
    })
  }

  // Summon straight onto the facing page. open() shuts it by default, so the
  // order matters here.
  function openSpread() {
    if (!root.opened) root.open()
    root.spreadOpen = true
  }

  // Render the month on screen as a cut-out spread and say where it went.
  function printMonth() {
    var key = Model.monthKey(root.headYear, root.headMonth)
    printProc.command = ["bash", "-c",
      "out=$(" + JSON.stringify(root.pluginDir + "/print-month") + " " + key + ")"
      + " && notify-send 'Monthly calendar' \"Spread saved to $out\""
      + " || notify-send -u critical 'Monthly calendar' 'Could not render the spread'"]
    printProc.running = true
  }

  function toggleSpread() {
    root.spreadOpen = !root.spreadOpen
    if (!root.spreadOpen) stopSectionEditing()
  }

  function stopSectionEditing() {
    root.editingSection = false
    keyCatcher.forceActiveFocus()
  }

  function stopEditing() {
    root.editing = false
    keyCatcher.forceActiveFocus()
  }

  function updateFocusIndex() {
    var index = dayList.indexAt(dayList.width / 2, dayList.contentY + dayList.height / 2)
    if (index >= 0) root.focusIndex = index
  }

  // -------------------------------------------------------------- lifecycle

  function open() {
    // Shut by default every time: the log is the thing, the facing page is
    // something you go and get.
    root.spreadOpen = false
    root.editingSection = false
    root.controller.show()
    // Deferred so the list has been laid out and has somewhere to scroll to.
    Qt.callLater(function() {
      root.goToToday()
      root.updateFocusIndex()
    })
  }

  function close() {
    root.flush()
    root.editing = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  onOpenedChanged: if (!root.opened) {
    root.flush()
    root.editing = false
    root.editingSection = false
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onDestruction: root.flush()

  IpcHandler {
    target: "pyang.journal"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function spread(): void { root.openSpread() }
    function toggleSpread(): void { root.toggleSpread() }
  }

  Timer {
    id: saveTimer
    interval: 600
    onTriggered: root.flush()
  }

  // FileView cannot create the directory it writes into, and the vault may not
  // exist yet on a fresh machine.
  Process {
    id: printProc
    running: false
  }

  Process {
    id: mkdirProc
    running: true
    command: ["mkdir", "-p", root.journalDir]
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      var now = clock.date
      if (now.getDate() === root.today.getDate()
          && now.getMonth() === root.today.getMonth()
          && now.getFullYear() === root.today.getFullYear()) return
      root.today = now
    }
  }

  // One watcher per month that has been on screen. Reading and writing share
  // the view; the `written` guard above is what stops our own write from
  // bouncing back as an edit.
  Instantiator {
    id: monthFiles
    model: root.loadedKeys

    delegate: FileView {
      required property string modelData
      path: root.journalDir + "/" + modelData + ".md"
      watchChanges: true
      printErrors: false
      onLoaded: root.ingest(modelData, text())
      onLoadFailed: root.ingest(modelData, null)
      onFileChanged: reload()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Monthly calendar"
    onPressed: function(b) { root.toggle() }

    // Drawn rather than set from the font: no single-bullet glyph exists in
    // the Nerd Font set. The Material range runs bug, bulletin-board,
    // bullhorn, bus with no bullet between them, and `ammunition` draws three
    // cartridges side by side. So this is one round -- ogive nose up over a
    // straight case, sized off the icon canvas so it tracks the bar's scale.
    iconComponent: Component {
      Item {
        anchors.fill: parent

        Shape {
          id: bullet
          anchors.centerIn: parent
          // The reference cartridge is 0.3265 wide for its height. Held to
          // that it reads thin beside the neighbouring icons, so it carries a
          // stouter 0.40 and the width is derived from the height rather than
          // tuned separately -- the two then stay in step when the size moves.
          // Every other proportion -- nose, cannelure, case, rim -- is the
          // reference's own.
          height: 2 * Math.round(parent.height * 0.42)
          width: Math.round(height * 0.40)
          antialiasing: true

          ShapePath {
            fillColor: button.foreground
            strokeWidth: 0
            strokeColor: "transparent"
            PathSvg { path: bullet.outline }
          }

          // Half-widths sampled down the reference nose, as a fraction of the
          // case's half-width, against height fraction. Traced rather than
          // invented: a parabola or a plain dome both come out too pointed,
          // because a real ogive flattens off well before its shoulder.
          readonly property var nose: [
            [0.000, 0.011], [0.027, 0.289], [0.055, 0.454], [0.082, 0.570],
            [0.110, 0.665], [0.137, 0.735], [0.164, 0.793], [0.192, 0.839],
            [0.219, 0.878], [0.246, 0.906], [0.274, 0.924], [0.301, 0.939],
            [0.329, 0.941], [0.356, 0.944], [0.366, 0.944]
          ]

          // Three separate pieces, as the reference has: the round, the case
          // below a cannelure gap, and the rim bar below another. Both gaps
          // are forced to a whole pixel -- at bar size they measure about half
          // a pixel and would otherwise vanish, welding the parts together.
          readonly property string outline: {
            var w = bullet.width
            var h = bullet.height
            var half = w / 2
            // Kept fractional on purpose. These are logical units and the
            // widget is only ten of them tall, so rounding the two gaps and
            // the rim up to a whole unit each spent a third of the height on
            // them and left the case at half its share. The display renders at
            // 2x, so half a unit is a real device pixel -- that is the floor,
            // and everything else keeps the reference's exact proportions.
            var gap = Math.max(0.5, h * 0.016)
            var rimHeight = Math.max(0.5, h * 0.035)
            var noseFoot = h * 0.366
            var caseTop = noseFoot + gap
            var rimTop = h - rimHeight
            var caseFoot = rimTop - gap
            var caseWaist = caseFoot - (caseFoot - caseTop) * 0.09
            var p = bullet.nose
            var d = []

            // up the left flank, over the tip, back down the right
            d.push("M " + (half - p[p.length - 1][1] * half) + " " + noseFoot)
            for (var i = p.length - 1; i >= 0; i--)
              d.push("L " + (half - p[i][1] * half) + " " + (p[i][0] * h))
            for (var j = 0; j < p.length; j++)
              d.push("L " + (half + p[j][1] * half) + " " + (p[j][0] * h))
            d.push("Z")

            // the case, tucking in slightly at its foot
            d.push("M 0 " + caseTop + " L " + w + " " + caseTop
                 + " L " + w + " " + caseWaist
                 + " L " + (half + 0.78 * half) + " " + caseFoot
                 + " L " + (half - 0.78 * half) + " " + caseFoot
                 + " L 0 " + caseWaist + " Z")

            // the rim
            d.push("M " + (half - 0.98 * half) + " " + rimTop
                 + " L " + (half + 0.98 * half) + " " + rimTop
                 + " L " + (half + 0.98 * half) + " " + h
                 + " L " + (half - 0.98 * half) + " " + h + " Z")

            return d.join(" ")
          }
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.spreadOpen ? Style.space(1040) : Style.space(520))
    contentHeight: panel.fittedContentHeight(
      root.headerHeight + 31 * root.rowHeight + root.footerHeight + Style.space(10),
      Style.space(860))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // How wide one page is. Shut, the log has the whole card; open, the two
      // pages split it either side of the spine.
      readonly property int pageWidth: root.spreadOpen
        ? Math.floor((width - root.spineGap * 2) / 2)
        : width
      // While a row owns the keyboard every key belongs to it -- including the
      // h/l/j/k that would otherwise be swallowed as navigation.
      blocked: root.editing || root.editingSection

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveMonth(dx)
        if (dy !== 0) root.moveCursor(dy, false)
      }
      onActivateRequested: root.goToIndex(root.cursorIndex, true)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.moveMonth(-1)
        else if (t === "]") root.moveMonth(1)
        else if (t === "{") root.moveMonth(-12)
        else if (t === "}") root.moveMonth(12)
        else if (t === "t" || t === "T") root.goToToday()
        else if (t === "s" || t === "S") root.toggleSpread()
        else if (t >= "1" && t <= "4") root.focusSection(parseInt(t, 10) - 1)
        else if (t === "p" || t === "P") root.printMonth()
      }

      // ---- Heading: the month at the top of the view, with the two chevrons
      //      that jump a whole month. Clicking the month itself is the way
      //      back to today, which is the only other place anyone wants to go.
      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        width: keyCatcher.pageWidth
        height: root.headerHeight

        Row {
          anchors.centerIn: parent
          anchors.verticalCenterOffset: -root.headerBias
          spacing: Style.space(18)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "󰅁"
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon
            color: prevMouse.containsMouse ? Style.hoverStateColor(root.fg, Color.accent) : root.mutedColor

            MouseArea {
              id: prevMouse
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.moveMonth(-1)
            }
          }

          Text {
            id: monthText
            anchors.verticalCenter: parent.verticalCenter
            text: root.monthLabel
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.letterSpacing: Style.space(1)
            color: monthMouse.containsMouse
              ? Style.hoverStateColor(root.fg, Color.accent)
              : (root.viewingCurrentMonth ? root.fg : root.awayMonthColor)

            MouseArea {
              id: monthMouse
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goToToday()
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "󰅂"
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon
            color: nextMouse.containsMouse ? Style.hoverStateColor(root.fg, Color.accent) : root.mutedColor

            MouseArea {
              id: nextMouse
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.moveMonth(1)
            }
          }
        }

        // Opens the facing page. Sits at the outer edge of the log, where a
        // thumb would go to turn the page.
        Text {
          id: spreadToggle
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: -root.headerBias
          text: root.spreadOpen ? "󰄽" : "󰄾"
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
          color: spreadMouse.containsMouse
            ? Style.hoverStateColor(root.fg, Color.accent)
            : root.mutedColor

          MouseArea {
            id: spreadMouse
            anchors.fill: parent
            anchors.margins: -Style.space(6)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleSpread()
          }
        }

        // The rule under the heading is the one the days hang from.
        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: Math.max(1, Style.space(1))
          color: root.weekRuleColor
        }
      }

      // ---- The days, as one continuous run. A plain interactive ListView, so
      //      the wheel, drag and keyboard all come for free, and there is no
      //      longer an end of month to handle specially.
      ListView {
        id: dayList
        anchors.top: header.bottom
        anchors.topMargin: Style.space(4)
        anchors.left: parent.left
        width: keyCatcher.pageWidth
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(4)
        clip: true
        model: root.days
        boundsBehavior: Flickable.StopAtBounds
        // Rest on a line boundary rather than between two, so the log's rules
        // stay in register with the facing page's instead of drifting in and
        // out of it as you scroll.
        snapMode: ListView.SnapToItem
        // Delegates hold text being typed into, so recycling one would hand a
        // half-written line to a different day.
        reuseItems: false
        cacheBuffer: root.rowHeight * 8

        onContentYChanged: root.updateFocusIndex()
        onCountChanged: root.updateFocusIndex()

        delegate: Item {
          id: dayRow
          required property var modelData
          required property int index

          width: dayList.width
          height: root.rowHeight

          readonly property bool isCursor: root.cursorIndex === index
          readonly property bool isEditing: root.editing && isCursor

          Component.onCompleted: root.ensureLoaded(modelData.monthKey)
          onIsEditingChanged: if (isEditing && !field.activeFocus) field.forceActiveFocus()

          Item {
            id: line
            anchors.fill: parent

            // Wash marking, in order of precedence: the row being typed in,
            // the row the cursor is parked on, and today.
            Rectangle {
              anchors.fill: parent
              anchors.bottomMargin: separator.height
              color: dayRow.isEditing
                ? Style.focusFillFor(root.fg, Color.accent)
                : dayRow.isCursor
                  ? Style.hoverFillFor(root.fg, Color.accent)
                  : dayRow.modelData.isToday
                    ? Style.normalFillFor(root.fg, Color.accent)
                    : "transparent"
            }

            // Reserved whether or not it is today's row, so the dates stay in
            // one column instead of jogging sideways on the day the arrow
            // appears.
            Item {
              id: todayMark
              anchors.left: parent.left
              anchors.leftMargin: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(8)
              height: parent.height

              Text {
                // Right-aligned rather than centred in the slot, so the arrow
                // sits against the date it points at instead of floating out
                // in the margin.
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: dayRow.modelData.isToday
                text: "▸"
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: Color.accent
              }
            }

            Text {
              id: dayNumber
              anchors.left: todayMark.right
              anchors.leftMargin: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              width: root.gutterWidth
              horizontalAlignment: Text.AlignRight
              text: dayRow.modelData.day
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: dayRow.modelData.isToday ? Color.accent : root.fg
            }

            Text {
              id: dayLetter
              anchors.left: dayNumber.right
              anchors.leftMargin: Style.space(7)
              anchors.verticalCenter: parent.verticalCenter
              width: root.letterWidth
              text: dayRow.modelData.letter
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: dayRow.modelData.isToday ? Color.accent : root.fg
            }

            // The margin line: the vertical rule the writing starts after.
            Rectangle {
              id: marginRule
              anchors.left: dayLetter.right
              anchors.leftMargin: Style.space(9)
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: 1
              color: root.ruleColor
            }

            TextInput {
              id: field
              anchors.left: marginRule.right
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              clip: true
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              selectByMouse: true
              selectionColor: Style.selectionFill
              selectedTextColor: root.fg
              activeFocusOnPress: true

              // Pulled from `entries` on every reload rather than bound to it,
              // so typing is never fighting a binding.
              property int rev: root.revision
              onRevChanged: text = root.contentFor(dayRow.modelData.dateKey)
              Component.onCompleted: text = root.contentFor(dayRow.modelData.dateKey)

              onTextChanged: root.setEntry(dayRow.modelData.dateKey,
                                           dayRow.modelData.monthKey, text)
              onActiveFocusChanged: if (activeFocus) {
                root.cursorIndex = dayRow.index
                root.editing = true
                root.editingSection = false
              }

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.stopEditing()
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                           || event.key === Qt.Key_Down) {
                  root.moveCursor(1, true)
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  root.moveCursor(-1, true)
                  event.accepted = true
                } else if (event.key === Qt.Key_Tab) {
                  root.moveCursor(1, true)
                  event.accepted = true
                } else if (event.key === Qt.Key_Backtab) {
                  root.moveCursor(-1, true)
                  event.accepted = true
                }
              }
            }

            // Saturday closes the week, so its rule is the heavy one.
            Rectangle {
              id: separator
              anchors.bottom: parent.bottom
              width: parent.width
              height: dayRow.modelData.weekEnd ? Math.max(2, Style.space(2)) : 1
              color: dayRow.modelData.weekEnd ? root.weekRuleColor : root.ruleColor
            }
          }
        }
      }

      // ---- The spine. Two pages of one notebook, not two panels.
      Rectangle {
        id: spine
        visible: root.spreadOpen
        anchors.left: parent.left
        anchors.leftMargin: keyCatcher.pageWidth + root.spineGap
        anchors.top: parent.top
        anchors.bottom: footer.top
        width: Math.max(1, Style.space(1))
        color: root.ruleColor
      }

      // ---- The facing page: four boxes for the month as a whole, against the
      //      left page's day-by-day. Ruled at the same pitch the text sits on,
      //      so writing lands on the lines rather than near them.
      Item {
        id: rightPage
        visible: root.spreadOpen
        anchors.left: spine.right
        anchors.leftMargin: root.spineGap
        anchors.right: parent.right
        // Flush with the top of the log, not below its heading: each box then
        // carries a title band of exactly the heading's height, which lands
        // its rule on the same line the days hang from.
        anchors.top: parent.top
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(4)

        readonly property int colGap: Style.space(14)
        readonly property int rowGap: Style.space(16)
        readonly property int colWidth: Math.floor((width - colGap) / 2)
        readonly property int topHeight: Math.round((height - rowGap) * 0.58)
        readonly property int bottomHeight: height - rowGap - topHeight

        Repeater {
          id: sectionBoxes
          model: root.sectionLayout

          delegate: Item {
            id: box
            required property var modelData
            required property int index

            // Handle for focusSection() above.
            // The top row's title band is the heading's own height, so its
            // rule sits exactly on the left page's. The lower row has no such
            // partner and just needs room for its title.
            readonly property int titleBand: box.modelData.row === 0
              ? root.headerHeight
              : Math.round(root.headerHeight * 0.62)

            // Enough slots to rule the box out, plus room to keep typing.
            // `grown` only ever goes up, so pressing Return on the last line
            // adds one rather than swallowing the keystroke.
            property int grown: 0
            readonly property int storedCount: {
              root.revision
              return root.sectionLines(root.headMonthKey, box.modelData.id).length
            }
            readonly property int lineSlots: Math.max(
              Math.floor(writingArea.height / root.rowHeight),
              box.storedCount + 1,
              box.grown)

            function focusLine(index) {
              if (index < 0) return
              if (index >= box.lineSlots) box.grown = index + 1
              Qt.callLater(function() {
                var row = lineList.itemAtIndex(index)
                if (row && row.field) row.field.forceActiveFocus()
              })
            }

            x: box.modelData.col === 0 ? 0 : rightPage.colWidth + rightPage.colGap
            y: box.modelData.row === 0 ? 0 : rightPage.topHeight + rightPage.rowGap
            width: rightPage.colWidth
            height: box.modelData.row === 0 ? rightPage.topHeight : rightPage.bottomHeight

            Text {
              id: boxTitle
              anchors.bottom: boxRule.top
              anchors.bottomMargin: Style.space(5)
              anchors.left: parent.left
              text: box.modelData.title.toUpperCase()
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.letterSpacing: Style.space(1)
              color: root.sectionTitleColor
            }

            // Positioned first, with the title hung above it, so the rule is
            // the thing that lands on a known line rather than wherever the
            // title's height happens to push it.
            Rectangle {
              id: boxRule
              anchors.top: parent.top
              anchors.topMargin: box.titleBand - height
              width: parent.width
              height: Math.max(1, Style.space(1))
              color: root.weekRuleColor
            }

            Item {
              id: writingArea
              anchors.top: boxRule.bottom
              // Same gap the day list leaves under the heading rule, so the
              // two pages' lines stay in register the whole way down.
              anchors.topMargin: Style.space(4)
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              clip: true

              // One single-line field per rule, built exactly the way the day
              // page is. A single multi-line TextEdit can never sit on rules at
              // the day page's pitch -- Qt gives TextEdit no line-height
              // control at all -- but a column of one-line fields can, and it
              // gets the same Enter-moves-down behaviour for free.
              ListView {
                id: lineList
                anchors.fill: parent
                clip: true
                model: box.lineSlots
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                reuseItems: false

                delegate: Item {
                  id: lineRow
                  required property int index

                  width: lineList.width
                  height: root.rowHeight

                  readonly property var field: lineField

                  TextInput {
                    id: lineField
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    clip: true
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    selectByMouse: true
                    selectionColor: Style.selectionFill
                    selectedTextColor: root.fg

                    property bool syncing: false
                    property string monthNow: root.headMonthKey
                    property int rev: root.revision

                    function reload() {
                      lineField.syncing = true
                      lineField.text = root.sectionLineAt(root.headMonthKey,
                                                          box.modelData.id, lineRow.index)
                      lineField.syncing = false
                    }

                    onMonthNowChanged: lineField.reload()
                    onRevChanged: lineField.reload()
                    Component.onCompleted: lineField.reload()

                    onTextChanged: if (!lineField.syncing)
                      root.setSectionLine(root.headMonthKey, box.modelData.id,
                                          lineRow.index, lineField.text)
                    onActiveFocusChanged: if (lineField.activeFocus) {
                      root.editingSection = true
                      root.editing = false
                    }

                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Escape) {
                        root.stopSectionEditing()
                        event.accepted = true
                      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                 || event.key === Qt.Key_Down) {
                        box.focusLine(lineRow.index + 1)
                        event.accepted = true
                      } else if (event.key === Qt.Key_Up) {
                        box.focusLine(lineRow.index - 1)
                        event.accepted = true
                      }
                    }
                  }

                  Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: root.ruleColor
                  }
                }
              }
            }
          }
        }
      }

      // ---- Where it all ends up, so the Obsidian side is never a mystery.
      Item {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.footerHeight

        // Just the note's name. The folder never changes, so spelling it out
        // every time bought nothing and ran the label into the hints; the
        // width is still bounded and elided as a backstop.
        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(10)
          anchors.right: hints.left
          anchors.rightMargin: Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: root.footerBias
          text: root.noteName
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.mutedColor
          opacity: 0.8
        }

        Text {
          id: hints
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: root.footerBias
          text: (root.editing || root.editingSection) ? "esc  done"
            : root.spreadOpen ? "1-4  boxes     s  close     p  print     t  today" : "←→  month     ↵  write     s  facing page     t  today"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.mutedColor
          opacity: 0.8
        }
      }
    }
  }
}
