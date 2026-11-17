import QtQuick
import Quickshell
import Quickshell.Io

// State for the llama.cpp router (local-llm.service, see `bin/lllm --help`).
// Model ids from the server are validated and only ever passed as argv or
// JSON to curl; the few `sh -c` commands here are fixed strings.
Item {
  id: root

  property var settings: ({})
  // True while the panel is open: poll fast and read VRAM.
  property bool watching: false

  readonly property int port: intSetting("port", 8080, 1, 65535)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 5, 2, 300)
  readonly property string baseUrl: "http://127.0.0.1:" + port
  readonly property string unitName: "local-llm.service"
  // Written by `lllm setup --api-key`: one "Authorization: Bearer …" line,
  // handed to curl as `-H @file` so the key never shows up in argv.
  readonly property string authHeaderPath: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/local-llm/api-key.header"
  property bool authRequired: false
  function authArgs() { return authRequired ? ["-H", "@" + authHeaderPath] : [] }

  property bool online: false
  property bool polled: false
  // systemd's view while the HTTP API is down: inactive | failed | activating | unknown
  property string unitState: "unknown"
  // False until `lllm setup` has installed local-llm.service.
  property bool installed: true
  // The CLI ships with the plugin; run it from here so it works without PATH changes.
  readonly property string cliPath: String(Qt.resolvedUrl("bin/lllm")).replace(/^file:\/\//, "")
  property var models: []          // [{ id, status, vision, aliases }]
  property int vramMiB: -1         // llama-server VRAM, -1 = unknown
  property int gpuUsedMiB: 0       // whole GPU, every process
  property int gpuTotalMiB: 0
  // Share of the card the model holds (drives the icon's upper triangle) and
  // how full the card is overall (the gauge turns to the warning colour).
  readonly property real vramFraction: gpuTotalMiB > 0 && vramMiB > 0 ? Math.min(1, vramMiB / gpuTotalMiB) : 0
  readonly property bool gpuNearlyFull: gpuTotalMiB > 0 && vramMiB > 0 && gpuUsedMiB / gpuTotalMiB > 0.92
  // True while the model process is busy (prompt processing or generating).
  // Read from /proc CPU time, because querying the model (/slots) would wake a sleeping one.
  property bool thinking: false
  property var _childPids: []
  property var _lastTicks: ({})
  property double _lastTickTime: 0
  property string lastError: ""

  // Optimistic state so clicks show immediately: id -> "loading" | "unloading"
  property var pending: ({})
  // -1 follow reality, 0/1 while a stop/start is settling
  property int desiredServer: -1

  readonly property bool serverOn: desiredServer === -1 ? online : desiredServer === 1
  readonly property bool busy: actionProcess.running || unitProcess.running
  readonly property var loadedModel: {
    for (var i = 0; i < models.length; i++) {
      var st = statusOf(models[i])
      if (st === "loaded" || st === "sleeping") return models[i]
    }
    return null
  }
  readonly property bool anyLoading: {
    for (var i = 0; i < models.length; i++)
      if (statusOf(models[i]) === "loading") return true
    return false
  }
  // After sleep-idle-seconds the router reports "sleeping": weights freed, ~250 MB CUDA context kept.
  readonly property bool loadedAsleep: loadedModel !== null && statusOf(loadedModel) === "sleeping"

  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined || v === null ? fallback : v
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function statusOf(m) {
    if (!m) return "unloaded"
    var p = pending[m.id]
    return p !== undefined ? p : m.status
  }

  function clip(s, n) {
    s = String(s === undefined || s === null ? "" : s).replace(/[\u0000-\u001f\u007f]/g, "")
    return s.length > n ? s.substring(0, n - 1) + "…" : s
  }

  function parseModels(raw) {
    var parsed
    try { parsed = JSON.parse(raw) } catch (e) { return null }
    if (!parsed || !Array.isArray(parsed.data)) return null
    var known = { "loaded": 1, "sleeping": 1, "unloaded": 1, "loading": 1, "unloading": 1, "failed": 1 }
    var out = []
    for (var i = 0; i < parsed.data.length && out.length < 200; i++) {
      var m = parsed.data[i]
      if (!m || typeof m.id !== "string" || m.id === "" || m.id.length > 200) continue
      var st = m.status && typeof m.status.value === "string" && known[m.status.value] ? m.status.value : "unloaded"
      var args = m.status && Array.isArray(m.status.args) ? m.status.args : []
      var aliases = []
      if (Array.isArray(m.aliases))
        for (var j = 0; j < m.aliases.length && aliases.length < 4; j++)
          if (typeof m.aliases[j] === "string") aliases.push(clip(m.aliases[j], 60))
      out.push({ id: m.id, status: st, vision: args.indexOf("--mmproj") !== -1, aliases: aliases })
    }
    return out
  }

  // rescan=true also picks up models added or removed on disk (the
  // local-llm-reload.path unit normally does that already).
  function refresh(rescan) {
    if (pollProcess.running) return
    pollProcess.command = ["curl", "-sf", "--max-time", "3", "--max-filesize", "2000000"].concat(
                           authArgs(), [baseUrl + (rescan ? "/models?reload=1" : "/models")])
    pollProcess.running = true
  }

  function applyModels(list) {
    // Drop optimistic entries once the server agrees (or the model vanished).
    var next = ({})
    for (var id in pending) {
      var m = null
      for (var i = 0; i < list.length; i++) if (list[i].id === id) m = list[i]
      if (!m) continue
      var done = pending[id] === "loading"
        ? (m.status === "loaded" || m.status === "sleeping")
        : m.status === "unloaded"
      if (!done && m.status !== "failed") next[id] = pending[id]
    }
    pending = next
    models = list
  }

  function post(path, modelId) {
    if (actionProcess.running) return
    actionProcess.command = ["curl", "-sf", "--max-time", "15", "-X", "POST",
                             "-H", "Content-Type: application/json"].concat(authArgs(), [
                             "-d", JSON.stringify({ model: modelId }), baseUrl + path])
    actionProcess.running = true
  }

  function setPending(id, value) {
    var p = Object.assign({}, pending)
    p[id] = value
    pending = p
    pendingTimeout.restart()
  }

  function loadModel(m) {
    if (!m || !online) return
    setPending(m.id, "loading")
    post("/models/load", m.id)
  }

  function unloadModel(m) {
    if (!m || !online) return
    setPending(m.id, "unloading")
    post("/models/unload", m.id)
  }

  function toggleModel(m) {
    var st = statusOf(m)
    if (st === "loaded" || st === "sleeping" || st === "loading") unloadModel(m)
    else loadModel(m)
  }

  function unloadAll() {
    if (loadedModel) unloadModel(loadedModel)
  }

  function setServer(on) {
    if (on && !online && !installed) { runCli("setup"); return }
    if (unitProcess.running) return
    desiredServer = on ? 1 : 0
    lastError = ""
    unitProcess.command = ["systemctl", "--user", on ? "start" : "stop", unitName]
    unitProcess.running = true
  }

  function toggleServer() { setServer(!serverOn) }

  function openWebUi() {
    if (online) Qt.openUrlExternally(baseUrl)
  }

  // Run a subcommand of the bundled CLI in a floating terminal. `sub` is
  // always one of the fixed words below, never external text.
  function runCli(sub) {
    if (!/^(setup|pull|fit|edit|logs|sandbox shell)$/.test(sub)) return
    var quoted = "'" + cliPath.replace(/'/g, "'\\''") + "'"
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", quoted + " " + sub])
  }

  FileView {
    id: authHeaderView
    path: root.authHeaderPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.authRequired = text().indexOf("Authorization:") === 0; root.refresh(false) }
    onLoadFailed: { root.authRequired = false; root.refresh(false) }
  }

  Timer {
    id: pollTimer
    interval: root.anyLoading || Object.keys(root.pending).length > 0 || root.desiredServer !== -1
      ? 1000 : (root.watching ? 2000 : root.refreshIntervalSec * 1000)
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onWatchingChanged: if (watching) { refresh(true); vramTimer.restart() }

  Timer {
    // Feeds the VRAM gauge in the bar icon, so it runs with the panel closed
    // too — but only while a model is loaded (or asleep).
    id: vramTimer
    interval: root.watching ? 2000 : 5000
    repeat: true
    triggeredOnStart: true
    running: root.online && root.loadedModel !== null
    onTriggered: if (!vramProcess.running) vramProcess.running = true
    onRunningChanged: if (!running) { root.vramMiB = -1; root.gpuUsedMiB = 0 }
  }

  Timer {
    // A load can take a while for big models, but never forever.
    id: pendingTimeout
    interval: 180000
    onTriggered: root.pending = ({})
  }

  Timer {
    id: settleTimeout
    interval: 20000
    running: root.desiredServer !== -1
    onTriggered: root.desiredServer = -1
  }

  Process {
    id: pollProcess
    command: []
    stdout: StdioCollector { id: pollOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.polled = true
      if (exitCode === 0) {
        var list = root.parseModels(String(pollOut.text || ""))
        if (list !== null) {
          root.online = true
          root.installed = true
          root.unitState = "active"
          if (root.desiredServer === 1) root.desiredServer = -1
          root.applyModels(list)
          return
        }
      }
      root.online = false
      root.models = []
      root.pending = ({})
      if (root.desiredServer === 0) root.desiredServer = -1
      if (!unitStateProcess.running) unitStateProcess.running = true
    }
  }

  Process {
    id: unitStateProcess
    command: ["systemctl", "--user", "show", "-p", "LoadState", "-p", "ActiveState", root.unitName]
    stdout: StdioCollector { id: unitStateOut; waitForEnd: true }
    onExited: {
      var out = String(unitStateOut.text || "")
      var active = out.match(/^ActiveState=(\w+)$/m)
      var load = out.match(/^LoadState=([\w-]+)$/m)
      var s = active ? active[1] : ""
      root.unitState = /^(active|inactive|failed|activating|deactivating)$/.test(s) ? s : "unknown"
      root.installed = !(load && load[1] === "not-found")
    }
  }

  Process {
    id: actionProcess
    command: []
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.pending = ({})
        root.lastError = "llama-server request failed (curl exit " + exitCode + ")"  // i18n: ignore
      } else {
        root.lastError = ""
      }
      root.refresh()
    }
  }

  Process {
    id: unitProcess
    command: []
    stderr: StdioCollector { id: unitErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.desiredServer = -1
        root.lastError = root.clip(String(unitErr.text || "systemctl failed").trim(), 160)
      }
      root.refresh()
    }
  }

  Process {
    id: vramProcess
    // Fixed command: whole-GPU usage, a separator, then per-process usage.
    command: ["sh", "-c", "nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits; echo ---; nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader,nounits"]
    stdout: StdioCollector { id: vramOut; waitForEnd: true }
    onExited: function(exitCode) {
      var halves = String(vramOut.text || "").split("---")
      if (exitCode !== 0 || halves.length !== 2) { root.vramMiB = -1; return }
      var used = 0, totalMem = 0
      var gpus = halves[0].split("\n")
      for (var g = 0; g < gpus.length && g < 16; g++) {
        var m = gpus[g].split(",")
        if (m.length !== 2) continue
        var u = parseInt(m[0], 10), t = parseInt(m[1], 10)
        if (isFinite(u) && isFinite(t)) { used += u; totalMem += t }
      }
      var llama = 0
      var lines = halves[1].split("\n")
      for (var i = 0; i < lines.length && i < 256; i++) {
        var parts = lines[i].split(",")
        if (parts.length < 2) continue
        if (/llama-server\s*$/.test(parts[0].trim())) {
          var mib = parseInt(parts[parts.length - 1], 10)
          if (isFinite(mib)) llama += mib
        }
      }
      root.gpuUsedMiB = used
      root.gpuTotalMiB = totalMem
      root.vramMiB = llama
    }
  }

  // ---- thinking detection: CPU time of the router's child (model) processes ----
  Timer {
    id: busyTimer
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.online && root.loadedModel !== null
    onRunningChanged: if (!running) { root.thinking = false; root._childPids = []; root._lastTicks = ({}) }
    onTriggered: {
      if (root._childPids.length === 0) { if (!pidProcess.running) pidProcess.running = true; return }
      if (statProcess.running) return
      var paths = []
      for (var i = 0; i < root._childPids.length; i++) paths.push("/proc/" + root._childPids[i] + "/stat")
      statProcess.command = ["cat"].concat(paths)
      statProcess.running = true
    }
  }

  // Re-discover the model process when a different model is loaded. (loadedModel
  // itself is a fresh object after every poll, so key on the id.)
  readonly property string loadedId: loadedModel ? loadedModel.id : ""
  property int _idleSamples: 0
  onLoadedIdChanged: { _childPids = []; _lastTicks = ({}); thinking = false }

  Process {
    id: pidProcess
    // Fixed command; no external values are interpolated.
    command: ["sh", "-c", "pgrep -P \"$(systemctl --user show -p MainPID --value local-llm.service)\""]
    stdout: StdioCollector { id: pidOut; waitForEnd: true }
    onExited: {
      var pids = []
      var lines = String(pidOut.text || "").split("\n")
      for (var i = 0; i < lines.length && pids.length < 8; i++)
        if (/^\d{1,9}$/.test(lines[i].trim())) pids.push(lines[i].trim())
      root._childPids = pids
    }
  }

  Process {
    id: statProcess
    command: []
    stdout: StdioCollector { id: statOut; waitForEnd: true }
    onExited: function(exitCode) {
      var now = Date.now()
      var ticks = ({})
      var lines = String(statOut.text || "").split("\n")
      for (var i = 0; i < lines.length && i < 8; i++) {
        var line = lines[i]
        var close = line.lastIndexOf(")")
        if (close < 0) continue
        var pid = line.substring(0, line.indexOf(" "))
        var f = line.substring(close + 2).split(" ")
        // after "(comm) ": state ppid ... utime is field 14, stime 15 → indices 11, 12
        var t = parseInt(f[11], 10) + parseInt(f[12], 10)
        if (isFinite(t)) ticks[pid] = t
      }
      if (exitCode !== 0 || Object.keys(ticks).length === 0) {
        root._childPids = []   // process gone; rediscover next tick
        root.thinking = false
        return
      }
      var dt = (now - root._lastTickTime) / 1000
      var busiest = -1
      for (var p in ticks)
        if (root._lastTicks[p] !== undefined && dt > 0)
          busiest = Math.max(busiest, (ticks[p] - root._lastTicks[p]) / dt)
      // Idle model ≈ 0 ticks/s, generating ≈ 100 (one core spinning on the GPU).
      // No previous sample (busiest < 0): keep the current state. Leaving
      // "thinking" needs two idle samples so pauses between tokens don't flicker.
      if (busiest > 30) {
        root.thinking = true
        root._idleSamples = 0
      } else if (busiest >= 0 && ++root._idleSamples >= 2) {
        root.thinking = false
      }
      root._lastTicks = ticks
      root._lastTickTime = now
    }
  }
}
