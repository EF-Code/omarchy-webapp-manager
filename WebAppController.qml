import QtQuick
import Quickshell
import Quickshell.Io
import "WebAppModel.js" as Model

QtObject {
  id: root

  property var apps: []
  property bool busy: false
  property bool statusWarning: false
  property string statusMessage: ""
  property string pendingAction: ""
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("scripts/webapp-managerctl")).replace(/^file:\/\//, ""))

  signal operationFinished(string action, bool success)

  function run(args, action) {
    if (process.running) {
      statusWarning = true
      statusMessage = "Another Web App Manager operation is still running."
      return false
    }
    pendingAction = action
    busy = true
    process.command = [root.helperPath].concat(args)
    process.running = true
    return true
  }

  function refresh() { run(["scan"], "scan") }

  function install(name, url, icon) {
    return run(["install", "--name", String(name), "--url", String(url), "--icon", String(icon || "")], "install")
  }

  function remove(app) {
    if (!app || !app.desktopFile) return false
    return run(["remove", "--desktop-file", String(app.desktopFile)], "remove")
  }

  function launch(app) {
    if (!app || !app.desktopFile) return false
    return run(["launch", "--desktop-file", String(app.desktopFile)], "launch")
  }

  function helperMessage(value, fallback) {
    return value && value.error && value.error.message ? String(value.error.message) : fallback
  }

  function finish(action, exitCode, value) {
    busy = false
    if (exitCode !== 0 || !value || value.ok !== true) {
      statusWarning = true
      statusMessage = helperMessage(value, "The Web App Manager helper failed.")
      operationFinished(action, false)
      return
    }

    statusWarning = false
    if (action === "scan") {
      apps = Model.normalizeApps(value.apps)
      statusMessage = Model.summary(apps)
      operationFinished(action, true)
      return
    }

    if (action === "launch") {
      statusMessage = "Launched web app."
      operationFinished(action, true)
      return
    }

    statusMessage = action === "install" ? "Web app installed." : "Web app removed."
    operationFinished(action, true)
    Qt.callLater(root.refresh)
  }

  Process {
    id: process
    command: []

    stdout: StdioCollector {
      id: stdoutCollector
      waitForEnd: true
    }

    stderr: StdioCollector {
      id: stderrCollector
      waitForEnd: true
    }

    onExited: function(exitCode) {
      var value = Model.parseResponse(stdoutCollector.text)
      if (exitCode !== 0 && value.ok === true) {
        value = { ok: false, error: { message: String(stderrCollector.text || "Helper exited unsuccessfully.").trim() } }
      }
      root.finish(root.pendingAction, exitCode, value)
    }
  }
}
