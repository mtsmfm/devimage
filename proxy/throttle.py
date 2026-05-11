"""Per-host outbound rate limiting + malware blocklist for devimage.

Loaded by mitmproxy in the throttle service (compose.throttle.yml).

- Sliding-window rate limit per destination host. Over-limit requests
  sleep instead of erroring, so well-behaved agents naturally
  backpressure (and badly-behaved ones don't amplify via retries).
- Blocklist fetched from URLhaus on startup and refreshed every 6h;
  matching hosts get a 403.
"""
from __future__ import annotations

import asyncio
import logging
import time
import urllib.request
from collections import defaultdict, deque

from mitmproxy import http

# host -> (max_requests, window_seconds). Sliding window.
LIMITS: dict[str, tuple[int, int]] = {
    # Package registries: bursty during install (npm i can fire hundreds
    # of requests in seconds). Cap loose so normal dev work isn't broken.
    "registry.npmjs.org":     (3000, 60),
    "pypi.org":               (3000, 60),
    "files.pythonhosted.org": (3000, 60),
}
# 600 req / 5 min ≈ 2 req/s sustained, with room for short bursts.
DEFAULT: tuple[int, int] = (600, 300)

BLOCKLIST_SOURCES = [
    # URLhaus (abuse.ch): malware distribution & C2 hosts. CC0, daily.
    "https://urlhaus.abuse.ch/downloads/hostfile/",
]
BLOCKLIST_REFRESH_SECONDS = 6 * 3600

log = logging.getLogger("throttle")
_hits: dict[str, deque[float]] = defaultdict(deque)
_blocked: set[str] = set()


def _suffix_walk(host: str):
    """Yield host and each parent zone, stopping before the bare TLD.

    For "a.b.example.com": "a.b.example.com", "b.example.com", "example.com".
    """
    parts = host.split(".")
    for i in range(len(parts) - 1):
        yield ".".join(parts[i:])


def _lookup_limit(host: str) -> tuple[int, int]:
    # Most-specific match wins because we walk leaf → root.
    for cand in _suffix_walk(host):
        if cand in LIMITS:
            return LIMITS[cand]
    return DEFAULT


def _is_blocked(host: str) -> bool:
    return any(cand in _blocked for cand in _suffix_walk(host))


def _parse_hosts_file(text: str) -> set[str]:
    out: set[str] = set()
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        # hosts format: "0.0.0.0 example.com" or "127.0.0.1 example.com".
        # Plain "example.com" lines are accepted too.
        host = line.split()[-1].lower()
        if "." in host and host not in {"localhost", "broadcasthost"}:
            out.add(host)
    return out


def _fetch(url: str) -> str:
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read().decode("utf-8", errors="replace")


async def _refresh_blocklist() -> None:
    while True:
        merged: set[str] = set()
        for url in BLOCKLIST_SOURCES:
            try:
                text = await asyncio.to_thread(_fetch, url)
                entries = _parse_hosts_file(text)
                merged |= entries
                log.info("blocklist: fetched %d entries from %s", len(entries), url)
            except Exception as e:
                log.warning("blocklist: failed to fetch %s: %s", url, e)
        if merged:
            _blocked.clear()
            _blocked.update(merged)
            log.info("blocklist: %d total entries active", len(_blocked))
        await asyncio.sleep(BLOCKLIST_REFRESH_SECONDS)


class Throttle:
    async def running(self) -> None:
        asyncio.create_task(_refresh_blocklist())

    async def request(self, flow: http.HTTPFlow) -> None:
        host = flow.request.pretty_host.lower()

        if _is_blocked(host):
            flow.response = http.Response.make(
                403,
                b"blocked by devimage throttle: known malicious host\n",
                {"Content-Type": "text/plain"},
            )
            log.info("blocked: %s", host)
            return

        limit, window = _lookup_limit(host)
        now = time.monotonic()
        q = _hits[host]
        while q and now - q[0] >= window:
            q.popleft()
        if len(q) >= limit:
            wait = window - (now - q[0])
            log.info("throttling %s: sleeping %.1fs", host, wait)
            await asyncio.sleep(wait)
        _hits[host].append(time.monotonic())


addons = [Throttle()]
