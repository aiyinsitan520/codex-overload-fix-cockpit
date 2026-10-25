#!/usr/bin/env python3
"""Summarise a relay.log: request volume, retries, and size-vs-attempts.

Usage:
    python analyze_log.py relay.log
    python analyze_log.py relay.log --since "2026-10-23 18:00"
"""

import argparse
import re
import statistics
import sys
from collections import OrderedDict

LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \[(\d+)\] (.*)")
SIZE = re.compile(r"\((\d+)B\)")

BUCKETS = [
    ("<100 KB", 0, 100_000),
    ("100-200 KB", 100_000, 200_000),
    ("200-500 KB", 200_000, 500_000),
    (">500 KB", 500_000, float("inf")),
]


def parse(path, since=None):
    """Return {port: {start, size, attempts, outcome, retry_kinds}}."""
    reqs = OrderedDict()
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = LINE.match(line.rstrip("\n"))
            if not m:
                continue
            ts, port, msg = m.groups()
            if since and ts < since:
                continue
            if msg.startswith("POST /responses"):
                s = SIZE.search(msg)
                reqs[port] = {
                    "start": ts,
                    "size": int(s.group(1)) if s else 0,
                    "attempts": 0,
                    "ok": 0,
                    "giveup": 0,
                    "kinds": [],
                    "model": _field(msg, "model"),
                }
                continue
            rec = reqs.get(port)
            if rec is None:
                continue
            if msg.startswith("attempt"):
                rec["attempts"] += 1
                if "ok, streaming" in msg:
                    rec["ok"] += 1
                elif msg.startswith("giving up"):
                    rec["giveup"] += 1
                else:
                    rec["kinds"].append(_kind(msg))
            if msg.startswith("giving up"):
                rec["giveup"] += 1
    return reqs


def _field(msg, name):
    m = re.search(name + r"=([^ ]+)", msg)
    return m.group(1) if m else None


def _kind(msg):
    if "http 429" in msg:
        return "429"
    if "server_is_overloaded" in msg or "server_overloaded" in msg:
        return "overload"
    # cockpit edition: the pool-cooldown short-circuit is a 503 that came back
    # in microseconds. It is not an upstream answer, so it is counted apart.
    if "pool cooling" in msg:
        return "cooling"
    if "stream error" in msg or "connect/read error" in msg:
        return "conn"
    if "http 5" in msg:
        return "5xx"
    return "other"


def report(reqs):
    if not reqs:
        print("no /responses traffic found")
        return

    total_att = sum(r["attempts"] for r in reqs.values())
    retries = total_att - len(reqs)
    giveups = sum(r["giveup"] for r in reqs.values())

    kinds = {}
    for r in reqs.values():
        for k in r["kinds"]:
            kinds[k] = kinds.get(k, 0) + 1

    print(f"requests       {len(reqs)}")
    print(f"attempts       {total_att}")
    print(f"retries        {retries}")
    print(f"gave up        {giveups}")
    if kinds:
        print("retry reasons  " + ", ".join(f"{k}={v}" for k, v in sorted(kinds.items())))
    first = next(iter(reqs.values()))["start"]
    last = list(reqs.values())[-1]["start"]
    print(f"window         {first}  ->  {last}")
    print()

    print(f"{'request body':>14} {'n':>4} {'attempts/request':>27} {'mean':>6} {'worst':>6}")
    print("-" * 62)
    for name, lo, hi in BUCKETS:
        att = [r["attempts"] for r in reqs.values() if lo <= r["size"] < hi]
        if not att:
            continue
        spread = " ".join(str(a) for a in sorted(att))
        if len(spread) > 25:
            spread = spread[:22] + "..."
        print(f"{name:>14} {len(att):>4} {spread:>27} {statistics.mean(att):>6.2f} {max(att):>6}")
    print()

    heavy = sorted((r for r in reqs.values() if r["size"] > 500_000),
                   key=lambda r: -r["size"])
    if heavy:
        print("requests over 500 KB:")
        for r in heavy:
            model = r["model"] or "?"
            print(f"  {r['start']}  {r['size']:>9,} B  {r['attempts']}x  {model}")
        print()

    slow = sorted(reqs.values(), key=lambda r: -r["attempts"])[:5]
    print("worst retry counts:")
    for r in slow:
        if r["attempts"] <= 1:
            continue
        print(f"  {r['start']}  {r['size']:>9,} B  {r['attempts']}x  "
              f"({', '.join(r['kinds']) or 'n/a'})")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", nargs="?", default="relay.log")
    ap.add_argument("--since", help='only lines at or after this timestamp, e.g. "2026-10-23 18:00"')
    args = ap.parse_args()
    try:
        report(parse(args.log, args.since))
    except FileNotFoundError:
        print(f"no such file: {args.log}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
