import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Owns the feed: runs bin/omapress, holds the parsed posts and read state,
// schedules refreshes, and announces new posts. The panel only renders.
Item {
  id: root

  property var settings: ({})

  property string state: "loading"     // loading | ready | error
  property string message: ""
  property string source: "none"       // network | cache | none
  property bool offline: false
  property var feed: ({})
  property var items: []
  property int unread: 0
  property double fetchedTs: 0
  property bool refreshing: false
  property bool everLoaded: false
  property string actionStatus: ""

  // The configured feed URL after policy; "" means the setting is unusable
  // and no fetch runs. An empty setting means the default feed.
  readonly property string feedUrl: {
    var configured = String(setting("feedUrl", "")).trim()
    return Model.safeFeedUrl(configured === "" ? "https://omarchy.org/news/rss.xml" : configured)
  }
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 1800, 300, 86400)
  readonly property int maxItems: intSetting("maxItems", 30, 5, Model.MAX_ITEMS)
  readonly property bool notifyNewPosts: boolSetting("notifyNewPosts", true)
  readonly property bool busy: fetchProcess.running || markProcess.running
  readonly property string feedTitle: String(feed && feed.title ? feed.title : "") || "Omarchy News"
  readonly property int maxPayloadChars: Model.MAX_PAYLOAD_CHARS
  readonly property string feedLink: Model.safeLink(feed && feed.link ? feed.link : "") || "https://omarchy.org/news"

  // Resolve the helper next to this file so a clone runs its own copy.
  // resolvedUrl percent-encodes; argv wants the bytes.
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("bin/omapress")).replace(/^file:\/\//, ""))

  // Deadlines. The helper gets a --budget a few seconds under the QML
  // deadline so it unwinds on its own (running its cleanup) before the
  // watchdog ever has to signal it; --own-process-group lets one group
  // signal take the helper and anything it started down together.
  readonly property int fetchTimeoutMs: 45000
  readonly property int markTimeoutMs: 15000
  readonly property int maxQueuedMarks: 32

  function helperArgv(args, timeoutMs) {
    var budget = Math.max(5, Math.round(timeoutMs / 1000) - 5)
    return ["python3", helperPath, "--budget", String(budget), "--own-process-group"].concat(args)
  }

  signal itemsReplaced()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "boolean") return value
    var s = String(value).toLowerCase()
    if (s === "true" || s === "1" || s === "yes" || s === "on") return true
    if (s === "false" || s === "0" || s === "no" || s === "off") return false
    return fallback
  }

  function refresh() {
    if (fetchProcess.running) return
    if (feedUrl === "") {
      state = "error"
      message = "Feed URL must be https and name a public host"
      return
    }
    refreshing = true
    fetchTimedOut = false
    fetchProcess.command = helperArgv(["fetch", "--url", feedUrl, "--max", String(maxItems)], fetchTimeoutMs)
    fetchProcess.running = true
    watchdog.watch(fetchProcess, "Feed fetch", fetchTimeoutMs)
  }

  property bool fetchTimedOut: false
  property bool markTimedOut: false

  // Refresh only when the last fetch is older than `maxAgeSec`; used on
  // panel open so a click never spams the server.
  function refreshIfStale(maxAgeSec) {
    if (!everLoaded) { refresh(); return }
    var age = Date.now() / 1000 - fetchedTs
    if (age > maxAgeSec) refresh()
  }

  function itemById(id) {
    var index = Model.itemIndexById(items, id)
    return index === -1 ? null : items[index]
  }

  // Flip the local flag right away so the row and the badge react on click;
  // the helper persists it and echoes the authoritative state back.
  function setReadLocally(id, read) {
    var next = items.slice()
    var index = Model.itemIndexById(next, id)
    if (index === -1) return
    if (next[index].read === read) return
    var copy = {}
    for (var key in next[index]) copy[key] = next[index][key]
    copy.read = read
    next[index] = copy
    items = next
    unread = Model.unreadCount(items)
  }

  function markRead(id) {
    if (!id) return
    setReadLocally(id, true)
    runMark(["mark-read", String(id)])
  }

  function markUnread(id) {
    if (!id) return
    setReadLocally(id, false)
    runMark(["mark-unread", String(id)])
  }

  function toggleRead(id) {
    var item = itemById(id)
    if (!item) return
    if (item.read) markUnread(id)
    else markRead(id)
  }

  function markAllRead() {
    if (unread === 0) return
    var next = []
    for (var i = 0; i < items.length; i++) {
      var copy = {}
      for (var key in items[i]) copy[key] = items[i][key]
      copy.read = true
      next.push(copy)
    }
    items = next
    unread = 0
    runMark(["mark-all-read"])
  }

  property var _markQueue: []

  function runMark(args) {
    if (markProcess.running) {
      if (_markQueue.length >= maxQueuedMarks) {
        actionStatus = "Too many pending changes; try again in a moment"
        actionStatusTimer.restart()
        return
      }
      _markQueue = _markQueue.concat([args])
      return
    }
    markTimedOut = false
    markProcess.command = helperArgv(args, markTimeoutMs)
    markProcess.running = true
    watchdog.watch(markProcess, "Saving read state", markTimeoutMs)
  }

  // The one path to the browser. Re-checked here even though the helper
  // filtered the link already: this is the consumer, and the cache between
  // the two is a file.
  function openUrl(url) {
    var target = Model.safeLink(String(url || "").trim())
    if (target === "") return
    Qt.openUrlExternally(target)
  }

  function openItem(item) {
    if (!item) return
    markRead(item.id)
    openUrl(item.link)
  }

  function applyPayload(raw, fromFetch) {
    var parsed = Model.parsePayload(raw)
    if (!parsed.ok) {
      state = everLoaded ? state : "error"
      message = parsed.error
      return
    }
    state = String(parsed.state || "ready")
    message = String(parsed.message || "")
    source = String(parsed.source || "none")
    offline = state === "ready" && source === "cache" && message !== ""
    if (state === "ready") {
      feed = parsed.feed
      items = parsed.items
      unread = parsed.unread
      fetchedTs = parsed.fetchedTs
      everLoaded = true
      itemsReplaced()
      if (fromFetch && notifyNewPosts && parsed.newIds.length > 0) announce(parsed.items, parsed.newIds)
    }
  }

  function announce(list, newIds) {
    var picks = Model.itemsToNotify(list, newIds, 3)
    var total = 0
    for (var i = 0; i < newIds.length; i++) {
      var item = itemById(newIds[i])
      if (item && !item.read) total++
    }
    if (picks.length === 0) return
    if (total > picks.length) {
      Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Omapress", "-g", "\uf1ea", "-u", "low",
        total + " new posts on " + Model.notifyText(feedTitle, 120), "Open the news panel to catch up",
        "--exec", "omarchy-shell", "shell", "summon", "io.github.renerocksai.omapress", "{}"])
      return
    }
    for (var j = 0; j < picks.length; j++) {
      var pick = picks[j]
      var args = ["omarchy-notification-send", "--app-name", "Omapress", "-g", "\uf1ea", "-u", "low",
        Model.notifyText(pick.title, 200) || "New post", Model.notifyText(pick.summary) || Model.notifyText(feedTitle, 120)]
      var link = Model.safeLink(String(pick.link || ""))
      if (link !== "") args = args.concat(["--exec", "xdg-open", link])
      Quickshell.execDetached(args)
    }
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 160 ? value.substring(0, 157) + "…" : value
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // Right after login the first fetch often races the network coming up.
    // Retry a few times quickly until something has loaded.
    id: startupRamp
    property int ticks: 0
    interval: 5000
    repeat: true
    running: true
    onTriggered: {
      ticks += 1
      if (root.everLoaded || ticks >= 6) startupRamp.running = false
      else root.refresh()
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    onTriggered: root.actionStatus = ""
  }

  ProcessWatchdog {
    id: watchdog
    onTimedOut: function(proc, label) {
      if (proc === fetchProcess) root.fetchTimedOut = true
      else if (proc === markProcess) root.markTimedOut = true
    }
  }

  Component.onDestruction: watchdog.terminateAll()

  // StdioCollector cannot be capped from QML; the producer caps itself
  // (bin/omapress emit()) and parsePayload refuses anything over the same
  // budget, so an over-budget document is dropped, never parsed.
  Process {
    id: fetchProcess
    running: false
    command: []
    stdout: StdioCollector { id: fetchStdout; waitForEnd: true }
    stderr: StdioCollector { id: fetchStderr; waitForEnd: true }
    onExited: function(exitCode) {
      watchdog.forget(fetchProcess)
      root.refreshing = false
      if (root.fetchTimedOut) {
        if (!root.everLoaded) root.state = "error"
        root.message = "Feed fetch timed out"
        return
      }
      var out = String(fetchStdout.text || "")
      var err = String(fetchStderr.text || "")
      if (out.trim() !== "") {
        root.applyPayload(out, true)
      } else {
        if (!root.everLoaded) root.state = "error"
        root.message = root.elide(err || "The omapress helper produced no output")
      }
      if (exitCode !== 0 && root.message === "") root.message = root.elide(err || "Feed fetch failed")
    }
  }

  Process {
    id: markProcess
    running: false
    command: []
    stdout: StdioCollector { id: markStdout; waitForEnd: true }
    stderr: StdioCollector { id: markStderr; waitForEnd: true }
    onExited: function(exitCode) {
      watchdog.forget(markProcess)
      var out = String(markStdout.text || "")
      if (root.markTimedOut) {
        root.actionStatus = "Saving read state timed out"
        actionStatusTimer.restart()
      } else if (exitCode === 0 && out.trim() !== "") {
        root.applyPayload(out, false)
      } else {
        root.actionStatus = root.elide(String(markStderr.text || "") || "Could not save read state")
        actionStatusTimer.restart()
      }
      if (root._markQueue.length > 0) {
        var next = root._markQueue[0]
        root._markQueue = root._markQueue.slice(1)
        root.runMark(next)
      }
    }
  }
}
