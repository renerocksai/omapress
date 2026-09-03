// node --test tests/model.test.mjs
import test from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const Model = require("../Model.js")

const NOW = new Date(2026, 8, 3, 14, 0, 0).getTime() // 3 Sep 2026, local time
const ts = (y, m, d) => Math.floor(new Date(y, m - 1, d, 9).getTime() / 1000)

test("parsePayload normalizes a helper document into the closed shape", () => {
  const parsed = Model.parsePayload(JSON.stringify({ schemaVersion: 1, state: "ready", items: [{ id: "a", extra: 1 }], unread: "9", newIds: ["a", "zzz"] }))
  assert.equal(parsed.ok, true)
  assert.equal(parsed.unread, 1)
  assert.deepEqual(parsed.newIds, ["a"])
  assert.deepEqual(parsed.feed, { title: "", link: "", description: "" })
  assert.deepEqual(Object.keys(parsed.items[0]).sort(), ["author", "blocks", "id", "link", "links", "publishedTs", "read", "summary", "title"])
  assert.equal(parsed.items[0].title, "Untitled")
})

test("parsePayload rejects garbage, wrong schema, and oversized output", () => {
  assert.equal(Model.parsePayload("").ok, false)
  assert.equal(Model.parsePayload("{nope").ok, false)
  assert.equal(Model.parsePayload("42").ok, false)
  assert.equal(Model.parsePayload("[]").ok, false)
  assert.equal(Model.parsePayload(JSON.stringify({ schemaVersion: 2, items: [] })).ok, false)
  const huge = "{" + " ".repeat(Model.MAX_PAYLOAD_CHARS) + "}"
  assert.equal(Model.parsePayload(huge).ok, false)
  assert.match(Model.parsePayload(huge).error, /budget/)
})

test("coerceItem clips strings, caps collections, strips control characters", () => {
  const item = Model.coerceItem({
    id: "id",
    title: "t".repeat(9999) + "\x07",
    author: 12,
    summary: "s\x00s",
    link: "https://x.example/" + "p".repeat(5000),
    publishedTs: "not a number",
    blocks: Array.from({ length: 1000 }, (_, i) => ({ kind: i % 2 ? "weird" : "code", text: "b".repeat(100) })),
    links: Array.from({ length: 100 }, (_, i) => ({ href: "https://x.example/" + i, text: "l".repeat(9999) })),
    read: "yes"
  })
  assert.equal(item.title.length, 300)
  assert.ok(item.title.endsWith("…"))
  assert.equal(item.author, "12")
  assert.equal(item.summary, "ss")
  assert.equal(item.link, "")
  assert.equal(item.publishedTs, 0)
  assert.equal(item.blocks.length, Model.MAX_BLOCKS_PER_ITEM)
  assert.equal(item.blocks[1].kind, "p")
  assert.equal(item.links.length, Model.MAX_LINKS_PER_ITEM)
  assert.equal(item.links[0].text.length, 200)
  assert.equal(item.read, false)
  assert.equal(Model.coerceItem({ id: "has space" }), null)
  assert.equal(Model.coerceItem({ id: "x".repeat(3000) }), null)
  assert.equal(Model.coerceItem("junk"), null)
})

test("parsePayload caps item count and drops duplicate ids", () => {
  const items = Array.from({ length: 500 }, (_, i) => ({ id: "i" + (i % 100) }))
  const parsed = Model.parsePayload(JSON.stringify({ schemaVersion: 1, state: "ready", items }))
  assert.equal(parsed.items.length, Model.MAX_ITEMS)
  assert.equal(new Set(parsed.items.map(i => i.id)).size, Model.MAX_ITEMS)
})

test("body cap holds across blocks", () => {
  const item = Model.coerceItem({ id: "x", blocks: Array.from({ length: 20 }, () => ({ kind: "p", text: "y".repeat(3999) })) })
  const total = item.blocks.reduce((n, b) => n + b.text.length, 0)
  assert.ok(total <= 30000, "body over cap: " + total)
})

test("notifyText is single-line, clipped, and control-free", () => {
  assert.equal(Model.notifyText("a\nb\x1bc   d"), "a bc d")
  assert.equal(Model.notifyText("x".repeat(1000)).length, 300)
  assert.equal(Model.notifyText("x".repeat(1000), 50).length, 50)
  assert.equal(Model.notifyText(null), "")
})

test("safeUrl enforces the link policy at the consumer", () => {
  assert.equal(Model.safeLink("https://omarchy.org/news/x"), "https://omarchy.org/news/x")
  assert.equal(Model.safeLink("http://omarchy.org/news/x"), "http://omarchy.org/news/x")
  assert.equal(Model.safeLink("HTTPS://Omarchy.org/X"), "HTTPS://Omarchy.org/X")
  const bad = [
    "javascript:alert(1)", "file:///etc/passwd", "ftp://a.example/", "mailto:a@b.example",
    "https://user:pw@omarchy.org/", "https://real.example@evil.example/", "https://omarchy.org:8443/",
    "https://omarchy.org:443/", "https://localhost/", "https://foo.localhost/", "https://printer.local/",
    "https://box.lan/", "https://svc.internal/", "https://127.0.0.1/", "https://[::1]/", "https://2130706433/",
    "https://0x7f000001/", "https://omarchy.org/a b", "https://omarchy.org/a\tb", "https://omarchy.org/\x00",
    "https://single/", "https:///path", "", null, 42, "https://omarchy.org/" + "x".repeat(3000), "//omarchy.org/x",
    "https:omarchy.org"
  ]
  for (const url of bad) assert.equal(Model.safeLink(url), "", String(url))
})

test("safeFeedUrl is https only", () => {
  assert.equal(Model.safeFeedUrl(" https://omarchy.org/news/rss.xml "), "https://omarchy.org/news/rss.xml")
  assert.equal(Model.safeFeedUrl("http://omarchy.org/news/rss.xml"), "")
  assert.equal(Model.safeFeedUrl("file:///home/me/feed.xml"), "")
  assert.equal(Model.safeFeedUrl("https://localhost/rss.xml"), "")
})

test("safeColor accepts only theme, hex, or a plain name", () => {
  assert.equal(Model.safeColor("#e5484d"), "#e5484d")
  assert.equal(Model.safeColor("#ABC"), "#abc")
  assert.equal(Model.safeColor("#e5484d80"), "#e5484d80")
  assert.equal(Model.safeColor("tomato"), "tomato")
  assert.equal(Model.safeColor("theme"), "theme")
  assert.equal(Model.safeColor(""), "theme")
  assert.equal(Model.safeColor("url(evil)"), "theme")
  assert.equal(Model.safeColor("#ggg"), "theme")
  assert.equal(Model.safeColor(42), "theme")
})

test("coerceItem drops links that fail the policy", () => {
  const item = Model.coerceItem({ id: "x", link: "javascript:1", links: [{ href: "https://u@a.example/" }, { href: "https://ok.example/" }] })
  assert.equal(item.link, "")
  assert.deepEqual(item.links.map(l => l.href), ["https://ok.example/"])
})

test("dateLabel uses day words near today and drops the year otherwise", () => {
  assert.equal(Model.dateLabel(ts(2026, 9, 3), NOW), "Today")
  assert.equal(Model.dateLabel(ts(2026, 9, 2), NOW), "Yesterday")
  assert.equal(Model.dateLabel(ts(2026, 8, 24), NOW), "24 Aug")
  assert.equal(Model.dateLabel(ts(2025, 12, 31), NOW), "31 Dec 2025")
  assert.equal(Model.dateLabel(0, NOW), "")
})

test("relativeTime", () => {
  const now = NOW
  assert.equal(Model.relativeTime(now / 1000 - 10, now), "just now")
  assert.equal(Model.relativeTime(now / 1000 - 300, now), "5m ago")
  assert.equal(Model.relativeTime(now / 1000 - 7200, now), "2h ago")
  assert.equal(Model.relativeTime(now / 1000 - 3 * 86400, now), "3d ago")
  assert.equal(Model.relativeTime(0, now), "never")
})

test("itemMeta joins date and author", () => {
  assert.equal(Model.itemMeta({ publishedTs: ts(2026, 9, 3), author: "DHH" }, NOW), "Today · DHH")
  assert.equal(Model.itemMeta({ publishedTs: ts(2026, 9, 3), author: "" }, NOW), "Today")
  assert.equal(Model.itemMeta(null, NOW), "")
})

test("heroMeta reflects feed state", () => {
  assert.equal(Model.heroMeta({ refreshing: true, items: 0 }, NOW), "Fetching news…")
  assert.equal(Model.heroMeta({ state: "error", items: 0 }, NOW), "Could not load news")
  assert.equal(Model.heroMeta({ state: "ready", unread: 3, source: "network", fetchedTs: NOW / 1000 - 120 }, NOW), "3 unread · updated 2m ago")
  assert.equal(Model.heroMeta({ state: "ready", unread: 0, source: "cache", offline: true, fetchedTs: NOW / 1000 - 3600 }, NOW), "All caught up · offline · updated 1h ago")
})

test("tooltip", () => {
  assert.equal(Model.tooltip({ feedTitle: "Omarchy News", unread: 2 }), "Omarchy News · 2 unread")
  assert.equal(Model.tooltip({ unread: 0 }), "Omarchy News · All caught up")
  assert.equal(Model.tooltip({ state: "error", items: 0 }), "Omarchy News · unavailable")
})

test("itemsToNotify picks unread new posts, oldest first, capped", () => {
  const items = [
    { id: "d", publishedTs: 4, read: false },
    { id: "c", publishedTs: 3, read: false },
    { id: "b", publishedTs: 2, read: true },
    { id: "a", publishedTs: 1, read: false },
    { id: "z", publishedTs: 9, read: false }
  ]
  const picked = Model.itemsToNotify(items, ["a", "b", "c", "d"], 2)
  assert.deepEqual(picked.map(i => i.id), ["c", "d"])
  assert.deepEqual(Model.itemsToNotify(items, [], 3), [])
})

test("unreadCount and itemIndexById", () => {
  const items = [{ id: "a", read: true }, { id: "b", read: false }]
  assert.equal(Model.unreadCount(items), 1)
  assert.equal(Model.itemIndexById(items, "b"), 1)
  assert.equal(Model.itemIndexById(items, "nope"), -1)
})

test("blockPrefix bullets list items only", () => {
  assert.equal(Model.blockPrefix({ kind: "item" }), "•  ")
  assert.equal(Model.blockPrefix({ kind: "p" }), "")
})
