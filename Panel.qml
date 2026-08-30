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

  // ---- Where the notes live. Overridable per-entry in shell.json so the
  //      vault can move without touching this file.
  readonly property string home: Quickshell.env("HOME")
  readonly property string vaultDir: setting("vault", home + "/Documents/Obsidian")
  readonly property string folder: setting("folder", "Monthly Log")
  readonly property string journalDir: vaultDir + "/" + folder

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

  // ---------------------------------------------------------------- entries

  function contentFor(dateKey) {
    var value = root.entries[dateKey]
    return value === undefined || value === null ? "" : String(value)
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
    Model.applyMonth(root.entries, key, text === null ? ({}) : Model.parseMonth(text))
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
    if (!root.existingMonths[key] && !Model.monthHasContent(year, month, root.entries)) return
    var out = Model.serializeMonth(year, month, root.entries)
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
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onDestruction: root.flush()

  Timer {
    id: saveTimer
    interval: 600
    onTriggered: root.flush()
  }

  // FileView cannot create the directory it writes into, and the vault may not
  // exist yet on a fresh machine.
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
          // 10% wider than tall-for-tall proportion, which reads better in
          // the bar than the narrower round did. Symmetry does not depend on
          // the width here -- the single centre-line control point below is
          // what guarantees it -- so this is free to be any integer.
          width: Math.round(2 * Math.round(parent.width * 0.15) * 1.1)
          height: 2 * Math.round(parent.height * 0.36)
          antialiasing: true

          ShapePath {
            id: outline
            fillColor: button.foreground
            strokeWidth: 0
            strokeColor: "transparent"

            readonly property real w: bullet.width
            readonly property real h: bullet.height
            readonly property real nose: bullet.height * 0.42

            startX: 0
            startY: outline.nose

            // One quadratic with its control point on the centre line, so the
            // nose is symmetric by construction rather than by two curves
            // agreeing. Control at -nose puts the apex exactly on y = 0.
            PathQuad {
              controlX: outline.w / 2
              controlY: -outline.nose
              x: outline.w
              y: outline.nose
            }
            PathLine { x: outline.w; y: outline.h }
            PathLine { x: 0;         y: outline.h }
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
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(
      root.headerHeight + 31 * root.rowHeight + root.footerHeight + Style.space(10),
      Style.space(860))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a row owns the keyboard every key belongs to it -- including the
      // h/l/j/k that would otherwise be swallowed as navigation.
      blocked: root.editing

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
      }

      // ---- Heading: the month at the top of the view, with the two chevrons
      //      that jump a whole month. Clicking the month itself is the way
      //      back to today, which is the only other place anyone wants to go.
      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
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
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(4)
        clip: true
        model: root.days
        boundsBehavior: Flickable.StopAtBounds
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

      // ---- Where it all ends up, so the Obsidian side is never a mystery.
      Item {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.footerHeight

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: root.footerBias
          text: root.folder + "/" + root.noteName
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.mutedColor
          opacity: 0.8
        }

        Text {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: root.footerBias
          text: root.editing ? "esc  done" : "←→  month     ↵  write     t  today"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.mutedColor
          opacity: 0.8
        }
      }
    }
  }
}
