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


if __name__ == "__main__":
    unittest.main(verbosity=1)
