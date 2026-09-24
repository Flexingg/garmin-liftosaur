"""Endpoint rules of the watch app, proven off-device.

The watch builds every backend URL through `module LiftEndpoint`
(embedded/monkeyc/source/Endpoint.mc). Monkey C only runs on the device, so
these tests exercise its hand-kept Python mirror
(embedded/monkeyc/tools/endpoint_mirror.py) and check the mirror's constants
still match the Monkey C source.

The regression they pin: a base URL with a trailing "/" or a stray space
produced "//api/v1/..." (404) or a FastAPI 307 that makeWebRequest never
follows, and the rotating quick-tunnel hostname needs a failover order.
"""
from __future__ import annotations

import os
import sys

import pytest

_TOOLS = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "embedded", "monkeyc", "tools"))
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)

import endpoint_mirror as ep  # noqa: E402

_MC = os.path.join(_TOOLS, "..", "source", "Endpoint.mc")


def _no_double_slash_after_scheme(url: str) -> bool:
    return "//" not in url.split("://", 1)[1]


# ----------------------------------------------------------------- lockstep

def test_mirror_constants_match_endpoint_mc():
    assert ep.check_mc(_MC) == []


def test_mirror_cli_reports_lockstep():
    assert ep.main(["--mc", _MC]) == 0


def test_mirror_check_detects_drift(tmp_path):
    src = open(_MC, encoding="utf-8").read()
    drifted = tmp_path / "Endpoint.mc"
    drifted.write_text(src.replace('"/api/v1/watch/health"', '"/api/v1/health"'))
    problems = ep.check_mc(str(drifted))
    assert any("HEALTH_PATH" in p for p in problems)


# ---------------------------------------------------------------- normalize

@pytest.mark.parametrize("raw, want", [
    ("https://h.trycloudflare.com", "https://h.trycloudflare.com"),
    ("https://h.trycloudflare.com/", "https://h.trycloudflare.com"),
    ("https://h.trycloudflare.com///", "https://h.trycloudflare.com"),
    ("  https://h.trycloudflare.com  ", "https://h.trycloudflare.com"),
    ("\thttps://h.trycloudflare.com/\t", "https://h.trycloudflare.com"),
    (" \t https://h.trycloudflare.com/ \t/ ", "https://h.trycloudflare.com"),
    ("HTTPS://h.trycloudflare.com", "https://h.trycloudflare.com"),
    ("HtTpS://Host.Example/", "https://Host.Example"),
    ("https://h.example/base/", "https://h.example/base"),
])
def test_normalize_accepts_and_cleans(raw, want):
    assert ep.normalizeBaseUrl(raw) == want


@pytest.mark.parametrize("raw", [
    None, "", "   ", "\t", "/", "///",
    "http://h.trycloudflare.com",          # plain http -> -1001 on the device
    "HTTP://h.trycloudflare.com",
    "ftp://h.example",
    "h.trycloudflare.com",                 # no scheme
    "https://",                            # no host
    "https://h.try cloudflare.com",        # inner space
    "https://h.example/a b",
])
def test_normalize_rejects(raw):
    assert ep.normalizeBaseUrl(raw) == ""


@pytest.mark.parametrize("raw, want", [
    ("http://127.0.0.1:8008", "http://127.0.0.1:8008"),
    ("http://127.0.0.1:8008/", "http://127.0.0.1:8008"),
    ("http://localhost:8008", "http://localhost:8008"),
])
def test_normalize_allows_plain_http_on_loopback_only(raw, want):
    assert ep.normalizeBaseUrl(raw) == want


def test_strip_edges():
    assert ep.stripEdges(" \t/x/y/\t ") == "x/y"
    assert ep.stripEdges("") == ""
    assert ep.stripEdges(" / \t") == ""
    assert ep.stripEdges("a b") == "a b"


# ------------------------------------------------------------------ joinUrl

@pytest.mark.parametrize("base, path", [
    ("https://h", "/api/v1/watch/programs"),
    ("https://h", "api/v1/watch/programs"),
    ("https://h/", "/api/v1/watch/programs"),
    ("https://h/", "api/v1/watch/programs"),
    ("https://h//", "//api/v1/watch/programs"),
])
def test_join_has_exactly_one_slash(base, path):
    assert ep.joinUrl(base, path) == "https://h/api/v1/watch/programs"


def test_join_trailing_slash_regression():
    url = ep.joinUrl("https://h/", "/api/v1/watch/programs")
    assert _no_double_slash_after_scheme(url)
    assert url == "https://h/api/v1/watch/programs"


def test_join_keeps_query_and_never_adds_slash_before_it():
    url = ep.joinUrl("https://h/", "/api/v1/watch/plan?program=a%2Fb")
    assert url == "https://h/api/v1/watch/plan?program=a%2Fb"
    assert "/?" not in url


def test_join_empty_base_is_empty():
    assert ep.joinUrl("", "/api/v1/watch/programs") == ""


def test_join_empty_path_is_base():
    assert ep.joinUrl("https://h/", "") == "https://h"


def test_join_after_normalize_never_double_slashes():
    for raw in ("https://h/", " https://h// ", "HTTPS://h\t"):
        url = ep.joinUrl(ep.normalizeBaseUrl(raw), ep.HEALTH_PATH)
        assert url == "https://h/api/v1/watch/health"
        assert _no_double_slash_after_scheme(url)


# --------------------------------------------------------------- candidates

def test_candidates_order_learned_configured_baked():
    assert ep.candidates("https://a", "https://b", "https://c") == [
        "https://a", "https://b", "https://c"]


def test_candidates_dedupe_after_normalize():
    assert ep.candidates("https://a/", " https://a", "HTTPS://a") == ["https://a"]
    assert ep.candidates("https://b", "https://a", "https://b/") == [
        "https://b", "https://a"]


def test_candidates_drop_empties_and_invalid():
    assert ep.candidates(None, "", "https://c") == ["https://c"]
    assert ep.candidates("http://evil", "  ", None) == []
    assert ep.candidates(None, "https://b/", "https://b") == ["https://b"]


# ---------------------------------------------------- follow / retry / next

_CODES = [200, 204, 301, 307, 308, 400, 404, 422, 500, 503, -300, -104, -1001, 0]


@pytest.mark.parametrize("code", _CODES)
def test_should_follow_only_3xx(code):
    assert ep.shouldFollow(code) is (code in (301, 307, 308))


@pytest.mark.parametrize("code", _CODES)
def test_is_retryable_everything_but_2xx(code):
    assert ep.isRetryable(code) is (code not in (200, 204))


def test_follow_boundaries():
    assert ep.shouldFollow(300) and ep.shouldFollow(399)
    assert not ep.shouldFollow(299) and not ep.shouldFollow(400)
    assert not ep.isRetryable(299) and ep.isRetryable(199) and ep.isRetryable(300)


def test_next_index():
    assert ep.nextIndex(0, 3) == 1
    assert ep.nextIndex(1, 3) == 2
    assert ep.nextIndex(2, 3) == -1
    assert ep.nextIndex(0, 1) == -1
    assert ep.nextIndex(0, 0) == -1


# ------------------------------------------------------------- describeCode

@pytest.mark.parametrize("code, text", [
    (200, "ok"),
    (204, "ok"),
    (301, "301 redirect"),
    (307, "307 redirect"),
    (308, "308 redirect"),
    (400, "400 rejected"),
    (404, "404 rejected"),
    (422, "422 rejected"),
    (500, "500 server error"),
    (503, "503 server error"),
    (-300, "network timeout (phone)"),
    (-1001, "https required"),
    (-104, "phone offline"),
    (-101, "no connection"),
    (-2, "network error"),
    (-403, "network error -403"),
    (0, "not tried"),
])
def test_describe_code_exact(code, text):
    assert ep.describeCode(code) == text


# ----------------------------------------------------------- parseDiscovery

def test_parse_discovery_valid():
    assert ep.parseDiscovery(
        {"backend": "https://them-pda-classifieds-experts.trycloudflare.com/"}
    ) == "https://them-pda-classifieds-experts.trycloudflare.com"


def test_parse_discovery_missing_key():
    assert ep.parseDiscovery({"url": "https://h"}) == ""


def test_parse_discovery_non_string_value():
    assert ep.parseDiscovery({"backend": 42}) == ""
    assert ep.parseDiscovery({"backend": None}) == ""
    assert ep.parseDiscovery({"backend": ["https://h"]}) == ""


def test_parse_discovery_null_and_string_body():
    assert ep.parseDiscovery(None) == ""
    assert ep.parseDiscovery('{"backend": "https://h"}') == ""


def test_parse_discovery_invalid_url():
    assert ep.parseDiscovery({"backend": "http://h.example"}) == ""
