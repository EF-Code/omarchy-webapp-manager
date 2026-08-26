.pragma library

var MAX_APPS = 256

function text(value, limit) {
  var result = String(value === undefined || value === null ? "" : value)
  if (result.length > limit) return result.slice(0, limit)
  return result
}

function parseResponse(raw) {
  try {
    var value = JSON.parse(String(raw || ""))
    return value && typeof value === "object" ? value : { ok: false, error: { message: "Invalid helper response" } }
  } catch (error) {
    return { ok: false, error: { message: "Invalid helper response" } }
  }
}

function normalizeApp(value) {
  var app = value && typeof value === "object" ? value : {}
  return {
    desktopFile: text(app.desktopFile, 512),
    desktopId: text(app.desktopId, 160),
    name: text(app.name || app.desktopId || "Unnamed web app", 120),
    url: text(app.url, 2048),
    exec: text(app.exec, 512),
    icon: text(app.icon, 256),
    iconState: text(app.iconState || "unknown", 32),
    mimeTypes: text(app.mimeTypes, 512),
    kind: app.kind === "handler" ? "handler" : "webapp",
    status: text(app.status || "unknown", 32)
  }
}

function normalizeApps(values) {
  var result = []
  if (!Array.isArray(values)) return result
  for (var i = 0; i < values.length && result.length < MAX_APPS; i++) {
    var app = normalizeApp(values[i])
    if (app.desktopFile !== "") result.push(app)
  }
  result.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return result
}

function filteredApps(values, query) {
  var apps = Array.isArray(values) ? values : []
  var needle = String(query || "").trim().toLowerCase()
  if (needle === "") return apps
  return apps.filter(function(app) {
    return String(app.name).toLowerCase().indexOf(needle) !== -1
      || String(app.url).toLowerCase().indexOf(needle) !== -1
      || String(app.desktopId).toLowerCase().indexOf(needle) !== -1
  })
}

function normalizeUrl(value) {
  var raw = text(value, 2048).trim()
  if (raw === "") return { ok: false, message: "Enter a URL." }
  if (!/^https?:\/\//i.test(raw)) raw = "https://" + raw
  if (!/^https?:\/\/[^\s]+$/i.test(raw)) return { ok: false, message: "Use a valid http:// or https:// URL." }
  return { ok: true, value: raw }
}

function normalizeName(value) {
  var raw = text(value, 120).trim()
  if (raw === "") return { ok: false, message: "Enter an app name." }
  if (raw === "." || raw === ".." || raw === "all") return { ok: false, message: "Choose a different app name." }
  if (/[\u0000-\u001f\u007f/\\]/.test(raw)) return { ok: false, message: "The app name contains an unsafe character." }
  return { ok: true, value: raw }
}

function normalizeIcon(value) {
  var raw = text(value, 2048).trim()
  if (raw === "") return { ok: true, value: "" }
  if (/^https?:\/\/[^\s]+$/i.test(raw)) return { ok: true, value: raw }
  if (/^[A-Za-z0-9._-]+$/.test(raw)) return { ok: true, value: raw }
  return { ok: false, message: "Use an icon name or an http(s) icon URL." }
}

function iconText(app) {
  return app && app.icon ? String(app.icon).slice(0, 1).toUpperCase() : "󰖟"
}

function statusLabel(app) {
  if (!app) return "Unknown"
  if (app.status === "healthy") return "Healthy"
  if (app.status === "handler") return "Protocol handler"
  if (app.status === "missing-icon") return "Missing icon"
  if (app.status === "invalid-url") return "Invalid URL"
  return "Needs attention"
}

function summary(values) {
  var count = Array.isArray(values) ? values.length : 0
  return count + " web app" + (count === 1 ? "" : "s")
}

function keyHelp() {
  return [
    { key: "↑↓ / j k", label: "select web app" },
    { key: "Enter / l", label: "launch selected app" },
    { key: "a", label: "add web app" },
    { key: "d / x", label: "remove selected app" },
    { key: "r", label: "refresh" },
    { key: "Esc", label: "close" }
  ]
}

if (typeof module !== "undefined") {
  module.exports = {
    parseResponse, normalizeApps, filteredApps, normalizeUrl,
    normalizeName, normalizeIcon, iconText, statusLabel, summary, keyHelp
  }
}
