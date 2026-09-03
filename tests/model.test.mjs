// node --test tests/model.test.mjs
import test from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const Model = require("../Model.js")

const NOW = new Date(2026, 8, 3, 14, 0, 0).getTime() // 3 Sep 2026, local time
const ts = (y, m, d) => Math.floor(new Date(y, m - 1, d, 9).getTime() / 1000)

test("parsePayload normalizes a helper document", () => {
  const parsed = Model.parsePayload(JSON.stringify({ state: "ready", items: [{ id: "a" }], unread: "1" }))
  assert.equal(parsed.ok, true)
  assert.equal(parsed.unread, 1)
  assert.deepEqual(parsed.newIds, [])
  assert.deepEqual(parsed.feed, {})
})

test("parsePayload rejects garbage", () => {
  assert.equal(Model.parsePayload("").ok, false)
  assert.equal(Model.parsePayload("{nope").ok, false)
  assert.equal(Model.parsePayload("42").ok, false)
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
