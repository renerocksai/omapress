// Pure helpers for the Omapress panel. No Qt access so the file can be
// unit-tested with node (see tests/model.test.mjs).

function parsePayload(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, error: "Helper returned nothing" }
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return { ok: false, error: "Helper returned garbage" }
    parsed.ok = true
    parsed.items = Array.isArray(parsed.items) ? parsed.items : []
    parsed.newIds = Array.isArray(parsed.newIds) ? parsed.newIds : []
    parsed.feed = parsed.feed && typeof parsed.feed === "object" ? parsed.feed : {}
    parsed.unread = Number(parsed.unread || 0)
    parsed.fetchedTs = Number(parsed.fetchedTs || 0)
    return parsed
  } catch (e) {
    return { ok: false, error: "Could not parse helper output" }
  }
}

function startOfDay(ms) {
  var d = new Date(ms)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// "Today", "Yesterday", "3 Sep", or "3 Sep 2025" for another year.
function dateLabel(timestampSec, nowMs) {
  var ts = Number(timestampSec || 0)
  if (!isFinite(ts) || ts <= 0) return ""
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var then = ts * 1000
  var dayDiff = Math.round((startOfDay(now) - startOfDay(then)) / 86400000)
  if (dayDiff === 0) return "Today"
  if (dayDiff === 1) return "Yesterday"
  var d = new Date(then)
  var label = d.getDate() + " " + MONTHS[d.getMonth()]
  if (d.getFullYear() !== new Date(now).getFullYear()) label += " " + d.getFullYear()
  return label
}

function relativeTime(timestampSec, nowMs) {
  var ts = Number(timestampSec || 0)
  if (!isFinite(ts) || ts <= 0) return "never"
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var diff = Math.max(0, Math.floor((now - ts * 1000) / 1000))
  if (diff < 60) return "just now"
  var minutes = Math.floor(diff / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 30) return days + "d ago"
  return Math.floor(days / 30) + "mo ago"
}

function itemMeta(item, nowMs) {
  if (!item) return ""
  var parts = []
  var date = dateLabel(item.publishedTs, nowMs)
  if (date) parts.push(date)
  var author = String(item.author || "").trim()
  if (author) parts.push(author)
  return parts.join(" · ")
}

function unreadLabel(unread) {
  var n = Number(unread || 0)
  if (n <= 0) return "All caught up"
  return n === 1 ? "1 unread" : n + " unread"
}

// Hero subtitle: what state the feed is in, in one short line.
function heroMeta(status, nowMs) {
  status = status || {}
  if (status.refreshing && status.items === 0) return "Fetching news…"
  if (status.state === "error") return "Could not load news"
  var parts = [unreadLabel(status.unread)]
  if (status.source === "cache" && status.offline) parts.push("offline")
  if (status.fetchedTs > 0) parts.push("updated " + relativeTime(status.fetchedTs, nowMs))
  return parts.join(" · ")
}

function tooltip(status) {
  status = status || {}
  var name = status.feedTitle || "Omarchy News"
  if (status.state === "error" && status.items === 0) return name + " · unavailable"
  return name + " · " + unreadLabel(status.unread)
}

function unreadCount(items) {
  var n = 0
  for (var i = 0; i < (items || []).length; i++) if (!items[i].read) n++
  return n
}

function itemIndexById(items, id) {
  for (var i = 0; i < (items || []).length; i++) if (String(items[i].id) === String(id)) return i
  return -1
}

// Which posts to announce: at most `limit` newest new posts, oldest first so
// notifications stack in reading order.
function itemsToNotify(items, newIds, limit) {
  var wanted = {}
  for (var i = 0; i < (newIds || []).length; i++) wanted[String(newIds[i])] = true
  var picked = []
  for (var j = 0; j < (items || []).length; j++) {
    if (wanted[String(items[j].id)] && !items[j].read) picked.push(items[j])
  }
  picked.sort(function(a, b) { return Number(a.publishedTs || 0) - Number(b.publishedTs || 0) })
  var max = limit === undefined ? 3 : Number(limit)
  return picked.length > max ? picked.slice(picked.length - max) : picked
}

function blockPrefix(block) {
  return block && block.kind === "item" ? "•  " : ""
}

if (typeof module !== "undefined") {
  module.exports = {
    parsePayload: parsePayload,
    dateLabel: dateLabel,
    relativeTime: relativeTime,
    itemMeta: itemMeta,
    unreadLabel: unreadLabel,
    heroMeta: heroMeta,
    tooltip: tooltip,
    unreadCount: unreadCount,
    itemIndexById: itemIndexById,
    itemsToNotify: itemsToNotify,
    blockPrefix: blockPrefix
  }
}
