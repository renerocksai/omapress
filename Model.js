// Pure helpers for the Omapress panel. No Qt access so the file can be
// unit-tested with node (see tests/model.test.mjs).

// The closed shape of what the helper may hand the panel. These mirror the
// caps in bin/omapress; the helper derives its output budget from them and
// this side refuses anything that does not fit, so neither end trusts the
// other to have stayed within bounds.
var MAX_PAYLOAD_CHARS = 8 * 1024 * 1024
var MAX_ITEMS = 50
var MAX_ID_CHARS = 2048
var MAX_TITLE_CHARS = 300
var MAX_AUTHOR_CHARS = 120
var MAX_SUMMARY_CHARS = 400
var MAX_BLOCKS_PER_ITEM = 200
var MAX_BLOCK_CHARS = 4000
var MAX_BODY_CHARS = 30000
var MAX_LINKS_PER_ITEM = 30
var MAX_LINK_TEXT_CHARS = 200
var MAX_FEED_TITLE_CHARS = 200
var MAX_FEED_DESC_CHARS = 400
var MAX_MESSAGE_CHARS = 300
var MAX_NOTIFY_TITLE_CHARS = 200
var MAX_NOTIFY_BODY_CHARS = 300
var BLOCK_KINDS = { p: true, heading: true, item: true, quote: true, code: true }

var CONTROL_RE = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/g

// Text for a single-line surface: control characters out, whitespace
// collapsed, clipped with an ellipsis.
function cleanText(value, limit) {
  var text = String(value === undefined || value === null ? "" : value).replace(CONTROL_RE, "").replace(/\s+/g, " ").trim()
  if (text.length > limit) text = text.substring(0, Math.max(0, limit - 1)).replace(/\s+$/, "") + "…"
  return text
}

// Multi-line text for a reader block: newlines survive, everything else as
// cleanText.
function cleanBlockText(value, limit) {
  var text = String(value === undefined || value === null ? "" : value).replace(CONTROL_RE, "")
  if (text.length > limit) text = text.substring(0, Math.max(0, limit - 1)) + "…"
  return text
}

function cleanId(value) {
  var text = String(value === undefined || value === null ? "" : value)
  if (text === "" || text.length > MAX_ID_CHARS || /[\s\x00-\x1f\x7f]/.test(text)) return ""
  return text
}

// ---- URL policy. The same rules bin/omapress applies, re-checked here at
// the final consumer: a click, a notification's --exec, the feed URL from
// shell.json. A URL that fails becomes "" and nothing is opened.
var HOSTNAME_RE = /^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/
var BLOCKED_SUFFIXES = [".localhost", ".local", ".internal", ".home.arpa", ".lan"]

function safeUrl(value, allowHttp) {
  var text = typeof value === "string" ? value : ""
  if (text === "" || text.length > MAX_ID_CHARS) return ""
  if (/[\s\x00-\x1f\x7f]/.test(text)) return ""
  var match = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^\/?#]*)([\/?#].*)?$/.exec(text)
  if (!match) return ""
  var scheme = match[1].toLowerCase()
  if (scheme !== "https" && !(allowHttp && scheme === "http")) return ""
  var authority = match[2]
  if (authority === "" || authority.indexOf("@") !== -1 || authority.indexOf(":") !== -1 || authority.charAt(0) === "[") return ""
  var host = authority.toLowerCase().replace(/\.$/, "")
  if (host === "localhost") return ""
  for (var i = 0; i < BLOCKED_SUFFIXES.length; i++) {
    if (host.length > BLOCKED_SUFFIXES[i].length && host.substring(host.length - BLOCKED_SUFFIXES[i].length) === BLOCKED_SUFFIXES[i]) return ""
  }
  if (/^[0-9.]+$/.test(host) || /^0x[0-9a-f]+$/.test(host)) return ""
  if (!HOSTNAME_RE.test(host) || host.indexOf(".") === -1) return ""
  return text
}

// A link the panel may show and open: http or https.
function safeLink(value) {
  return safeUrl(value, true)
}

// The feed URL from settings: https only, the same as the helper enforces.
function safeFeedUrl(value) {
  return safeUrl(typeof value === "string" ? value.trim() : "", false)
}

// unreadColor from settings: "theme", a hex color, or a plain color name.
function safeColor(value) {
  var text = typeof value === "string" ? value.trim().toLowerCase() : ""
  if (text === "" || text === "theme") return "theme"
  if (/^#(?:[0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/.test(text)) return text
  if (/^[a-z]{1,24}$/.test(text)) return text
  return "theme"
}

function cleanUrlish(value) {
  return safeLink(typeof value === "string" ? value.trim() : "")
}

function notifyText(value, limit) {
  return cleanText(value, limit === undefined ? MAX_NOTIFY_BODY_CHARS : limit)
}

function coerceBlock(value) {
  if (!value || typeof value !== "object") return null
  var kind = BLOCK_KINDS[value.kind] ? String(value.kind) : "p"
  if (typeof value.text !== "string") return null
  var text = cleanBlockText(value.text, MAX_BLOCK_CHARS)
  return text.trim() === "" ? null : { kind: kind, text: text }
}

function coerceLink(value) {
  if (!value || typeof value !== "object") return null
  var href = cleanUrlish(value.href)
  if (href === "") return null
  return { text: cleanText(value.text, MAX_LINK_TEXT_CHARS) || href, href: href }
}

function coerceItem(value) {
  if (!value || typeof value !== "object") return null
  var id = cleanId(value.id)
  if (id === "") return null
  var blocks = []
  var body = 0
  var rawBlocks = Array.isArray(value.blocks) ? value.blocks : []
  for (var b = 0; b < rawBlocks.length && blocks.length < MAX_BLOCKS_PER_ITEM; b++) {
    var block = coerceBlock(rawBlocks[b])
    if (!block) continue
    var room = MAX_BODY_CHARS - body
    if (room <= 0) break
    if (block.text.length > room) block.text = block.text.substring(0, Math.max(0, room - 1)) + "…"
    body += block.text.length
    blocks.push(block)
  }
  var links = []
  var rawLinks = Array.isArray(value.links) ? value.links : []
  for (var l = 0; l < rawLinks.length && links.length < MAX_LINKS_PER_ITEM; l++) {
    var link = coerceLink(rawLinks[l])
    if (link) links.push(link)
  }
  var published = Number(value.publishedTs)
  if (!isFinite(published) || published < 0) published = 0
  return {
    id: id,
    title: cleanText(value.title, MAX_TITLE_CHARS) || "Untitled",
    link: cleanUrlish(value.link),
    author: cleanText(value.author, MAX_AUTHOR_CHARS),
    publishedTs: Math.min(4102444800, Math.floor(published)),
    summary: cleanText(value.summary, MAX_SUMMARY_CHARS),
    blocks: blocks,
    links: links,
    read: value.read === true
  }
}

function coerceFeed(value) {
  var feed = value && typeof value === "object" ? value : {}
  return {
    title: cleanText(feed.title, MAX_FEED_TITLE_CHARS),
    link: cleanUrlish(feed.link),
    description: cleanText(feed.description, MAX_FEED_DESC_CHARS)
  }
}

// Helper output → the one shape the rest of the plugin reads. Anything
// outside the schema is dropped, oversized strings are clipped, oversized
// collections are cut, and a document over the budget is refused whole.
function parsePayload(raw) {
  var text = String(raw || "")
  if (text.length > MAX_PAYLOAD_CHARS) return { ok: false, error: "Helper output exceeds the size budget" }
  text = text.trim()
  if (text === "") return { ok: false, error: "Helper returned nothing" }
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "Could not parse helper output" }
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { ok: false, error: "Helper returned garbage" }
  if (parsed.schemaVersion !== 1) return { ok: false, error: "Helper output has an unknown schema" }
  var state = parsed.state === "error" ? "error" : "ready"
  var source = parsed.source === "network" || parsed.source === "cache" ? parsed.source : "none"
  var items = []
  var rawItems = Array.isArray(parsed.items) ? parsed.items : []
  var seen = {}
  for (var i = 0; i < rawItems.length && items.length < MAX_ITEMS; i++) {
    var item = coerceItem(rawItems[i])
    if (!item || seen[item.id]) continue
    seen[item.id] = true
    items.push(item)
  }
  var newIds = []
  var rawNew = Array.isArray(parsed.newIds) ? parsed.newIds : []
  for (var n = 0; n < rawNew.length && newIds.length < MAX_ITEMS; n++) {
    var id = cleanId(rawNew[n])
    if (id !== "" && seen[id]) newIds.push(id)
  }
  var fetched = Number(parsed.fetchedTs)
  return {
    ok: true,
    state: state,
    message: cleanText(parsed.message, MAX_MESSAGE_CHARS),
    source: source,
    feed: coerceFeed(parsed.feed),
    items: items,
    unread: unreadCount(items),
    newIds: newIds,
    fetchedTs: isFinite(fetched) && fetched > 0 ? Math.floor(fetched) : 0
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
    MAX_PAYLOAD_CHARS: MAX_PAYLOAD_CHARS,
    MAX_ITEMS: MAX_ITEMS,
    MAX_BLOCKS_PER_ITEM: MAX_BLOCKS_PER_ITEM,
    MAX_LINKS_PER_ITEM: MAX_LINKS_PER_ITEM,
    cleanText: cleanText,
    cleanId: cleanId,
    safeUrl: safeUrl,
    safeLink: safeLink,
    safeFeedUrl: safeFeedUrl,
    safeColor: safeColor,
    notifyText: notifyText,
    coerceItem: coerceItem,
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
