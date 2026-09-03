#!/usr/bin/env bash
# Exercises bin/omapress against the fixture feed with throwaway state/cache
# directories. Run from anywhere: tests/helper-test.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
helper="$here/../bin/omapress"
fixture="$here/fixtures/feed.xml"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export OMAPRESS_STATE_DIR="$work/state"
export OMAPRESS_CACHE_DIR="$work/cache"

fail() { echo "FAIL: $*" >&2; exit 1; }
field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }

url="https://feed.example.org/rss.xml"
src() { "$helper" fetch --url "$url" --source "$1"; }

# First run: everything newer than 14 days is unread, nothing is "new".
out=$(src "$fixture")
[[ $(field 'd["state"]' <<<"$out") == ready ]] || fail "first fetch not ready: $(field 'd["message"]' <<<"$out")"
[[ $(field 'd["source"]' <<<"$out") == network ]] || fail "first fetch not from network"
[[ $(field 'len(d["items"])' <<<"$out") == 3 ]] || fail "expected 3 items"
[[ $(field 'd["newIds"]' <<<"$out") == "[]" ]] || fail "first run must not report new posts"
[[ $(field 'd["items"][0]["title"]' <<<"$out") == "Fresh post & friends" ]] || fail "entities not decoded in title"
[[ $(field 'd["items"][0]["author"]' <<<"$out") == "DHH" ]] || fail "dc:creator not picked up"
[[ $(field 'd["items"][0]["read"]' <<<"$out") == False ]] || fail "fresh post should be unread"
[[ $(field 'd["items"][2]["read"]' <<<"$out") == True ]] || fail "ancient post should start read"
[[ $(field '[b["kind"] for b in d["items"][0]["blocks"]]' <<<"$out") == "['p', 'heading', 'item', 'item', 'quote', 'code']" ]] || fail "block kinds wrong: $(field '[b["kind"] for b in d["items"][0]["blocks"]]' <<<"$out")"
[[ $(field 'd["items"][0]["blocks"][0]["text"]' <<<"$out") == "Hello world, this has a link and bold text." ]] || fail "inline markup not flattened"
[[ $(field 'd["items"][0]["links"][0]["href"]' <<<"$out") == "https://example.org/a" ]] || fail "link not collected"
[[ $(field 'len(d["items"][0]["links"])' <<<"$out") == 1 ]] || fail "duplicate link not merged"
[[ $(field 'd["items"][1]["summary"]' <<<"$out") == "Only a description, no body." ]] || fail "description-only post summary"
[[ $(field 'd["items"][1]["blocks"][0]["text"]' <<<"$out") == "Only a description, no body." ]] || fail "description-only post body"
[[ $(field 'd["unread"]' <<<"$out") == 2 ]] || fail "unread count"

# Second run: still no new posts, served from network (fixture has no ETag).
out=$(src "$fixture")
[[ $(field 'd["newIds"]' <<<"$out") == "[]" ]] || fail "second run reported new posts"

# A post appearing later is new.
grow="$work/grown.xml"
sed 's#</channel>#<item><title>Newest</title><link>https://example.org/new</link><guid>https://example.org/new</guid><pubDate>Thu, 03 Sep 2026 10:00:00 GMT</pubDate><description>brand new</description></item></channel>#' "$fixture" > "$grow"
out=$(src "$grow")
[[ $(field 'd["newIds"]' <<<"$out") == "['https://example.org/new']" ]] || fail "new post not detected: $(field 'd["newIds"]' <<<"$out")"
[[ $(field 'd["items"][0]["title"]' <<<"$out") == Newest ]] || fail "items not sorted newest first"
[[ $(field 'd["unread"]' <<<"$out") == 3 ]] || fail "unread after growth"

# Read state round trip.
out=$("$helper" mark-read https://example.org/new)
[[ $(field 'd["unread"]' <<<"$out") == 2 ]] || fail "mark-read"
[[ $(field 'd["source"]' <<<"$out") == cache ]] || fail "mark commands must not hit the network"
out=$("$helper" mark-unread https://example.org/new)
[[ $(field 'd["unread"]' <<<"$out") == 3 ]] || fail "mark-unread"
out=$("$helper" mark-all-read)
[[ $(field 'd["unread"]' <<<"$out") == 0 ]] || fail "mark-all-read"

# Mark commands accept only well-formed ids the cache holds, and not too many.
if "$helper" mark-read "has space" >/dev/null 2>&1; then fail "mark-read accepted an id with whitespace"; fi
if "$helper" mark-read $(printf 'x%.0s ' $(seq 1 60)) >/dev/null 2>&1; then fail "mark-read accepted 60 ids"; fi
out=$("$helper" mark-unread https://example.org/not-in-feed https://example.org/new)
[[ $(field 'd["unread"]' <<<"$out") == 1 ]] || fail "unknown id should be ignored, known one applied"
python3 -c 'import json,sys,os; p=os.path.join(os.environ["OMAPRESS_STATE_DIR"],"state.json"); d=json.load(open(p)); assert "https://example.org/not-in-feed" not in d["read"] and "https://example.org/not-in-feed" not in d["known"]' || fail "unknown id leaked into state"
"$helper" mark-read https://example.org/new >/dev/null

# Offline: same URL unreachable, cache serves with an offline message.
mv "$grow" "$grow.gone"
out=$(src "$grow")
[[ $(field 'd["state"]' <<<"$out") == ready ]] || fail "offline should still be ready from cache"
[[ $(field 'd["source"]' <<<"$out") == cache ]] || fail "offline source"
[[ $(field 'd["message"].startswith("Offline")' <<<"$out") == True ]] || fail "offline message: $(field 'd["message"]' <<<"$out")"
[[ $(field 'len(d["items"])' <<<"$out") == 4 ]] || fail "offline items"

# --offline never touches the network and reports no error.
out=$("$helper" fetch --offline --url "$url")
[[ $(field 'd["message"]' <<<"$out") == "" ]] || fail "--offline should be quiet"

# A different URL with nothing cached is an error, exit 1.
if out=$("$helper" fetch --url "https://other.example.org/feed.xml" --source "$work/missing.xml" 2>/dev/null); then fail "missing feed should exit non-zero"; fi
[[ $(field 'd["state"]' <<<"$out") == error ]] || fail "missing feed state"

# URL policy at the entry point: refused before any state is touched.
for bad in "http://omarchy.org/news/rss.xml" "https://user:pw@omarchy.org/rss.xml" "https://omarchy.org:8443/rss.xml" \
           "https://localhost/rss.xml" "https://127.0.0.1/rss.xml" "https://[::1]/rss.xml" "https://10.0.0.5/rss.xml" \
           "file:///etc/passwd" "https://omarchy.org/r ss.xml" "https://feed.local/rss.xml" "ftp://omarchy.org/x"; do
  if out=$("$helper" fetch --url "$bad" --source "$fixture" 2>/dev/null); then fail "accepted bad URL $bad"; fi
  [[ $(field 'd["state"]' <<<"$out") == error ]] || fail "bad URL not an error: $bad"
  [[ $(field 'd["message"].startswith("Feed URL refused")' <<<"$out") == True ]] || fail "bad URL message: $bad -> $(field 'd["message"]' <<<"$out")"
done

# An oversized source is refused, not truncated.
python3 -c 'import sys; sys.stdout.write("<rss><channel>" + "<item><title>x</title><guid>g</guid></item>" * 120000 + "</channel></rss>")' > "$work/huge.xml"
out=$("$helper" fetch --url "https://huge.example.org/rss.xml" --source "$work/huge.xml" 2>/dev/null || true)
[[ $(field 'd["message"]' <<<"$out") == "Feed is larger than 4 MiB" ]] || fail "oversize: $(field 'd["message"]' <<<"$out")"

# A symlinked source is refused.
ln -s "$fixture" "$work/link.xml"
out=$("$helper" fetch --url "https://link.example.org/rss.xml" --source "$work/link.xml" 2>/dev/null || true)
[[ $(field 'd["message"]' <<<"$out") == "Feed URL refused: source is not a regular file" ]] || fail "symlink source: $(field 'd["message"]' <<<"$out")"

# A FIFO is not a regular file either, and must not block the run.
mkfifo "$work/pipe.xml"
out=$("$helper" fetch --url "https://pipe.example.org/rss.xml" --source "$work/pipe.xml" 2>/dev/null || true)
[[ $(field 'd["message"]' <<<"$out") == "Feed URL refused: source is not a regular file" ]] || fail "fifo source: $(field 'd["message"]' <<<"$out")"

# Atom feeds parse too.
out=$("$helper" fetch --url "https://atom.example.org/feed.atom" --source "$here/fixtures/feed.atom")
[[ $(field 'd["feed"]["title"]' <<<"$out") == "Atom Example" ]] || fail "atom title"
[[ $(field 'd["items"][0]["link"]' <<<"$out") == "https://example.org/atom-1" ]] || fail "atom link"
[[ $(field 'd["items"][0]["author"]' <<<"$out") == "Ada" ]] || fail "atom author"

echo "helper tests passed"
