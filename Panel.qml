import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "WebAppModel.js" as Model

Panel {
  id: root
  moduleName: "io.github.ef-code.webapp-manager"
  ipcTarget: "io.github.ef-code.webapp-manager"
  manageIpc: true

  property var anchorItem: null
  property var hostWidget: null
  property color foreground: bar ? bar.barForeground : Color.foreground
  property color background: Color.menu.background
  property string searchText: ""
  property int selectedIndex: 0
  property bool addOpen: false
  property string draftName: ""
  property string draftUrl: ""
  property string draftIcon: ""
  property var pendingRemove: null
  property bool keyboardReturnPending: false

  property var backend: WebAppController { id: backendObject }
  readonly property var filteredApps: Model.filteredApps(backend.apps, searchText)
  readonly property var selectedApp: filteredApps.length > 0 && selectedIndex >= 0 && selectedIndex < filteredApps.length
    ? filteredApps[selectedIndex] : null

  function open() { controller.show() }
  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }

  function refresh() {
    if (!backend.busy) backend.refresh()
  }

  function select(index) {
    if (filteredApps.length === 0) {
      selectedIndex = 0
      return
    }
    selectedIndex = Math.max(0, Math.min(index, filteredApps.length - 1))
    appList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function moveSelection(delta) {
    if (filteredApps.length === 0) return
    select((selectedIndex + delta + filteredApps.length) % filteredApps.length)
  }

  function beginAdd() {
    pendingRemove = null
    addOpen = true
    draftName = ""
    draftUrl = ""
    draftIcon = ""
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function cancelAdd() {
    addOpen = false
    draftName = ""
    draftUrl = ""
    draftIcon = ""
  }

  function submitAdd() {
    var name = Model.normalizeName(draftName)
    if (!name.ok) { backend.statusWarning = true; backend.statusMessage = name.message; return }
    var url = Model.normalizeUrl(draftUrl)
    if (!url.ok) { backend.statusWarning = true; backend.statusMessage = url.message; return }
    var icon = Model.normalizeIcon(draftIcon)
    if (!icon.ok) { backend.statusWarning = true; backend.statusMessage = icon.message; return }
    backend.install(name.value, url.value, icon.value)
  }

  function requestRemove(app) {
    if (!app || backend.busy) return
    addOpen = false
    pendingRemove = app
  }

  function confirmRemove() {
    if (!pendingRemove) return
    if (backend.remove(pendingRemove)) pendingRemove = null
  }

  function launch(app) {
    if (app && !backend.busy) backend.launch(app)
  }

  function copyUrl(app) {
    if (!app || !app.url) return
    Quickshell.execDetached(["wl-copy", app.url])
    backend.statusWarning = false
    backend.statusMessage = "URL copied to the clipboard."
  }

  function keyText(value) {
    var key = String(value || "").toLowerCase()
    if (key === "j" || key === "down") moveSelection(1)
    else if (key === "k" || key === "up") moveSelection(-1)
    else if (key === "r") refresh()
    else if (key === "a") beginAdd()
    else if (key === "l") launch(selectedApp)
    else if (key === "d" || key === "x") requestRemove(selectedApp)
    else if (key === "c") copyUrl(selectedApp)
    else if (key === "/") searchField.forceActiveFocus()
  }

  onFilteredAppsChanged: select(selectedIndex)
  onOpenedChanged: {
    if (opened) {
      refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      addOpen = false
      pendingRemove = null
    }
  }

  Connections {
    target: backend
    function onOperationFinished(action, success) {
      if (!success) return
      if (action === "install") cancelAdd()
      if (action === "remove") pendingRemove = null
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: fittedContentWidth(Style.space(620))
    contentHeight: fittedContentHeight(contentColumn.implicitHeight, Style.space(650))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || nameField.activeFocus || urlField.activeFocus || iconField.activeFocus || root.addOpen || !!root.pendingRemove
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveSelection(dy)
      }
      onReturnRequested: root.keyboardReturnPending = true
      onActivateRequested: {
        root.keyboardReturnPending = false
        root.launch(root.selectedApp)
      }
      onDeleteRequested: root.requestRemove(root.selectedApp)
      onCloseRequested: root.close()
      onTextKey: function(text) { root.keyText(text) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
          id: contentColumn
          width: panelFlick.width
          spacing: Style.space(10)

          RowLayout {
            Layout.fillWidth: true
            Text {
              text: "WEB APP MANAGER"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Item { Layout.fillWidth: true }
            Button { text: "Refresh"; focusable: true; enabled: !backend.busy; onClicked: root.refresh() }
            Button { text: "?"; focusable: true; onClicked: help.active = !help.active }
          }

          Rectangle {
            Layout.fillWidth: true
            visible: backend.statusMessage !== ""
            implicitHeight: statusText.implicitHeight + Style.space(14)
            color: backend.statusWarning ? Qt.alpha(Color.urgent, 0.16) : Qt.alpha(Color.accent, 0.12)
            radius: Style.cornerRadius
            Text {
              id: statusText
              anchors.fill: parent
              anchors.margins: Style.space(7)
              text: backend.statusMessage
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Loader {
            id: help
            Layout.fillWidth: true
            active: false
            visible: active
            sourceComponent: Component {
              Rectangle {
                width: parent ? parent.width : 0
                implicitHeight: helpColumn.implicitHeight + Style.space(14)
                color: Qt.alpha(root.foreground, 0.06)
                radius: Style.cornerRadius
                ColumnLayout {
                  id: helpColumn
                  anchors.fill: parent
                  anchors.margins: Style.space(7)
                  Repeater {
                    model: Model.keyHelp()
                    RowLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      Text { text: modelData.key; color: Color.accent; font.family: "monospace"; font.pixelSize: Style.font.caption; Layout.preferredWidth: Style.space(100) }
                      Text { text: modelData.label; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                    }
                  }
                }
              }
            }
          }

          RowLayout {
            Layout.fillWidth: true
            TextField {
              id: searchField
              Layout.fillWidth: true
              placeholderText: "Search installed web apps…"
              text: root.searchText
              onTextChanged: { root.searchText = text; root.selectedIndex = 0 }
              activeFocusOnTab: true
            }
            Button { text: "+ Add"; focusable: true; enabled: !backend.busy; onClicked: root.beginAdd() }
          }

          Rectangle {
            Layout.fillWidth: true
            visible: root.addOpen
            color: Qt.alpha(root.foreground, 0.06)
            radius: Style.cornerRadius
            implicitHeight: addColumn.implicitHeight + Style.space(16)

            ColumnLayout {
              id: addColumn
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(7)

              Text { text: "ADD WEB APP"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.subtitle; font.bold: true }
              TextField { id: nameField; Layout.fillWidth: true; placeholderText: "Name, e.g. GitHub"; text: root.draftName; onTextChanged: root.draftName = text; activeFocusOnTab: true }
              TextField { id: urlField; Layout.fillWidth: true; placeholderText: "https://example.com"; text: root.draftUrl; onTextChanged: root.draftUrl = text; activeFocusOnTab: true }
              TextField { id: iconField; Layout.fillWidth: true; placeholderText: "Icon name or URL (optional)"; text: root.draftIcon; onTextChanged: root.draftIcon = text; activeFocusOnTab: true }
              Text { Layout.fillWidth: true; text: "The native Omarchy installer will create the user launcher and fetch an icon when possible."; color: Qt.alpha(root.foreground, 0.68); font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
              RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                Button { text: "Cancel"; focusable: true; onClicked: root.cancelAdd() }
                Button { text: "Install"; focusable: true; enabled: !backend.busy; onClicked: root.submitAdd() }
              }
            }
          }

          Rectangle {
            Layout.fillWidth: true
            visible: !!root.pendingRemove
            color: Qt.alpha(Color.urgent, 0.14)
            radius: Style.cornerRadius
            implicitHeight: removeColumn.implicitHeight + Style.space(16)
            ColumnLayout {
              id: removeColumn
              anchors.fill: parent
              anchors.margins: Style.space(8)
              Text { Layout.fillWidth: true; text: root.pendingRemove ? "Move “" + root.pendingRemove.name + "” to the user trash?" : ""; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; wrapMode: Text.WordWrap }
              Text { Layout.fillWidth: true; text: "The launcher can be restored from the desktop trash. Its icon is left untouched."; color: Qt.alpha(root.foreground, 0.68); font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
              RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                Button { text: "Cancel"; focusable: true; onClicked: root.pendingRemove = null }
                Button { text: "Move to Trash"; focusable: true; enabled: !backend.busy; onClicked: root.confirmRemove() }
              }
            }
          }

          ListView {
            id: appList
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(Style.space(330), Math.max(Style.space(74), contentHeight))
            model: root.filteredApps
            spacing: Style.space(6)
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              required property var modelData
              required property int index
              width: appList.width
              height: Style.space(66)
              radius: Style.cornerRadius
              color: index === root.selectedIndex ? Qt.alpha(Color.accent, 0.18) : Qt.alpha(root.foreground, 0.05)

              MouseArea {
                anchors.fill: parent
                onClicked: root.select(index)
              }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(9)

                Rectangle {
                  Layout.preferredWidth: Style.space(34)
                  Layout.preferredHeight: Style.space(34)
                  radius: Style.cornerRadius
                  color: Qt.alpha(Color.accent, 0.18)
                  Text { anchors.centerIn: parent; text: Model.iconText(modelData); color: Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0
                  Text { Layout.fillWidth: true; text: modelData.name; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true; elide: Text.ElideRight }
                  Text { Layout.fillWidth: true; text: modelData.url || modelData.kind; color: Qt.alpha(root.foreground, 0.66); font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideMiddle }
                }

                Text {
                  text: Model.statusLabel(modelData)
                  color: modelData.status === "healthy" || modelData.status === "handler" ? Color.accent : Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Text {
            Layout.fillWidth: true
            visible: root.filteredApps.length === 0
            text: root.backend.apps.length === 0 ? "No Omarchy web apps found. Add one above to create a launcher." : "No web apps match this search."
            color: Qt.alpha(root.foreground, 0.68)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Rectangle {
            Layout.fillWidth: true
            visible: !!root.selectedApp && !root.addOpen && !root.pendingRemove
            color: Qt.alpha(root.foreground, 0.06)
            radius: Style.cornerRadius
            implicitHeight: detailColumn.implicitHeight + Style.space(16)
            ColumnLayout {
              id: detailColumn
              anchors.fill: parent
              anchors.margins: Style.space(8)
              Text { text: root.selectedApp ? root.selectedApp.name : ""; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.subtitle; font.bold: true }
              Text { Layout.fillWidth: true; text: root.selectedApp ? (root.selectedApp.url || "Protocol handler") : ""; color: Qt.alpha(root.foreground, 0.72); font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideMiddle }
              RowLayout {
                Layout.fillWidth: true
                Button { text: "Launch"; focusable: true; enabled: !backend.busy; onClicked: root.launch(root.selectedApp) }
                Button { text: "Copy URL"; focusable: true; enabled: !!(root.selectedApp && root.selectedApp.url); onClicked: root.copyUrl(root.selectedApp) }
                Button { text: "Remove"; focusable: true; enabled: !backend.busy; onClicked: root.requestRemove(root.selectedApp) }
                Item { Layout.fillWidth: true }
              }
            }
          }

          Text {
            Layout.fillWidth: true
            text: "Enter launch · a add · d remove · r refresh · Esc close"
            color: Qt.alpha(root.foreground, 0.54)
            font.family: "monospace"
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
