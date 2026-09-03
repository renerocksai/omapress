import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus popup for the Omarchy news feed. Two views inside one
// panel: the post list, and an inline reader for the selected post.
//
// Keys (list):   j/k or arrows move · Enter/l read · o open in browser
//                x toggle read · a mark all read · r refresh · Esc close
// Keys (reader): j/k scroll · h/Backspace/Esc back · Enter/o open in browser
//                x toggle read
Panel {
  id: root
  moduleName: "io.github.renerocksai.omapress"
  ipcTarget: "io.github.renerocksai.omapress"
  manageIpc: false

  property string view: "list"          // list | reader
  property var readerItem: null
  property int itemIndex: 0
  property bool cursorActive: false
  property int linkHover: -1

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color soft: Qt.darker(foreground, 1.2)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool highlightUnread: news.boolSetting("highlightUnread", true)
  readonly property bool hasNews: news.unread > 0
  // "theme" follows the bar's active color; anything else is a CSS color.
  readonly property color unreadColor: {
    var value = String(news.setting("unreadColor", "#e5484d")).trim()
    if (value === "" || value.toLowerCase() === "theme") return urgent
    var parsed = Qt.color(value)
    return parsed.valid === false ? urgent : parsed
  }
  readonly property string glyph: "\uf1ea"   // nf-fa-newspaper_o

  // The reader keeps a snapshot of the post it opened; look the live copy up
  // so the read/unread toggle reflects what the service currently holds.
  readonly property var readerLive: {
    var list = news.items
    if (!readerItem) return null
    return news.itemById(readerItem.id) || readerItem
  }

  // ---------------------------------------------------------------- cursor

  function ensureCursor() {
    if (news.items.length === 0) { itemIndex = 0; return }
    if (itemIndex >= news.items.length) itemIndex = news.items.length - 1
    if (itemIndex < 0) itemIndex = 0
  }

  function selectedItem() {
    if (news.items.length === 0) return null
    ensureCursor()
    return news.items[itemIndex]
  }

  function setItemCursor(index) {
    cursorActive = true
    itemIndex = index
    scrollCursorIntoView()
  }

  function moveCursor(dy) {
    cursorActive = true
    ensureCursor()
    if (news.items.length === 0 || dy === 0) return
    itemIndex = Math.max(0, Math.min(news.items.length - 1, itemIndex + dy))
    scrollCursorIntoView()
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (view !== "list" || !itemColumn) return
    if (itemIndex >= 0 && itemIndex < itemColumn.children.length) scrollItemIntoView(itemColumn.children[itemIndex])
  }

  function scrollReader(dy) {
    if (!panelFlick) return
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    panelFlick.contentY = Math.max(0, Math.min(maxY, panelFlick.contentY + dy * Style.space(96)))
  }

  // ------------------------------------------------------------------ views

  function openReader(item) {
    if (!item) return
    readerItem = item
    view = "reader"
    linkHover = -1
    if (panelFlick) panelFlick.contentY = 0
    news.markRead(item.id)
  }

  function backToList() {
    view = "list"
    readerItem = null
    Qt.callLater(function() {
      if (panelFlick) panelFlick.contentY = 0
      scrollCursorIntoView()
    })
  }

  function activateCursor() {
    if (view === "reader") {
      news.openItem(readerLive)
      return
    }
    openReader(selectedItem())
  }

  function openInBrowser() {
    if (view === "reader") news.openItem(readerLive)
    else if (cursorActive) news.openItem(selectedItem())
    else news.openUrl(news.feedLink)
  }

  function toggleReadAtCursor() {
    if (view === "reader") {
      if (readerLive) news.toggleRead(readerLive.id)
      return
    }
    if (!cursorActive) return
    var item = selectedItem()
    if (item) news.toggleRead(item.id)
  }

  function handleClose() {
    if (view === "reader") backToList()
    else close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    view = "list"
    readerItem = null
    if (panelFlick) panelFlick.contentY = 0
    news.refreshIfStale(120)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onItemIndexChanged: scrollCursorIntoView()

  Service {
    id: news
    settings: root.settings
    onItemsReplaced: root.ensureCursor()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { news.refresh(); return "ok" }
    function markAllRead(): string { news.markAllRead(); return "ok" }
    function unread(): string { return String(news.unread) }
  }

  // ------------------------------------------------------------- bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    // `active` recolors the glyph; the color is the user's unreadColor, since
    // many themes have no red in their bar-active slot.
    active: root.hasNews && root.highlightUnread
    useActiveColor: true
    activeColor: root.unreadColor
    tooltipText: Model.tooltip({ feedTitle: news.feedTitle, unread: news.unread, state: news.state, items: news.items.length })
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) news.refresh()
      else if (buttonCode === Qt.MiddleButton) news.markAllRead()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------------ popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.view === "reader") {
          if (dx < 0) root.backToList()
          else if (dy !== 0) root.scrollReader(dy)
          return
        }
        if (dx > 0) { root.cursorActive = true; root.activateCursor(); return }
        if (!root.cursorActive) { root.cursorActive = true; root.ensureCursor(); return }
        root.moveCursor(dy)
      }
      onActivateRequested: {
        if (root.view === "reader") root.activateCursor()
        else if (root.cursorActive) root.activateCursor()
        else { root.cursorActive = true; root.ensureCursor() }
      }
      onCloseRequested: root.handleClose()
      onDeleteRequested: root.toggleReadAtCursor()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") news.refresh()
        else if (t === "a" || t === "A") news.markAllRead()
        else if (t === "o" || t === "O") root.openInBrowser()
        else if (t === "\b" && root.view === "reader") root.backToList()
        else if (t === "g") { if (panelFlick) panelFlick.contentY = 0 }
        else if (t === "G") { if (panelFlick) panelFlick.contentY = Math.max(0, panelFlick.contentHeight - panelFlick.height) }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------------------------------------------------------- hero
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // Reached from the hero's Components, where `root` is the hero.
            readonly property color urgentColor: root.unreadColor
            readonly property bool lit: root.hasNews

            PanelHero {
              id: hero
              width: parent.width
              title: news.feedTitle
              meta: Model.heroMeta({
                refreshing: news.refreshing, items: news.items.length, state: news.state,
                unread: news.unread, source: news.source, offline: news.offline, fetchedTs: news.fetchedTs
              })
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: root.glyph
                  color: header.lit ? header.urgentColor : hero.foreground
                  font.family: hero.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
              trailingControl: Component {
                Row {
                  spacing: Style.space(4)

                  PanelActionButton {
                    iconText: "󰑐"
                    tooltipText: "Refresh (r)"
                    foreground: hero.foreground
                    fontFamily: hero.fontFamily
                    enabled: !news.refreshing
                    onClicked: news.refresh()
                  }

                  PanelActionButton {
                    iconText: "󰄬"
                    tooltipText: "Mark all read (a)"
                    foreground: hero.foreground
                    fontFamily: hero.fontFamily
                    visible: header.lit
                    enabled: !news.busy
                    onClicked: news.markAllRead()
                  }
                }
              }
            }
          }

          // -------------------------------------------------- status lines
          Text {
            visible: news.message !== "" || news.actionStatus !== ""
            width: parent.width
            text: news.actionStatus !== "" ? news.actionStatus : news.message
            color: news.state === "error" && news.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: news.items.length === 0
            width: parent.width
            text: news.state === "error" ? "Press r to try again."
                : (news.refreshing || news.state === "loading") ? "Fetching news…"
                : "Nothing published yet."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(12)
            bottomPadding: Style.space(12)
          }

          PanelSeparator {
            visible: news.items.length > 0
            foreground: root.foreground
          }

          // ------------------------------------------------------ post list
          Column {
            id: itemColumn
            visible: root.view === "list" && news.items.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: news.items
              NewsRow {
                required property var modelData
                required property int index
                width: itemColumn.width
                item: modelData
                rowIndex: index
              }
            }
          }

          // --------------------------------------------------------- reader
          Column {
            id: reader
            visible: root.view === "reader" && root.readerLive !== null
            width: parent.width
            spacing: Style.space(10)

            Button {
              text: "All news"
              iconText: "󰁍"
              tooltipText: "Back (h, Esc)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.backToList()
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.readerLive ? String(root.readerLive.title || "") : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              wrapMode: Text.WordWrap
              lineHeight: 1.15
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: Model.itemMeta(root.readerLive).toUpperCase()
              visible: text !== ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }

            PanelSeparator { foreground: root.foreground }

            Column {
              width: parent.width
              spacing: Style.space(10)

              Repeater {
                model: root.readerLive ? root.readerLive.blocks : []
                BlockText {
                  required property var modelData
                  width: parent ? parent.width : 0
                  block: modelData
                }
              }
            }

            PanelSeparator {
              visible: root.readerLive && root.readerLive.links && root.readerLive.links.length > 0
              foreground: root.foreground
            }

            Column {
              visible: root.readerLive && root.readerLive.links && root.readerLive.links.length > 0
              width: parent.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "LINKS IN THIS POST"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Column {
                id: linkColumn
                width: parent.width
                spacing: Style.space(2)

                Repeater {
                  model: root.readerLive ? root.readerLive.links : []
                  LinkRow {
                    required property var modelData
                    required property int index
                    width: linkColumn.width
                    link: modelData
                    rowIndex: index
                  }
                }
              }
            }

            PanelSeparator { foreground: root.foreground }

            Row {
              spacing: Style.space(8)

              Button {
                text: "Open in browser"
                iconText: "󰖟"
                tooltipText: "Enter, o"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: news.openItem(root.readerLive)
              }

              Button {
                text: root.readerLive && root.readerLive.read ? "Mark unread" : "Mark read"
                iconText: root.readerLive && root.readerLive.read ? "󰄱" : "󰄬"
                tooltipText: "x"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.readerLive) news.toggleRead(root.readerLive.id)
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component NewsRow: CursorSurface {
    id: newsRow
    property var item: null
    property int rowIndex: 0
    readonly property bool unread: item ? !item.read : false

    hasCursor: root.cursorActive && root.view === "list" && root.itemIndex === rowIndex
    foreground: root.foreground

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      onEntered: root.setItemCursor(newsRow.rowIndex)
      onClicked: function(mouse) {
        if (mouse.button === Qt.MiddleButton) news.openItem(newsRow.item)
        else root.openReader(newsRow.item)
      }
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(10)

      // Unread marker. Stays in the layout when read so titles line up.
      Rectangle {
        Layout.alignment: Qt.AlignTop
        Layout.topMargin: Style.space(5)
        width: Style.space(7)
        height: Style.space(7)
        radius: width / 2
        color: newsRow.unread ? root.unreadColor : "transparent"
        border.width: newsRow.unread ? 0 : 1
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: newsRow.item ? String(newsRow.item.title || "Untitled") : ""
          color: newsRow.unread ? root.foreground : root.soft
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: newsRow.unread
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: Model.itemMeta(newsRow.item)
          visible: text !== ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: newsRow.item ? String(newsRow.item.summary || "") : ""
          visible: text !== ""
          color: newsRow.unread ? root.soft : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
          lineHeight: 1.15
        }
      }

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        iconText: "󰖟"
        tooltipText: "Open in browser"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: news.openItem(newsRow.item)
      }
    }
  }

  component LinkRow: CursorSurface {
    id: linkRow
    property var link: null
    property int rowIndex: 0

    hasCursor: root.linkHover === rowIndex
    foreground: root.foreground
    implicitHeight: linkContent.implicitHeight + Style.space(8)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.linkHover = linkRow.rowIndex
      onExited: if (root.linkHover === linkRow.rowIndex) root.linkHover = -1
      onClicked: news.openUrl(linkRow.link ? linkRow.link.href : "")
    }

    RowLayout {
      id: linkContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: "󰌷"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: linkRow.link ? String(linkRow.link.text || linkRow.link.href) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        Layout.maximumWidth: linkContent.width * 0.45
        textFormat: Text.PlainText
        text: linkRow.link ? String(linkRow.link.href).replace(/^https?:\/\//, "").replace(/\/$/, "") : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }
  }

  component BlockText: Item {
    id: blockItem
    property var block: null
    readonly property string kind: block ? String(block.kind || "p") : "p"
    readonly property bool isCode: kind === "code"
    readonly property bool isQuote: kind === "quote"
    readonly property bool isHeading: kind === "heading"
    readonly property bool isItem: kind === "item"
    readonly property real leftInset: isQuote ? Style.space(12) : (isItem ? Style.space(8) : (isCode ? Style.space(8) : 0))
    readonly property real rightInset: isCode ? Style.space(8) : 0
    readonly property real verticalInset: isCode ? Style.space(6) : 0

    implicitHeight: blockText.implicitHeight + verticalInset * 2

    Rectangle {
      visible: blockItem.isCode
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Style.normalFillFor(root.foreground, root.accent)
    }

    Rectangle {
      visible: blockItem.isQuote
      width: Style.space(2)
      height: parent.height
      color: root.dim
    }

    Text {
      id: blockText
      x: blockItem.leftInset
      y: blockItem.verticalInset
      width: parent.width - blockItem.leftInset - blockItem.rightInset
      textFormat: Text.PlainText
      text: Model.blockPrefix(blockItem.block) + (blockItem.block ? String(blockItem.block.text || "") : "")
      color: blockItem.isQuote ? root.soft : root.foreground
      font.family: root.fontFamily
      font.pixelSize: blockItem.isHeading ? Style.font.title : Style.font.body
      font.bold: blockItem.isHeading
      font.italic: blockItem.isQuote
      wrapMode: blockItem.isCode ? Text.WrapAnywhere : Text.WordWrap
      lineHeight: blockItem.isCode ? 1.2 : 1.35
    }
  }
}
