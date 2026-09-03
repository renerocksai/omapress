#!/usr/bin/env python3
"""Unit tests for the pure parts of bin/omapress. Run: python3 tests/helper_unit.py"""
import importlib.machinery
import importlib.util
import io
import os
import sys
import unittest
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "bin", "omapress")
loader = importlib.machinery.SourceFileLoader("omapress", HELPER)
spec = importlib.util.spec_from_loader("omapress", loader)
om = importlib.util.module_from_spec(spec)
loader.exec_module(om)


class UrlPolicy(unittest.TestCase):
    def ok(self, url, **kw):
        self.assertEqual(om.check_url(url, resolve=False, **kw), url)

    def bad(self, url, fragment, **kw):
        with self.assertRaises(om.UrlError) as ctx:
            om.check_url(url, resolve=False, **kw)
        self.assertIn(fragment, str(ctx.exception))

    def test_accepts_plain_https(self):
        self.ok("https://omarchy.org/news/rss.xml")
        self.ok("https://sub.domain.example/path?x=1&y=2#frag")

    def test_scheme(self):
        self.bad("http://omarchy.org/", "https")
        self.ok("http://omarchy.org/", allow_http=True)
        self.bad("ftp://omarchy.org/", "https")
        self.bad("file:///etc/passwd", "https")
        self.bad("javascript:alert(1)", "https")
        self.ok("HTTPS://omarchy.org/x")

    def test_credentials(self):
        self.bad("https://user@omarchy.org/", "credentials")
        self.bad("https://user:pw@omarchy.org/", "credentials")
        self.bad("https://real.example@evil.example/", "credentials")

    def test_port(self):
        self.bad("https://omarchy.org:8443/", "default port")
        self.bad("https://omarchy.org:443/", "default port")
        self.bad("https://omarchy.org:abc/", "invalid port")

    def test_local_hosts(self):
        self.bad("https://localhost/", "local host")
        self.bad("https://LOCALHOST./", "local host")
        self.bad("https://foo.localhost/", "local host")
        self.bad("https://printer.local/", "local host")
        self.bad("https://box.lan/", "local host")
        self.bad("https://svc.internal/", "local host")

    def test_ip_literals(self):
        self.bad("https://127.0.0.1/", "not an address")
        self.bad("https://10.1.2.3/", "not an address")
        self.bad("https://[::1]/", "not an address")
        self.bad("https://[fe80::1]/", "not an address")
        self.bad("https://8.8.8.8/", "not an address")
        self.bad("https://2130706433/", "not an address")
        self.bad("https://0x7f000001/", "not an address")

    def test_control_and_whitespace(self):
        self.bad("https://omarchy.org/a b", "whitespace")
        self.bad("https://omarchy.org/a\tb", "whitespace")
        self.bad("https://omarchy.org/a\nb", "whitespace")
        self.bad("https://omarchy.org/\x00", "whitespace")
        self.bad("https://omarchy.org/\x7f", "whitespace")
        self.bad("https://omarchy.org/ ", "whitespace")

    def test_length_and_shape(self):
        self.bad("", "empty")
        self.bad("https://omarchy.org/" + "a" * 3000, "too long")
        self.bad("https:///path", "no host")
        self.bad("https://single/", "valid public hostname")
        self.bad("https://-bad.example/", "valid public hostname")
        self.bad("https://bad_.example/", "valid public hostname")

    def test_private_resolution(self):
        self.assertFalse(om._is_public_address("127.0.0.1"))
        self.assertFalse(om._is_public_address("10.0.0.1"))
        self.assertFalse(om._is_public_address("192.168.1.1"))
        self.assertFalse(om._is_public_address("169.254.1.1"))
        self.assertFalse(om._is_public_address("::1"))
        self.assertFalse(om._is_public_address("fd00::1"))
        self.assertFalse(om._is_public_address("0.0.0.0"))
        self.assertTrue(om._is_public_address("93.184.216.34"))
        self.assertTrue(om._is_public_address("2606:2800:220:1:248:1893:25c8:1946"))


class LinkPolicy(unittest.TestCase):
    def test_safe_link(self):
        self.assertEqual(om.safe_link("https://omarchy.org/x"), "https://omarchy.org/x")
        self.assertEqual(om.safe_link("http://omarchy.org/x"), "http://omarchy.org/x")
        for bad in ("javascript:alert(1)", "file:///etc/passwd", "ftp://a.example/", "https://u:p@a.example/",
                    "https://localhost/", "https://127.0.0.1/", "https://a.example:8080/", "https://a.example/ x",
                    "mailto:x@y.example", "https://box.lan/", "", None, "https://a.example/" + "x" * 3000):
            self.assertEqual(om.safe_link(bad), "", bad)

    def test_links_filtered_at_parse_and_cache(self):
        body = ('<a href="javascript:alert(1)">js</a><a href="https://u:p@evil.example/">cred</a>'
                '<a href="https://127.0.0.1/">ip</a><a href="http://ok.example/p">ok</a><a href="https://also.example/">also</a>')
        rss = ('<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>T</title>'
               '<link>javascript:1</link><item><title>t</title><guid>g</guid><link>https://u@x.example/</link>'
               '<content:encoded><![CDATA[%s]]></content:encoded></item></channel></rss>' % body).encode()
        feed, items = om.parse_feed(rss)
        self.assertEqual(feed["link"], "")
        self.assertEqual(items[0]["link"], "")
        self.assertEqual([l["href"] for l in items[0]["links"]], ["http://ok.example/p", "https://also.example/"])
        cache = om.coerce_cache({"items": [{"id": "g", "link": "https://localhost/x",
                                            "links": [{"href": "file:///etc/passwd"}, {"href": "https://ok.example/"}]}],
                                 "feed": {"link": "https://[::1]/"}})
        self.assertEqual(cache["items"][0]["link"], "")
        self.assertEqual([l["href"] for l in cache["items"][0]["links"]], ["https://ok.example/"])
        self.assertEqual(cache["feed"]["link"], "")


class Redirects(unittest.TestCase):
    def make(self, url):
        import urllib.request
        return urllib.request.Request(url)

    def test_refuses_downgrade_and_private(self):
        handler = om.PolicyRedirectHandler()
        req = self.make("https://omarchy.org/rss.xml")
        for target in ("http://omarchy.org/rss.xml", "https://127.0.0.1/", "https://user:pw@omarchy.org/", "https://localhost/"):
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                handler.redirect_request(req, io.BytesIO(b""), 302, "Found", {}, target)
            self.assertIn("redirect refused", str(ctx.exception.reason))

    def test_hop_cap(self):
        handler = om.PolicyRedirectHandler()
        req = self.make("https://omarchy.org/rss.xml")
        for _ in range(om.MAX_REDIRECTS):
            new = handler.redirect_request(req, io.BytesIO(b""), 302, "Found", {}, "https://omarchy.org/next")
            self.assertIsNotNone(new)
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            handler.redirect_request(req, io.BytesIO(b""), 302, "Found", {}, "https://omarchy.org/next")
        self.assertIn("too many redirects", str(ctx.exception.reason))


class Deadline(unittest.TestCase):
    def setUp(self):
        self.saved = om.DEADLINE

    def tearDown(self):
        om.DEADLINE = self.saved

    def test_net_timeout_is_capped_by_remaining(self):
        import time
        om.DEADLINE = time.monotonic() + 2.0
        self.assertLessEqual(om.net_timeout(), 2.0)
        om.DEADLINE = time.monotonic() + 100.0
        self.assertEqual(om.net_timeout(), om.REQUEST_TIMEOUT)

    def test_spent_budget_raises(self):
        import time
        om.DEADLINE = time.monotonic() - 1.0
        with self.assertRaises(om.Timeout):
            om.net_timeout()
        with self.assertRaises(om.Timeout):
            om.read_bounded(io.BytesIO(b"x" * 10), 100)

    def test_alarm_handler_raises_timeout(self):
        with self.assertRaises(om.Timeout):
            om.on_alarm(14, None)

    def test_terminate_unwinds(self):
        with self.assertRaises(om.Terminated):
            om.on_terminate(15, None)


class BoundedRead(unittest.TestCase):
    def test_under_limit(self):
        self.assertEqual(om.read_bounded(io.BytesIO(b"x" * 1000), 1000), b"x" * 1000)

    def test_one_byte_over_is_refused(self):
        with self.assertRaises(om.BodyTooLarge):
            om.read_bounded(io.BytesIO(b"x" * 1001), 1000)

    def test_streams_in_chunks(self):
        class Counting(io.BytesIO):
            calls = 0
            def read(self, n=-1):
                self.calls += 1
                self.assertion = n
                return super().read(n)
        stream = Counting(b"y" * (om.READ_CHUNK * 3))
        om.read_bounded(stream, om.READ_CHUNK * 3)
        self.assertGreaterEqual(stream.calls, 3)


class Caps(unittest.TestCase):
    def rss(self, items_xml, channel_extra=""):
        return ('<?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">'
                "<channel><title>T</title>" + channel_extra + items_xml + "</channel></rss>").encode("utf-8")

    def item(self, guid="g1", title="t", body="<p>b</p>", link="https://x.example/p"):
        return ("<item><title>%s</title><guid>%s</guid><link>%s</link>"
                "<content:encoded><![CDATA[%s]]></content:encoded></item>" % (title, guid, link, body))

    def test_title_and_author_clipped_and_cleaned(self):
        # U+0085 is a C1 control XML 1.0 still allows through; C0 ones it rejects itself.
        feed, items = om.parse_feed(self.rss(self.item(title="a" * 1000 + "\u0085b")))
        self.assertEqual(len(items[0]["title"]), om.MAX_TITLE_CHARS)
        self.assertTrue(items[0]["title"].endswith("…"))
        feed, items = om.parse_feed(self.rss(self.item(title="a\u0085b")))
        self.assertEqual(items[0]["title"], "ab")

    def test_block_count_and_body_caps(self):
        body = "".join("<p>%d para</p>" % i for i in range(om.MAX_BLOCKS_PER_ITEM * 3))
        feed, items = om.parse_feed(self.rss(self.item(body=body)))
        self.assertEqual(len(items[0]["blocks"]), om.MAX_BLOCKS_PER_ITEM)
        body = "<p>" + "x" * (om.MAX_BODY_CHARS * 2) + "</p>" + "<p>after</p>"
        feed, items = om.parse_feed(self.rss(self.item(body=body)))
        total = sum(len(b["text"]) for b in items[0]["blocks"])
        self.assertLessEqual(total, om.MAX_BODY_CHARS)
        self.assertLessEqual(len(items[0]["blocks"][0]["text"]), om.MAX_BLOCK_CHARS)

    def test_link_caps(self):
        body = "".join('<a href="https://x.example/%d">%s</a>' % (i, "l" * 500) for i in range(200))
        feed, items = om.parse_feed(self.rss(self.item(body=body)))
        self.assertEqual(len(items[0]["links"]), om.MAX_LINKS_PER_ITEM)
        self.assertEqual(len(items[0]["links"][0]["text"]), om.MAX_LINK_TEXT_CHARS)
        body = '<a href="https://x.example/%s">long</a>' % ("q" * 5000)
        feed, items = om.parse_feed(self.rss(self.item(body=body)))
        self.assertEqual(items[0]["links"], [])

    def test_bad_ids_are_dropped_not_clipped(self):
        feed, items = om.parse_feed(self.rss(self.item(guid="g" * 5000) + self.item(guid="has space") + self.item(guid="ok")))
        self.assertEqual([i["id"] for i in items], ["ok"])

    def test_item_count_cap(self):
        feed, items = om.parse_feed(self.rss("".join(self.item(guid="g%d" % i) for i in range(om.MAX_ITEMS * 10))))
        self.assertEqual(len(items), om.MAX_ITEMS * 4)

    def test_dtd_is_refused(self):
        bomb = b'<?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol">]><rss><channel><item><title>&lol;</title><guid>g</guid></item></channel></rss>'
        with self.assertRaises(om.FeedRejected):
            om.parse_feed(bomb)
        with self.assertRaises(om.FeedRejected):
            om.parse_feed(b'<rss><!doctype x><channel></channel></rss>')

    def test_payload_budget_holds_for_worst_case(self):
        worst = {"schemaVersion": 1, "state": "ready", "message": "m" * om.MAX_MESSAGE_CHARS, "source": "network",
                 "url": "u" * om.MAX_URL_CHARS, "fetchedTs": 0, "generatedTs": 0,
                 "feed": {"title": "t" * om.MAX_FEED_TITLE_CHARS, "link": "l" * om.MAX_ID_CHARS, "description": "d" * om.MAX_FEED_DESC_CHARS},
                 "items": [{"id": "i" * om.MAX_ID_CHARS, "title": "t" * om.MAX_TITLE_CHARS, "link": "l" * om.MAX_ID_CHARS,
                            "author": "a" * om.MAX_AUTHOR_CHARS, "publishedTs": 4102444800, "summary": "s" * om.MAX_SUMMARY_CHARS,
                            "blocks": [{"kind": "heading", "text": "x" * (om.MAX_BODY_CHARS // om.MAX_BLOCKS_PER_ITEM)}] * om.MAX_BLOCKS_PER_ITEM,
                            "links": [{"text": "t" * om.MAX_LINK_TEXT_CHARS, "href": "h" * om.MAX_ID_CHARS}] * om.MAX_LINKS_PER_ITEM,
                            "read": False}] * om.MAX_ITEMS,
                 "unread": om.MAX_ITEMS, "newIds": ["i" * om.MAX_ID_CHARS] * om.MAX_ITEMS}
        import json
        self.assertLess(len(json.dumps(worst, ensure_ascii=False)), om.MAX_PAYLOAD_CHARS)

    def test_cache_is_coerced(self):
        cache = om.coerce_cache({"items": [{"id": "ok", "title": "t" * 9999, "blocks": [{"kind": "evil", "text": "x"}, "junk", {"kind": "p", "text": 5}],
                                            "links": [{"href": "javascript:1", "text": "j"}, {"href": "https://a.example", "extra": 1}], "extra": "dropped"},
                                           {"id": "bad id"}, "junk"] * 100 + [{"id": "u%d" % i} for i in range(100)], "fetchedTs": "nope", "url": 12, "etag": "e\x00e"})
        # Junk and duplicates do not count against the cap; distinct valid ids fill it.
        self.assertEqual(len(cache["items"]), om.MAX_ITEMS)
        self.assertEqual(cache["items"][1]["id"], "u0")
        item = cache["items"][0]
        self.assertEqual(sorted(item.keys()), ["author", "blocks", "id", "link", "links", "publishedTs", "summary", "title"])
        self.assertEqual(len(item["title"]), om.MAX_TITLE_CHARS)
        self.assertEqual(item["blocks"], [{"kind": "p", "text": "x"}])
        self.assertEqual(cache["fetchedTs"], 0)
        self.assertEqual(cache["url"], "")
        self.assertEqual(cache["etag"], "ee")

    def test_state_lists_are_bounded(self):
        import json, tempfile
        with tempfile.TemporaryDirectory() as tmp:
            os.environ["OMAPRESS_STATE_DIR"] = tmp
            om._STORES.clear()
            try:
                with open(os.path.join(tmp, "state.json"), "w") as handle:
                    json.dump({"read": ["r%d" % i for i in range(5000)] + [5, "bad id", ""], "known": "nope"}, handle)
                state = om.load_state()
                self.assertEqual(len(state["read"]), om.MAX_STATE_IDS)
                self.assertEqual(state["known"], [])
                with open(os.path.join(tmp, "state.json"), "w") as handle:
                    handle.write("{" + '"read": ["' + "x" * (om.MAX_STATE_BYTES) + '"]}')
                self.assertEqual(om.load_state()["read"], [])
            finally:
                del os.environ["OMAPRESS_STATE_DIR"]
                om._STORES.clear()


if __name__ == "__main__":
    unittest.main(verbosity=1)
