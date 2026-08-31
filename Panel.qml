import QtQuick
import QtQuick.Controls
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar search over an Obsidian vault.
//
// The bar entry is a text label. Left click (or keyboard summon) opens a
// panel with a search field and a ranked note list; typing searches the vault
// by title, path and full text. Enter or a click opens the note in Obsidian
// through its obsidian:// URI. Data comes from search.sh, which only reads
// the filesystem, so Obsidian never has to be running.
Panel {
  id: root

  moduleName: "rperaza.obsidian-notes"
  ipcTarget: "rperaza.obsidian-notes"

  // Popup content must stay readable when the bar is double-clicked to
  // transparent. bar.barForeground is intentionally animated to contrast the
  // wallpaper behind a transparent bar (via omarchy-bar-text-color), so it
  // can become near-black on light wallpapers while the popup card stays
  // Color.popups.background (dark). Using barForeground inside the popup
  // therefore makes dark-on-dark unreadable — see screenshot. Use the
  // popup surface palette instead, which is always contrasting its card.
  readonly property color foreground: Color.popups.text
  readonly property color dim: Util.alpha(Color.popups.text, 0.62)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string configuredVaultPath: String(root.setting("vaultPath", "")).trim()
  readonly property string vaultPath: configuredVaultPath.indexOf("~/") === 0
    ? (Quickshell.env("HOME") || "") + configuredVaultPath.slice(1)
    : configuredVaultPath
  readonly property string searchCommand: (Quickshell.env("HOME") || "")
    + "/.config/omarchy/plugins/rperaza.obsidian-notes/search.sh"
  readonly property string createCommand: (Quickshell.env("HOME") || "")
    + "/.config/omarchy/plugins/rperaza.obsidian-notes/create-note.sh"

  property var results: []
  property int selectedIndex: -1
  property bool searching: false
  property bool choosingVault: false
  property bool composing: false
  property bool saving: false
  property string saveError: ""
  property string lastError: ""

  readonly property int maxRows: 8
  readonly property real rowHeight: Style.space(56)
  readonly property string query: filterField.text.trim()
  readonly property bool empty: !searching && results.length === 0 && lastError === ""

  readonly property string footerText: {
    if (searching) return "Searching…"
    if (lastError) return lastError
    if (results.length === 0) return "↑↓ navigate   ·   Enter open   ·   Esc close"
    return results.length + (results.length === 1 ? " result" : " results")
      + "   ·   ↑↓ navigate   ·   Enter open   ·   Esc close"
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- URI / formatting helpers -------------------------------------------

  function vaultName() {
    var parts = String(root.vaultPath).split("/").filter(function(p) { return p !== "" })
    return parts.length > 0 ? parts[parts.length - 1] : root.vaultPath
  }

  function encode(s) {
    return encodeURIComponent(String(s))
  }

  function obsidianUri(relPath) {
    var file = String(relPath || "").replace(/\.md$/, "")
    return "obsidian://open?vault=" + root.encode(root.vaultName()) + "&file=" + root.encode(file)
  }

  // Vault content is untrusted input: titles, paths and snippets can contain
  // HTML such as <img src="http://…">, and QML Text defaults to AutoText,
  // which would let the shared shell process fetch remote resources. Every
  // Text rendering note data therefore pins textFormat: Text.PlainText, and
  // strings passed to kit components that own their own label (Button) are
  // entity-escaped first because their internal label cannot be configured.
  function escapeHtml(s) {
    return String(s === null || s === undefined ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }

  function whenText(epoch) {
    if (epoch === null || epoch === undefined || isNaN(Number(epoch))) return ""
    var d = new Date(Number(epoch) * 1000)
    var now = new Date()
    var pad = function(n) { return n < 10 ? "0" + n : String(n) }
    if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()) {
      return "today " + pad(d.getHours()) + ":" + pad(d.getMinutes())
    }
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return pad(d.getDate()) + " " + months[d.getMonth()]
  }

  // ---- actions -------------------------------------------------------------

  function runSearch() {
    if (searchProcess.running) return
    if (root.vaultPath === "") {
      root.searching = false
      root.results = []
      root.selectedIndex = -1
      root.lastError = "Select your vault folder to get started"
      return
    }
    root.searching = true
    root.lastError = ""
    searchProcess.command = [root.searchCommand, root.vaultPath, filterField.text]
    searchProcess.running = true
    searchDeadline.restart()
  }

  function persistVaultPath(path) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.vaultPath = String(path || "")

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)

    filterField.text = ""
    root.lastError = ""
    Qt.callLater(root.runSearch)
  }

  function localPath(fileUrl) {
    var value = String(fileUrl || "")
    if (value.indexOf("file://") === 0) value = value.slice(7)
    try { return decodeURIComponent(value) }
    catch (e) { return value }
  }

  function parseResults(raw) {
    searchDeadline.stop()
    var text = String(raw || "").trim()
    root.searching = false
    if (text === "") {
      root.results = []
      root.selectedIndex = -1
      return
    }
    try {
      var parsed = JSON.parse(text)
      root.results = (parsed && Array.isArray(parsed)) ? parsed : []
    } catch (e) {
      console.warn(root.moduleName + ": invalid search output", e)
      root.lastError = "Invalid search response"
      root.results = []
    }
    root.selectedIndex = root.results.length > 0 ? 0 : -1
    if (root.selectedIndex >= 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function move(delta) {
    var n = root.results.length
    if (n <= 0) return
    root.selectedIndex = Math.max(0, Math.min(n - 1, root.selectedIndex + delta))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function openNote() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.results.length) return
    var note = root.results[root.selectedIndex]
    if (!note || !note.path) return
    root.close()
    Qt.callLater(function() {
      Quickshell.execDetached(["xdg-open", root.obsidianUri(note.path)])
    })
  }

  function startComposing() {
    root.choosingVault = false
    root.composing = true
    root.saveError = ""
    noteEditor.text = ""
    Qt.callLater(function() { noteEditor.forceActiveFocus() })
  }

  function cancelComposing() {
    root.composing = false
    root.saveError = ""
    noteEditor.text = ""
    Qt.callLater(function() { filterField.forceActiveFocus() })
  }

  function saveNote() {
    if (root.saving) return
    if (noteEditor.text.trim() === "") {
      root.saveError = "Write something before saving"
      return
    }
    root.saving = true
    root.saveError = ""
    createProcess.command = [root.createCommand, root.vaultPath, noteEditor.text]
    createProcess.running = true
  }

  onOpenedChanged: if (opened) {
    filterField.text = ""
    root.composing = false
    root.saveError = ""
    root.choosingVault = root.vaultPath === ""
    if (!root.choosingVault) root.runSearch()
    Qt.callLater(function() {
      if (!root.choosingVault) filterField.forceActiveFocus()
    })
  }

  Component.onCompleted: root.runSearch()

  Process {
    id: searchProcess
    command: []
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseResults(text)
    }

    onExited: function(exitCode) {
      searchDeadline.stop()
      root.searching = false
      // Timeout-killed helpers exit 124 (timeout) or 143; the deadline timer
      // already set a user-visible message, so do not overwrite it.
      if (exitCode !== 0 && root.lastError === "" && !searchDeadline.running) {
        // Keep the timeout message if the deadline fired; otherwise generic.
        if (exitCode === 124 || exitCode === 143) {
          if (root.lastError === "") root.lastError = "Search timed out"
        } else {
          console.warn(root.moduleName + ": search command exited", exitCode)
          root.lastError = "Search failed (error " + exitCode + ")"
        }
      } else if (exitCode !== 0 && root.lastError === "") {
        console.warn(root.moduleName + ": search command exited", exitCode)
        root.lastError = "Search failed (error " + exitCode + ")"
      }
    }
  }

  // Whole-operation deadline for the helper: even with bounded helper I/O,
  // a pathological vault could keep search.sh alive. The helper itself has
  // an internal SECONDS budget and bounded find; this timer is the QML-side
  // hard kill so the shared shell process cannot be held indefinitely.
  Timer {
    id: searchDeadline
    interval: 4500
    repeat: false
    onTriggered: {
      if (searchProcess.running) {
        searchProcess.running = false
        root.searching = false
        if (root.lastError === "") root.lastError = "Search timed out"
      }
    }
  }

  Process {
    id: createProcess
    command: []
    running: false

    stdout: StdioCollector {
      id: createOutput
      waitForEnd: true
    }

    onExited: function(exitCode) {
      root.saving = false
      if (exitCode !== 0) {
        root.saveError = "Could not save the note (error " + exitCode + ")"
        return
      }
      root.composing = false
      noteEditor.text = ""
      filterField.text = ""
      root.runSearch()
      Qt.callLater(function() { filterField.forceActiveFocus() })
    }
  }

  FolderListModel {
    id: folderModel
    folder: "file://" + (root.vaultPath || Quickshell.env("HOME") || "/")
    showDirs: true
    showFiles: false
    showDirsFirst: true
    showDotAndDotDot: false
  }

  // ---- bar entry -----------------------------------------------------------

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "Notes"
    fontSize: Style.font.bodySmall
    horizontalMargin: 6.5
    tooltipText: "Search Obsidian notes"

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (root.vaultPath !== "")
          Quickshell.execDetached(["xdg-open", "obsidian://open?vault=" + root.encode(root.vaultName())])
      } else {
        root.toggle()
      }
    }
  }

  // ---- search panel ---------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.composing ? noteEditor : filterField
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: filterField.activeFocus || noteEditor.activeFocus

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.move(dy) }
      onActivateRequested: root.openNote()
      onReturnRequested: root.openNote()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        filterField.insert(filterField.cursorPosition, t)
        filterField.forceActiveFocus()
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.spacing.md

        Row {
          visible: !root.choosingVault && !root.composing
          width: parent.width
          spacing: Style.spacing.sm

          TextField {
            id: filterField
            width: parent.width - addButton.width - vaultButton.width - parent.spacing * 2
            placeholderText: root.vaultPath === "" ? "Select a vault…" : "Search the vault…"
            foreground: root.foreground
            enabled: root.vaultPath !== ""

            onTextChanged: filterTimer.restart()
            onAccepted: root.openNote()
            Keys.onUpPressed: root.move(-1)
            Keys.onDownPressed: root.move(1)
            Keys.onEscapePressed: {
              if (filterField.text !== "") filterField.text = ""
              else root.close()
            }
          }

          Button {
            id: addButton
            text: "+"
            tooltipText: "Create a quick note"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.title
            bordered: true
            focusable: true
            onClicked: root.startComposing()
          }

          Button {
            id: vaultButton
            iconText: "󰒓"
            tooltipText: "Change vault"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconSize: Style.font.icon
            horizontalPadding: Style.space(7)
            bordered: true
            focusable: true
            onClicked: {
              folderModel.folder = "file://" + (root.vaultPath || Quickshell.env("HOME") || "/")
              root.choosingVault = true
            }
          }
        }

        Column {
          visible: root.composing && !root.choosingVault
          width: parent.width
          spacing: Style.spacing.sm

          Text {
            text: "New note · omarchy-notes"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextArea {
            id: noteEditor
            width: parent.width
            height: Style.space(220)
            placeholderText: "Write your note…"
            color: root.foreground
            placeholderTextColor: root.dim
            selectionColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: TextEdit.Wrap
            padding: Style.space(10)
            background: Rectangle {
              color: "transparent"
              radius: Style.cornerRadius
              border.color: root.dim
              border.width: 1
            }
            Keys.onEscapePressed: root.cancelComposing()
          }

          Text {
            visible: root.saveError !== ""
            width: parent.width
            text: root.saveError
            textFormat: Text.PlainText
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            spacing: Style.spacing.sm

            Button {
              text: root.saving ? "Saving…" : "Save"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              focusable: true
              enabled: !root.saving
              onClicked: root.saveNote()
            }

            Button {
              text: "Cancel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              focusable: true
              enabled: !root.saving
              onClicked: root.cancelComposing()
            }
          }
        }

        Column {
          visible: root.choosingVault
          width: parent.width
          spacing: Style.spacing.sm

          Text {
            width: parent.width
            text: root.localPath(folderModel.folder)
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            Button {
              text: "Up"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              enabled: String(folderModel.parentFolder) !== ""
              onClicked: folderModel.folder = folderModel.parentFolder
            }

            Button {
              text: "Use this folder"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: {
                root.persistVaultPath(root.localPath(folderModel.folder))
                root.choosingVault = false
              }
            }

            Button {
              visible: root.vaultPath !== ""
              text: "Cancel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.choosingVault = false
            }
          }

          ListView {
            id: folderList
            width: parent.width
            height: root.rowHeight * 6
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: folderModel
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Button {
              required property int index
              required property string fileName
              required property url fileUrl
              width: folderList.width
              text: root.escapeHtml(fileName)
              leftAlign: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: folderModel.folder = fileUrl
            }
          }
        }

        Timer {
          id: filterTimer
          interval: 200
          repeat: false
          onTriggered: root.runSearch()
        }

        ListView {
          id: resultList
          visible: !root.choosingVault && !root.composing
          width: parent.width
          height: Math.min(root.results.length, root.maxRows) * root.rowHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: root.results.length > root.maxRows
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.results
          currentIndex: root.selectedIndex

          delegate: Rectangle {
            id: row
            required property int index
            readonly property var note: root.results[index] || ({})
            width: resultList.width
            height: root.rowHeight
            radius: Style.space(4)
            color: root.selectedIndex === index
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
              : "transparent"

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.selectedIndex = index
              onPositionChanged: root.selectedIndex = index
              onClicked: {
                root.selectedIndex = index
                root.openNote()
              }
            }

            Column {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: row.note.title || row.note.path || "…"
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                width: parent.width
                text: row.note.path || ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                visible: (row.note.snippet || "") !== ""
                text: row.note.snippet || ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.rightMargin: Style.space(10)
              anchors.topMargin: Style.space(8)
              text: root.whenText(row.note.modified)
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          id: emptyText
          width: parent.width
          visible: !root.choosingVault && !root.composing && root.empty
          text: root.query === "" ? "The vault is empty or cannot be read" : "No results for “" + root.query + "”"
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
          padding: Style.space(24)
        }

        Text {
          width: parent.width
          visible: !root.choosingVault && !root.composing
          text: root.footerText
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
        }
      }
    }
  }
}
