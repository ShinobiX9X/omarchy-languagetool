import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "GrammarCheck.js" as GC

// Grammar check overlay: reads the selected text (or the clipboard), checks it
// with LanguageTool, lets you apply suggestions, then pastes or copies the
// result. Summon with: omarchy-shell shell toggle io.github.shinobix9x.languagetool
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: (root.manifest && root.manifest.id) || "io.github.shinobix9x.languagetool"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/languagetool/credentials"
  readonly property int requestTimeoutMs: 30000
  readonly property int maxResponseBytes: 4 * 1024 * 1024

  property bool opened: false
  // idle | reading | confirm | checking | ready | error
  property string state_: "idle"
  property string statusText: ""
  property string warningText: ""
  property string original: ""
  property string working: ""
  property var matches: []
  property int current: 0
  property int applied: 0
  property string language: ""
  property bool premium: false
  property int generation: 0
  property var pendingXhr: null
  property string clipboardText: ""
  property bool pasteAfterCopy: false

  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property color selectedText: Commons.Color.menu.selectedText
  property color errorColor: Commons.Color.urgent
  property color mutedColor: Commons.Color.muted
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.lg
  property int cardWidth: Math.min(Style.space(720), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(560), panel.height - Style.gapsOut * 2)

  readonly property var currentMatch: root.matches.length > 0 ? root.matches[root.current] : null

  function open(payloadJson) {
    root.generation++
    root.cancelRequest()
    root.opened = true
    root.state_ = "reading"
    root.statusText = "Reading the selection…"
    root.warningText = ""
    root.original = ""
    root.working = ""
    root.matches = []
    root.current = 0
    root.applied = 0
    root.language = ""
    typesPrimary.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.generation++
    root.cancelRequest()
    // A wl-paste waiting on an unresponsive app would otherwise block the
    // next summon, and nothing checked stays in memory once closed.
    typesPrimary.running = false
    typesClipboard.running = false
    readPrimary.running = false
    readClipboard.running = false
    root.state_ = "idle"
    root.original = ""
    root.working = ""
    root.matches = []
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function fail(message) {
    root.state_ = "error"
    root.statusText = message
  }

  function gotText(text, fromClipboard) {
    if (!root.opened || root.state_ !== "reading") return
    if (!text.trim()) {
      root.fail("Select some text (or copy it) and press the shortcut again.")
      return
    }
    if (text.length > GC.MAX_TEXT) {
      root.fail("The text is too long (" + text.length + " characters, the limit is " + GC.MAX_TEXT + ").")
      return
    }
    root.original = text
    root.working = text
    if (fromClipboard) {
      // Nothing was selected: show what would be sent and wait for Enter, so
      // a forgotten clipboard never leaves the machine by accident.
      root.state_ = "confirm"
      root.statusText = "Nothing is selected. Press Enter to check this clipboard text, Esc to cancel."
      return
    }
    root.check()
  }

  function refuseSecret(types) {
    return GC.marksSecret(types)
  }

  function reading() {
    return root.opened && root.state_ === "reading"
  }

  function check() {
    configFile.reload()
    var conf = GC.parseConfig(configFile.text())
    var ep = GC.endpoint(conf)
    if (ep.error) {
      root.fail(ep.error + " (" + root.configPath + ")")
      return
    }
    root.premium = ep.sendCredentials
    if (ep.sendCredentials) keyMode.running = true

    root.state_ = "checking"
    root.statusText = ep.custom ? "Checking with your LanguageTool server…"
      : ep.sendCredentials ? "Checking with LanguageTool Premium…" : "Checking with LanguageTool (free)…"

    var gen = root.generation
    var text = root.working
    var xhr = new XMLHttpRequest()
    root.pendingXhr = xhr
    deadline.restart()
    xhr.onreadystatechange = function() {
      if (xhr.readyState === XMLHttpRequest.HEADERS_RECEIVED) {
        var declared = Number(xhr.getResponseHeader("Content-Length"))
        if (declared > root.maxResponseBytes) Qt.callLater(function() { xhr.abort() })
        return
      }
      // Chunked replies have no Content-Length; cap them while they arrive.
      if (xhr.readyState === XMLHttpRequest.LOADING) {
        if ((xhr.responseText || "").length > root.maxResponseBytes) Qt.callLater(function() { xhr.abort() })
        return
      }
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (root.pendingXhr === xhr) {
        root.pendingXhr = null
        deadline.stop()
      }
      if (gen !== root.generation) return
      root.handleReply(xhr.status, xhr.responseText || "", text)
    }
    xhr.open("POST", ep.url)
    xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded")
    xhr.setRequestHeader("Accept", "application/json")
    xhr.send(GC.formBody(text, conf, ep))
  }

  function handleReply(status, body, text) {
    if (status === 0) {
      root.fail("Could not reach LanguageTool (offline, timed out or the reply was too large).")
      return
    }
    if (body.length > root.maxResponseBytes) {
      root.fail("LanguageTool's reply was too large.")
      return
    }
    if (status === 401 || status === 403) {
      root.fail("LanguageTool refused the username or API key (HTTP " + status + "). Check " + root.configPath + ".")
      return
    }
    if (status === 413) {
      root.fail("The text is too long for your LanguageTool plan.")
      return
    }
    if (status === 429) {
      root.fail("Too many checks in a short time (HTTP 429). Wait a minute, or add a Premium API key.")
      return
    }
    if (status < 200 || status >= 300) {
      // The body is plain text from the server; show a short piece of it as text only.
      root.fail("LanguageTool error " + status + ": " + body.replace(/\s+/g, " ").slice(0, 160))
      return
    }
    var result
    try {
      result = GC.parseMatches(body, text)
    } catch (e) {
      root.fail("LanguageTool sent a reply that is not valid JSON.")
      return
    }
    root.language = result.language
    root.matches = result.matches
    root.current = 0
    root.state_ = "ready"
    root.statusText = ""
  }

  function cancelRequest() {
    deadline.stop()
    var xhr = root.pendingXhr
    root.pendingXhr = null
    // Aborting inside a readystatechange handler crashes Qt, so always defer.
    if (xhr) Qt.callLater(function() { xhr.abort() })
  }

  function move(delta) {
    if (root.matches.length === 0) return
    root.current = (root.current + delta + root.matches.length) % root.matches.length
  }

  function applySuggestion(n) {
    var m = root.currentMatch
    if (!m || n < 0 || n >= m.suggestions.length) return
    var r = GC.applyFix(root.working, root.matches, root.current, m.suggestions[n])
    root.working = r.text
    root.matches = r.matches
    root.applied++
    if (root.current >= root.matches.length) root.current = Math.max(0, root.matches.length - 1)
  }

  function skip() {
    if (root.matches.length === 0) return
    var next = root.matches.slice()
    next.splice(root.current, 1)
    root.matches = next
    if (root.current >= next.length) root.current = Math.max(0, next.length - 1)
  }

  function applyAll() {
    var r = GC.applyAll(root.working, root.matches)
    root.working = r.text
    root.matches = r.matches
    root.applied += r.applied
    root.current = 0
  }

  function finish(paste) {
    if (root.state_ !== "ready") return
    root.clipboardText = root.working
    root.pasteAfterCopy = paste
    root.dismiss()
    copyProc.running = true
  }

  // Selected text first, then the clipboard. `-t text` keeps images out.
  // Each source is skipped when a password manager marked it as secret.
  Process {
    id: typesPrimary
    command: ["wl-paste", "--primary", "--list-types"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.reading()) return
        if (root.refuseSecret(text)) root.fail("The selection is marked as a password, so it was not sent.")
        else readPrimary.running = true
      }
    }
  }

  Process {
    id: typesClipboard
    command: ["wl-paste", "--list-types"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.reading()) return
        if (root.refuseSecret(text)) root.fail("The clipboard holds a password, so it was not sent.")
        else readClipboard.running = true
      }
    }
  }

  Process {
    id: readPrimary
    command: ["wl-paste", "--primary", "--no-newline", "--type", "text"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.reading()) return
        if (text.trim()) root.gotText(text, false)
        else typesClipboard.running = true
      }
    }
  }

  Process {
    id: readClipboard
    command: ["wl-paste", "--no-newline", "--type", "text"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.gotText(text, true)
    }
  }

  // The corrected text goes over stdin, never argv, so it is not visible in
  // the process list. wl-copy forks to serve it and the parent exits.
  Process {
    id: copyProc
    command: ["wl-copy", "--type", "text/plain;charset=utf-8"]
    stdinEnabled: true
    onStarted: {
      write(root.clipboardText)
      root.clipboardText = ""
      stdinEnabled = false
    }
    onExited: {
      stdinEnabled = true
      if (root.pasteAfterCopy) pasteTimer.restart()
    }
  }

  // Same paste as Omarchy's emoji picker: Shift+Insert into the window that
  // gets focus back once the overlay is gone.
  Timer {
    id: pasteTimer
    interval: 180
    onTriggered: Quickshell.execDetached(["wtype", "-M", "shift", "-k", "Insert", "-m", "shift"])
  }

  Timer {
    id: deadline
    interval: root.requestTimeoutMs
    onTriggered: root.cancelRequest()
  }

  FileView {
    id: configFile
    path: root.configPath
    blockLoading: true
    printErrors: false
  }

  Process {
    id: keyMode
    command: ["stat", "-c", "%a", root.configPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (GC.looseMode(text))
          root.warningText = "Your API key file can be read by other accounts: run chmod 600 " + root.configPath
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-grammar-check"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var ctrl = event.modifiers & Qt.ControlModifier
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.state_ === "confirm") root.check()
            else root.finish(true)
          } else if (ctrl && event.key === Qt.Key_C) {
            root.finish(false)
          } else if (event.key === Qt.Key_Right || (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))) {
            root.move(1)
          } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab) {
            root.move(-1)
          } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            root.applySuggestion(event.key - Qt.Key_1)
          } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
            root.skip()
          } else if (event.key === Qt.Key_A) {
            root.applyAll()
          } else {
            return
          }
          event.accepted = true
        }
      }

      Column {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // Header
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: {
            var parts = ["Grammar check"]
            if (root.language) parts.push(root.language)
            if (root.state_ === "ready")
              parts.push(root.matches.length === 0 ? "no issues left" : (root.matches.length + " issue" + (root.matches.length === 1 ? "" : "s")))
            if (root.applied > 0) parts.push(root.applied + " fixed")
            return parts.join(" · ")
          }
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: root.warningText !== ""
          textFormat: Text.PlainText
          text: "󰀦 " + root.warningText
          color: root.errorColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        // The text with the issues underlined; the current one in bold.
        Rectangle {
          width: parent.width
          height: parent.height - y - issueBox.height - hints.height - root.contentSpacing * 2
          color: "transparent"
          border.color: Util.alpha(root.foreground, 0.15)
          border.width: 1
          radius: root.cornerRadius

          Flickable {
            id: flick
            anchors.fill: parent
            anchors.margins: Style.spacing.lg
            clip: true
            contentHeight: preview.paintedHeight
            boundsBehavior: Flickable.StopAtBounds

            Text {
              id: preview
              width: flick.width
              // StyledText with every piece of text escaped in GC.highlight;
              // plain text whenever nothing is highlighted.
              textFormat: root.state_ === "ready" && root.matches.length > 0 ? Text.StyledText : Text.PlainText
              text: root.state_ === "ready" && root.matches.length > 0
                ? GC.highlight(root.working, root.matches, root.current, String(root.errorColor), String(root.selectedText))
                : (root.working || root.statusText)
              color: root.working ? root.foreground : root.mutedColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              wrapMode: Text.Wrap
            }
          }
        }

        // Current issue and its suggestions
        Column {
          id: issueBox
          width: parent.width
          spacing: Style.spacing.md

          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: root.state_ !== "ready" || root.currentMatch !== null || root.applied > 0 || root.matches.length === 0
            text: root.state_ === "error" || root.state_ === "checking" || root.state_ === "reading" || root.state_ === "confirm"
              ? (root.working ? root.statusText : "")
              : root.currentMatch
                ? (root.current + 1) + "/" + root.matches.length + "  " + root.currentMatch.message
                  + (root.currentMatch.rule ? "  (" + root.currentMatch.rule + ")" : "")
                : (root.applied > 0 ? "Done. Enter pastes the corrected text, Ctrl+C copies it." : "No issues found.")
            color: root.state_ === "error" ? root.errorColor : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.currentMatch !== null

            Repeater {
              model: root.currentMatch ? root.currentMatch.suggestions : []

              delegate: Rectangle {
                required property int index
                required property string modelData
                width: chipText.implicitWidth + Style.spacing.controlPaddingX * 2
                height: chipText.implicitHeight + Style.spacing.controlPaddingY * 2
                radius: root.cornerRadius
                color: chipMouse.containsMouse ? root.selectedBackground : Util.alpha(root.foreground, 0.06)

                Text {
                  id: chipText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: (index + 1) + "  " + (modelData === "" ? "(remove)" : modelData)
                  color: chipMouse.containsMouse ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  id: chipMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.applySuggestion(index)
                }
              }
            }
          }
        }

        Text {
          id: hints
          width: parent.width
          textFormat: Text.PlainText
          text: "1–9 apply  ·  ←/→ move  ·  Space skip  ·  A apply all  ·  Enter paste  ·  Ctrl+C copy  ·  Esc close"
          color: root.mutedColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
